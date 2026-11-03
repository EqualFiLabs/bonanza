# Requirements Document

## Introduction

Statics Lottery is a standalone, sellout-or-deadline onchain lottery that accepts a governance-approved ERC-20 payment token configured per Round, schedules each Round at opening for a drand Quicknet beacon strictly after its sales deadline plus delay, replacing that schedule only on atomic early Sellout with a beacon strictly after sellout plus delay, and permits anyone to finalize the result once the committed beacon is available.

Each Round distributes its payment-token revenue among the winning ticket holder, the Statics Treasury, and Statics Operators. Operator revenue is contributed directly to the standalone `OperatorFeeRouter` in the same ERC-20 token used to purchase that Round's tickets.

The protocol is designed around permissionless operation and minimal administrative trust. All tunable economic and operational parameters are governance-configurable for future rounds, while each live round permanently snapshots the configuration under which users purchased tickets. Administrative changes SHALL NOT retroactively alter an existing round.

Robinhood Chain's operated sequencer and chain governance are part of the target
chain trusted computing base. V1 assumes the sequencer follows the chain's
canonical transaction-ordering and timestamp rules in good faith. The Lottery
does not claim to remain outcome-fair if that sequencer deliberately withholds or
reorders purchases, or holds back L2 time to select an already-known beacon; such
behavior violates the accepted sequencer-honesty assumption and is outside the
public-participant threat model for V1.

Randomness verification SHALL be delegated to the shared `EqualFiDrandRegistry`. Operator reward accounting SHALL be delegated to the standalone `OperatorFeeRouter`. The Lottery SHALL NOT duplicate either responsibility.

## Glossary

**Lottery**

The standalone Statics Lottery protocol.

**Round**

A single lottery instance containing a finite configured number of tickets and its own snapshotted economic and operational configuration.

**Ticket**

A non-transferable lottery entry represented by an integer position within a Round.

**Sellout**

The point at which every configured ticket in a Round has been purchased.

**Round Configuration**

The complete set of tunable values governing a Round.

**Round Configuration Version**

An immutable governance-created Round Configuration that may be enabled or disabled for opening new Rounds.

**Payment Token**

The governance-approved ERC-20 token in which a Round's ticket price, receipts, liabilities, revenue, and claims are denominated.

**Configuration Snapshot**

The immutable copy of Round Configuration assigned when a Round is opened.

**Winner Share**

The configured portion of gross Round revenue allocated to the winning ticket holder.

**Protocol Share**

The portion of gross Round revenue remaining after the Winner Share.

**Operator Share**

The configured portion of Protocol Share allocated to Statics Operators.

**Treasury Share**

The portion of Protocol Share remaining after the Operator Share.

**Finalizer Tip**

A configurable incentive denominated in the Round's Payment Token and credited from the Treasury Share to the account that successfully finalizes a Round.

**Expiration**

The sales cutoff reached when an unsold Round reaches its configured sales duration. This enables a deadline draw, not a refund.

**EqualFiDrandRegistry**

The standalone shared EqualFi infrastructure contract responsible for verifying and caching drand Quicknet randomness.

**Quicknet Round**

A specific drand Quicknet beacon round selected as the randomness source for a lottery Round, scheduled at opening and deterministically rescheduled on early Sellout.

**OperatorFeeRouter**

The standalone EqualFi contract responsible for distributing approved ERC-20 revenue assets across Statics Operator NFTs according to synchronized Operator weights.

**Pending Operator Revenue**

Operator revenue, denominated and held in a Round's Payment Token, that has been accounted for by the Lottery but has not yet been successfully contributed to `OperatorFeeRouter`.

**Terminal State**

A settled Round state from which ticket purchases can never resume. The legacy expired enum value is reserved and unreachable for new Rounds.

---

## Requirements

### Requirement 1: Governance-Configurable Lottery Parameters

**User Story:** As protocol governance, I want every tunable economic and operational lottery parameter to be configurable, so that the protocol can be adjusted without redeploying the Lottery.

#### Acceptance Criteria

1. THE Lottery SHALL maintain a governance-controlled catalog of immutable Round Configuration Versions.
2. THE configurable parameters SHALL include at minimum:
   - Payment Token;
   - ticket price;
   - ticket count;
   - Round sales duration or expiration period;
   - Winner Share;
   - Operator/Treasury allocation of the Protocol Share;
   - optional recipient address and gross-revenue allocation;
   - randomness delay following the sales cutoff (Sellout or deadline);
   - Finalizer Tip;
   - any per-purchase ticket limit;
   - the global active-Round concurrency limit.
3. WHEN a new tunable parameter affecting Round behavior is introduced, THE parameter SHALL be governed through the same configuration model rather than being permanently hardcoded unless it is a protocol invariant or external-standard constant.
4. Governance SHALL create a new Round Configuration Version rather than mutate an existing version.
5. Governance SHALL be able to enable or disable a Round Configuration Version for new Round opening without altering any existing Round.
6. THE Lottery SHALL distinguish tunable Round parameters from fixed external trust anchors or protocol constants such as basis-point denominators, cryptographic constants, and immutable external protocol dependencies.
7. THE Lottery SHALL reject configurations whose values violate required accounting, token-compatibility, or lifecycle invariants.
8. Governance SHALL be able to set a configurable parameter to zero when zero is a semantically valid value, including disabling an optional Finalizer Tip or optional per-purchase limit.
9. THE Lottery SHALL NOT require redeployment solely to add an approved Payment Token or change a tunable Round parameter for future Rounds.
10. Initial deployment defaults SHALL allocate 50% of gross receipts to the Winner, 20% to Operators, and the remainder to Treasury before the Finalizer Tip. These defaults SHALL remain governance-configurable for future Rounds.

