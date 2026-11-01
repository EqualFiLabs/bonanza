# Implementation Plan: FIDDY participation rewards

1. Specify backed FIDDY, approved consumers, PositionNFT authority and purchase-time staker revenue.
2. Add namespaced token/reserve state, exact funding/conversions and consumer permissions.
3. Extend immutable configurations and both purchase entrypoints with account attribution.
4. Book staker revenue at every purchase, list revenue assets at configuration creation (at most 64), and settle the booked staker total without calling Statics.
5. Add staking with complete one-call checkpoints across all revenue assets and a 24-hour unstake lock with a stake-weighted reset.
6. Add unique Operator registration validated at every checkpoint by direct activation and ownership reads, forfeiting invalid boost excess to other stakers.
7. Restrict FIDDY withdrawals to the PositionNFT owner and FIDDY payouts to the caller, Treasury or the dedicated snapshotted Round Recipient, and require a consumer Router for FIDDY-priced Operator revenue.
8. Expose a per-account nonce for PositionNFT market buyer protection.
9. Initialize FIDDY in the same transaction as the deployment Diamond cut.
10. Qualify real shared integration, storage upgrades, adversarial assets and economic conservation; commit the candidate, review locally, remediate and update the feature PR with terminal CI evidence.

No chain deployment, public conversion activation, AMM construction or sibling-repository modification is included. Existing historical proof results do not cover this extension.

- [x] Mint fully backed FIDDY reward inventory at reserve funding, distribute existing units for participation, and protect inventory from surplus without double-counting STATICS backing.
- [x] Book staker revenue at purchase and remove the Statics transfer-history dependency.
- [x] Lock unstaking for 24 hours with a stake-weighted reset on top-ups.
- [x] Validate Operator boosts by direct reads and forfeit invalid boost excess.
- [x] Restrict FIDDY payouts and require a consumer Router for FIDDY Operator revenue.
- [x] Expose the per-account nonce.
- [x] Initialize FIDDY with the deployment Diamond cut.


## Optional round recipient (Requirement 27)

- [x] Extend existing configuration/snapshot, round claim and per-token accounting structures directly; update creators, initialization builders and selectors (27.1, 27.4, 27.9).
- [x] Validate recipient addresses and combined Operator/staker/recipient budgets; allocate and reserve actual receipts with Treasury-funded capped tips (27.2, 27.3, 27.5).
- [x] Add permissionless fixed-recipient delivery with exact-token checks, pause-safe retry, FIDDY isolation, events and surplus protection (27.6, 27.7, 27.8).
- [x] Retire obsolete ABI upgrade fixtures and preserve historical formal material privately; add current-ABI lifecycle, hostile-token, fuzz and stateful conservation coverage (27.3-27.9).
- [ ] Complete focused checks, local review/remediation and terminal PR CI. Existing formal evidence does not establish recipient behavior.
