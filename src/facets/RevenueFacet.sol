// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { IRevenue } from "../interfaces/IRevenue.sol";
import { LibBonanza } from "../libraries/LibBonanza.sol";
import { LibExactToken } from "../libraries/LibExactToken.sol";
import { LibLotteryStorage } from "../libraries/LibLotteryStorage.sol";
import { LibOperatorFeeRouter } from "../libraries/LibOperatorFeeRouter.sol";
import { LibReentrancy } from "../libraries/LibReentrancy.sol";
import { Errors } from "../shared/Errors.sol";
import { AssetAccounting, IntegrationConfig, Round, RoundStatus } from "../shared/Types.sol";

contract RevenueFacet is IRevenue {
    modifier nonReentrant() {
        LibReentrancy.enter();
        _;
        LibReentrancy.exit();
    }

    function flushOperatorRevenue(uint64 integrationVersion, address asset, uint256 amount)
        external
        nonReentrant
        returns (uint256 flushed)
    {
        if (amount == 0) revert Errors.ZeroAmount();
        LibLotteryStorage.IntegrationStorage storage integrations =
            LibLotteryStorage.integrationStorage();
        if (integrationVersion == 0 || integrationVersion > integrations.currentVersion) {
            revert Errors.IntegrationNotFound(integrationVersion);
        }

        LibLotteryStorage.AccountingStorage storage accountingStorage =
            LibLotteryStorage.accountingStorage();
        uint256 available = accountingStorage.pendingOperatorRevenue[integrationVersion][asset];
        if (amount > available) {
            revert Errors.InsufficientOperatorRevenue(integrationVersion, amount, available);
        }

        accountingStorage.pendingOperatorRevenue[integrationVersion][asset] = available - amount;
        accountingStorage.assetAccounting[asset].pendingOperatorRevenueTotal -= amount;

        IntegrationConfig storage integration = integrations.integrations[integrationVersion];
        LibOperatorFeeRouter.contributeExact(integration.operatorFeeRouter, asset, amount);
        emit OperatorRevenueFlushed(integrationVersion, asset, msg.sender, amount);
        return amount;
    }

    /// @notice Anyone may deliver the full settled allocation to its snapshotted recipient.
    function flushRecipientRevenue(uint256 roundId)
        external
        nonReentrant
        returns (uint256 flushed)
    {
        Round storage round = _settledRound(roundId);
        flushed = _clearRecipientRevenue(round);
        LibExactToken.pushRoundRecipientExact(round, flushed);
        emit RecipientRevenueFlushed(
            roundId, round.config.paymentToken, round.config.recipient, flushed
        );
    }

    /// @notice The snapshotted recipient may claim its full allocation to a receiver it chooses,
    /// so an address that can no longer receive the Payment Token can still recover it.
    /// BONANZA keeps the ordinary caller-or-Treasury receiver restriction.
    function claimRecipientRevenue(uint256 roundId, address receiver)
        external
        nonReentrant
        returns (uint256 claimed)
    {
        if (receiver == address(0) || receiver == address(this)) {
            revert Errors.InvalidAddress();
        }
        Round storage round = _settledRound(roundId);
        if (msg.sender != round.config.recipient) revert Errors.NotRecipient(msg.sender);
        claimed = _clearRecipientRevenue(round);
        LibExactToken.pushExact(round.config.paymentToken, receiver, claimed);
        emit RecipientRevenueClaimed(
            roundId, round.config.paymentToken, msg.sender, receiver, claimed
        );
    }

    function flushTreasury(address asset, uint256 amount)
        external
        nonReentrant
        returns (uint256 flushed)
    {
        if (amount == 0) revert Errors.ZeroAmount();
        AssetAccounting storage accounting =
            LibLotteryStorage.accountingStorage().assetAccounting[asset];
        uint256 available = accounting.treasuryAvailable;
        if (amount > available) {
            revert Errors.InsufficientTreasuryBalance(amount, available);
        }

        address recipient = LibLotteryStorage.governanceStorage().treasuryRecipient;
        if (recipient == address(0) || recipient == address(this)) {
            revert Errors.InvalidAddress();
        }
        accounting.treasuryAvailable = available - amount;
        LibExactToken.pushExact(asset, recipient, amount);
        emit TreasuryFlushed(asset, recipient, amount);
        return amount;
    }

    function availableTokenSurplus(address asset) public view returns (uint256) {
        LibLotteryStorage.AccountingStorage storage accountingStorage =
            LibLotteryStorage.accountingStorage();
        if (!accountingStorage.admittedPaymentToken[asset]) {
            revert Errors.SurplusAssetNotAdmitted(asset);
        }
        AssetAccounting storage accounting = accountingStorage.assetAccounting[asset];
        uint256 accounted = accounting.activeRoundEscrow + accounting.winnerLiability
            + accounting.refundLiability + accounting.finalizerLiability
            + accounting.pendingOperatorRevenueTotal + accounting.treasuryAvailable
            + accounting.recipientLiability + LibBonanza.extraReserved(asset);
        uint256 balance = IERC20(asset).balanceOf(address(this));
        return balance > accounted ? balance - accounted : 0;
    }

    function absorbTokenSurplus(address asset) external nonReentrant returns (uint256 amount) {
        amount = availableTokenSurplus(asset);
        if (amount == 0) revert Errors.NoTokenSurplus();
        LibLotteryStorage.accountingStorage().assetAccounting[asset].treasuryAvailable += amount;
        emit TokenSurplusAbsorbed(asset, amount);
    }

    function flushNativeSurplus() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) revert Errors.NoNativeSurplus();
        address recipient = LibLotteryStorage.governanceStorage().treasuryRecipient;
        if (recipient == address(0) || recipient == address(this)) {
            revert Errors.InvalidAddress();
        }

        (bool success,) = payable(recipient).call{ value: amount }("");
        if (!success) revert Errors.NativeTransferFailed();
        emit NativeSurplusFlushed(recipient, amount);
    }

    function _settledRound(uint256 roundId) private view returns (Round storage round) {
        round = LibLotteryStorage.gameStorage().rounds[roundId];
        if (round.status == RoundStatus.None) revert Errors.RoundNotFound(roundId);
        if (round.status != RoundStatus.Settled) revert Errors.RoundNotSettled(roundId);
    }

    /// @dev Clears the whole claim and its per-token liability before any token interaction.
    function _clearRecipientRevenue(Round storage round) private returns (uint256 amount) {
        amount = round.recipientClaimable;
        if (amount == 0) revert Errors.NoRecipientRevenue();
        round.recipientClaimable = 0;
        LibLotteryStorage.accountingStorage()
                .assetAccounting[round.config.paymentToken]
                .recipientLiability -= amount;
    }
}