### Requirement 2: Timelocked Configuration Changes

**User Story:** As a participant, I want parameter changes to be delayed and observable, so that governance cannot immediately change the terms of future lottery rounds without notice.

#### Acceptance Criteria

1. ALL privileged configuration changes SHALL be controlled through a timelocked governance authority.
2. THE Lottery SHALL NOT provide an alternate privileged path capable of bypassing the timelock for economic parameter changes.
3. WHEN governance creates, enables, or disables a Round Configuration Version, changes the global opening policy, or updates the current integration version, THE change SHALL govern only future Round opening and SHALL NOT alter an already-open Round.
4. THE timelock SHALL NOT be capable of rewriting a Round's existing Configuration Snapshot.
5. THE timelock SHALL NOT be capable of changing a Round's selected winning ticket or committed Quicknet Round after Sellout.

### Requirement 3: Immutable Per-Round Configuration

**User Story:** As a ticket buyer, I want the terms of my lottery round fixed when the round opens, so that later governance actions cannot change the wager I entered.

#### Acceptance Criteria

1. WHEN a Round is opened, THE Lottery SHALL snapshot every parameter that can affect that Round's Payment Token, economics, purchases, expiration, randomness commitment, settlement, or finalizer compensation.
2. AFTER a Round is opened, THE Configuration Snapshot SHALL NOT be modified.
3. WHEN the configuration catalog, enabled states, global opening policy, or current integration changes, THE change SHALL NOT alter any already-open Round.
4. Settlement SHALL use only the Round's Configuration Snapshot.
5. Deadline-draw eligibility SHALL use only the Round's Configuration Snapshot.
6. Winner, Operator, Recipient, Treasury, and Finalizer allocations SHALL use only the Round's Configuration Snapshot.

### Requirement 4: Permissionless Round Opening

**User Story:** As a protocol user, I want eligible lottery rounds to be startable without depending on an administrator, so that operation does not stop merely because an admin is unavailable.

#### Acceptance Criteria

1. WHEN the global active-Round concurrency limit permits another Round, ANY account SHALL be able to open a Round from a governance-enabled Round Configuration Version by purchasing its first ticket or tickets.
2. A newly opened Round SHALL use the caller-selected enabled Round Configuration Version.
3. THE Lottery SHALL assign each Round a unique identifier.
4. THE Lottery SHALL record the Round's opening time and expiration condition.
5. THE Lottery SHALL NOT permit opening a Round that violates the configured concurrency policy.
6. THE Lottery SHALL permit concurrent active Rounds to use different enabled Round Configuration Versions and different Payment Tokens.
7. Disabling a Round Configuration Version SHALL prevent new Rounds from opening from that version but SHALL NOT alter or pause a Round already opened from it.
8. A Round Configuration Version SHALL have at most one non-terminal Round at a time, so capacity occupied by that version always represents a Round that additional participants can join.
9. Initial deployment SHALL default to a global active-Round concurrency limit of 100. Governance SHALL retain the ability to change this limit after deployment.

### Requirement 5: Governance-Approved ERC-20 Ticket Purchases

**User Story:** As a player, I want to buy one or more lottery tickets using the Round's advertised ERC-20 Payment Token, so that the currency and exact price of my participation are fixed when the Round opens.

#### Acceptance Criteria

1. WHILE a Round is open and unexpired, A user SHALL be able to purchase one or more available tickets using that Round's snapshotted Payment Token.
2. THE required payment SHALL equal the Round's snapshotted ticket price multiplied by the requested ticket quantity.
3. THE Lottery SHALL pull the required payment from the buyer through ERC-20 `transferFrom` after the buyer has granted sufficient allowance.
4. THE Lottery SHALL verify that the buyer spent and the Lottery received exactly the required payment and SHALL reject fee-on-transfer, sender-fee, or otherwise inexact transfers.
5. THE Lottery SHALL reject purchases exceeding the number of unsold tickets.
6. IF a configured per-purchase ticket limit is enabled, THE Lottery SHALL reject purchases exceeding that limit.
7. EACH successfully purchased ticket SHALL be permanently attributed to the purchasing address for that Round.
8. V1 tickets SHALL NOT be independently transferable.
9. THE Lottery SHALL provide sufficient public state to determine how many tickets have sold and how many remain.
10. THE Lottery SHALL reject native ETH ticket payments.
11. Direct ERC-20 transfers to the Lottery SHALL NOT create tickets or purchase credit.

### Requirement 6: Efficient Multi-Ticket Ownership

**User Story:** As a player purchasing multiple tickets, I want one purchase to efficiently represent all of my entries, so that gas does not scale linearly with individual ticket storage.

#### Acceptance Criteria

