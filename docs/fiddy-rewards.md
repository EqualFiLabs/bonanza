# FIDDY rewards

## Token and custody

FIDDY is the Lottery Diamond's restricted ERC-20, backed one-for-one in STATICS
base units. Following Burntato's reserve model, exact STATICS funding immediately
allocates backing and mints matching FIDDY into protocol reward inventory. Participation
credits those existing FIDDY units to a canonical PositionNFT account, reducing inventory
without changing supply, backing or the Diamond's ERC-20 balance. Inventory exhaustion
credits only available units, reports the shortfall and creates no debt. Reserve funding
remains available with public conversions disabled and grants the funder no withdrawal right.

Ordinary transfers require either endpoint to be an explicitly approved consumer.
There is no implicit governance exemption. Exact protocol movements handle account
deposits and withdrawals; raw transfers into custody do not credit accounts. External
FIDDY can be deposited into an owned PositionNFT. Unstaked account FIDDY can be withdrawn
only to the current PositionNFT owner, who is the caller. Approval does not confer account
authority. Consumer approval does not confer mint, redemption or reserve authority.
Revocation affects future ordinary transfers; consumers are trusted integration contracts
and must not trap their users' holdings. No AMM is installed by this extension.

Winner, finalizer-tip, staker revenue and recipient-directed claims in FIDDY go to the caller or
the governance Treasury recipient. Treasury delivery goes to its configured recipient. The dedicated Round
Recipient payout goes only to that Round's snapshotted recipient. Other Payment Tokens keep their arbitrary receiver
semantics. Unwrapping pays STATICS and keeps its receiver parameter.

PositionNFT sales transfer FIDDY account ownership. The dedicated Round Recipient payout
also permits the configured revenue allocation without an approved consumer. Account balance, stake, stake lock, registration and accrued revenue all
follow the PositionNFT.

Wrap and unwrap launch independently disabled, with zero public wrap cap. When
explicitly enabled, wrapping pulls exact STATICS, credits an owned account and
increments public-wrap outstanding. Unwrapping burns unstaked account FIDDY and
returns exact STATICS; outstanding decreases by min(redemption, outstanding).
Participation issuance consumes no public wrap capacity. Unwrap does not change
the cap. No arbitrary inventory/backing withdrawal or unbacked mint exists.

## Configuration and participation

Reward settings are immutable per-version state and separately snapshotted per round.
Configurations created without reward settings have no rewards. The optional Recipient
is embedded directly in the current configuration and Round snapshot types; this release
uses a fresh deployment ABI and storage layout.
New reward configurations require explicit rates/splits and start disabled.
The 50% winner baseline remains; no illustrative staker split is a launch choice.

Creating a reward configuration with a nonzero staker share lists its Payment Token as a
revenue asset if it is not already listed. At most 64 revenue assets can ever be listed;
the 65th distinct asset reverts `RevenueAssetLimitReached`. Listing never loops over
configurations, and an asset is always listed before its revenue index can first move.

A configuration priced in FIDDY with a nonzero Operator share is rejected unless the current
integration's Operator Fee Router is an approved FIDDY consumer, because the Router must be
able to pay Operators. The same rule is checked again before opening and before every Router
funding attempt; funding stays retryable and FIDDY waits in the Lottery until it passes.
FIDDY as a Payment Token is not planned for launch.

Both opening (including its initial purchase) and later buying accept explicit
PositionNFT selection. Reward-enabled configurations cannot use accountless
entrypoints. Tickets and winner claims remain wallet-owned under existing semantics.
Participation has no buyer-side minimum issuance. A buyer can receive zero FIDDY when
inventory is exhausted. A minimum can be added with a facet cut before finalization.

## Revenue allocation

Ticket sales are final; there is no refund or cancellation path. The staker share of each
purchase is therefore known when the purchase is made, and it is booked immediately with
one rounding step:

