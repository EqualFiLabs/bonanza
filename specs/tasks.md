# Implementation Plan: FIDDY participation rewards

1. Specify backed FIDDY, approved consumers, PositionNFT authority and purchase-time staker revenue.
2. Add namespaced token/reserve state, exact funding/conversions and consumer permissions.
3. Extend immutable configurations and both purchase entrypoints with account attribution.
4. Book staker revenue at every purchase, list revenue assets at configuration creation (at most 64), and settle the booked staker total without calling Statics.
5. Add staking with complete one-call checkpoints across all revenue assets and a 24-hour unstake lock with a stake-weighted reset.
6. Add unique Operator registration validated at every checkpoint by direct activation and ownership reads, forfeiting invalid boost excess to other stakers.
7. Restrict FIDDY withdrawals to the PositionNFT owner and FIDDY payouts to the caller or Treasury, and require a consumer Router for FIDDY-priced Operator revenue.
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

- [x] Use the reduced seven-selector Statics interface and qualify a matching pinned dependency.
