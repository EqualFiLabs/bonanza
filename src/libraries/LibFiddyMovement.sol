// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @dev One exact protocol movement, consumed by the ERC-20 update hook.
library LibFiddyMovement {
    bytes32 private constant SLOT = keccak256("statics.lottery.fiddy.movement.v1");

    function authorize(address from, address to, uint256 amount) internal {
        bytes32 slot = SLOT;
        bytes32 movement = keccak256(abi.encode(from, to, amount));
        assembly ("memory-safe") { tstore(slot, movement) }
    }

    function clear() internal {
        bytes32 slot = SLOT;
        assembly ("memory-safe") { tstore(slot, 0) }
    }

    function consume(address from, address to, uint256 amount) internal returns (bool) {
        bytes32 slot = SLOT;
        bytes32 movement;
        assembly ("memory-safe") { movement := tload(slot) }
        if (movement != keccak256(abi.encode(from, to, amount))) return false;
        clear();
        return true;
    }
}
