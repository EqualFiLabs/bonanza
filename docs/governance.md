# Governance and Progressive Immutability

Bonanza separates code authority from ordinary future-Round configuration. Code can be
made permanently immutable while the protocol continues to create and operate new configurations.

## Authority model

The Diamond stores one `authority` address at construction. Production deployment is expected to
set it to an external timelock or governance executor. The Lottery does not implement an internal
delay, proposal system, voting system, multisig, or authority-transfer function.

Every authority-gated call is immediate once the authority invokes the Diamond. The safety delay
therefore belongs to the external authority contract and must be validated at deployment. Using an
EOA would remove that operational delay.

The authority may:

- add, replace, or remove facet selectors before finalization;
- execute an initializer during a Diamond cut;
- create immutable Round Configuration Versions, including explicit BONANZA reward settings;
- initialize verified BONANZA bindings once, approve consumers, and control conversions, capacity and boosts;
- enable or disable versions for future opening;
- create immutable Integration Versions;
- set the global active-Round limit;
- set the Treasury recipient and guardian;
- pause or unpause new participation; and
- irreversibly finalize Diamond cuts.

Before code finalization, this role can install arbitrary delegatecall logic. It is consequently
trusted not to mutate live Round snapshots, corrupt namespaced storage, erase liabilities, or
redirect custody. A timelock makes a proposed change observable; it does not make unsafe code safe.

## Round Configuration Versions

`createLotteryConfig` validates and appends a complete immutable struct:

- Payment Token;
- ticket price and count;
- sales duration;
- randomness delay;
- maximum tickets per purchase;
- winner BPS;
- Operator share of the remaining Protocol Share;
- optional recipient address and gross-revenue BPS; and
- finalizer tip.

Creation also admits the Payment Token address for canonical-token surplus accounting. The version
number only increases, and there is no function that edits an existing struct.

An independent enable flag controls whether a version may open a future Round. Disabling a version:

- prevents only new `openRound` calls;
- does not close or mutate an existing Round;
- does not change the Round's token, economics, deadline, or beacon; and
- does not block settlement, claims, or revenue delivery.

Re-enabling the same version permits a new Round after its prior Round is terminal, subject to the
global concurrency limit.

## Integration Versions

`setIntegrationConfig` appends a Registry and Operator Router pair under a new monotonically
increasing version. Prior entries cannot be overwritten. A Round snapshots the current version at
opening.

This protects two historical boundaries:

- a sold-out Round continues to read the Registry against which its Quicknet target was selected;
  and
- pending Operator revenue remains deliverable only through the Router version associated with
  the settling Round.

Changing current integrations affects future Rounds only. It is not a migration mechanism for
live Rounds or existing Operator buckets.

## Global concurrency

`maxActiveRounds` limits all nonterminal Rounds across every configuration and Payment Token. Zero
disables new opening. Reducing the limit below the current active count does not cancel a Round; it
only prevents additional opening until enough Rounds become terminal.

Each Configuration Version also has at most one nonterminal Round. This prevents one enabled
configuration from opening multiple simultaneous copies while still allowing WETH, STATICS, USDG,
or other configurations to operate concurrently within the global limit.

## Guardian and pause

The guardian has one bounded emergency power: it may call `setPaused(true)`. It cannot unpause.
The authority may pause or unpause.

The pause flag gates exactly:

- `openRound`; and
- `buyTickets`.

It does not gate:

- `settleRound` for sellout or deadline draws;
- winner or finalizer claims;
- Operator or Treasury delivery;
- token or native surplus handling; or
- any view.

This design lets governance stop new exposure without censoring liability-reducing exits. Future
facets that create exposure must explicitly adopt the same pause namespace and policy.

## Treasury role

The Treasury recipient is a destination, not an authority. It cannot call privileged Lottery
functions merely by being the recipient. Public callers may deliver recorded Treasury funds only
to the current configured address.

