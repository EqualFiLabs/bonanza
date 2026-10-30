# AGENTS.md

## Project Identity and Boundaries

- The product is **Statics Lottery**. `fiddy` is the workspace/repository name,
  not the protocol's user-facing name.
- Treat `specs/requirements.md`, `specs/design.md`, and `specs/tasks.md` as the
  source-of-truth specification set. Keep them synchronized when an accepted
  product or architecture decision changes.
- Preserve the single-address `StaticsLotteryDiamond` architecture. Add or
  replace behavior through facets and namespaced Diamond storage; do not create
  per-round proxies, separate ticket contracts, or separate custody contracts
  without an explicit design change.
- `EqualFiDrandRegistry` is the external randomness-verification boundary. Do
  not duplicate BLS or drand verification inside the Lottery.
- `OperatorFeeRouter` is the external Operator-allocation boundary. The Lottery
  accounts for and forwards the configured Operator share; it does not maintain
  the Router's per-Operator ownership, reward-index, or claim state. FIDDY staking
  registrations are a separate PositionNFT account concern.
- The Lottery consumes only the generic Statics external-account lifecycle and
  PositionNFT `ownerOf`; it does not read Statics NFT transfer history. Custody,
  FIDDY backing, staking and revenue stay in the Lottery. Do not add product
  callbacks or modify finalized launch dependencies.
- Do not modify sibling repositories or external deployments unless the user
  explicitly expands the scope. Inspect their live source and manifests when
  validating an integration assumption.

## Ethereum Skills

- Use the global `$security` and `$testing` skills before writing or changing
  production Solidity.
- Use `$addresses` when resolving standard protocol addresses. For EqualFi,
  Statics, drand, Router, and Payment Token deployments, verify the live source
  and deployment manifest; never guess an address.
- Use `$x-ray` when preparing the implementation for audit.
- Use `$audit` for the independent security review of a committed release
  candidate.
- Apply specialized skills proportionately. A narrow documentation or test-only
  change does not require rerunning unrelated expensive verification.
- Repository specifications, live source, deployment manifests, and this
  repository's invariants take precedence over generic skill guidance.

## Protocol Invariants

- FIDDY reserve funding follows Burntato: exact STATICS funding immediately mints
  matching FIDDY into protocol reward inventory. Ticket participation distributes
  existing inventory without minting or changing backing. Public wrap and unwrap
  have independent enable flags and both launch disabled, with zero wrap capacity.
- Governance creates immutable Round Configuration Versions and controls which
  versions may open future rounds. Opening a round snapshots its configuration,
  including its Payment Token; later governance changes must not mutate an open
  round.
- Opening from an enabled configuration is permissionless under the specified
  lifecycle rules. The opener must not be able to override the configured token
  or economics.
- Multiple rounds may run concurrently, including rounds using different
  Payment Tokens. Enforce the global concurrency limit without coupling their
  custody or accounting.
- Native ETH is not ticket principal. Reject accidental native ETH transfers.
  WETH is an ordinary configurable ERC-20 Payment Token, not a privileged path.
- Keep all principal, proceeds, liabilities, fees, claims, and solvency checks
  scoped to the round's Payment Token. One token or round must never subsidize
  another.
- Support only exact-transfer, non-rebasing Payment Tokens. Verify both sender
  spend and recipient receipt balance deltas for inbound and outbound transfers;
  reject fee-on-transfer, sender-fee, rebasing, or otherwise inexact behavior.
- A sold-out round is final: it cannot be cancelled or refunded. It proceeds to
  the configured drand round and settlement.
- An unsold round draws among purchased tickets after its configured sales deadline.
  Allocate actual receipts; never create new refund liabilities or purchase refund credits.
- Sales duration remains configurable, including week-long rounds; do not impose a 24-hour cap.
- At opening schedule the first beacon strictly after deadline plus delay. Only an
  atomic early sellout may supersede that schedule with its deterministic future beacon.
- There is no fallback randomness. A sold-out round waits for the committed
  drand round and must not switch providers, use a later round, or derive local
  entropy.
- Settlement is accounting-only. It records the winner and token-denominated
  claim liabilities without calling the Payment Token or requiring winner
  delivery, Treasury delivery, Operator Router availability, or claimant
  cooperation in the settlement transaction.
- Claims and revenue delivery are pull-based and independently retryable. A
  failed recipient or Router interaction must not reverse settlement or block
  unrelated claims.
- Pausing may stop new exposure, but must not prevent deadline draws, winner claims,
  Treasury claims, Operator funding retries, or other liability-reducing exits.
- Forward the Operator share in the same Payment Token directly to the
  configured `OperatorFeeRouter`. Do not silently swap tokens, wrap native ETH,
  or reproduce Router distribution state inside the Lottery.