1. THE Lottery SHALL support purchasing multiple consecutive ticket positions in one transaction.
2. THE Lottery SHALL record sufficient information to resolve the owner of any valid ticket position deterministically.
3. THE Lottery SHALL NOT require minting an ERC-721 or ERC-1155 token for every lottery ticket.
4. Winner lookup SHALL NOT require iterating across every ticket in the Round.
5. THE owner resolved for a winning ticket SHALL be the address to which that ticket was attributed at purchase.

### Requirement 7: Deterministic Sellout and Deadline Commitments

**User Story:** As a buyer, I want sales to close before the selected beacon becomes public, with no choice of beacon for a late finalizer.

#### Acceptance Criteria

1. AT opening, THE Lottery SHALL store the Registry-selected first Quicknet Round strictly after `expiresAt + randomnessDelay`, rejecting zero, incorrectly scheduled, or already cached targets.
2. WHILE sales remain open, purchases SHALL NOT change that deadline target unless the purchase atomically sells out the Round before its deadline.
3. AT early Sellout, THE Lottery SHALL replace the deadline schedule deterministically with the first beacon strictly after `selloutAt + randomnessDelay`, rejecting invalid or cached targets atomically with the final purchase.
4. AFTER Sellout or the sales deadline, THE target SHALL NOT be replaceable by buyers, governance configuration, finalizers, or any other ordinary call.
5. THE Registry and delay SHALL come from the Round's immutable snapshots; later catalog changes SHALL NOT affect the Round.
6. THE freshness interpretation SHALL retain the documented honest-sequencer assumption; cache absence does not establish offchain freshness against a malicious sequencer.

### Requirement 8: Shared drand Quicknet Randomness

**User Story:** As a participant, I want lottery outcomes derived from independently verifiable public randomness, so that neither the protocol nor the finalizer can choose the winner.

#### Acceptance Criteria

1. THE Lottery SHALL consume verified randomness from `EqualFiDrandRegistry`.
2. THE Lottery SHALL NOT implement a separate lottery-specific BLS verifier.
3. THE Lottery SHALL accept a Round as settleable only when the exact committed Quicknet Round has been successfully verified by the Registry.
4. IF the committed Quicknet Round is already cached by the Registry, THE Lottery SHALL be able to reuse it without requiring another BLS verification.
5. IF the committed Quicknet Round has not yet been cached, THE settlement path SHALL permit the caller to provide the proof necessary for the Registry to verify and cache it.
6. THE Lottery SHALL NOT use `blockhash`, `prevrandao`, a sequencer-provided random value, administrator-supplied entropy, or another fallback randomness source to settle a closed Round.
7. Failure or delay of the Quicknet beacon SHALL NOT authorize replacement of the committed randomness source.
8. The drand construction SHALL protect target immutability and winner derivation against public participants, relayers, finalizers, and ordinary configuration governance under the deployed code and the Robinhood-operated-sequencer honesty assumption; it SHALL NOT be represented as removing the chain sequencer's inherent ordering and timestamp influence or the separately documented pre-finalization Diamond upgrade trust.

### Requirement 9: Domain-Separated Winner Selection

**User Story:** As a participant, I want the lottery to derive its outcome specifically for this chain, contract, and Round, so that reuse of a public randomness beacon by other applications does not couple outcomes.

#### Acceptance Criteria

1. THE Lottery SHALL derive application-specific randomness from the canonical randomness returned by `EqualFiDrandRegistry`.
2. THE derivation SHALL commit to the blockchain identity.
3. THE derivation SHALL commit to the Lottery contract identity.
4. THE derivation SHALL commit to the lottery Round identifier.
5. FOR identical Registry randomness, different Lottery Round identifiers SHALL produce independently domain-separated application seeds.
6. THE winning ticket SHALL be deterministically derived from the resulting application-specific seed.
7. THE winning ticket SHALL always resolve to a valid sold ticket in the Round.

### Requirement 10: Permissionless Settlement

**User Story:** As a participant, I want anyone to be able to finalize a closed Round after randomness is available, so that payouts do not depend on an administrator or keeper.

#### Acceptance Criteria

1. WHEN the committed Quicknet randomness becomes verifiably available, ANY account SHALL be able to finalize the Round.
2. Settlement SHALL produce exactly one winning ticket.
3. Settlement SHALL be irreversible once successfully completed.
4. THE same Round SHALL NOT be successfully settled more than once.
5. Settlement SHALL NOT require authorization from governance, the Treasury, an Operator holder, or a designated keeper.
6. THE successful finalizer SHALL receive the Round's snapshotted Finalizer Tip subject to the Treasury allocation available to that Round.
7. THE Finalizer Tip SHALL NOT reduce the Winner Share.
8. THE Finalizer Tip SHALL NOT reduce the Operator Share.
9. IF the configured Finalizer Tip exceeds the Treasury allocation available for the Round, THE amount paid SHALL be limited to the available Treasury allocation rather than causing settlement to fail.

### Requirement 11: Deterministic Revenue Allocation

**User Story:** As a participant, Treasury stakeholder, or Operator holder, I want Round proceeds to be allocated according to the exact snapshotted rules, so that funds cannot be redirected after ticket sales begin.

