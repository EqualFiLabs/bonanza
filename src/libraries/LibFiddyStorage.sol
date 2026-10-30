// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { FiddyConfig, FiddyAccount, FiddyAsset, FiddyCredit } from "../shared/FiddyTypes.sol";

library LibFiddyStorage {
    bytes32 internal constant SLOT = keccak256("statics.lottery.storage.fiddy.v1");

    struct State {
        address underlying;
        address positionNFT;
        address operators;
        address registry;
        bool wrapEnabled;
        bool unwrapEnabled;
        bool boostsEnabled;
        uint256 wrapCap;
        uint256 wrapOutstanding;
        uint256 inventory; // Preminted FIDDY available for participation rewards.
        uint256 allocatedBacking; // STATICS backing all supply, including inventory.
        uint256 custodyTotal;
        uint256 totalWeight;
        mapping(address => bool) consumers;
        mapping(uint64 => FiddyConfig) configs;
        mapping(uint256 => FiddyConfig) rounds;
        mapping(uint256 => FiddyAccount) accounts;
        mapping(uint256 => uint256) operatorAccount;
        mapping(address => FiddyAsset) assets;
        mapping(uint256 => mapping(address => FiddyCredit)) credits;
        mapping(uint256 => uint256) stakerAccrued; // Staker revenue booked per round.
        address[] revenueAssets;
    }

    function state() internal pure returns (State storage s) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") { s.slot := slot }
    }
}