- Diamond upgrades remain governed and timelocked until irreversible
  finalization. Finalization disables future Diamond cuts; it must not silently
  remove separate configuration-governance powers unless the specification says
  so explicitly.

## Naming Constraint

- Do not use workflow placeholders such as `Task`, `Task 1`, `Task (n)`, or
  similar labels in filenames, contract names, function names, test names, or
  commit messages.
- Numbered implementation checklists are allowed inside `specs/tasks.md`, but
  production and test vocabulary must describe the behavior being delivered.

## Solidity Guidance

- Preserve Diamond storage compatibility, facet selector manifests, and the
  single-address external surface when changing production contracts.
- Use explicit namespaced storage layouts and review every storage-layout or
  selector change for collision and upgrade safety.
- Follow checks-effects-interactions, use reentrancy protection on value-moving
  paths, and record claim liabilities before external calls. Rely on atomic
  rollback when an exact-transfer verification fails.
- Use `SafeERC20`-style calls together with explicit balance-delta validation;
  a successful ERC-20 return value alone is insufficient for exact accounting.
- Prefer custom errors and behavior-specific events. Events must include enough
  round, configuration, token, and amount context to reconstruct accounting.
- Do not change a production ABI width merely to work around a compiler or test
  harness issue when compatibility matters.
- Do not hard-code an address from a discussion, stale document, or unverified
  deployment note. Verify the intended chain and current deployment source.

## Compiling and Testing

- Do not use `forge build --force`, `forge build --contracts`, or `forge clean`
  as routine commands. They discard useful cache state and can make parallel
  work interfere with itself.
- Prefer focused commands such as `forge test --match-path <path>` while
  iterating, then run the complete applicable release gate on the committed
  candidate.
- Every production behavior change must include tests at the narrowest useful
  level and integration coverage for each affected value-moving lifecycle.
- Do not enable global `via_ir`, change the optimizer policy, or change the EVM
  target merely to make one file compile. Use a narrowly scoped exception only
  when necessary and document why.
- Before any RPC, fork, deployment, or live-chain check, load the operator's
  canonical private RPC environment in the same shell. Use
  `ROBINHOOD_MAINNET` or `ROBINHOOD_TESTNET` for Robinhood and never print or
  commit RPC values. Report skipped or unavailable live validation separately
  from passed local tests.
- Match validation cost to the changed behavior. Do not rerun expensive formal
  verification when the changed property is outside the model; use focused
  regression evidence and state the proof boundary accurately.

## Test Fidelity Guardrails

- Use unit harnesses for narrow branches, storage transitions, and states that
  are otherwise unreachable. Do not present harness-only evidence as proof of a
  real end-to-end flow.
- Cover each value-moving lifecycle with real ERC-20 approvals, transfers,
  balance changes, claims, and exact-delta assertions.
- Test concurrent rounds with different Payment Tokens and prove that settlement,
  deadline draws, fees, and excess-balance handling remain isolated by token and round.
- Include adversarial token tests for receiver fees, sender fees, rebasing or
  balance drift, unusual return values, and reentrant callbacks where applicable.
- Use the real `OperatorFeeRouter` and `EqualFiDrandRegistry` interfaces in
  integration tests. Mocks may cover narrow failure branches, but they do not
  establish compatibility with live deployments.
- Final testnet validation must use an actual committed drand Quicknet round and
  exercise delayed settlement, winner claims, Treasury claims, Operator Router
  funding, and unsold deadline draws.
- Fuzz and invariant tests broaden state-space coverage; they supplement rather
  than replace real lifecycle tests.
- Synthetic balance injection, direct storage mutation, and shortcut minting
  must be narrow, documented, and excluded from end-to-end confidence claims.

## Commit Discipline

- Keep commits narrow, reviewable, and independently valid. Stage explicit paths
  so unrelated dirty or untracked files are never swept into the commit.
- Use a Conventional Commit title of 72 characters or fewer. Do not mention
  workflow task numbers in the title or body.
- Use present-tense body bullets that explain what changed and why. Separate
  specification, implementation, validation, and remediation slices when that
  improves reviewability.
- Before pushing, opening a PR, or changing an external repository, confirm the
  exact `OWNER/REPO` and authorization. Never infer repository ownership from
  credentials, a checkout path, or a remote already present on the machine.
- When handing work back, include the proposed or used commit message in a fenced
  block and distinguish focused local checks from unrun, remote, fork, formal,
  or live-deployment validation.

## Compiler Resilience for Test Harnesses

- For external or public test helper and fuzz entry-point numeric parameters,
  prefer `uint256`, bound the value, then cast to the narrower production type.
  This reduces stack pressure without changing the production ABI.
- Keep helpers small and behavior-specific. If a test needs unusual compiler
  settings or synthetic setup, isolate and explain the exception rather than
  weakening repository-wide settings or production interfaces.