#### Acceptance Criteria

1. WHEN a closed Round settles, THE Lottery SHALL calculate gross Round revenue from the Round's actual receipts (`ticketPrice * soldTickets`).
2. THE Lottery SHALL allocate the configured Winner Share from gross Round revenue.
3. THE Lottery SHALL allocate the Operator share of the non-winner Protocol Share and the optional Recipient share of gross receipts, then assign Treasury the remainder after booked FIDDY staker revenue.
4. THE Winner Share, Operator Share, Recipient Share, Treasury Share, and Finalizer Tip SHALL be deterministically derivable from the Configuration Snapshot and gross Round revenue.
5. THE total allocated value SHALL NOT exceed gross Round revenue.
6. THE Lottery SHALL account for rounding deterministically.
7. Any rounding remainder SHALL be assigned according to a documented deterministic rule and SHALL NOT become untracked value.
8. Governance SHALL NOT be able to redirect an already-accounted winner or Operator allocation.

### Requirement 12: Pull-Based Winner Claims

**User Story:** As a winner, I want to claim my prize after settlement without making settlement depend on my wallet's ability to receive the Round's Payment Token.

#### Acceptance Criteria

1. Settlement SHALL record the Winner Share as claimable rather than requiring successful delivery to the winner during finalization.
2. ONLY the recorded winning ticket owner SHALL be entitled to claim the Winner Share.
3. THE winner SHALL NOT be able to claim the same prize more than once.
4. A failed prize transfer SHALL NOT consume the winner's claim.
5. Settlement SHALL remain possible even when the winner is a contract that cannot receive or process the Round's Payment Token.
6. THE Lottery SHALL preserve winner liabilities until successfully claimed.

### Requirement 13: Operator Revenue Integration

**User Story:** As a Statics Operator holder, I want the lottery's Operator allocation routed through the universal Operator Fee Router, so that lottery revenue participates in the same reward accounting as other Statics revenue sources.

#### Acceptance Criteria

1. THE Lottery SHALL NOT implement per-Operator reward distribution.
2. Settlement SHALL account the Operator Share as Pending Operator Revenue denominated in the Round's Payment Token and isolated by integration version and token.
3. Settlement SHALL NOT depend on a successful call to `OperatorFeeRouter`.
4. ANY account SHALL be able to attempt to flush Pending Operator Revenue after it has been accounted.
5. WHEN Operator revenue is flushed, THE Lottery SHALL approve and contribute the same Payment Token through the supported `OperatorFeeRouter.addRewards` ingress without converting it to another asset.
6. A successful Router contribution SHALL transfer exactly the requested Payment Token amount from the Lottery to the Router.
7. IF the Operator Fee Router rejects or cannot currently accept the contribution, THE Pending Operator Revenue SHALL remain accounted and retryable.
8. A failed Operator revenue flush SHALL NOT affect winner settlement, winner claims or other finalized accounting.
9. Pending Operator Revenue SHALL NOT be withdrawable as Treasury revenue.
10. A successful flush SHALL reduce Pending Operator Revenue for only the applicable integration-version and Payment-Token bucket by exactly the amount successfully contributed.
11. THE Lottery SHALL treat incomplete Router bootstrap, an unregistered or disabled Payment Token, zero Router effective weight, Router capacity limits, token failure, and Router reversion as retryable flush failures.
12. Individual Operator entitlement SHALL be determined by the `OperatorFeeRouter` under its synchronized-weight, forfeiture, and claim rules when the contribution is accepted; the Lottery SHALL determine only the total Operator amount owed by the Round.

### Requirement 14: Treasury Accounting

**User Story:** As protocol governance, I want Treasury revenue clearly separated from player and Operator liabilities, so that only legitimately earned Treasury funds can be withdrawn.

#### Acceptance Criteria

1. THE Lottery SHALL separately account by ERC-20 token for Treasury revenue, Winner liabilities, Recipient liabilities, Finalizer liabilities, and Pending Operator Revenue. The reserved refund-liability field SHALL remain zero for new Rounds.
2. THE Treasury SHALL NOT be able to withdraw tokens backing an outstanding winner claim.
3. THE Treasury SHALL NOT be able to withdraw tokens backing an outstanding Finalizer claim.
4. THE Treasury SHALL NOT be able to withdraw Pending Operator Revenue.
5. THE Lottery SHALL permit only legitimately available Treasury revenue or provable surplus to leave through Treasury-controlled paths.
6. Treasury withdrawal authority SHALL NOT modify Round outcomes or liabilities.

### Requirement 15: Unsold Deadline Draws

**User Story:** As a buyer, I want the Round to draw at its deadline even if some tickets remain unsold.

#### Acceptance Criteria

