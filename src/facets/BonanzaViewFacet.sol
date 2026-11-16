// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { LibBonanzaStorage } from "../libraries/LibBonanzaStorage.sol";
import {
    BonanzaConfig,
    BonanzaAccount,
    BonanzaAsset,
    BonanzaCredit
} from "../shared/BonanzaTypes.sol";

contract BonanzaViewFacet {
    function bonanzaBindings()
        external
        view
        returns (address underlying, address positionNFT, address operators, address registry)
    {
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        return (s.underlying, s.positionNFT, s.operators, s.registry);
    }

    function bonanzaReserve()
        external
        view
        returns (
            uint256 inventory,
            uint256 backing,
            uint256 custody,
            bool wrapEnabled,
            bool unwrapEnabled,
            uint256 cap,
            uint256 outstanding
        )
    {
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        return (
            s.inventory,
            s.allocatedBacking,
            s.custodyTotal,
            s.wrapEnabled,
            s.unwrapEnabled,
            s.wrapCap,
            s.wrapOutstanding
        );
    }

    function bonanzaAccount(uint256 id) external view returns (BonanzaAccount memory) {
        return LibBonanzaStorage.state().accounts[id];
    }

    function bonanzaConfig(uint64 version) external view returns (BonanzaConfig memory) {
        return LibBonanzaStorage.state().configs[version];
    }

    function bonanzaRoundConfig(uint256 roundId) external view returns (BonanzaConfig memory) {
        return LibBonanzaStorage.state().rounds[roundId];
    }

    function bonanzaAsset(address asset) external view returns (BonanzaAsset memory) {
        return LibBonanzaStorage.state().assets[asset];
    }

    function bonanzaCredit(uint256 id, address asset) external view returns (BonanzaCredit memory) {
        return LibBonanzaStorage.state().credits[id][asset];
    }

    function bonanzaOperatorAccount(uint256 operatorId) external view returns (uint256) {
        return LibBonanzaStorage.state().operatorAccount[operatorId];
    }

    function bonanzaStaking()
        external
        view
        returns (uint256 totalWeight, bool boostsEnabled, uint256 revenueAssetCount)
    {
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        return (s.totalWeight, s.boostsEnabled, s.revenueAssets.length);
    }

    /// @notice Staker revenue booked by a round's purchases.
    function bonanzaRoundRevenue(uint256 roundId) external view returns (uint256) {
        return LibBonanzaStorage.state().stakerAccrued[roundId];
    }

    function bonanzaRevenueAssets() external view returns (address[] memory) {
        return LibBonanzaStorage.state().revenueAssets;
    }
}
