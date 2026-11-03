# Statics Lottery formal targets

> Historical verification scope: these models describe earlier candidates. The current
> optional-recipient ABI and allocations have no formal proof result. Obsolete Halmos
> harnesses and their concrete sanity controls are retained privately, outside this build.

This package defines symbolic properties over the production Lottery facets and inductive
accounting properties. Formal execution is restricted to the dedicated verification system
described in the private operator tooling. Do not install, probe, or invoke Halmos
on an ordinary development host.

Certora proof definitions and clone-to-run instructions are in
[certora/README.md](certora/README.md). Specifications, harnesses, configurations
and execution tooling are versioned; generated results, logs, counterexamples
and internal reports remain private and ignored.

## Required Halmos rules

- `check_selloutCommitmentIsStrictlyFuture`
- `check_selloutCommitmentMatchesRegistrySelection`
- `check_selloutCommitmentIgnoresCatalogChanges`
- `check_settlementConservesRevenue`
- `check_settlementPreservesPaymentTokenSolvency`
- `check_settlementRecordsOperatorAndFinalizerLiabilities`
- `check_settlementDoesNotMutateIsolatedToken`
- `check_settlementRecordsTerminalStatus`
- `check_winnerClaimCannotRepeat`
- `check_operatorFlushIsAtomicAndTokenIsolated`
- `check_cutFinalizationCannotBeReversed`

Every required rule must complete without a counterexample, timeout, unknown result, panic, or
bounded-loop warning. A compiled harness is not a proof result. Branch-feasibility pruning has a 1 ms solver budget: an unresolved branch is explored rather than discarded. Assertion solving has no timeout; all panic codes remain failures. An outer execution timeout is an incomplete run, never a pass.

- `check_deadlineCommitmentIsFutureAndFixed`
- `check_deadlineRejectsPurchasesAtOrAfterClose`
- `check_deadlineRejectsPrematureSettlement`
- `check_deadlineWinnerIsSoldAndRevenueConserved`

## Deadline model

The deadline commitment property calls the shared production scheduling helper for positive `uint32` durations and all `uint32` delays, using the deterministic Registry schedule summary. The purchase property funds and approves an exact-transfer token, executes a successful production `buyTickets` call immediately before a fixed deadline, then requires the exact `RoundExpired` error at/after it with unchanged ticket, receipt, and token balances. Its seeded initial sold/receipt history is synthetic; it proves the purchase guard, not whole-round solvency. The settlement properties call production `settleRound`, including its readiness gate, seed derivation, sold-ticket lookup, allocation, and accounting. A single cumulative ownership range contains every positive sold quantity below `uint32.max` (constrained directly with `vm.assume`, without a modulo-based input remap); the configured cap is one larger. The Registry summary supplies one canonical cached beacon after the cutoff. Token custody is abstracted for this accounting-only path. These harnesses seed reachable preconditions rather than proving the opening/purchase history; Diamond integration tests cover that history.

Harness seed/read helpers accept mapping keys as runtime parameters so the prover uses the same runtime Keccak storage representation as the production paths; hard-coded precomputed mapping hashes are not interchangeable in Halmos 0.3.3.

The removed refund-claim rule belongs to the retired API; historical reports retain that result for the original release. Current rounds have no refund transition, checked by deadline settlement assertions and stateful invariants. All remaining original properties must still pass. The original evidence files bind their original source; new candidate evidence is separate.

## Model bounds

The commitment rule calls the shared production `_commitSelloutTarget` implementation with every
`uint32` randomness delay and a deterministic Registry summary whose first round after the supplied
timestamp is exactly `timestamp + 1`. The live `_commitSellout` path resolves its Registry and delay
from the Round's
snapshotted integration and configuration before calling this same helper. The rule proves the
stored target is strictly after the supplied L2 timestamp boundary, uncached when selected, and
unchanged by later mutation of the configuration catalog. It does not prove the preceding ticket
purchase, integration-version
resolution, the one-way lifecycle gate around `_commitSellout`, or Diamond dispatch; Foundry
integration and stateful invariants cover those paths. The Registry summary does not prove
Quicknet arithmetic or cryptography; those belong to the separate `EqualFiDrandRegistry` proof
package.

