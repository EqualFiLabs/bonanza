# Payment Token Policy

Statics Lottery accepts governance-configured ERC-20 assets. WETH, STATICS, USDG, and any
future asset all use the same token path; native ETH is never ticket principal and receives no
special treatment.

An approved Payment Token must have one canonical contract address for its underlying balance
ledger, transfer exactly the requested amount, not rebase, and not change balances outside explicit
transfers. Every Lottery ingress and egress measures both the sender's spend and the receiver's
receipt around a `SafeERC20` call. A mismatch reverts the entire transaction. Token decimals are
not normalized: configuration values use the token's base units.

Balance-delta checks cannot guarantee that a token remains compatible after the transaction.
Before governance approves an asset, it must review the token's upgrade authority, fee controls,
rebasing behavior, pause and blocklist controls, callback behavior, alternate ERC-20 facades, and
any other mutable mechanism that could prevent the Diamond from satisfying an outstanding
liability. Two addresses that control the same underlying balance ledger must never both be
approved. A token whose behavior can later strand claims is outside the supported V1 asset set even
if a test transfer succeeds.

Each Round snapshots its Payment Token. Custody and every accounting category remain scoped to
that token so one asset cannot subsidize another. Surplus classification accepts only canonical
Payment Token addresses previously admitted through governance configuration; arbitrary token
addresses are rejected before their balances are queried.

## FIDDY as a Payment Token

FIDDY is not planned as a launch Payment Token, but the code supports it under extra rules:

- A FIDDY-priced configuration with a nonzero Operator share is rejected unless the current
  integration's Operator Fee Router is an approved FIDDY consumer. Without that approval the
  Router could receive FIDDY but never pay it out. The same check runs before opening and before
  every Router funding attempt. A failed funding attempt leaves the FIDDY in the Lottery and stays
  retryable.
- Winner claims, finalizer-tip claims and staker revenue claims in FIDDY go only to the caller
  or governance Treasury recipient. The dedicated Round Recipient payout goes only to its
  snapshotted recipient, with no receiver override. This narrow exit preserves ordinary FIDDY
  transfer restrictions.
- FIDDY reward inventory, account custody and reserved FIDDY staker revenue are counted alongside
  ordinary Lottery liabilities for surplus purposes.
