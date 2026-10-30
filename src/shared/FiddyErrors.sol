// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

library FiddyErrors {
    error NotPositionOwner();
    error InvalidBinding();
    error AlreadyInitialized();
    error NotInitialized();
    error OnlyProtocol();
    error TransferRestricted();
    error ConversionDisabled();
    error WrapCapacityExceeded();
    error InsufficientFiddy();
    error InvalidRewardsConfig();
    error PositionRequired();
    error InvalidRegistration();
    error OperatorAlreadyRegistered();
    error AccountNotEmpty();
    error RevenueAssetLimitReached();
    error StakeLocked(uint256 unlockAt);
}