1. AT or after the snapshotted deadline, THE Lottery SHALL reject additional purchases, including a purchase that would sell out the Round.
2. ANY account SHALL be able to call `settleRound` directly for an unsold Round after its deadline once the exact scheduled beacon is available. No prior close transaction is required.
3. THE winner SHALL be selected by `uint256(applicationSeed) % soldTickets` and resolved only among purchased tickets.
4. A one-ticket Round SHALL draw normally. Opening already requires a paid purchase, so no reachable Round has zero sold tickets.
5. THE Lottery SHALL allocate actual receipts using the snapshotted percentages and Treasury-funded tip cap. No unsold-round refund liability or purchase refund credit SHALL be created.
6. THE Lottery SHALL NOT expose `expireRound`, `claimRefund`, or `refundableAmount` in a fresh deadline-draw deployment.
7. Late settlement SHALL use the originally scheduled deadline target, including a valid previously cached beacon, without selecting a new target from the caller's timestamp.
8. THE stored unsold status SHALL remain `Open` until settlement; eligibility and purchase closure SHALL be determined from the immutable timestamp.
9. Sales duration SHALL remain a positive configurable `uint32`; 24 hours is an example, not a cap or mandatory default.

### Requirement 16: Draw Finality

**User Story:** As a participant, I want the result fixed by the sales cutoff and scheduled randomness.

#### Acceptance Criteria

1. AFTER early Sellout or the deadline, THE Round SHALL NOT be cancellable or refundable and SHALL NOT accept more purchases.
2. The effective beacon, snapshotted economics, and ticket entries SHALL remain unchanged through late settlement and configuration changes.
3. A closed Round SHALL wait for its exact committed beacon without any later-beacon or alternate-entropy fallback.
4. Pause SHALL NOT block settlement or subsequent claims and revenue delivery.

### Requirement 17: Restricted Emergency Controls

**User Story:** As a participant, I want emergency controls narrowly scoped, so that an administrator cannot use a pause mechanism to seize funds or censor completed rounds.

#### Acceptance Criteria

1. IF an emergency pause mechanism exists, THEN it MAY prevent new Round opening or new ticket purchases.
2. An emergency pause SHALL NOT prevent settlement of already-sold-out Rounds.
3. An emergency pause SHALL NOT prevent winner claims.
4. An emergency pause SHALL NOT prevent settlement of unsold Rounds after their deadline.
5. An emergency pause SHALL NOT authorize withdrawal of player or Operator liabilities.
6. An emergency pause SHALL NOT permit replacement of committed randomness.
7. Emergency authority SHALL NOT modify existing Configuration Snapshots.

### Requirement 18: Permissionless Liveness

**User Story:** As a protocol user, I want all lifecycle transitions needed to complete a Round to remain permissionless, so that the system can continue operating without an active protocol team.

#### Acceptance Criteria

1. THE Lottery SHALL NOT require an administrator to finalize a closed Round.
2. THE Lottery SHALL NOT require an administrator to settle an unsold Round after its deadline.
3. THE Lottery SHALL NOT require an administrator to enable winner claims after settlement.
4. THE Lottery SHALL permit deadline settlement in one transaction without a separate close call.
5. THE Lottery SHALL NOT require an administrator to flush already-accounted Operator revenue.
6. IF no privileged actor takes any action after a Round opens, users SHALL still have a protocol path to reach the appropriate terminal state once the objective preconditions are satisfied.

### Requirement 19: Solvency and Conservation

**User Story:** As a participant, I want the Lottery's accounting to conserve every deposited Payment Token independently, so that the contract cannot create unsupported claims, cross-subsidize tokens, or lose track of user funds.

#### Acceptance Criteria

1. FOR every Round, total distributed, claimable, refundable, Treasury-accounted, and Operator-accounted value SHALL NOT exceed the Round's Payment Token legitimately received for that Round.
2. A ticket purchase SHALL increase the Round's accounted receipts by exactly the amount paid.
3. Settlement SHALL reclassify Round receipts into deterministic liabilities and revenue buckets without creating additional principal.
4. Deadline settlement SHALL reclassify actual receipts into winner, Operator, Treasury, and finalizer allocations without creating refunds.
5. A successful winner claim SHALL reduce winner liability by exactly the amount transferred.
6. New Rounds SHALL never create refund liability or refund credits. Legacy refund storage slots SHALL remain reserved.
7. A successful Operator flush SHALL reduce Pending Operator Revenue by exactly the amount transferred into the supported Operator revenue path.
8. Treasury withdrawals SHALL reduce only Treasury-available balances.
9. Accounting for one Payment Token SHALL NOT consume, offset, or rely upon custody of another token.
10. Direct unsolicited ERC-20 transfers or forced native ETH SHALL NOT silently create lottery tickets, winner claims, or Operator entitlement.
11. THE Lottery SHALL maintain a deterministic per-token policy for provable surplus that cannot consume recorded liabilities.
12. THE Lottery SHALL classify ERC-20 surplus only through a canonical Payment Token address previously admitted by governance, and governance validation SHALL reject multiple token addresses that control the same underlying balance ledger.

### Requirement 20: Reentrancy and Failed-Transfer Safety

**User Story:** As a participant, I want external token interactions isolated from accounting updates, so that malicious tokens, receivers, or external contracts cannot corrupt Round balances.

#### Acceptance Criteria

1. External value-transfer paths SHALL be protected against reentrant double claims.
2. A failed winner transfer SHALL preserve the winner's claim.
3. A failed deadline-winner transfer SHALL preserve the winner claim.
4. A failed Treasury transfer SHALL NOT consume Treasury accounting incorrectly.
5. A failed Payment Token or Operator Fee Router interaction SHALL preserve Pending Operator Revenue.
6. A failed external call SHALL NOT permit a Round to settle twice or alter its winner.
7. User-controlled receivers SHALL NOT be able to mutate another user's entitlement through reentrancy.

