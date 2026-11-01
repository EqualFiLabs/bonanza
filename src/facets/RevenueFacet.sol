// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { IRevenue } from "../interfaces/IRevenue.sol";
import { LibFiddy } from "../libraries/LibFiddy.sol";
import { LibExactToken } from "../libraries/LibExactToken.sol";
import { LibLotteryStorage } from "../libraries/LibLotteryStorage.sol";
import { LibOperatorFeeRouter } from "../libraries/LibOperatorFeeRouter.sol";
import { LibReentrancy } from "../libraries/LibReentrancy.sol";
import { Errors } from "../shared/Errors.sol";
import { AssetAccounting, IntegrationConfig } from "../shared/Types.sol";

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
            + LibFiddy.extraReserved(asset);
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
}
