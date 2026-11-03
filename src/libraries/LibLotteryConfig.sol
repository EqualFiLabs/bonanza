// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { Errors } from "../shared/Errors.sol";
import { IntegrationConfig, LotteryConfig, RoundConfigSnapshot } from "../shared/Types.sol";

library LibLotteryConfig {
    uint16 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Runtime delta checks supplement this validation. Governance must approve only
    /// exact-transfer, non-rebasing assets whose mutable controls cannot strand liabilities.
    function validate(LotteryConfig memory config) internal view {
        if (config.paymentToken == address(0)) revert Errors.InvalidAddress();
        if (config.paymentToken.code.length == 0) revert Errors.NoCode(config.paymentToken);
        if (
            config.ticketPrice == 0 || config.ticketCount == 0 || config.salesDuration == 0
                || config.winnerBps > BPS_DENOMINATOR
                || config.operatorProtocolBps > BPS_DENOMINATOR
                || config.recipientBps > BPS_DENOMINATOR
                || (config.maxTicketsPerPurchase != 0
                    && config.maxTicketsPerPurchase > config.ticketCount)
        ) {
            revert Errors.InvalidConfig();
        }
        if (
            config.recipientBps != 0
                && (config.recipient == address(0) || config.recipient == address(this))
        ) {
            revert Errors.InvalidAddress();
        }
        validateAllocation(config, 0);
    }

    /// @dev Recipient BPS is gross-based; Operator and staker BPS apply to the non-winner share.
    function validateAllocation(LotteryConfig memory config, uint16 stakerProtocolBps)
        internal
        pure
    {
        uint256 protocolBps = uint256(config.operatorProtocolBps) + stakerProtocolBps;
        if (config.winnerBps > BPS_DENOMINATOR || protocolBps > BPS_DENOMINATOR) {
            revert Errors.InvalidConfig();
        }
        if (
            uint256(config.recipientBps) * BPS_DENOMINATOR
                > (BPS_DENOMINATOR - uint256(config.winnerBps)) * (BPS_DENOMINATOR - protocolBps)
        ) {
            revert Errors.InvalidConfig();
        }
    }

    function validate(IntegrationConfig memory config) internal view {
        _validateContract(config.drandRegistry);
        _validateContract(config.operatorFeeRouter);
    }

    function snapshot(LotteryConfig memory config)
        internal
        pure
        returns (RoundConfigSnapshot memory)
    {
        return RoundConfigSnapshot({
            paymentToken: config.paymentToken,
            ticketPrice: config.ticketPrice,
            ticketCount: config.ticketCount,
            salesDuration: config.salesDuration,
            randomnessDelay: config.randomnessDelay,
            maxTicketsPerPurchase: config.maxTicketsPerPurchase,
            winnerBps: config.winnerBps,
            operatorProtocolBps: config.operatorProtocolBps,
            recipientBps: config.recipientBps,
            recipient: config.recipient,
            finalizerTip: config.finalizerTip
        });
    }

    function _validateContract(address target) private view {
        if (target == address(0)) revert Errors.InvalidAddress();
        if (target.code.length == 0) revert Errors.NoCode(target);
    }
}
