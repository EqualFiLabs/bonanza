# Payment Token Accounting

Statics Lottery accounts independently in each Round's ERC-20 Payment Token. It does not normalize
decimals, quote values in USD, swap assets, or privilege WETH. Every ticket price, claim, fee, and
surplus amount is expressed in the selected token's base units.

## Supported token policy

Governance may configure an ERC-20 only when it has one canonical ledger address and is expected
to remain:

- exact-transfer in both directions;
- non-rebasing and balance-stable outside explicit transfers;
- compatible with `SafeERC20` calls and repeated balance queries; and
- operational for claims and Router/Treasury delivery.

Runtime code checks each transfer, but it cannot prove future behavior. Token upgrades, fees,
rebases, pauses, blocklists, callbacks, or alternate facades over the same ledger remain governance
and monitoring concerns. The complete admission policy is in
[payment-token-policy.md](payment-token-policy.md).

Native ETH is not a Payment Token. The Diamond rejects ordinary native transfers. WETH is an
ordinary configurable ERC-20; forced native ETH is tracked only as separate Treasury surplus.

## Per-token accounting

For each admitted token address `asset`, the Diamond stores:

| Field | Meaning |
|---|---|
| `activeRoundEscrow` | Ticket receipts still backing open or sold-out Rounds |
| `winnerLiability` | Settled proceeds not yet claimed by winners |
| `recipientLiability` | Settled round allocations not yet delivered to their fixed recipients |
| `refundLiability` | Reserved legacy slot; zero for fresh deadline-draw deployments |
| `finalizerLiability` | Recorded settlement tips not yet claimed |
| `pendingOperatorRevenueTotal` | Operator proceeds not yet accepted by a Router |
| `treasuryAvailable` | Treasury proceeds or absorbed surplus not yet delivered |

The recorded amount for one token is:

```text
accounted(asset) =
    activeRoundEscrow
  + winnerLiability
  + recipientLiability
  + refundLiability
  + finalizerLiability
  + pendingOperatorRevenueTotal
  + treasuryAvailable
  + fiddyRevenueReserved(asset)
  + (asset == STATICS ? fiddyBacking : 0)
  + (asset == Diamond ? fiddyInventory + fiddyAccountCustody : 0)
```

For a compatible canonical token, the solvency condition is:

```text
IERC20(asset).balanceOf(StaticsLotteryDiamond) >= accounted(asset)
```

Every mapping key is the Round's snapshotted Payment Token. A WETH Round cannot debit a STATICS
liability, and one token's excess balance cannot satisfy another token's shortage.

## Purchase accounting

For ticket quantity `q`:

```text
amount = ticketPrice * q
```

Before calling the token, the transaction records:

```text
share = floor(amount * (10000 - winnerBps) * stakerProtocolBps / 100000000)  // 0 without FIDDY rewards
round.soldTickets                  += q
round.receipts                     += amount
stakerAccrued[round]               += share
assetAccounting[token].activeRoundEscrow += amount - share
fiddyRevenueReserved(token)        += share   // or treasuryAvailable += share at zero stake weight
```

The staker share is final at purchase because tickets are never refunded. Escrow therefore holds
only the part of receipts still to be allocated at settlement, and reserved staker revenue holds
the rest until stakers claim it.

It then calls `transferFrom(buyer, Diamond, amount)` and measures four balances:

```text
buyerBefore - buyerAfter       == amount
diamondAfter - diamondBefore   == amount
```

Both equalities are required. Receiver-fee, sender-fee, rebasing, balance-drift, false-return, or
otherwise inexact behavior reverts the complete transaction, including the earlier storage writes.
A direct token transfer to the Diamond never creates tickets or participant claims.

## Successful settlement

Let `gross = round.receipts` and `D = 10_000`:

The deployment defaults are 50% Winner, 20% Operators and the remaining 30% Treasury
before the Finalizer Tip and integer rounding. They use `winnerBps = 5000` and
`operatorProtocolBps = 4000`, because the Operator percentage applies to the Protocol
Share after the Winner allocation. For 100 units received and a 1-unit Finalizer Tip,
the allocations are 50 Winner, 20 Operators, 29 Treasury and 1 Finalizer.

After deployment, the authority can call `createLotteryConfig` with new economics,
enable that version through `setLotteryConfigEnabled`, and disable older versions
for new openings. Existing Rounds retain their snapshots and original payouts.
These configuration powers remain available after `finalizeProtocol` disables
Diamond upgrades. Historical deployment manifests retain their original settings.

```text
winner       = floor(gross * winnerBps / D)
protocol     = gross - winner
operator     = floor(protocol * operatorProtocolBps / D)
staker       = stakerAccrued[round]   // sum of per-purchase shares; 0 without FIDDY rewards
recipient    = floor(gross * recipientBps / D)
treasuryGross = protocol - operator - staker - recipient
finalizer    = min(finalizerTip, treasuryGross)
treasury     = treasuryGross - finalizer
```