The proof treats that timestamp and transaction order as EVM inputs. It does not prove wall-clock
freshness, fair ordering, or resistance to a Robinhood sequencer deliberately holding L2 time
stale. V1 accepts honest ordering and timestamp progression by the Robinhood-operated sequencer as
a target-chain trust assumption.

The settlement rules call the shared production allocation and accounting implementations for one
bounded Round. The conservation rule isolates the pure allocation helper; the state-transition
rules start the payment token and one unrelated token exactly solvent. Together they cover every
nonzero `uint64` gross amount, every valid Winner and Operator BPS value, and every `uint64`
Finalizer Tip, then prove revenue conservation, payment-token solvency,
aggregate/versioned Operator equality, and no mutation of the unrelated token's custody or
accounting. It does not prove Registry acquisition, ticket-owner lookup, or the external
`settleRound` state gate; concrete integration tests cover those paths.

The claim rules call the production `ClaimsFacet` for every nonzero `uint96` winner
amount using an exact-transfer ERC-20. They prove one successful delivery clears the matching
claim and aggregate liability, transfers the exact amount, and makes an identical second claim
fail without additional delivery.

The Operator rule calls the production `RevenueFacet` for payment and isolated-token amounts in
`[1, type(uint64).max]`. It explores both exact Router acceptance and atomic Router rejection. It
proves the payment-token liability, custody, and exact allowance either all advance together or
all remain unchanged, while the unrelated token is untouched. Router reward-index math and
Operator ownership accounting remain outside this Lottery model.

The cut rule deploys the production Diamond, `DiamondCutFacet`, and `GovernanceFacet`, installs
only the finalization selectors, finalizes once, and proves both later Diamond cuts and repeated
finalization fail while the finalized flag remains set. It does not prove governance-key honesty
or timelock liveness.

## Trusted computing base and exclusions

The proofs trust Solidity 0.8.30 compilation, Halmos EVM semantics, Keccak-256, exact behavior of
the bounded ERC-20 and external-dependency summaries, and the synthetic initial states documented
above. Direct storage seeding establishes reachable preconditions only; each claimed transition
then calls production facet code.

The package does not prove drand cryptography or network liveness, `OperatorFeeRouter` internal
distribution, arbitrary ERC-20 behavior, governance honesty, sequencer ordering or timestamp
honesty, compiler correctness, target-client correctness, or Robinhood runtime behavior. Foundry
fuzz/invariant tests, the Registry proof package, integration tests, audit review, and Robinhood
testnet validation are separate evidence.

## Additional local verification campaign

An expanded private campaign assesses production commit
`795425ef6a8830278b56b9052aa2271e92930eb3`. All workloads execute on the dedicated
verification system, including the source-built local Certora prover; there are
no hosted proof submissions. Production Solidity and compiler policy are unchanged.
The coverage summary below describes that campaign. Accepted Certora definitions
are now versioned for reproduction; internal reports, diagnostics and generated
result artifacts stay in private recoverable storage.

The expansion adds arbitrary-prior-ledger settlement conservation across all six
buckets, full production-width allocation and receipt arithmetic, full-width
claim and partial Operator-delivery transitions, surplus absorption, paid entry
and atomic sellout behavior, multiple-owner ticket boundaries, production
settlement flow, and first-post Registry composition under primitive summaries.

The paid-entry proof has two families: arbitrary prices with a three-ticket cap,
and arbitrary valid ticket quantities at price one. The production settlement
flow uses three one-ticket owners and fixed economics; separate rules prove
allocation widths and arbitrary three-range ownership boundaries. Arbitrary-ledger
transition properties assume a solvent prestate and bounded aggregate credits;
they do not establish unbounded whole-protocol history invariants. The continuation below
adds a separate inductive accounting model.