```text
share = amount * (10000 - winnerBps) * stakerProtocolBps / 100000000
```

`winnerBps` comes from the round's configuration snapshot and `stakerProtocolBps` from its
FIDDY snapshot. Every purchase path books the share: `openRound`, `openRoundForPosition`,
`buyTickets` and `buyTicketsForPosition`. The purchase adds `amount - share` to round escrow
and records `share` against the round. When total stake weight is positive, the share is
reserved and added to the asset's revenue index; division dust follows the dust rule below.
When total weight is zero, the share goes to Treasury and emits `FiddyZeroWeightRevenue`.
Otherwise `FiddyRevenueBooked` reports the round, asset, amount, total weight and new index.

Settlement computes the winner, Operator, Recipient and finalizer amounts from aggregate receipts:

```text
winner    = floor(receipts * winnerBps / 10000)
protocol  = receipts - winner
operator  = floor(protocol * operatorProtocolBps / 10000)
staker    = sum of booked purchase shares for the round
recipient = floor(receipts * recipientBps / 10000)
finalizer = min(finalizerTip, protocol - operator - staker - recipient)
treasury  = protocol - operator - staker - recipient - finalizer
```

Escrow is released by `receipts - staker`. Settlement emits `StakerRevenueSettled` with the
round's booked staker total. It neither reads nor calls Statics, and it does not change
FIDDY staking state. The sum of per-purchase floors never exceeds the floor of the aggregate,
and `protocol - operator >= receipts * (10000 - winnerBps) * stakerProtocolBps / 10000^2`
whenever the Operator and staker BPS sum to at most 10000. The staker total is therefore
always covered. The additional combined bound
`recipientBps * 10000 <= (10000 - winnerBps) * (10000 - operatorProtocolBps - stakerProtocolBps)`
also reserves the gross-based Recipient share.

Because revenue accrues at purchase, a stake added just before settlement earns nothing from
earlier purchases.

## Staking

Staked FIDDY stays in the account's custody balance; available FIDDY is balance minus stake.
Base weight equals stake. Revenue indexes are per asset and global. An account's accrual is
`weight * (index - paidIndex)` with fractional remainders retained per account.

Before any weight change, and in claim and cleanup, the account is checkpointed across every
listed revenue asset in the same call. There is no paging and no global synchronization.
`checkpointFiddyAccount(id)` is permissionless and takes no work limit. Its purpose is to let
anyone trigger the boost check below.

### Unstake lock

`STAKE_LOCK` is 24 hours. Each account stores a stake start time. On a stake of `amount`:

```text
prior      = staked
credit     = prior == 0 ? 0 : min(now - stakeStart, STAKE_LOCK)
stakeStart = now - floor(prior * credit / (prior + amount))
```

Rounding down only lengthens the lock. This mirrors the weighted reset in Statics'
`LibGlobalRewards._increasePending`. A large top-up on an old small stake relocks almost
fully. `unstakeFiddy` reverts with `StakeLocked` until `now >= stakeStart + STAKE_LOCK`.
A partial unstake leaves the start time unchanged. The lock stays with the PositionNFT when
it is sold. The lock exists to stop flash-funded and same-transaction self-rebate stakes; it
is not a vesting schedule.

## Operator boosts

One Operator may register to one PositionNFT and vice versa. Registration requires that the
caller owns both the PositionNFT and the Operator NFT, that `boostsEnabled` is on, and that
the registry multiplier is within [10000, 12500]. The account stores that multiplier and its
weight becomes `staked * multiplier / 10000`. Activation alone does not increase weight;
re-registering refreshes the stored multiplier. Statics linking is unrelated.
`boostsEnabled` gates new registrations only; disabling it does not revoke existing boosts.

If the Operator is registered to another account, registration checks that account's boost.
An invalid boost is forfeited and cleared first. A valid one makes registration revert
`OperatorAlreadyRegistered`.

### Validity by direct reads

