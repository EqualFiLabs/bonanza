# Bonanza verification summary

Formal verification evidence applies to an exact source revision, compiler
configuration, runtime, model, and property set. A historical result does not
establish a later candidate's correctness.

## Historical coverage

| Candidate | Coverage recorded in the historical summary | Boundary |
|---|---|---|
| Lottery `795425ef6a8830278b56b9052aa2271e92930eb3` | Accounting transitions, deadline commitment and settlement, ownership lookup, Diamond routing/finalization, initialization, and callback boundaries | Different source and allocation surface from the current candidate |
| Token/rewards `de6b9b713d5de2f8e4a297e1c16a9992ecc5b3db` | Backing, custody, restricted movements, participation, staking, and bounded revenue/boost properties | Predates the optional recipient and current naming/ABI; full-width and fractional-accrual cases were not all established |
| Registry `f8db2a1752d22672d4de1708545e286a32c41497` | Quicknet representation handling, commitment arithmetic, acceptance, and immutable beacon caching | Separate dependency and cryptographic/precompile assumptions |

These entries summarize prior work; they are not new proof runs. The historical
Lottery and token results used Solidity 0.8.30. Exact compiler settings, tool
versions, runtime hashes, property inventories, assumptions, and per-rule outcomes
remain bound to the privately retained evidence.

## Current candidate

Historical results do **not** qualify the optional recipient allocation, current
ABI and storage layout, renamed release, or two-step authority handover. No current-candidate formal sign-off
is asserted here. Compilation, tests, CI, fork execution, and live deployment
checks are separate evidence, as described in the
[release checkpoint](../docs/release-checkpoint.md).

The models rely on documented exact-transfer token behavior, dependency
summaries, initialization assumptions, and property-specific bounds. They do
not establish cryptographic hardness, compiler or client correctness, gas
availability, governance honesty, network liveness, or honest sequencer ordering
and timestamp progression. Timeout, unknown, vacuous, or incomplete obligations
are not passing results.

Specifications, harnesses, prover configuration, execution tooling, generated
results, and internal review material are retained privately. Only this summary
is maintained in version control.