Expanded Halmos partitions use an isolated copy of version 0.3.3 with three
byte-to-bit width corrections in its SHA256/MODEXP primitive summaries. Positive
congruence and intentionally false-property controls exercise that model. The
original suites use stock Halmos. The private evidence records the precise tool
diff, binary and input hashes, verification and deployment-compilation runtimes,
compiler settings, non-vacuity checks, and per-rule outcomes. The primitive models
do not establish cryptographic security or target-client precompile correctness.

The pinned Router's existing formal suite is rerun separately with its own
Solidity 0.8.33/Cancun configuration. Deployment readiness remains separate from
these bounded formal properties. An unresolved or timed-out obligation is never
counted as a passing result, and the campaign does not constitute mainnet sign-off.

Results for this campaign:

| Suite | Passing properties | Incomplete properties |
| --- | ---: | ---: |
| Original Lottery Halmos | 15 | 0 |
| Original Registry Halmos | 34 | 0 |
| Expanded Halmos | 11 | 2 |
| Pinned Router Halmos | 5 | 0 |
| Registry local Certora | 10 | 0 |
| Expanded local Certora | 6 | 0 |
| Pinned Router local Certora | 11 | 0 |

The initial two incomplete obligations were compressed-signature first-post
acceptance and rejection composition; their full-coordinate runs exceeded the 15-minute
execution limit. The continuation below discharges both obligations. Uncompressed
first-post composition,
malformed pairing return handling, and invalid encoding rejection pass. Five
isolated mutation controls each produce the expected counterexample. Separate
concrete validation passes 130 Lottery tests, 33 Registry tests, and five expanded
tests, including four fuzz tests at 1,024 runs each.

## Inductive history and compressed-signature continuation

A private continuation uses the same production commit, compiler policy and
local-only execution environment. Production Solidity remains unchanged. The
following results supplement the preceding campaign rather than replacing its
original evidence.

| Continuation | Result |
| --- | --- |
| Production compressed first-post composition | 2 passing properties |
| Total decoder and modular composition cross-checks | 3 passing properties |
| Arbitrary-history accounting | 14 passing inductive invariants |
| Existing-round snapshot preservation | 1 passing parametric rule |
| Accounting mutation controls | 8 expected counterexamples |
| Compressed composition negative controls | 2 expected counterexamples |
| Independent width-correction calibration | 7 positive symbolic properties, 3 expected negative counterexamples, 5 concrete tests |
| Concurrent lifecycle and stateful witnesses | 5 passing concrete tests across 4 suites |

Both compressed first-post properties now pass against unchanged production
Registry and decoder code with a 30-minute execution cap. Acceptance establishes
canonical randomness and permanent cache behavior; pairing rejection leaves
storage unchanged. The rules retain full canonical coordinate widths, both sign
flags and every positive round. Neither result has a counterexample, stuck path
or bounded-loop warning. The earlier 15-minute timeouts remain historical
incomplete runs, and their two obligations are now discharged by these direct
production proofs.

Three supplementary properties prove a total full-width decoder lemma and both
posting outcomes using its established result as an input-bound summary. The
source refinement and shared input domain receive independent agent review; a
strict private gate requires the direct proofs, all three supplementary proofs
and their exact source/tool bindings.

The history model uses actual Lottery, Settlement, Claims, Revenue and Governance
facet code with shared namespaced storage. Constructor bases and preservation
across all 23 facet functions prove per-token solvency, aggregate liabilities,
receipt accounting, zero refunds, configuration economics, fresh round storage,
active counts and slot consistency. A separate parametric rule preserves existing
round snapshots. These proofs use induction without a fixed transaction count,
round count or three-round ownership bound. Production integer widths and the
intrinsic concurrency limit remain in effect.