The Genesis activation registry only raises tiers through `activate`, and every
owner-changing Genesis transfer deletes the tier through `onGenesisTransfer`. A registered
boost is invalid if either:

- `multiplierBps(operatorId)` is lower than the stored multiplier, which means the Operator
  NFT changed hands; or
- the Operator NFT's `ownerOf` differs from the PositionNFT's `ownerOf`, so selling the
  position drops the boost.

A higher multiplier is not a transfer; the stored value is kept until the owner re-registers.
Every checkpoint of a registered account checks validity before booking accrual. That covers
claim, stake, unstake, `checkpointFiddyAccount`, register, remove and cleanup, so a stale
boost never becomes claimable. `indexedFiddyRevenue` reports the post-forfeit amount.

### Forfeit

When the boost is invalid, for each listed asset:

1. Split the accrual since `paidIndex` into a base part `staked * delta` and an excess
   `(weight - staked) * delta`, both RAY-scaled.
2. Credit the base part to the account with the usual remainder handling.
3. Redistribute the excess to the other stakers:
   `index += excess / (totalWeight - accountWeight)`, with the division remainder handled as
   dust. With no other weight, the excess goes to Treasury.
4. Set the account's `paidIndex` to the index after redistribution, so it receives no part
   of its own forfeit.

The registration and the Operator mapping are then cleared, weight returns to stake, total
weight is updated and `FiddyBoostForfeited` is emitted per asset with the forfeited amount.
The forfeit covers the whole boosted excess since the account's last checkpoint, including
excess earned before the transfer. Excess booked by a checkpoint before either NFT changes
hands is kept.

**Accepted residual.** Selling the Operator NFT, buying it back and re-activating it to the
same tier, all between two checkpoints, is not detected.

## Account nonce

Each account has a `uint64` `nonce`, exposed through `fiddyAccount(id)`. It increments on
every owner action that changes the account: deposit, withdraw, wrap, unwrap, stake, unstake,
claim with a nonzero payout, register, remove, cleanup and participation credit. It also
increments on a boost forfeit. A third-party checkpoint that only books accrued revenue does
not increment it, so it cannot be used to cancel a seller's listings. A PositionNFT market
can condition orders on this nonce together with Statics' `stateNonce`.

## Account authority and lifecycle

Financial actions require current `ownerOf`, never NFT approvals. One aggregate FIDDY
external leg attaches atomically with the first financial state and remains while the account
holds tokens, stake, a registration or entitlement. NFT transfer changes financial control and
carries prior rewards without moving reserves. The seller must claim before sale if desired.
Unstaking does not redeem underlying.

Cleanup checkpoints the account, requires zero balance, stake and whole claims for every
listed asset, surrenders only sub-unit fractions as dust, clears any registration and detaches
the leg. No whole claim or FIDDY balance is erased to detach a leg.

Global division dust is separately reserved and never reinjected into indexes; whole units of
dust move to Treasury. All payment assets remain independent.

## Integration, trust and release boundaries

Pin the generic Statics candidate at
a43eb11c10afc0d9107c7881210dc4bf87cf6e3e for actual-source tests. The Lottery uses only the
Statics external account lifecycle (`attachExternalAccountLeg`, `detachExternalAccountLeg`),
the `supportsInterface` binding check at initialization, and `ownerOf`. It does not read the
Statics NFT transfer history, and it adds no product callbacks. The shared interface has seven
lifecycle/discovery selectors and ERC-165 ID `0x2795ac62`; the former eleven-selector ID
`0x6a782754` is not accepted for new bindings. Matching interface deployment and Statics module
approval are prerequisites for new accounts. Existing FIDDY financial storage, revenue indexes,
boost rules and account nonces require no migration from this ABI change. This dependency pin
is a local integration candidate, not evidence of a production upgrade.

Trust assumptions:

- Exits (withdraw, unwrap, unstake and claim) depend on Statics only through PositionNFT
  `ownerOf`. Statics is upgradeable by its own governance; a broken `ownerOf` would block
  account actions. This is accepted.
