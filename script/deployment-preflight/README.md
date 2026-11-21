# Fresh-deployment dependency preflight

This read-only command checks an explicitly prepared manifest against one RPC
block before a **fresh** Bonanza deployment. It checks that the selected block's
hash is unchanged after all reads and pins every code and view read to that hash
using EIP-1898. It sends no transaction and reads no private key. It does not
deploy a Diamond or qualify one after deployment.

## Prepare a manifest

Create a private JSON file with the following shape. Replace every placeholder
with an address or runtime code hash verified from the intended chain's source
and deployment manifest. Do not commit private RPC endpoints or unreviewed
deployment choices.

```json
{
  "chainId": 4663,
  "contracts": {
    "registry": {"address": "<address>", "runtimeCodeHash": "<hash>"},
    "statics": {"address": "<address>", "runtimeCodeHash": "<hash>"},
    "positionNFT": {"address": "<address>", "runtimeCodeHash": "<hash>"},
    "router": {"address": "<address>", "runtimeCodeHash": "<hash>"},
    "operatorCollection": {"address": "<address>", "runtimeCodeHash": "<hash>"},
    "activationRegistry": {"address": "<address>", "runtimeCodeHash": "<hash>"},
    "operatorVault": {"address": "<address>", "runtimeCodeHash": "<hash>"},
    "authority": {"address": "<address>", "runtimeCodeHash": "<hash>"}
  },
  "rewardAssets": ["statics"],
  "minimumAuthorityDelaySeconds": 86400
}
```

`rewardAssets` names every payment token intended to carry a nonzero Operator
share. Use `[]` if no configuration has an Operator share. Add each token to
`contracts` with its verified address and runtime hash. Router bootstrap,
effective weight, and reward-asset readiness are checked only when this list is
nonempty; Router code and bindings are always checked.
The `authority` must expose the OpenZeppelin-style `getMinDelay()` view. Set the
minimum to the governance delay approved for this deployment; the example's
value is illustrative, not a launch decision. If another governance executor is
intended, review its actual delay and execution path separately rather than
weakening this check.

## Run

Use the canonical private RPC environment in the same shell, as required by
`AGENTS.md`. For Robinhood Mainnet this is `ROBINHOOD_MAINNET`. Do not print the
RPC value.

```sh
python3 -m pip install -r script/mainnet-rehearsal/requirements.txt
python3 script/deployment-preflight/preflight.py \
  --manifest /private/path/bonanza-preflight.json \
  --rpc-env ROBINHOOD_MAINNET
```

The command exits `0` only when every check passes, `1` for a failed onchain
check, and `2` for invalid input or a missing RPC variable. It checks the chain,
each expected runtime hash, the Statics external-account interface on the
PositionNFT, Router bindings and reward-asset readiness, and the authority's
minimum delay. All code and view reads use the selected block hash with
`requireCanonical`; an endpoint that rejects EIP-1898 hash-pinned reads fails
the preflight. A changed block hash also fails. RPC URLs and transport
exception text are not printed.

This preflight does not establish that a proxy implementation or governance
configuration cannot later change. Before broadcast, review upgrade powers,
the authority's proposer/executor permissions and actual scheduling path,
payment-token behavior, candidate artifacts, metadata, and target-chain
dependencies. After deployment, verify the installed Diamond selectors, runtime
hashes, configuration, roles, and full-match explorer source. The
[release checkpoint](../../docs/release-checkpoint.md) lists the broader release
conditions; the [fork rehearsal](../mainnet-rehearsal/README.md) covers a local
candidate execution path.

Offline tests:

```sh
python3 -m unittest discover -s script/deployment-preflight -p 'test_*.py' -v
```
