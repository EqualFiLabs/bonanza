// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { IFiddyProtocol } from "../interfaces/IFiddyProtocol.sol";
import { LibLotteryStorage } from "./LibLotteryStorage.sol";

import { Errors } from "../shared/Errors.sol";
import { FiddyErrors } from "../shared/FiddyErrors.sol";

library LibExactToken {
    using SafeERC20 for IERC20;

    function pullExact(address asset, address sender, uint256 amount) internal {
        IERC20 token = IERC20(asset);
        uint256 senderBefore = token.balanceOf(sender);
        uint256 receiverBefore = token.balanceOf(address(this));

        if (asset == address(this)) {
            IFiddyProtocol(address(this)).protocolMoveFiddy(sender, address(this), amount);
        } else {
            token.safeTransferFrom(sender, address(this), amount);
        }

        uint256 senderAfter = token.balanceOf(sender);
        uint256 receiverAfter = token.balanceOf(address(this));
        uint256 spent = senderBefore >= senderAfter ? senderBefore - senderAfter : 0;
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (spent != amount || received != amount) {
            revert Errors.InexactTokenTransfer(asset, amount, spent, received);
        }
    }

    function pushExact(address asset, address receiver, uint256 amount) internal {
        IERC20 token = IERC20(asset);
        uint256 senderBefore = token.balanceOf(address(this));
        uint256 receiverBefore = token.balanceOf(receiver);

        if (asset == address(this)) {
            // FIDDY leaves custody only to the caller or Treasury, so protocol payouts cannot
            // route around the transfer restriction.
            if (
                receiver != msg.sender
                    && receiver != LibLotteryStorage.governanceStorage().treasuryRecipient
            ) revert FiddyErrors.ReceiverRestricted(receiver);
            IFiddyProtocol(address(this)).protocolMoveFiddy(address(this), receiver, amount);
        } else {
            token.safeTransfer(receiver, amount);
        }

        uint256 senderAfter = token.balanceOf(address(this));
        uint256 receiverAfter = token.balanceOf(receiver);
        uint256 spent = senderBefore >= senderAfter ? senderBefore - senderAfter : 0;
        uint256 received = receiverAfter >= receiverBefore ? receiverAfter - receiverBefore : 0;
        if (spent != amount || received != amount) {
            revert Errors.InexactTokenTransfer(asset, amount, spent, received);
        }
    }
}
