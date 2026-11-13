// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBonanzaProtocol } from "../interfaces/IBonanzaProtocol.sol";
import { LibLotteryStorage } from "./LibLotteryStorage.sol";

import { Round } from "../shared/Types.sol";

import { Errors } from "../shared/Errors.sol";
import { BonanzaErrors } from "../shared/BonanzaErrors.sol";

library LibExactToken {
    using SafeERC20 for IERC20;

    function pullExact(address asset, address sender, uint256 amount) internal {
        IERC20 token = IERC20(asset);
        uint256 senderBefore = token.balanceOf(sender);
        uint256 receiverBefore = token.balanceOf(address(this));

        if (asset == address(this)) {
            IBonanzaProtocol(address(this)).protocolMoveBonanza(sender, address(this), amount);
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
        if (asset == address(this)) {
            // Ordinary BONANZA payouts leave custody only to the caller or Treasury. The
            // fixed round recipient has a separate exit below.
            if (
                receiver != msg.sender
                    && receiver != LibLotteryStorage.governanceStorage().treasuryRecipient
            ) revert BonanzaErrors.ReceiverRestricted(receiver);
        }
        _pushExact(asset, receiver, amount);
    }

    /// @dev A separate protocol exit fixed to the round's configured recipient. It cannot be
    /// used to redirect winner, finalizer or staking withdrawals around BONANZA restrictions.
    function pushRoundRecipientExact(Round storage round, uint256 amount) internal {
        _pushExact(round.config.paymentToken, round.config.recipient, amount);
    }

    function _pushExact(address asset, address receiver, uint256 amount) private {
        IERC20 token = IERC20(asset);
        uint256 senderBefore = token.balanceOf(address(this));
        uint256 receiverBefore = token.balanceOf(receiver);

        if (asset == address(this)) {
            IBonanzaProtocol(address(this)).protocolMoveBonanza(address(this), receiver, amount);
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