The induction assumes exact-transfer, non-rebasing tokens, passive summarized
external dependencies and a fixed facet set. Token summaries permit donations
but omit callbacks and external balance decreases. Ticket-owner search is
abstracted, so arbitrary ownership-search correctness and winner fairness are
outside this theorem. Initialization correspondence is reviewed at source level;
Diamond dispatch and upgrades are separate obligations. The concrete witnesses
exercise the actual Diamond and concurrent two-token lifecycles; bounded stateful
runs supplement the inductive proofs.

Independent agent review qualifies the isolated Halmos width correction for the
Registry's actual nonempty SHA inputs and concrete nonzero MODEXP output lengths.
It also reproduces unsupported boundary cases. SHA256 and MODEXP remain
uninterpreted primitive functions, with canonical field outputs and successful
execution assumed. These results do not prove cryptographic arithmetic,
precompile gas behavior or target-chain implementation correctness. Independent
agent review is distinct from third-party assurance.

Private evidence retains per-rule inventories, compiler scenes, source and
specification hashes, verification/deployment-compilation runtime hashes,
configuration, tool pins, assumptions, reviews and mutation counterexamples.
Target-chain rehearsal, deployed lifecycle compatibility and mainnet readiness
remain separate release evidence.

## Ownership, initialization and callback boundary closure

A further private campaign uses the same production commit and compiler policy.
The following guarantees supplement the original accounting induction; its
frozen passive-dependency model is retained rather than relabeled as a different
proof.

Ticket-range induction establishes nonzero owners, strictly increasing full-width
endpoints, capacity and sold-ticket coverage across actual facet histories.
An exact-source loop refinement proves initialization, window preservation,
halving, convergence and unique interval membership for owner lookup. The
production endpoint width implies at most 32 search iterations, without a small
range-count bound. A separate production settlement property places the selected
ticket inside the sold range. Resource-heavy monolithic search diagnostics are
not counted as passing proofs.

Actual Diamond checks cover dispatch context, shared storage, revert propagation,
selector replacement/removal, initialization and irreversible cut finalization.
Four routing invariants hold inductively across arbitrary successful selector
operations. Reviewed source composition extends those operations to batches;
failed batches retain their prestate through EVM rollback. Initializer checks
combine actual compiled execution and all-calldata rejection guards with an
exact-source configuration-element induction. A pinned OpenZeppelin timelock
composition checks delay, cancellation, rescheduling and finalization. These
results require approved initialization and facet code: routing consistency does
not establish accounting safety for arbitrary new implementations.

Callback closure combines arbitrary-input rejection at all nine protected
entrypoints, successful guard restoration, governance callback preservation of
existing ledgers and round snapshots, and three full-width observed transfer-delta
lemmas. Separate failed-execution obligations check cross-contract rollback.
Concrete callback fuzzing and an adversarial behavior matrix supplement these
proofs. The custody bridge retains the admitted-token assumptions: truthful balance
observations, exact-transfer/non-rebasing behavior, ordinary approval semantics
and no exogenous balance decrease. Failed symbolic diagnostics are retained
separately and never counted as passing evidence.

Read-only calls against both target-network clients pass three primitive vectors
and 17 candidate verifier/Registry checks per network at recorded blocks. Both
networks also pass a concurrent-round lifecycle on pinned forks using the actual
initializer, Diamond facets, Registry and pinned Router code, including reward
claims. Native-client calls and Foundry fork execution are separate evidence;
the fork uses fixture assets and Operator identities with an explicit local time
warp. Compiler artifacts, override runtimes and result records are bound together
by strict private provenance gates and independently reviewed.

These are compositional guarantees under documented assumptions, distinct from
third-party assurance or a production deployment sign-off. Deployment-bound
runtime/configuration and authority-role verification remain release conditions.
Cryptographic security, compiler/EVM correctness, gas availability, governance
honesty, admitted-token behavior and honest sequencer time/order remain trust
boundaries. Router deployment remains outside this assessment.
