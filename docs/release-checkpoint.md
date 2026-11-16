# Bonanza release checkpoint

This page separates the current source candidate from historical deployment and
verification evidence. It does not assert production readiness.

## Current source

The current candidate includes deadline draws, backed BONANZA inventory and
PositionNFT accounts, staking and Operator boosts, and optional round-recipient
allocations and two-step authority handover. It uses Bonanza/BONANZA names and
the matching current ABI.

This is a fresh-deployment candidate. Historical finalized Diamonds are not
updated by the source changes. Clients must use the matching interfaces,
selectors, events, and configuration types.

## Evidence boundaries

| Evidence | Meaning for this candidate |
|---|---|
| CI | Builds, formatting, lint, ABI parity, tests, Slither, and runner safety for the exact commit that completed the workflow |
| Local tests | Executed cases under their fixtures and inputs; environment-gated fork tests may be skipped |
| Fork rehearsal | Local execution against a pinned chain state when actually run and recorded; the runner's presence is not an execution result |
| Formal verification | Historical results apply to their original candidates and models; see the [summary](../formal/README.md) |
| Committed testnet manifests | Historical deployment and lifecycle evidence; they do not qualify the current ABI or economics |

The complete suite and static analysis run in
[CI](https://github.com/EqualFiLabs/bonanza/actions/workflows/ci.yml). A green run
for an earlier commit does not establish a later commit's validation state.

## Historical testnet records

The [deployment index](../deployments/README.md) and
[testnet provenance guide](robinhood-testnet.md) describe the original Robinhood
Testnet rehearsal. That deployment predates deadline draws and the current
BONANZA/recipient surface. Its refund transactions describe the retired lifecycle;
current rounds have no cancellation or refund path.

The recorded Lottery source is
`bdd725d809d16812ab910e5add937d76223814c6`. Deployment manifests retain the exact
original names, addresses, selectors, hashes, and transactions as historical
records. They are not current deployment targets.

## Deployment conditions

A release needs validation of the exact candidate, target-chain dependencies,
runtime hashes, selector installation, token admission, and governance roles.
The external authority must supply the intended timelock; Diamond finalization
disables code changes while leaving configuration governance available.

Deployment artifacts must retain embedded IPFS compiler metadata and CBOR.
Effective build settings and the exact artifacts require inspection before
broadcast; full-match explorer verification is required before activation.
Historical proof results, local fixtures, or testnet role choices do not satisfy
these deployment conditions.

The normative behavior remains in the [requirements](../specs/requirements.md)
and [design](../specs/design.md). Read the [governance](governance.md),
[accounting](accounting.md), and [randomness](randomness.md) guides for the
associated trust boundaries.