### Requirement 21: Public Observability

**User Story:** As a player, integrator, or indexer, I want complete public visibility into Round state and accounting, so that lottery behavior can be independently verified.

#### Acceptance Criteria

1. THE Lottery SHALL expose the global opening policy, current integration version, every immutable Round Configuration Version, and each version's enabled state.
2. THE Lottery SHALL expose each Round's immutable Configuration Snapshot.
3. THE Lottery SHALL expose each Round's lifecycle status.
4. THE Lottery SHALL expose ticket sales progress.
5. THE Lottery SHALL expose the scheduled Quicknet Round from opening and emit every deterministic early-Sellout rescheduling.
6. THE Lottery SHALL expose the winning ticket and winner after settlement.
7. THE Lottery SHALL expose outstanding winner, Finalizer, Treasury, and Operator accounting by token needed to verify solvency, retaining the unused refund-liability field, which stays zero.
8. THE Lottery SHALL emit events sufficient for an indexer to reconstruct Round opening, purchases, Sellout, randomness commitment, settlement, claims, deadline scheduling, configuration changes, Treasury movement, and Operator revenue flushing.

### Requirement 22: External Dependency Isolation

**User Story:** As a protocol maintainer, I want the Lottery to rely on narrow external interfaces, so that randomness verification and Operator accounting remain independent reusable infrastructure.

#### Acceptance Criteria

1. THE Lottery SHALL delegate Quicknet proof verification and beacon caching to `EqualFiDrandRegistry`.
2. THE Lottery SHALL delegate Statics Operator reward distribution to `OperatorFeeRouter`.
3. Reward-enabled operation SHALL use only the generic Statics external-account lifecycle, its interface binding check and PositionNFT `ownerOf`; product custody and accounting remain in the Lottery. The Lottery SHALL NOT depend on Statics NFT transfer history.
4. THE Lottery SHALL NOT maintain its own copy of Statics Operator ownership or activation-weight accounting.
5. THE Lottery SHALL NOT maintain its own BLS12-381 verification implementation.
6. A failure in Operator reward ingress SHALL NOT block the lottery lifecycle.
7. THE Lottery's external dependency addresses and cryptographic trust anchors SHALL be treated separately from ordinary tunable Round parameters.

### Requirement 23: Robinhood Chain Deployment and Testnet Validation

**User Story:** As a protocol maintainer, I want the production design exercised on Robinhood Testnet before mainnet deployment, so that the actual randomness and lifecycle integrations are validated in the target execution environment.

#### Acceptance Criteria

1. THE Lottery and `EqualFiDrandRegistry` SHALL support deployment on Robinhood Chain.
2. THE implementation SHALL support end-to-end testing on Robinhood Testnet.
3. Testnet validation SHALL use an actual drand Quicknet beacon rather than mocked production randomness for the final integration test.
4. Testnet validation SHALL demonstrate onchain verification of a valid Quicknet proof through the shared Registry.
5. Testnet validation SHALL demonstrate a complete Round from ticket purchases through Sellout, randomness availability, settlement, and winner claim.
6. A fresh testnet rehearsal SHALL demonstrate an unsold deadline draw with a real committed beacon, actual-receipt allocations, and winner claim. Historical refund evidence SHALL NOT count as validation of the new behavior.
7. Testnet validation SHALL demonstrate that failed Operator revenue ingress does not block Round settlement.
8. Testnet validation SHALL demonstrate successful direct contribution of each exercised Payment Token to the configured Operator Fee Router integration when that dependency is available.
9. Testnet validation SHALL demonstrate concurrent active Rounds using at least two different governance-enabled Payment Tokens, including isolated purchase, settlement, claim, deadline-draw, Treasury, and Operator accounting.
10. Testnet validation SHALL demonstrate the production L2 timestamp-based target-selection path but SHALL NOT be represented as proving resistance to a malicious Robinhood sequencer.

### Requirement 24: Diamond Upgradeability and Permanent Immutability

**User Story:** As protocol governance, I want the Lottery to be upgradeable during its controlled-launch phase and capable of permanently disabling upgrades later, so that bugs and integrations can be addressed early while the protocol can ultimately become immutable.

#### Acceptance Criteria

1. THE Lottery SHALL use an EIP-2535 Diamond proxy architecture.
2. THE Lottery SHALL support adding, replacing, and removing facets while upgradeability remains enabled.
3. ALL Diamond upgrades SHALL be controlled through timelocked governance.
4. THE Lottery SHALL NOT expose an alternate privileged upgrade path capable of bypassing the timelock.
5. THE Diamond SHALL provide an irreversible mechanism for permanently disabling future Diamond upgrades.
6. ONCE permanent immutability has been activated, THE Diamond SHALL NOT permit any facet to be added, replaced, or removed.
7. THE immutability transition SHALL NOT be reversible by governance, an administrator, a guardian, or any other account.
8. ACTIVATING permanent immutability SHALL NOT disable ordinary permissionless Lottery operation.
9. ACTIVATING permanent immutability SHALL NOT prevent configuration changes that are explicitly designed to remain governable, unless governance itself has separately been disabled.
10. AN upgrade SHALL NOT modify the immutable Configuration Snapshot of an already-open Round.
11. AN upgrade SHALL NOT erase or redirect previously recorded winner claims, refund liabilities, Pending Operator Revenue, or Treasury accounting.
12. THE Diamond storage architecture SHALL preserve state compatibility across upgrades while upgradeability remains enabled.

