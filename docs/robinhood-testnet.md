# Historical Robinhood Testnet Composition and Provenance

The Robinhood Testnet deployment on chain `46630` is a disposable integration rehearsal for
an earlier Bonanza Lottery release. It combines existing Statics Genesis replica
contracts with freshly deployed Lottery, drand Registry, and Operator Fee Router
components. It did not replay the Statics Genesis launch.

These records predate deadline draws and the current BONANZA/recipient surface.
Original manifest names, hashes, and transactions are preserved as historical
evidence. See the [release checkpoint](release-checkpoint.md) for current status.

## Provenance map

| Component | Origin in this rehearsal | Canonical evidence |
|---|---|---|
| Genesis Operator collection | Reused | [`EqualFiLabs/statics` rehearsal manifest](https://github.com/EqualFiLabs/statics/blob/31e870900615197277bcccef6bfdb06dba452930/deployments/robinhood-testnet-46630-rehearsal-20260903T033729Z.json) |
| Genesis activation registry | Reused | Same Statics manifest and runtime hash pinned in [`lottery.json`](../deployments/robinhood-testnet/lottery.json) |
| Genesis Operator vault | Reused | Same Statics manifest and runtime hash pinned in `lottery.json` |
| WETH and STATICS | Reused | Same Statics manifest; admitted as ordinary Lottery Payment Tokens |
| EqualFi drand Registry | Fresh | [`registry.json`](../deployments/robinhood-testnet/registry.json) |
| Operator Fee Router and testnet admin | Fresh | [`EqualFiLabs/operator-fee-router` deployment manifest](https://github.com/EqualFiLabs/operator-fee-router/blob/5454f935a2037453f5d2f819d64c864f16363df4/deployments/46630/operator-fee-router-rehearsal.json) |
| Historical Lottery Diamond, facets, and initializer | Fresh | [`lottery.json`](../deployments/robinhood-testnet/lottery.json) |

The Statics manifest is pinned at commit
`31e870900615197277bcccef6bfdb06dba452930`, and identifies Genesis replica source commit
`43018f109006aa2c2eef2808adc2aa74dfc9a6d4b`. The Router deployment evidence is pinned at commit
`5454f935a2037453f5d2f819d64c864f16363df4`; the deployed production Router bytecode comes from
source commit `f98a17780cb250ce28f446ab54eb078512fb2e0b`.

This provenance pass also corrects the activation registry runtime hash previously transcribed in
the Lottery evidence. Live bytecode and the pinned Statics manifest both hash to
`0xc4bf24efb6c99c95060186a30200b7ee952604d77b917d0dae2cde87e6419e82`.

The chain-guarded Router admin replaces the production 24-hour timelock only for this rehearsal.
The Lottery also uses one disposable testnet EOA across operational roles. Neither arrangement is
a production governance recommendation.

## What the rehearsal exercised

The committed deployment and lifecycle evidence establishes:

- the recorded runtime hashes and successful deployment/configuration receipts;
- Router bootstrap across Operator IDs 1 through 5,555 and registration of WETH and STATICS;
- concurrent Lottery Rounds whose principal and accounting stay isolated by Payment Token;
- a sold-out Round committed to an actual future drand Quicknet Round and settled after the
  committed beacon became available;
- winner, finalizer, and Treasury claims, plus an expired unsold Round's refunds;
- failed Operator funding that preserved the Lottery liability, followed by successful same-token
  delivery into the Router for both WETH and STATICS; and
- Diamond storage preservation across an upgrade, irreversible code finalization, and continuing
  post-finalization Lottery operation.

## What it did not exercise

Reusing the Genesis contracts does not make the Lottery rehearsal evidence for the full Statics
Genesis launch. In particular, this rehearsal did not exercise:

- the Genesis launch distributor's sale, allocation, or claim ceremony;
- Genesis pool creation, launch-liquidity initialization, or price discovery;
- Statics Diamond behavior, staking, borrowing, flash loans, or other Statics protocol modules; or
- downstream claims by individual Operators after the Router accepted Lottery funding.

Those claims remain governed by the Statics and Router repositories' own source, manifests, tests,
and review evidence.

## Validation boundary

[`validate-robinhood-testnet-lottery.sh`](../script/validate-robinhood-testnet-lottery.sh) checks the
Lottery deployment manifest against live chain ID, bytecode, Diamond selectors, initial state,
external dependency state, and recorded receipts. It now also checks every pinned Statics Genesis
dependency hash and the manifest's internal dependency wiring.

[`validate-robinhood-testnet-lifecycle.sh`](../script/validate-robinhood-testnet-lifecycle.sh)
reconciles the later lifecycle manifest. The Router repository separately validates its complete
bootstrap and deployment receipt history. Explorer source verification was intentionally waived
for these throwaway deployments; runtime hashes and exact source/toolchain pins are the evidence
boundary.

## Fresh deadline-draw rehearsal (pending)

The historical Diamond was finalized; do not point new scripts at it. The revised lifecycle script requires `LOTTERY_DIAMOND` for an explicitly verified fresh deployment. Existing token, Registry, and Router addresses must be revalidated before any authorized broadcast. Deployment remains guarded to chain 46630 and the dedicated testnet signer. No new transaction is authorized or claimed by the deadline-draw PR.

Run `PrepareConcurrentTestnetRounds` against the fresh Diamond, settle its sold-out WETH Round through `SettleWethTestnetRound`, and settle the unsold STATICS Round through `SettleDeadlineTestnetRound` after its recorded deadline beacon is available. Supply that exact beacon's `QUICKNET_SIGNATURE` and `LOTTERY_ROUND_ID`. Continue the sold-out STATICS and upgrade/finalization steps, then use the deadline script again for the post-finalization partial Round. The finalizer must be the sole buyer in these rehearsal scripts so winner claims can be exercised by the dedicated signer.

Keep the two-minute rehearsal configuration for practical execution; this is not a production-duration default. Record new receipts, opening/sellout scheduling logs, actual receipts, sold-ticket outcomes, claim balances, and runtime hashes in new manifests, preserving the historical files. Validators accept an explicit manifest path. The lifecycle validator permits an omitted `lifecycleModel` only for the pinned historical `deployments/robinhood-testnet/lifecycle.json`; other historical manifests must explicitly select `legacy`. Missing, unknown, or invalid models fail before any RPC call. For a new lifecycle manifest set `lifecycleModel` to `deadline-draws`, include `deadlineDrawRoundIds`, and include a Quicknet record for every exercised draw. The validator checks opening-schedule logs, cutoff arithmetic, sold-ticket selection, and claim/accounting reconciliation.
