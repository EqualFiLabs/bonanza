// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { LibFiddyStorage } from "../libraries/LibFiddyStorage.sol";
import { FiddyConfig, FiddyAccount, FiddyAsset, FiddyCredit } from "../shared/FiddyTypes.sol";

contract FiddyViewFacet {
    function fiddyBindings()
        external
        view
        returns (address underlying, address positionNFT, address operators, address registry)
    {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        return (s.underlying, s.positionNFT, s.operators, s.registry);
    }

    function fiddyReserve()
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
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
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

    function fiddyAccount(uint256 id) external view returns (FiddyAccount memory) {
        return LibFiddyStorage.state().accounts[id];
    }

    function fiddyConfig(uint64 version) external view returns (FiddyConfig memory) {
        return LibFiddyStorage.state().configs[version];
    }

    function fiddyRoundConfig(uint256 roundId) external view returns (FiddyConfig memory) {
        return LibFiddyStorage.state().rounds[roundId];
    }

    function fiddyAsset(address asset) external view returns (FiddyAsset memory) {
        return LibFiddyStorage.state().assets[asset];
    }

    function fiddyCredit(uint256 id, address asset) external view returns (FiddyCredit memory) {
        return LibFiddyStorage.state().credits[id][asset];
    }

    function fiddyOperatorAccount(uint256 operatorId) external view returns (uint256) {
        return LibFiddyStorage.state().operatorAccount[operatorId];
    }

    function fiddyStaking()
        external
        view
        returns (uint256 totalWeight, bool boostsEnabled, uint256 revenueAssetCount)
    {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        return (s.totalWeight, s.boostsEnabled, s.revenueAssets.length);
    }

    /// @notice Staker revenue booked by a round's purchases.
    function fiddyRoundRevenue(uint256 roundId) external view returns (uint256) {
        return LibFiddyStorage.state().stakerAccrued[roundId];
    }

    function fiddyRevenueAssets() external view returns (address[] memory) {
        return LibFiddyStorage.state().revenueAssets;
    }
}
