// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { Math } from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import { LibFiddyStorage } from "./LibFiddyStorage.sol";
import { LibLotteryStorage } from "./LibLotteryStorage.sol";
import { FiddyAccount, FiddyAsset, FiddyCredit } from "../shared/FiddyTypes.sol";
import { FiddyErrors } from "../shared/FiddyErrors.sol";

library LibFiddyStaking {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_REVENUE_ASSETS = 64;
    event FiddyRevenueAssetListed(address indexed asset);
    event FiddyRevenueBooked(
        uint256 indexed roundId,
        address indexed asset,
        uint256 amount,
        uint256 totalWeight,
        uint256 indexRay
    );
    event FiddyZeroWeightRevenue(uint256 indexed roundId, address indexed asset, uint256 amount);

    /// @dev One floor per purchase. Summed over purchases this never exceeds the protocol
    /// remainder after the Operator share when Operator and staker BPS sum to at most BPS.
    function stakerShare(uint256 amount, uint16 winnerBps, uint16 stakerProtocolBps)
        internal
        pure
        returns (uint256)
    {
        return amount * (BPS - winnerBps) * stakerProtocolBps / (BPS * BPS);
    }

    /// @dev Listing is bounded and never loops over configurations.
    function list(address asset) internal {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        FiddyAsset storage revenue = s.assets[asset];
        if (revenue.listed) return;
        if (s.revenueAssets.length == MAX_REVENUE_ASSETS) {
            revert FiddyErrors.RevenueAssetLimitReached();
        }
        revenue.listed = true;
        s.revenueAssets.push(asset);
        emit FiddyRevenueAssetListed(asset);
    }

    /// @notice Books the staker share of one final ticket purchase against the current weight.
    function book(uint256 roundId, address asset, uint256 amount, uint16 winnerBps)
        internal
        returns (uint256 share)
    {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        share = stakerShare(amount, winnerBps, s.rounds[roundId].stakerProtocolBps);
        if (share == 0) return 0;
        s.stakerAccrued[roundId] += share;
        uint256 weight = s.totalWeight;
        if (weight == 0) {
            LibLotteryStorage.accountingStorage().assetAccounting[asset].treasuryAvailable += share;
            emit FiddyZeroWeightRevenue(roundId, asset, share);
        } else {
            FiddyAsset storage revenue = s.assets[asset];
            revenue.reserved += share;
            revenue.indexRay += Math.mulDiv(share, RAY, weight);
            dust(asset, mulmod(share, RAY, weight));
            emit FiddyRevenueBooked(roundId, asset, share, weight, revenue.indexRay);
        }
    }

    function accrued(uint256 id, address asset)
        internal
        view
        returns (uint256 whole, uint256 remainder)
    {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        FiddyCredit storage c = s.credits[id][asset];
        uint256 delta = s.assets[asset].indexRay - c.paidIndex;
        uint256 weight = s.accounts[id].weight;
        whole = c.claimable + Math.mulDiv(weight, delta, RAY);
        uint256 fraction = mulmod(weight, delta, RAY) + c.remainderRay;
        whole += fraction / RAY;
        remainder = fraction % RAY;
    }

    function checkpoint(uint256 id, address asset) internal {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        FiddyCredit storage c = s.credits[id][asset];
        (c.claimable, c.remainderRay) = accrued(id, asset);
        c.paidIndex = s.assets[asset].indexRay;
    }

    /// @dev Complete in one call; listing is capped at MAX_REVENUE_ASSETS.
    function checkpointAll(uint256 id) internal {
        address[] storage assets = LibFiddyStorage.state().revenueAssets;
        uint256 count = assets.length;
        for (uint256 i; i < count; ++i) {
            checkpoint(id, assets[i]);
        }
    }

    function updateWeight(uint256 id) internal {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        FiddyAccount storage a = s.accounts[id];
        uint256 weight = Math.mulDiv(a.staked, a.registered ? a.multiplierBps : BPS, BPS);
        s.totalWeight = s.totalWeight - a.weight + weight;
        a.weight = weight;
    }

    function clearRegistration(uint256 id) internal {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        FiddyAccount storage a = s.accounts[id];
        if (a.registered) delete s.operatorAccount[a.operatorId];
        a.registered = false;
        a.operatorId = 0;
        a.multiplierBps = BPS;
    }

    function dust(address asset, uint256 scaled) internal {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        FiddyAsset storage revenue = s.assets[asset];
        // Consume whole dust immediately so accumulated scaled values remain bounded.
        uint256 whole = scaled / RAY;
        uint256 fraction = revenue.dustRay + scaled % RAY;
        whole += fraction / RAY;
        revenue.dustRay = fraction % RAY;
        if (whole != 0) {
            revenue.reserved -= whole;
            LibLotteryStorage.accountingStorage().assetAccounting[asset].treasuryAvailable += whole;
        }
    }
}
