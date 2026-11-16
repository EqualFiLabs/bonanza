// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IGovernance } from "../interfaces/IGovernance.sol";
import { LibBonanza } from "../libraries/LibBonanza.sol";
import { LibBonanzaStaking } from "../libraries/LibBonanzaStaking.sol";
import { LibBonanzaStorage } from "../libraries/LibBonanzaStorage.sol";
import { BonanzaConfig } from "../shared/BonanzaTypes.sol";
import { BonanzaErrors } from "../shared/BonanzaErrors.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibLotteryConfig } from "../libraries/LibLotteryConfig.sol";
import { LibLotteryStorage } from "../libraries/LibLotteryStorage.sol";
import { LibOperatorFeeRouter } from "../libraries/LibOperatorFeeRouter.sol";
import { Errors } from "../shared/Errors.sol";
import { IntegrationConfig, LotteryConfig } from "../shared/Types.sol";

contract GovernanceFacet is IGovernance {
    modifier onlyAuthority() {
        LibDiamond.enforceAuthority();
        _;
    }

    function authority() external view returns (address) {
        return LibDiamond.authority();
    }

    function pendingAuthority() external view returns (address) {
        return LibDiamond.diamondStorage().pendingAuthority;
    }

    /// @notice Nomination grants no powers; only the nominee may complete the handover.
    function nominateAuthority(address nominee) external onlyAuthority {
        if (nominee == address(0) || nominee == address(this)) revert Errors.InvalidAddress();
        LibDiamond.diamondStorage().pendingAuthority = nominee;
        emit AuthorityTransferNominated(LibDiamond.authority(), nominee);
    }

    function cancelAuthorityTransfer() external onlyAuthority {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address nominee = ds.pendingAuthority;
        if (nominee == address(0)) revert Errors.NoPendingAuthority();
        ds.pendingAuthority = address(0);
        emit AuthorityTransferCancelled(ds.authority, nominee);
    }

    /// @notice Available after code finalization; does not change the cut-disabled latch.
    function acceptAuthority() external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        if (ds.pendingAuthority == address(0) || msg.sender != ds.pendingAuthority) {
            revert Errors.NotPendingAuthority(msg.sender);
        }
        address previousAuthority = ds.authority;
        ds.authority = msg.sender;
        ds.pendingAuthority = address(0);
        emit AuthorityTransferred(previousAuthority, msg.sender);
    }

    function createLotteryConfig(LotteryConfig calldata config)
        external
        onlyAuthority
        returns (uint64 version)
    {
        return _createConfig(config);
    }

    function createRewardLotteryConfig(
        LotteryConfig calldata config,
        BonanzaConfig calldata rewards
    ) external onlyAuthority returns (uint64 version) {
        LibBonanza.enforceInitialized();
        if (
            uint256(config.operatorProtocolBps) + rewards.stakerProtocolBps > 10_000
                || (!rewards.participation && rewards.unitsPerTicket != 0)
        ) revert BonanzaErrors.InvalidRewardsConfig();
        version = _createConfig(config);
        LibLotteryConfig.validateAllocation(config, rewards.stakerProtocolBps);
        LibBonanzaStorage.state().configs[version] = rewards;
        if (rewards.stakerProtocolBps != 0) LibBonanzaStaking.list(config.paymentToken);
        emit BonanzaConfigCreated(version, rewards);
    }

    function _createConfig(LotteryConfig calldata config) private returns (uint64 version) {
        LibLotteryConfig.validate(config);
        if (config.operatorProtocolBps != 0) {
            LibLotteryStorage.IntegrationStorage storage integrations =
                LibLotteryStorage.integrationStorage();
            LibOperatorFeeRouter.enforcePayable(
                integrations.integrations[integrations.currentVersion].operatorFeeRouter,
                config.paymentToken
            );
        }
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
