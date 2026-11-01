// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface IRevenue {
    event OperatorRevenueFlushed(
        uint64 indexed integrationVersion,
        address indexed asset,
        address indexed caller,
        uint256 amount
    );
    event RecipientRevenueFlushed(
        uint256 indexed roundId, address indexed asset, address indexed recipient, uint256 amount
    );
    event TreasuryFlushed(address indexed asset, address indexed recipient, uint256 amount);
    event TokenSurplusAbsorbed(address indexed asset, uint256 amount);
    event NativeSurplusFlushed(address indexed recipient, uint256 amount);

    function flushOperatorRevenue(uint64 integrationVersion, address asset, uint256 amount)
        external
        returns (uint256 flushed);
    function flushRecipientRevenue(uint256 roundId) external returns (uint256 flushed);
    function flushTreasury(address asset, uint256 amount) external returns (uint256 flushed);
    function availableTokenSurplus(address asset) external view returns (uint256);
    function absorbTokenSurplus(address asset) external returns (uint256 amount);
    function flushNativeSurplus() external returns (uint256 amount);
}
