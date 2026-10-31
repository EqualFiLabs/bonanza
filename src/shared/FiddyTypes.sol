// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

struct FiddyBindings {
    address underlying;
    address positionNFT;
    address operators;
    address registry;
}

struct FiddyConfig {
    uint96 unitsPerTicket;
    uint16 stakerProtocolBps;
    bool participation;
}

struct FiddyAccount {
    uint256 balance;
    uint256 staked;
    uint256 weight;
    uint256 operatorId;
    uint256 multiplierBps;
    uint64 stakeStart; // Unstaking unlocks STAKE_LOCK after this weighted start time.
    uint64 nonce; // Changes with every owner action and boost forfeit, for order conditioning.
    bool registered;
    bool attached;
}

struct FiddyAsset {
    uint256 indexRay;
    uint256 reserved;
    uint256 dustRay;
    bool listed;
}

struct FiddyCredit {
    uint256 paidIndex;
    uint256 claimable;
    uint256 remainderRay;
}