The final subtraction gives all division remainder to Treasury. The exact conservation identity is:

```text
winner + operator + recipient + staker + treasury + finalizer == gross
```

Settlement performs only storage reclassification:

```text
activeRoundEscrow                              -= gross - staker
winnerLiability                               += winner
recipientLiability                            += recipient
round.recipientClaimable                      = recipient
pendingOperatorRevenue[integration][token]    += operator
pendingOperatorRevenueTotal                   += operator
treasuryAvailable                             += treasury
finalizerCredits[token][settler]              += finalizer
finalizerLiability                            += finalizer
```

It does not call the Payment Token, winner, Treasury recipient, or Operator Router. A blocked
recipient or unavailable Router therefore cannot prevent the Round from becoming `Settled`.

## Unsold deadline accounting

At the sales deadline an unsold Round stops accepting tickets, then settles using its recorded beacon and the same allocation formula. `gross = ticketPrice * soldTickets`, not the configured ticket cap. The winner is selected among sold tickets only. One-ticket Rounds follow the same percentages and Treasury-funded tip cap.

No timeout refund is available, and new purchases never write refund credits. The unused refund ledger fields remain in their historical positions for layout compatibility; the new public surface omits expiry/refund selectors. Existing historical deployments are not migrated by this change.

## Winner and finalizer claims

The recorded winner alone may claim `round.winnerClaimable`, but may select any nonzero receiver
other than the Diamond. Finalizer tips are aggregated by token and finalizer address. Each claim:

1. reads the caller's recorded credit;
2. sets that credit to zero;
3. decreases the matching per-token aggregate liability;
4. transfers the exact amount; and
5. verifies Diamond spend and receiver receipt.

The shared Diamond-wide reentrancy guard covers every value-moving claim. Atomic rollback preserves
the entitlement if the receiver or token interaction fails.

## Operator revenue

Operator proceeds remain bucketed by both the Round's snapshotted Integration Version and Payment
Token:

```text
pendingOperatorRevenue[integrationVersion][asset]
```

The per-token aggregate changes by the same amount on every settlement and flush. A caller cannot
flush more than the selected bucket. Before delivery, the Lottery rechecks Router bootstrap,
positive synchronized weight, asset registration, and deposit enablement.

Delivery uses an exact temporary allowance:

1. decrement the version/token bucket and aggregate liability;
2. force-approve the configured Router for exactly `amount`;
3. call `addRewards(asset, amount)`;
4. clear the allowance; and
5. require exact Lottery spend and Router receipt.

Any readiness, token, allowance, or Router failure reverts the whole transaction and preserves the
pending liability for retry. The Lottery never swaps, wraps, or converts the Operator share.
Individual Operator entitlement begins only after the Router accepts the contribution and applies
its own then-current synchronized weights. See
[operator-router-integration.md](operator-router-integration.md).

## Treasury accounting

`flushTreasury(asset, amount)` is permissionless, but its receiver is always the current
governance-configured Treasury recipient. The caller cannot redirect it. The function caps `amount`
at `treasuryAvailable`, decreases that field before interaction, and requires an exact outbound
transfer. Winner, finalizer, and Operator liabilities are never Treasury-withdrawable. The reserved refund-liability field remains protected in solvency accounting and stays zero for new Rounds.

Changing the Treasury recipient affects later delivery of already-recorded Treasury funds, but it
does not change any participant or Operator entitlement.

## Surplus

For a governance-admitted canonical token:

```text
availableSurplus(asset) = max(balanceOf(Diamond) - accounted(asset), 0)
```

Any account may absorb that amount into `treasuryAvailable`; a later Treasury flush performs the
actual transfer. Arbitrary unadmitted addresses are rejected before a balance query. Absorption
cannot decrease or reclassify participant or Operator liabilities.

The address-based model cannot discover that two token addresses control the same underlying
ledger. Governance and deployment validation must never admit both aliases. This is an explicit
offchain admission invariant, not an onchain guarantee.

Forced native ETH is separate. `flushNativeSurplus` sends the Diamond's native balance only to the
configured Treasury recipient and never touches ERC-20 accounting.

## Evidence

The following layers exercise the accounting model independently:

- unit and integration tests cover exact ingress/egress, fee and sender-fee tokens, rebasing or
  drift behavior, deadline draws, claims, Router rollback, surplus, and same-ledger aliases;
- fuzz and stateful invariant tests cover revenue conservation, solvency, terminal monotonicity,
  concurrent Rounds, and cross-token isolation;
