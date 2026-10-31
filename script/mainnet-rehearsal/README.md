# Mainnet fork rehearsal

Run the pushed Lottery/FIDDY candidate against a pinned Robinhood Mainnet Anvil
fork. The runner is local-only: it verifies the loopback endpoint, Anvil instance,
chain ID, source block and block hash before every transaction. No mainnet signer
or deployment key is used. Existing services and occupied ports are preserved.

## Run

Requirements: Foundry with Osaka support, Python 3, and the Python packages in
`requirements.txt`. Install those in a project-local virtual environment when
needed. Initialize recursive Git submodules before building.

```sh
bash script/mainnet-rehearsal/run.sh run
# Optional: --port 8856 --fork-block <block> --seed 42 --steps 200
```

The wrapper loads the operator's canonical RPC environment. `LOTTERY_RPC_ENV`
can explicitly select another trusted RPC environment; `ROBINHOOD_MAINNET` must
be present. Private endpoints are not saved in artifacts or console output.

The default block is selected approximately 30 hours before the upstream head,
after the published mainnet drand deployment. This leaves real Quicknet proofs
available after exercising the Router's 24-hour governance delay. An explicitly
selected block must provide executable historical state and the verified drand
runtime. Provider failure is reported without silently choosing another endpoint.

Anvil remains running for inspection after success or failure. Its local URL and
the evidence directory are printed. To stop only the owned instance:

```sh
bash script/mainnet-rehearsal/run.sh stop
```

`resume` reverts the owned instance to its initial snapshot, archives the previous
attempt, records current source provenance, rebuilds, and reruns the full campaign.
It retains the original block, seed and soak length. Use a new `run` for different
parameters. `start` creates only the fork, ready for a later `resume`.

## Deployment and trust boundaries

The runner verifies mainnet runtime hashes for STATICS, WETH, Operators, the
activation registry, the Genesis vault, and the deployed drand registry against
their published manifests. It deploys the Lottery facets and initializer, an
actual Operator Fee Router with its real timelock, and the pinned Statics
PositionNFT/external-module facets with their real initializer and Diamond.
The Statics deployment covers the external-account integration surface; it is
not a deployment qualification of Statics markets, lending, or the whole stack.

Each compiler uses its own existing configuration. Builds and caches are scoped
to the run. Deployed runtimes must match those fresh artifacts; immutable regions
are checked separately through constructor bindings. Every Lottery selector is
verified against the installed facet address.

STATICS actor funding uses real ERC-20 transfers from a manifest-backed holder
impersonated only on Anvil. WETH uses real deposits from locally funded native
balances. An existing Operator is transferred by its impersonated owner and
activated through the real registry. Test-account EIP-7702 code is cleared if
present. The hostile token and flash borrower are explicitly synthetic local
fixtures. These setup assumptions are retained with each run.

## Scenarios and evidence

- Sellout and unsold deadline draws use genuine, round-matched Quicknet signatures
  verified by the deployed mainnet registry runtime. Claims, Router funding and
  Treasury delivery check exact token balance changes.
- Unauthorized governance, NFT approvals, direct protocol movements and duplicate
  claims must revert in mined transactions.
- Staking locks, weighted top-ups, Operator takeover, PositionNFT transfer,
  retrospective boost forfeiture, account nonces and cleanup execute together.
- Receiver-fee, sender-fee, blocked-transfer and reentrant fixtures prove purchase
  and claim rollback. Consumer-funded and wrap-funded same-transaction staking
  attempts must revert at the lock.
- FIDDY payment rounds cover restricted destinations, approved consumers, and
  recovery after Router consumer permission is revoked and restored.
- Governance scenarios preserve round snapshots, exercise pause-safe exits,
  add/replace/remove facet routes and irreversibly finalize upgrades.
- Same-block ordering permutes staking and purchases, PositionNFT transfer and
  revenue claims, plus final-ticket attempts and deadline settlement. Every call
  is mined in one block with its ordered receipt and expected revert trace.
- Real Quicknet abuse checks reject a signature from the adjacent round and a
  sign-bit-corrupted full-length proof, resolve competing settlements, and retry
  the originally committed beacon after a seven-day local delay.
- Statics dependency checks disable the approved FIDDY module while an account
  exits, then fill another PositionNFT to its real 64-leg capacity and require a
  first FIDDY attachment to roll back payment and account state.
- A second fully bootstrapped Operator Fee Router is registered through its own
  timelock. Rotation preserves historical liabilities, disabled deposits fail
  atomically, and partial delivery succeeds after re-enabling the new Router.
- Boundary cases cover exhausted inventory, zero stake weight, tiny receipts,
  zero/full winner allocations, concurrency limits, excess tokens and forced ETH.
- Capacity checks fund all 64 revenue assets, reject the 65th distinct asset and
  measure a full multi-asset boost forfeiture within the transaction gas budget.
- A seeded composed soak preserves accumulated state across purchases, claims,
  NFT transfers, checkpoints, funding and pauses. It finishes by closing rounds,
  claiming revenue, unstaking, unwrapping, detaching legs and reconciling liabilities.

Every scenario starts from the same post-deployment snapshot except transitions
within the composed soak, which never reset. Receipts and traces are captured
before any later snapshot rollback. Expected reverts require status zero, the
expected error selector, and unchanged financial state where applicable.
Successful-path transactions require status one. Gas is recorded in each receipt.

Accounting checks equate per-token custody with all liabilities and backing,
sum account custody and staking weights, and reconcile RAY-scaled entitlements
including dust. The selector coverage gate rejects unqueried views or missing
direct successful state-changing calls. One-time initialization and authenticated
Diamond self-calls are explicitly classified, with separate evidence.

Generated evidence, builds, logs and any internal review material stay under
the Git-ignored `.rehearsal` directory. Commit only reusable runner code and
documentation. Fork evidence does not replace CI, fuzzing or formal proofs, and
coverage of every selector is not proof of every possible state transition.

Offline runner checks:

```sh
python3 -m unittest discover -s script/mainnet-rehearsal -p 'test_*.py' -v
```
