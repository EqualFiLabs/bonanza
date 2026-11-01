// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { FiddyConfig } from "../shared/FiddyTypes.sol";

import { IntegrationConfig, LotteryConfig } from "../shared/Types.sol";

interface IGovernance {
    event LotteryConfigCreated(
        uint64 indexed version, address indexed paymentToken, LotteryConfig config
    );
    event FiddyConfigCreated(uint64 indexed version, FiddyConfig config);
    event LotteryConfigEnabled(uint64 indexed version, bool enabled);
    event MaxActiveRoundsUpdated(uint16 previousLimit, uint16 newLimit);
    event IntegrationConfigUpdated(
        uint64 indexed version, address indexed drandRegistry, address indexed operatorFeeRouter
    );
    event TreasuryRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event PauseStateUpdated(bool paused);
    event ProtocolFinalized();

    function createLotteryConfig(LotteryConfig calldata config) external returns (uint64 version);
    function createRewardLotteryConfig(LotteryConfig calldata config, FiddyConfig calldata rewards)
        external
        returns (uint64 version);
    function setLotteryConfigEnabled(uint64 version, bool enabled) external;
    function setMaxActiveRounds(uint16 maxActiveRounds) external;
    function integrationConfig()
        external
        view
        returns (IntegrationConfig memory config, uint64 version);
    function setIntegrationConfig(IntegrationConfig calldata config) external;
    function setTreasuryRecipient(address recipient) external;
    function setGuardian(address guardian) external;
    function setPaused(bool paused_) external;
    function paused() external view returns (bool);
    function guardian() external view returns (address);
    function treasuryRecipient() external view returns (address);
    function protocolFinalized() external view returns (bool);
    function finalizeProtocol() external;
}