- Registered accounts additionally read the Genesis collection's `ownerOf` and the activation
  registry's `multiplierBps` at every checkpoint. At the pinned candidate both contracts are
  non-upgradeable and the Genesis collection has no burn, so these reads cannot revert for a
  registered Operator.
- Settlement depends on neither.

Lottery governance retains configuration, consumer and conversion permissions, and
pre-finalization upgrade power. Accounts and actions are public and directly callable
without a relayer. Chain ordering and token operational assumptions remain those of the base
Lottery. Existing source licensing is unchanged.

Wrap, unwrap and consumer approval launch disabled. They are optional future switches that may
never be enabled. Unwrapping by anyone reopens public wrap capacity; the cap limits outstanding
public wraps, not total wrapped supply. Every unit stays fully backed either way.

Actual-candidate local integration and block-pinned fork evidence are separate from
deployment. This extension authorizes no live transactions or conversion activation.

### Formal verification summary

These results apply only to the historical candidate below. They do not cover the optional
recipient allocation or the current ABI and storage layout.

A candidate-bound campaign supplements the historical reports. It binds production source at
`de6b9b713d5de2f8e4a297e1c16a9992ecc5b3db`, tree
`3276d74d4f88c8a39087bddfd17ed40c613a6d8f`, to Solidity 0.8.30 and these deployed-bytecode
SHA-256 hashes:

```text
FiddyStakingFacet  426f1d1f92597ed28efd25083578e8dc92457ee05578ab564bf8f2e833879280
FiddyTokenFacet    b84177b385fe3b706ecf0621032a222aa433de3d6d5d1f368b395af2e5eb7d8c
LotteryFacet       376a1ab2a9b55b424f27fc6b7ffe852eaf9863c28d36505a9d7b76daefe826d6
RevenueFacet       36891f8a1582f9050e15b32af4ebb4fa0240c18bbc1b88a40d8f6239ec3e4547
SettlementFacet    f4bdc1a9ad4569711eb4e07c0abe6357b7210431b066a9160934653a2f6360a7
```

Certora verifies the following production transitions:

- reserve funding, participation, public wrap and unwrap preserve one-to-one backing and move
  supply, inventory, custody and outstanding wrap accounting together;
- every FIDDY Payment Token category is counted once and surplus absorption cannot consume any
  category;
- initialization binds once, preserves legacy state, leaves every optional feature disabled,
  rolls back invalid bindings and uses a namespace distinct from existing Lottery storage;
- allowance cannot bypass restricted transfer rules, consumers cannot withdraw protocol custody,
  and exact protocol movement capabilities reject mismatch, replay, external callers and leaked
  authorization after revert;
- PositionNFT transfer preserves account state while moving authority, failed attachment and
  detachment roll back atomically, cleanup rejects whole claims and surrenders only sub-unit dust;
- reward snapshots are immutable, issuance is inventory-capped without debt, opening and later
  participation use equivalent snapshots, repeat asset listing is idempotent and the 65th distinct
  revenue asset is rejected;
- bounded stake-lock rules prove first-stake initialization, safe timestamp conversion, no lock
  shortening and immediate relocking for nonzero top-ups when prior stake is at most `uint128`.
  Three additional nonvacuous rules establish that the canonical one-billion STATICS supply is
  below `uint128`, and that the production stake and unstake entry points preserve this bound from
  any account state where stake does not exceed its cap-bounded balance;
- booking and zero-accrual boost forfeiture conserve reserved plus Treasury value, while full-width
  settlement rules prove the per-purchase staker bound, aggregate settleability, five-way
  allocation conservation and escrow reclassification without double counting;
