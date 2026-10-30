// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IGovernance } from "../interfaces/IGovernance.sol";
import { LibFiddy } from "../libraries/LibFiddy.sol";
import { LibFiddyStaking } from "../libraries/LibFiddyStaking.sol";
import { LibFiddyStorage } from "../libraries/LibFiddyStorage.sol";
import { FiddyConfig } from "../shared/FiddyTypes.sol";
import { FiddyErrors } from "../shared/FiddyErrors.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibLotteryConfig } from "../libraries/LibLotteryConfig.sol";
import { LibLotteryStorage } from "../libraries/LibLotteryStorage.sol";
import { Errors } from "../shared/Errors.sol";
import { IntegrationConfig, LotteryConfig } from "../shared/Types.sol";

contract GovernanceFacet is IGovernance {
    modifier onlyAuthority() {
        LibDiamond.enforceAuthority();
        _;
    }

    function createLotteryConfig(LotteryConfig calldata config)
        external
        onlyAuthority
        returns (uint64 version)
    {
        return _createConfig(config);
    }

    function createRewardLotteryConfig(LotteryConfig calldata config, FiddyConfig calldata rewards)
        external
        onlyAuthority
        returns (uint64 version)
    {
        LibFiddy.enforceInitialized();
        if (
            uint256(config.operatorProtocolBps) + rewards.stakerProtocolBps > 10_000
                || (!rewards.participation && rewards.unitsPerTicket != 0)
        ) revert FiddyErrors.InvalidRewardsConfig();
        version = _createConfig(config);
        LibFiddyStorage.state().configs[version] = rewards;
        if (rewards.stakerProtocolBps != 0) LibFiddyStaking.list(config.paymentToken);
        emit FiddyConfigCreated(version, rewards);
    }

    function _createConfig(LotteryConfig calldata config) private returns (uint64 version) {
        LibLotteryConfig.validate(config);
        LibLotteryStorage.GameStorage storage gs = LibLotteryStorage.gameStorage();

        version = ++gs.nextConfigVersion;
        gs.configs[version] = config;
        LibLotteryStorage.accountingStorage().admittedPaymentToken[config.paymentToken] = true;
        emit LotteryConfigCreated(version, config.paymentToken, config);
    }

    function setLotteryConfigEnabled(uint64 version, bool enabled) external onlyAuthority {
        LibLotteryStorage.GameStorage storage gs = LibLotteryStorage.gameStorage();
        _enforceConfigExists(gs, version);
        gs.configEnabled[version] = enabled;
        emit LotteryConfigEnabled(version, enabled);
    }

    function setMaxActiveRounds(uint16 maxActiveRounds_) external onlyAuthority {
        LibLotteryStorage.GameStorage storage gs = LibLotteryStorage.gameStorage();
        uint16 previousLimit = gs.maxActiveRounds;
        gs.maxActiveRounds = maxActiveRounds_;
        emit MaxActiveRoundsUpdated(previousLimit, maxActiveRounds_);
    }

    function integrationConfig()
        external
        view
        returns (IntegrationConfig memory config, uint64 version)
    {
        LibLotteryStorage.IntegrationStorage storage integrations =
            LibLotteryStorage.integrationStorage();
        version = integrations.currentVersion;
        config = integrations.integrations[version];
    }

    function setIntegrationConfig(IntegrationConfig calldata config) external onlyAuthority {
        LibLotteryConfig.validate(config);
        LibLotteryStorage.IntegrationStorage storage integrations =
            LibLotteryStorage.integrationStorage();

        uint64 version = ++integrations.currentVersion;
        integrations.integrations[version] = config;
        emit IntegrationConfigUpdated(version, config.drandRegistry, config.operatorFeeRouter);
    }

    function setTreasuryRecipient(address recipient) external onlyAuthority {
        if (recipient == address(0) || recipient == address(this)) {
            revert Errors.InvalidAddress();
        }

        LibLotteryStorage.GovernanceStorage storage governance =
            LibLotteryStorage.governanceStorage();
        address previousRecipient = governance.treasuryRecipient;
        governance.treasuryRecipient = recipient;
        emit TreasuryRecipientUpdated(previousRecipient, recipient);
    }

    function setGuardian(address guardian_) external onlyAuthority {
        LibLotteryStorage.GovernanceStorage storage governance =
            LibLotteryStorage.governanceStorage();
        address previousGuardian = governance.guardian;
        governance.guardian = guardian_;
        emit GuardianUpdated(previousGuardian, guardian_);
    }

    function setPaused(bool paused_) external {
        address authority_ = LibDiamond.authority();
        if (msg.sender != authority_) {
            if (msg.sender != LibLotteryStorage.governanceStorage().guardian) {
                revert Errors.NotGuardian(msg.sender);
            }
            if (!paused_) revert Errors.UnpauseRequiresAuthority(msg.sender);
        }

        LibLotteryStorage.governanceStorage().paused = paused_;
        emit PauseStateUpdated(paused_);
    }

    function paused() external view returns (bool) {
        return LibLotteryStorage.governanceStorage().paused;
    }

    function guardian() external view returns (address) {
        return LibLotteryStorage.governanceStorage().guardian;
    }

    function treasuryRecipient() external view returns (address) {
        return LibLotteryStorage.governanceStorage().treasuryRecipient;
    }

    function protocolFinalized() external view returns (bool) {
        return LibDiamond.cutsDisabled();
    }

    function finalizeProtocol() external onlyAuthority {
        LibDiamond.disableCuts();
        emit ProtocolFinalized();
    }

    function _enforceConfigExists(LibLotteryStorage.GameStorage storage gs, uint64 version)
        private
        view
    {
        if (version == 0 || version > gs.nextConfigVersion) {
            revert Errors.ConfigNotFound(version);
        }
    }
}