### Requirement 25: Formal Verification of the drand Registry

**User Story:** As a Lottery participant, I want machine-checked evidence for the immutable randomness-verification boundary, so that the Registry cannot accept, misbind, or replace a Quicknet beacon without violating an explicit verified property.

#### Acceptance Criteria

1. BEFORE a production release, THE `EqualFiDrandRegistry` implementation SHALL have a versioned formal-verification package covering the source revision and compiled EVM runtime bytecode intended for deployment; the release gate SHALL confirm that the deployed bytecode matches.
2. THE formal model SHALL prove the boundary, strictly-after-supplied-timestamp minimality, ordering, and overflow behavior of `roundTime` and `firstRoundAfter` for their complete supported input domains.
3. THE formal model SHALL prove that every newly stored beacon is bound to the compiled Quicknet public key, Quicknet DST, exact encoded Round, and submitted signature point used by verification.
4. THE formal model SHALL cover all contract-side input validation and representation handling, including supported lengths, compressed-point flags and decompression, uncompressed-point decoding, infinity and field bounds, subgroup-validation calls, message serialization, precompile calldata, and precompile return-data handling.
5. SUBJECT to the documented EIP-2537 precompile model, THE formal model SHALL prove both that storage is unreachable unless the required BLS pairing verification succeeds and that a valid supported proof is stored when ordinary call preconditions hold.
6. THE formal model SHALL prove that equivalent valid 48-byte and 96-byte encodings normalize to the same canonical signature point and derive the same Round-bound randomness.
7. THE formal model SHALL prove first-write immutability: a successfully stored Round's randomness and `postedAt` never change, and any duplicate submission returns `false` without mutating that beacon.
8. THE formal model SHALL prove that no caller, owner, governance role, proxy path, or alternate entry point can bypass verification or replace a stored beacon.
9. REQUIRED proof artifacts SHALL pin the Registry source revision, compiler and settings, dependency revisions, formal tool version, specification revision, and verified runtime bytecode hash.
10. A required proof obligation SHALL NOT be reported as passing when its run times out, returns unknown, is vacuous, relies on an unconstrained success oracle, or depends on an undocumented assumption.
11. THE Registry proof report SHALL enumerate the trusted computing base and proof exclusions for its verification claim, including the EIP-2537 implementation, cryptographic assumptions, official Quicknet trust anchor, Solidity compiler, and Robinhood Chain execution environment.
12. Official Quicknet differential vectors and Robinhood runtime validation SHALL test the concrete cryptographic and precompile assumptions that the formal model abstracts; those tests SHALL be reported separately from machine-checked proofs.
13. THE project SHALL NOT describe the formal package as proving drand network liveness, threshold-operator honesty, cryptographic hardness, compiler correctness, EIP-2537 client correctness, or sequencer ordering and timestamp honesty unless those components are separately verified.
14. Lottery commitment proofs SHALL state that they establish ordering strictly after the supplied L2 timestamp boundary and exclude wall-clock freshness, fair transaction ordering, and malicious-sequencer behavior.

---

## Explicit V1 Constraints

- The Lottery uses an **EIP-2535 Diamond proxy**.
- The Diamond is upgradeable through timelocked governance during the controlled-launch phase.
- Diamond upgradeability can be **permanently and irreversibly disabled**.
- Once upgradeability is disabled, no facet can subsequently be added, replaced, or removed.
- Protocol immutability and parameter governance are separate concepts: freezing Diamond upgrades does not inherently freeze configurable parameters.
- Each Round uses one governance-approved ERC-20 Payment Token snapshotted from an immutable enabled Round Configuration Version.
- Concurrent active Rounds may use different Payment Tokens, including STATICS, USDG, or WETH.
- Native ETH is not accepted for ticket purchases.
- Tickets are non-transferable accounting entries rather than individual NFTs.
- Randomness comes exclusively from a previously committed drand Quicknet Round scheduled strictly after the L2 commitment boundary and verified by `EqualFiDrandRegistry`.
- The Round-selection freshness claim assumes honest transaction ordering and L2 timestamp progression by the Robinhood-operated sequencer; malicious behavior violates that accepted chain trust assumption.
- Sold-out Rounds have no blockhash, `prevrandao`, administrator, or alternate-RNG fallback.
- Unsold Rounds draw among sold tickets after their configured deadline and distribute actual receipts.
- Sold-out Rounds cannot be cancelled.
- Winner and finalizer payouts are pull-based.
- Operator reward distribution is handled by the standalone `OperatorFeeRouter`.
- Operator revenue is contributed directly in the Round's Payment Token without wrapping or conversion.
- Failure of Operator revenue routing cannot block settlement, claims, or revenue delivery.
- Existing Round configuration cannot be changed retroactively.
- All tunable economic and operational values are governance-configurable for future Rounds.
- The immutable drand Registry is a release-critical formal-verification target with an explicit trusted computing base and no unresolved required proof results.