Changing the recipient can redirect funds already classified as Treasury revenue. It cannot touch
winner, finalizer, or Operator liabilities. Production governance should treat a recipient
change as a value-routing action subject to the same external timelock review as other operational
parameters.

## Diamond upgrades

Before finalization, `diamondCut` supports EIP-2535 add, replace, and remove operations and optional
initializer delegatecall. The cut path checks:

- caller equals the installed authority;
- cuts are not disabled;
- selector sets and facet addresses are valid; and
- added/replacement/initializer targets have code.

The selector manifest and every namespaced storage layout are part of the upgrade review boundary.
A safe upgrade must demonstrate:

1. no selector collision or accidental removal;
2. preserved existing storage namespaces and field layouts;
3. unchanged live Round snapshots and accounting;
4. no new path around exact-token, reentrancy, pause, or authority controls; and
5. an initializer whose writes are intentional, bounded, and atomic with the cut.

The authority can technically violate these rules before finalization because delegatecall is
general. They are governance and audit obligations, not limitations imposed by EIP-2535 itself.

## Irreversible code finalization

`finalizeProtocol` calls the one-way `disableCuts` latch. It reverts if already finalized. After the
latch is set:

- every `diamondCut` call reverts;
- no function can reset the latch;
- current facets and storage continue operating; and
- configuration and operational governance remain available.

The Robinhood Testnet lifecycle added a facet, wrote isolated namespaced state, confirmed existing
Round/configuration/accounting hashes were preserved, finalized the code, submitted a failed live
authority cut, and then disabled/re-enabled a configuration and completed another refund Round.
The transactions and terminal state are recorded in
[`deployments/robinhood-testnet/lifecycle.json`](../deployments/robinhood-testnet/lifecycle.json).

## Optional governance renunciation

The Lottery intentionally provides no `renounceGovernance`, `setAuthority`, or configuration
finalization function. Calling `finalizeProtocol` does not renounce parameter governance.

If a production authority is an external timelock/governor, it may have its own ability to become
inoperable or renounce control. That would be an external governance action with consequences that
must be assessed separately:

- no new configuration or integration version could be created;
- enable flags, concurrency, guardian, Treasury recipient, and pause state could become permanent;
- a guardian pause could become irreversible if no authority remains to unpause; and
- live liabilities would remain claimable because exit paths are permissionless.

Governance renunciation is therefore optional and is not implied by code finalization. Adding an
in-Diamond renunciation mechanism would require an explicit specification and implementation
change, including a check that the chosen permanent pause and routing state is safe.

## Deployment checklist

Before a production deployment or authority change, verify:

- the authority address is the intended external timelock/governance executor;
- the actual operational delay, proposers, executors, cancellers, and emergency powers;
- the guardian and Treasury recipient are distinct roles where intended;
- every initial token passes the admission policy and has one canonical ledger address;
- Registry and Router addresses, chain, code hashes, bootstrap, weights, and asset state;
- initial selector and storage-layout manifests;
- initial configurations and global concurrency; and
- whether and when code finalization is intended.

The disposable Robinhood Testnet manifest uses one EOA for authority, guardian, and Treasury to
exercise the bounded lifecycle. It is explicitly not a production governance configuration.

## Deadline-draw release boundary

Sales duration remains a positive configurable `uint32`, including periods longer than 24 hours. Existing Round snapshots cannot be changed by configuration governance. The historical finalized testnet Diamond cannot receive this behavior; deploy a fresh Diamond after separate authorization. Historical refund evidence above describes the old release only.

BONANZA bindings are fixed after initialization. A fresh deployment initializes them in the same transaction as the Diamond cut. Initialization does not enable conversions, capacity, boosts, consumers or reward configurations. `boostsEnabled` gates new Operator registrations only; existing boosts are validated by direct activation and ownership reads at every account checkpoint. Reward configurations list their Payment Token as a revenue asset, up to 64 assets. A BONANZA-priced configuration with an Operator share requires the Router to be an approved BONANZA consumer. These configuration controls remain available after Diamond finalization. See [BONANZA rewards](bonanza-rewards.md).
