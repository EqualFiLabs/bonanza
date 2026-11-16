// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @dev Disposable adversarial asset; never a mainnet dependency or production deployment.
contract RehearsalToken is ERC20 {
    uint256 public mode;
    address public callback;
    bytes public payload;

    constructor() ERC20("Rehearsal asset", "TEST") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(uint256 mode_, address callback_, bytes calldata payload_) external {
        mode = mode_;
        callback = callback_;
        payload = payload_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (mode == 1) {
                super._update(from, address(0), 1);
                super._update(from, to, value - 1);
                return;
            }
            if (mode == 2) super._update(from, address(0), 1);
            if (mode == 3) revert("blocked recipient");
            if (mode == 4) {
                (bool ok, bytes memory reason) = callback.call(payload);
                if (!ok) {
                    assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
                }
            }
        }
        super._update(from, to, value);
    }
}

interface IRehearsalBonanza {
    function depositBonanza(uint256 id, uint256 amount) external;
    function stakeBonanza(uint256 id, uint256 amount) external;
    function unstakeBonanza(uint256 id, uint256 amount) external;
    function wrapBonanza(uint256 id, uint256 amount) external;
    function withdrawBonanza(uint256 id, uint256 amount) external;
    function unwrapBonanza(uint256 id, uint256 amount, address receiver) external;
    function openRound(uint64 version, uint32 quantity) external returns (uint256);
}

interface IRehearsalPosition {
    function createPosition(address receiver) external payable returns (uint256);
}

interface IRehearsalExternalModules {
    function attachExternalAccountLeg(uint256 positionId, bytes32 moduleType, bytes32 localId)
        external
        returns (bytes32);
}

/// @dev Consumer-funded and wrap-funded attempts must revert the complete purchase and stake.
contract RehearsalBorrower {
    uint256 public position;

    function create(address core) external {
        position = IRehearsalPosition(core).createPosition(address(this));
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    function attack(address lottery, address payment, uint64 version, uint256 amount, bool wrap)
        external
    {
        IERC20(payment).approve(lottery, type(uint256).max);
        IERC20(wrap ? payment : lottery).transferFrom(msg.sender, address(this), amount);
        if (wrap) {
            IRehearsalBonanza(lottery).wrapBonanza(position, amount);
        } else {
            IERC20(lottery).approve(lottery, amount);
            IRehearsalBonanza(lottery).depositBonanza(position, amount);
        }
        IRehearsalBonanza(lottery).stakeBonanza(position, amount);
        IRehearsalBonanza(lottery).openRound(version, 1);
        IRehearsalBonanza(lottery).unstakeBonanza(position, amount);
        if (wrap) {
            IRehearsalBonanza(lottery).unwrapBonanza(position, amount, address(this));
        } else {
            IRehearsalBonanza(lottery).withdrawBonanza(position, amount);
        }
        IERC20(wrap ? payment : lottery).transfer(msg.sender, amount);
    }
}

contract RehearsalFacet {
    function rehearsalPing() external pure returns (bytes32) {
        return keccak256("lottery-rehearsal");
    }
}

/// @dev Fills the actual Statics external-leg array without mutating its storage directly.
contract RehearsalModule {
    function fill(address core, uint256 positionId, bytes32 moduleType, uint256 count) external {
        for (uint256 i; i < count; ++i) {
            IRehearsalExternalModules(core)
                .attachExternalAccountLeg(positionId, moduleType, bytes32(i + 1));
        }
    }
}

contract RehearsalForceNative {
    function force(address payable recipient) external payable {
        selfdestruct(recipient);
    }
}