### Requirement 26: Backed FIDDY and PositionNFT revenue staking

The normative FIDDY specification is [FIDDY rewards](../docs/fiddy-rewards.md).

1. Every FIDDY unit SHALL have one allocated STATICS unit of backing. Reserve funding SHALL immediately mint backed FIDDY into reward inventory. Inventory is part of supply and its STATICS backing SHALL NOT be counted twice. Participation SHALL distribute existing inventory without minting or changing backing; inventory, account custody and Payment Token liabilities remain separately accounted.
2. Participation issuance SHALL be capped by funded inventory, attributed to an explicitly selected owned PositionNFT, and independent of ticket and winner rights.
3. FIDDY transfers SHALL require an approved consumer endpoint or an exact authorized protocol movement. Approvals alone never bypass this restriction. Account withdrawals SHALL pay only the current PositionNFT owner, and protocol FIDDY payouts SHALL go only to the caller, the Treasury recipient, or the fixed Recipient snapshotted for a settled Round through its dedicated payout path.
4. Public wrap and unwrap SHALL launch independently disabled with zero public wrap capacity. Only a separately enabled unwrap burns FIDDY and releases matching STATICS.
5. Future immutable configurations SHALL snapshot reward rates and staker protocol shares without enlarging existing embedded round storage. A configuration with a nonzero staker share SHALL list its Payment Token as a revenue asset at creation, with at most 64 revenue assets ever listed.
6. Every ticket purchase SHALL book its staker share, `amount * (10000 - winnerBps) * stakerProtocolBps / 10000^2` with one floor, into the asset's revenue index, or into Treasury when total weight is zero. Settlement SHALL give Treasury the protocol remainder less the Operator share, the booked staker total, the optional Recipient share and the capped finalizer tip, and SHALL NOT call Statics or change staking state.
7. Every weight change, claim and cleanup SHALL first checkpoint the account across all listed revenue assets in the same call. Unstaking SHALL be locked for 24 hours after staking, with a stake-weighted reset on top-ups.
8. Operator boosts SHALL use unique registrations requiring ownership of both NFTs, direct activation reads and prospective explicit refresh, independent of Statics links. Every checkpoint SHALL revoke a boost whose activation multiplier fell below the stored value or whose Operator owner differs from the PositionNFT owner, forfeiting the boosted excess since the last checkpoint to other stakers.
9. Current PositionNFT ownership SHALL control account actions and legitimate historical rewards. Occupied accounts SHALL retain closure protection. Each account SHALL expose a nonce that changes on every owner action that changes it and on a boost forfeit, but not on a third-party checkpoint.
10. Zero-weight revenue and rounding dust SHALL never be captured by future entrants. Inventory, backing, account custody and reserved staker revenue SHALL be protected from surplus absorption.
11. A FIDDY-priced configuration with a nonzero Operator share SHALL require the current Router to be an approved FIDDY consumer, and Router funding in FIDDY SHALL remain retryable until it is.


### Requirement 27: Optional Round Recipient

**User Story:** As a participant, I want a round to fund a disclosed recipient under fixed terms, so that its allocation cannot be redirected after tickets are purchased.

#### Acceptance Criteria

1. THE Round Configuration SHALL include `recipientBps` applied to gross receipts and `recipient`; zero BPS SHALL disable the allocation regardless of the stored address.
2. A positive Recipient share SHALL require a nonzero address other than the Lottery Diamond; both EOAs and contracts SHALL be permitted.
3. THE Lottery SHALL reject configurations whose Winner, Operator, Recipient and configured FIDDY staker allocations exceed gross receipts, including at rounding boundaries.
4. WHEN a Round opens, THE Lottery SHALL snapshot both recipient settings and SHALL NOT allow subsequent configuration or Treasury-recipient changes to redirect its proceeds.
5. Settlement SHALL record `floor(actualReceipts * recipientBps / 10000)` as a round claim and per-token liability without interacting with the Payment Token. The Finalizer Tip SHALL NOT reduce this allocation.
6. ANY account SHALL be able to deliver the full outstanding allocation only to the snapshotted recipient, in the round's Payment Token, including while paused. The snapshotted recipient SHALL also be able to claim the full outstanding allocation to a receiver it chooses, other than the zero address or the Lottery Diamond, including while paused; no other account SHALL choose the receiver. A failed, inexact or reentrant transfer SHALL revert atomically and preserve its liability without blocking independent payouts.
7. THE Lottery SHALL include all unpaid Recipient allocations in solvency and surplus protection, expose them through existing round/accounting views, and emit settlement and delivery amounts.
8. Restricted FIDDY payouts SHALL permit this fixed-recipient protocol exit without enabling redirected winner, finalizer or staking withdrawals or unrestricted onward transfers. A recipient-directed FIDDY claim SHALL go only to the recipient itself or the Treasury recipient.
9. This greenfield release SHALL extend configuration, round and accounting structures directly. It SHALL NOT provide legacy ABI adapters, migrations or separate recipient storage domains. Existing deployment defaults SHALL leave the allocation disabled.