- six nonvacuous compositional rules cover nonzero boost forfeiture for one listed asset with
  `uint32` primary stake, other stake and excess weight, where excess is at most 25% of base and the
  index delta is exactly one RAY. They prove the seeded ledger is conserved, the forfeiter retains
  base accrual, excess routes to Treasury when no other weight exists or redistributes only to other
  weight otherwise, the forfeiter cannot share its redistribution, and the post-state remains
  conserved.

The unconstrained full-width `uint256` stake-lock theorem remains open as robustness beyond the
deployment invariant, rather than as a reachable-state gap. The reachable-state conclusion assumes
the immutable canonical STATICS supply of `1_000_000_000 ether` and the separately verified FIDDY
backing and account-balance conservation properties. Its combined Halmos campaign did not finish
within 2,100 seconds, and two isolated partition checks each reached a separate 600-second bound. A
full-width Certora attempt was also excluded because its reported traces explicitly identified
bitwise-model imprecision in the 512-bit `Math.mulDiv` path; both reported examples passed when
replayed against compiled Solidity. Arbitrary nonzero index magnitudes and fractional dust in boost
forfeiture also remain outside the new compositional proof. Concrete nonzero-accrual boost, booking
and settlement fuzz controls passed 1,024 runs each. The formal models use deterministic
exact-transfer token and PositionNFT peers; the 64-asset boundary is unrolled through its required
exit check. Certora CLI 8.18.0 uses the pinned prover revision
`f5f77783430449791186f7812ebd53addf22cabd` with Z3 4.16.0. Generated specifications, logs and
reports remain in private evidence; this section is the versioned summary.

## Client and deployment preparation

Install token, staking and view selector groups together with the updated purchase,
governance, settlement and surplus facets. Use the current configuration, Round and accounting
types directly for a fresh deployment. Reward settings use their existing separate namespace;
recipient fields are embedded in the existing Lottery types.

The deployment script initializes FIDDY in the same transaction as the Diamond cut through
`LotteryInit.initializeWithFiddy`, binding STATICS, the PositionNFT, the Operator collection
and the activation registry. It reads the PositionNFT address from
`LOTTERY_FIDDY_POSITION_NFT`; initialization verifies its code and module interface and reverts
the whole cut otherwise. A freshly deployed Diamond therefore reports STATICS's decimals
immediately. Initialization enables no reward configuration. Both conversions, wrap capacity, boosts and external consumer
approval launch at zero/false. Statics governance must separately approve the Diamond as an
external account module before the first account attaches.

Clients read `fiddyReserve`, `fiddyAccount`, `fiddyOperatorAccount`, `fiddyAsset`,
`fiddyCredit`, `indexedFiddyRevenue`, `fiddyStaking`, `fiddyRoundRevenue` and
`fiddyRevenueAssets`. Account balance includes raw stake; available FIDDY is balance minus
stake. The unlock time is `stakeStart + 24 hours`. Claims remain available during pause.

Run the independent pinned Statics build before FIDDY tests, then the ABI parity check:

```sh
forge build --config-path integration/foundry.toml
forge build
python3 script/check-statics-abi.py
forge test --match-path 'test/Fiddy*.t.sol'
```

The Statics fixture uses its compiler/EVM/optimizer settings and local launch funding. FIDDY
tests deploy its resulting artifacts with their actual bytecode. These local fixtures are
distinct from block-pinned live dependency qualification. Neither executes a deployment
transaction.

Fork qualification uses Robinhood L2 block 101439372, hash
`0x81582e4e3659a1e4ad74399fc8ea090acfe2878468029d7dedf3f54e5ec988f4`. Its `NUMBER` opcode
returns L1 block 26303058. The test performs only local fork impersonation and candidate
creation; it does not broadcast. Runtime code hashes are checked against the pinned deployment
manifest before the registry handoff.

The optional round recipient is a fixed protocol payout destination for FIDDY-priced rounds.
It does not relax ordinary FIDDY transfers or receiver restrictions on other claim paths.
Recipient, Operator and configured staker allocations must fit the non-winner budget.