- the Lottery Halmos report proves bounded allocation/accounting transitions, claim
  non-repeatability, Operator flush atomicity, and isolated-token non-mutation; and
- The historical [`deployments/robinhood-testnet/lifecycle.json`](../deployments/robinhood-testnet/lifecycle.json)
  records concurrent WETH and STATICS Rounds whose claims, refund, Treasury proceeds, and Operator
  funding return the Diamond's recorded liabilities and token balances to zero.

Proof scope and exclusions are described in the
[formal coverage summary](../formal/README.md). Detailed execution reports and
generated proof results are retained privately.

The historical lifecycle and original proof report do not establish the deadline-draw candidate. New live testnet execution remains pending; candidate formal evidence is recorded separately.

## FIDDY accounting

FIDDY supply equals allocated STATICS backing, including preminted reward inventory.
Prefunding pulls exact STATICS, allocates backing and mints matching FIDDY into inventory.
Participation moves existing FIDDY from inventory to account custody without changing supply
or backing. Inventory is a subset of supply, not additional STATICS liability. Public
wrap moves exact STATICS into backing and creates account custody; unwrap burns unstaked account
FIDDY and releases exact STATICS. External transfers change neither backing nor supply. Total
account balances (including stake) equal `fiddyAccountCustody`; stake is not counted a second time.

Staker revenue is booked at purchase. With positive total weight the share is added to
`fiddyRevenueReserved(asset)` and to the asset's index; with zero weight it goes to Treasury.
Escrow and reserved revenue therefore both change at purchase, and settlement releases only
`receipts - stakerAccrued` from escrow. Claims reduce reserved. Whole units of index division
dust reduce reserved and increase Treasury. A forfeited boost excess moves between accounts
through the index, or to Treasury when no other weight exists; it never leaves reserved
otherwise. Each account retains fractional entitlement while active. Explicit empty-account
cleanup surrenders only fractions below one base unit. Historical fractions and index dust never
enter a later index.

For each asset, reserved revenue equals the sum over accounts of claimable revenue, retained
fractions and unbooked index accrual, plus global dust:

```text
reserved * RAY == sum(claimable * RAY + remainderRay + weight * (indexRay - paidIndex)) + dustRay
```

Winner = floor(receipts * winnerBps / 10000). The Operator amount is a floored fraction of the
protocol remainder. The staker amount is the sum of per-purchase floors, which never exceeds the
protocol remainder less the Operator amount. The Recipient receives a floored fraction of gross
receipts. Treasury receives the rest after Recipient revenue and the capped finalizer tip.
The combined configuration bound reserves room for all three allocations. Configurations without
FIDDY rewards have zero staker share.

For a FIDDY payment round, ticket escrow and all claims move existing supply; reward inventory,
account custody and reserved FIDDY revenue are counted alongside ordinary Lottery liabilities.
FIDDY payouts go only to the caller, the Treasury recipient, or the snapshotted Round Recipient
through its dedicated payout path. STATICS liabilities count
allocated backing once, without adding inventory again. Exact Router funding uses a single-use
protocol movement and clears its allowance, and requires the Router to be an approved FIDDY
consumer so it can pay Operators. Approved consumer status never permits raw transfers into
protocol custody or redemption.

Historical formal reports do not cover FIDDY. Current evidence consists of focused tests, stateful
conservation, actual-candidate integration, and separately reported fork qualification.


## Optional fixed recipient

Each configuration directly specifies `recipientBps` (of gross receipts) and `recipient`.
Zero BPS disables the allocation; positive BPS requires a nonzero address other than the Diamond.
The round snapshots both settings, so governance cannot redirect its allocation. Defaults remain
disabled. For a 50% Winner / 2.5% Operators / 45% recipient split, use 5000 winner BPS,
500 Operator protocol BPS and 4500 recipient BPS, with zero staker BPS. Treasury receives the
remaining 2.5% before the finalizer tip. Integer division may add dust to Treasury.

Config creation validates the recipient budget alongside the full configured staker share:
`recipientBps * 10000 <= (10000 - winnerBps) * (10000 - operatorProtocolBps - stakerProtocolBps)`.
The Operator and staker protocol BPS must also sum to at most 10000. Existing zero-weight staker
routing to Treasury and purchase-time booking remain unchanged.

Anyone may call `flushRecipientRevenue(roundId)` to send the entire unpaid allocation to that
round's fixed address. It uses the original Payment Token, remains available during pause, and
cannot redirect or double-pay a claim. Exact-transfer failures revert atomically. Winner,
Treasury, finalizer and Operator payouts remain independent. FIDDY uses a fixed-recipient protocol
exit; the receiver's ordinary transfers remain restricted. Recipient liabilities are excluded
from absorbable surplus. This release requires fresh deployment; historical validators retain
their deployment-specific tuple layouts.
