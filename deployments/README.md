# Historical Deployment Evidence

These records predate deadline draws and the current BONANZA/recipient surface.
They preserve the original deployment identities and do not identify a current
release target. See the [release checkpoint](../docs/release-checkpoint.md).

Deployment evidence is grouped by network. Each manifest has a distinct claim boundary; no single
file establishes source provenance, initial deployment state, and the later lifecycle by itself.

## Robinhood Testnet (46630)

| Evidence | Purpose |
|---|---|
| [`lottery.json`](robinhood-testnet/lottery.json) | Lottery source/toolchain, Diamond and facet deployment, initial configuration, and external-dependency provenance |
| [`registry.json`](robinhood-testnet/registry.json) | EqualFi drand Registry runtime and concrete Quicknet verification |
| [`lifecycle.json`](robinhood-testnet/lifecycle.json) | Concurrent Payment Token Rounds, delayed settlement, claims, refunds, Router delivery/retry, upgrade preservation, and finalization |

Read [the testnet composition and provenance map](../docs/robinhood-testnet.md) for the exact split
between reused Statics Genesis contracts, freshly deployed components, exercised flows, and
untested Genesis functionality.
