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

interface IRehearsalFiddy {
    function depositFiddy(uint256 id, uint256 amount) external;
    function stakeFiddy(uint256 id, uint256 amount) external;
    function unstakeFiddy(uint256 id, uint256 amount) external;
    function wrapFiddy(uint256 id, uint256 amount) external;
    function withdrawFiddy(uint256 id, uint256 amount) external;
    function unwrapFiddy(uint256 id, uint256 amount, address receiver) external;
    function openRound(uint64 version, uint32 quantity) external returns (uint256);
}

interface IRehearsalPosition {
    function createPosition(address receiver) external payable returns (uint256);
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
            IRehearsalFiddy(lottery).wrapFiddy(position, amount);
        } else {
            IERC20(lottery).approve(lottery, amount);
            IRehearsalFiddy(lottery).depositFiddy(position, amount);
        }
        IRehearsalFiddy(lottery).stakeFiddy(position, amount);
        IRehearsalFiddy(lottery).openRound(version, 1);
        IRehearsalFiddy(lottery).unstakeFiddy(position, amount);
        if (wrap) {
            IRehearsalFiddy(lottery).unwrapFiddy(position, amount, address(this));
        } else {
            IRehearsalFiddy(lottery).withdrawFiddy(position, amount);
        }
        IERC20(wrap ? payment : lottery).transfer(msg.sender, amount);
    }
}

contract RehearsalFacet {
    function rehearsalPing() external pure returns (bytes32) {
        return keccak256("lottery-rehearsal");
    }
}

contract RehearsalForceNative {
    function force(address payable recipient) external payable {
        selfdestruct(recipient);
    }
}
