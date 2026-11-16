// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IGovernance } from "../interfaces/IGovernance.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibBonanza } from "../libraries/LibBonanza.sol";
import { LibLotteryConfig } from "../libraries/LibLotteryConfig.sol";
import { LibLotteryStorage } from "../libraries/LibLotteryStorage.sol";
import { LibOperatorFeeRouter } from "../libraries/LibOperatorFeeRouter.sol";
import { LibReentrancy } from "../libraries/LibReentrancy.sol";
import { Errors } from "../shared/Errors.sol";
import { BonanzaBindings } from "../shared/BonanzaTypes.sol";
import { IntegrationConfig, LotteryConfig } from "../shared/Types.sol";

/// @notice Atomic initializer for a newly deployed Bonanza Diamond.
/// @dev This contract is delegatecalled by an authority-approved Diamond cut. The authority is
/// installed by the Diamond constructor and is verified here rather than written a second time.
contract LotteryInit {
    struct InitParams {
        address authority;
        address guardian;
        address treasuryRecipient;
        uint16 maxActiveRounds;
        IntegrationConfig integration;
        LotteryConfig[] lotteryConfigs;
    }

    function initialize(InitParams calldata params) external {
        _initialize(params);
    }

    /// @notice Also binds BONANZA, so the token is complete in the same transaction as the cut.
    function initializeWithBonanza(InitParams calldata params, BonanzaBindings calldata bonanza)
        external
    {
        _initialize(params);
        LibBonanza.initialize(bonanza);
    }

    function _initialize(InitParams calldata params) private {
        LibDiamond.enforceAuthority();
        address installedAuthority = LibDiamond.authority();
        if (params.authority != installedAuthority) {
            revert Errors.AuthorityMismatch(installedAuthority, params.authority);
        }
        if (
            params.guardian == address(0) || params.treasuryRecipient == address(0)
                || params.treasuryRecipient == address(this)
        ) {
            revert Errors.InvalidAddress();
        }
        if (params.lotteryConfigs.length == 0) revert Errors.EmptyLotteryConfigurations();

        LibLotteryConfig.validate(params.integration);
        LibReentrancy.initialize();

        LibLotteryStorage.IntegrationStorage storage integrations =
            LibLotteryStorage.integrationStorage();
        integrations.currentVersion = 1;
        integrations.integrations[1] = params.integration;
        emit IGovernance.IntegrationConfigUpdated(
            1, params.integration.drandRegistry, params.integration.operatorFeeRouter
        );

        LibLotteryStorage.GovernanceStorage storage governance =
            LibLotteryStorage.governanceStorage();
        governance.guardian = params.guardian;
        governance.treasuryRecipient = params.treasuryRecipient;
        emit IGovernance.GuardianUpdated(address(0), params.guardian);
        emit IGovernance.TreasuryRecipientUpdated(address(0), params.treasuryRecipient);

        LibLotteryStorage.GameStorage storage game = LibLotteryStorage.gameStorage();
        game.maxActiveRounds = params.maxActiveRounds;
        emit IGovernance.MaxActiveRoundsUpdated(0, params.maxActiveRounds);

        LibLotteryStorage.AccountingStorage storage accounting =
            LibLotteryStorage.accountingStorage();
        for (uint256 i; i < params.lotteryConfigs.length; ++i) {
            LotteryConfig calldata config = params.lotteryConfigs[i];
            LibLotteryConfig.validate(config);
            if (config.operatorProtocolBps != 0) {
                LibOperatorFeeRouter.enforcePayable(
                    params.integration.operatorFeeRouter, config.paymentToken
                );
            }

            uint64 version = ++game.nextConfigVersion;
            game.configs[version] = config;
            game.configEnabled[version] = true;
            accounting.admittedPaymentToken[config.paymentToken] = true;

            emit IGovernance.LotteryConfigCreated(version, config.paymentToken, config);
            emit IGovernance.LotteryConfigEnabled(version, true);
        }
    }
}
