// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IERC721 } from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import { Math } from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import { IFiddyActivation } from "../interfaces/IFiddyProtocol.sol";
import { LibFiddyStorage } from "./LibFiddyStorage.sol";
import { LibLotteryStorage } from "./LibLotteryStorage.sol";
import { FiddyAccount, FiddyAsset, FiddyCredit } from "../shared/FiddyTypes.sol";
import { FiddyErrors } from "../shared/FiddyErrors.sol";

library LibFiddyStaking {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_REVENUE_ASSETS = 64;
    uint256 internal constant STAKE_LOCK = 24 hours;
    event FiddyRevenueAssetListed(address indexed asset);
    event FiddyRevenueBooked(
        uint256 indexed roundId,
        address indexed asset,
        uint256 amount,
        uint256 totalWeight,
        uint256 indexRay
    );
    event FiddyZeroWeightRevenue(uint256 indexed roundId, address indexed asset, uint256 amount);
    event FiddyBoostForfeited(
        uint256 indexed positionId,
        uint256 indexed operatorId,
        address indexed asset,
        uint256 amount,
        uint256 indexRay
    );
    event FiddyBoostRevoked(uint256 indexed positionId, uint256 indexed operatorId);

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
        return accrued(id, asset, LibFiddyStorage.state().accounts[id].weight);
    }

    function accrued(uint256 id, address asset, uint256 weight)
        internal
        view
        returns (uint256 whole, uint256 remainder)
    {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        FiddyCredit storage c = s.credits[id][asset];
        uint256 delta = s.assets[asset].indexRay - c.paidIndex;
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

    /// @notice Checkpoints every listed asset, first forfeiting a boost that is no longer valid.
    function sync(uint256 id) internal {
        if (boostValid(id)) checkpointAll(id);
        else forfeit(id);
    }

    /// @dev Activation only rises while one holder keeps the Operator NFT, and every
    /// owner-changing Genesis transfer resets it, so a lower multiplier means the NFT moved. The
    /// boost also requires one current owner for both NFTs, so a position sale drops it.
    function boostValid(uint256 id) internal view returns (bool) {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        FiddyAccount storage a = s.accounts[id];
        if (!a.registered) return true;
        if (IFiddyActivation(s.registry).multiplierBps(a.operatorId) < a.multiplierBps) {
            return false;
        }
        return IERC721(s.operators).ownerOf(a.operatorId) == IERC721(s.positionNFT).ownerOf(id);
    }

    /// @notice Books base accrual since the last checkpoint and redistributes the boosted excess
    /// to every other weight, or to Treasury when none exists, then clears the registration.
    function forfeit(uint256 id) internal {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        FiddyAccount storage a = s.accounts[id];
        uint256 excessWeight = a.weight - a.staked;
        uint256 otherWeight = s.totalWeight - a.weight;
        address[] storage assets = s.revenueAssets;
        uint256 count = assets.length;
        for (uint256 i; i < count; ++i) {
            _forfeitAsset(id, assets[i], excessWeight, otherWeight);
        }
        uint256 operatorId = a.operatorId;
        clearRegistration(id);
        updateWeight(id);
        emit FiddyBoostRevoked(id, operatorId);
    }

    function _forfeitAsset(uint256 id, address asset, uint256 excessWeight, uint256 otherWeight)
        private
    {
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        FiddyAsset storage revenue = s.assets[asset];
        FiddyCredit storage c = s.credits[id][asset];
        uint256 delta = revenue.indexRay - c.paidIndex;
        (c.claimable, c.remainderRay) = accrued(id, asset, s.accounts[id].staked);
        if (excessWeight != 0 && delta != 0) {
            // The excess is excessWeight * delta in RAY-scaled units.
            uint256 amount = Math.mulDiv(excessWeight, delta, RAY);
            if (otherWeight == 0) {
                revenue.reserved -= amount;
                LibLotteryStorage.accountingStorage()
                        .assetAccounting[asset]
                        .treasuryAvailable += amount;
                dust(asset, mulmod(excessWeight, delta, RAY));
            } else {
                revenue.indexRay += Math.mulDiv(excessWeight, delta, otherWeight);
                dust(asset, mulmod(excessWeight, delta, otherWeight));
            }
            emit FiddyBoostForfeited(id, s.accounts[id].operatorId, asset, amount, revenue.indexRay);
        }
        // The account takes no part of its own forfeit.
        c.paidIndex = revenue.indexRay;
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
