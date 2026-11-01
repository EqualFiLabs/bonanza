# Operator Fee Router Integration

Statics Lottery pins the public `EqualFiLabs/operator-fee-router` implementation at
[`a6afe541c6261f1febb2eaf0f4d68ef5aa16548e`](https://github.com/EqualFiLabs/operator-fee-router/commit/a6afe541c6261f1febb2eaf0f4d68ef5aa16548e),
accepted in merged PR #1. Its contracts, tests, compiler configuration, and dependency pins are
identical to the originally reviewed `f98a17780cb250ce28f446ab54eb078512fb2e0b` snapshot; only two
README lines differ. The reachable pin restores clean checkout without changing Router behavior.
The implementation verifies both contributor spend and Router receipt during `addRewards`.

No deployment address is hard-coded in the Lottery. Each immutable Lottery integration version
pins one Router address, and each deployment manifest must identify that address, chain, runtime
code hash, and reviewed source revision. The reviewed Router repository does not yet contain a
completed mainnet deployment manifest, so this document makes no current mainnet-deployment claim.
The disposable Robinhood Testnet deployment is pinned in the
[`EqualFiLabs/operator-fee-router` rehearsal manifest](https://github.com/EqualFiLabs/operator-fee-router/blob/5454f935a2037453f5d2f819d64c864f16363df4/deployments/46630/operator-fee-router-rehearsal.json)
and cross-referenced by the Lottery deployment evidence.

Before a Round whose configuration has a nonzero Operator allocation can open, the Lottery checks
that the selected Router has completed bootstrap, has nonzero effective Operator weight, and marks
the Round's Payment Token as registered and deposit-enabled. The same conditions are checked again
before funding. When the Payment Token is FIDDY, the Router must also be an approved FIDDY consumer:
FIDDY transfers are restricted, and the Router can only pay Operators if it is approved. This rule
is enforced at configuration creation, at opening and at every funding attempt, so FIDDY Operator
revenue waits in the Lottery, retryable, rather than becoming stuck in the Router.

Settlement never calls the Router. It records Operator revenue by integration version and Payment
Token. A later permissionless flush reduces that exact liability, approves only the requested
amount, calls `addRewards`, clears the approval, and independently verifies the Lottery's spend and
the Router's receipt. Any failure reverts the entire flush, leaving the liability retryable in the
same token and integration-version bucket.
