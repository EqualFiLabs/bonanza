// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IERC721 } from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import { Math } from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { LibBonanza } from "../libraries/LibBonanza.sol";
import { LibBonanzaStorage } from "../libraries/LibBonanzaStorage.sol";
import { LibBonanzaStaking } from "../libraries/LibBonanzaStaking.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibReentrancy } from "../libraries/LibReentrancy.sol";
import { LibLotteryStorage } from "../libraries/LibLotteryStorage.sol";
import { LibExactToken } from "../libraries/LibExactToken.sol";
import { IBonanzaActivation } from "../interfaces/IBonanzaProtocol.sol";
import { IStaticsExternalModules } from "../interfaces/IStaticsExternalModules.sol";
import { BonanzaAccount, BonanzaCredit } from "../shared/BonanzaTypes.sol";
import { BonanzaErrors } from "../shared/BonanzaErrors.sol";
import { Errors } from "../shared/Errors.sol";

contract BonanzaStakingFacet {
    event BonanzaStaked(
        uint256 indexed positionId, uint256 amount, uint256 weight, uint256 stakeStart
    );
    event BonanzaUnstaked(uint256 indexed positionId, uint256 amount, uint256 weight);
    event BonanzaOperatorRegistered(
        uint256 indexed positionId, uint256 indexed operatorId, uint256 multiplierBps
    );
    event BonanzaOperatorRemoved(uint256 indexed positionId);
    event BonanzaBoostsEnabled(bool enabled);
    event BonanzaRevenueClaimed(
        uint256 indexed positionId, address indexed asset, address indexed receiver, uint256 amount
    );
    event BonanzaAccountClosed(uint256 indexed positionId);
    modifier guarded() {
        LibReentrancy.enter();
        _;
        LibReentrancy.exit();
    }

    /// @notice Gates new registrations only; existing boosts are validated at checkpoints.
    function setBonanzaBoostsEnabled(bool enabled) external {
        LibDiamond.enforceAuthority();
        LibBonanza.enforceInitialized();
        LibBonanzaStorage.state().boostsEnabled = enabled;
        emit BonanzaBoostsEnabled(enabled);
    }

    /// @notice Permissionlessly books an account's accrued revenue across every listed asset and
    /// forfeits a boost whose Operator or PositionNFT ownership no longer qualifies.
    function checkpointBonanzaAccount(uint256 id) external guarded {
        LibBonanza.enforceInitialized();
        IERC721(LibBonanzaStorage.state().positionNFT).ownerOf(id);
        LibBonanzaStaking.sync(id);
    }

    function stakeBonanza(uint256 id, uint256 amount) external guarded {
        LibBonanza.enforceOwner(id);
        _active();
        if (amount == 0) revert Errors.ZeroAmount();
        BonanzaAccount storage a = LibBonanzaStorage.state().accounts[id];
        if (amount > a.balance - a.staked) revert BonanzaErrors.InsufficientBonanza();
        LibBonanzaStaking.sync(id);
        // Credit time already served by the prior stake, weighted by size and rounded toward a
        // longer lock, as Statics does for pending reward eligibility.
        uint256 prior = a.staked;
        uint256 credit;
        if (prior != 0) {
            credit = Math.min(block.timestamp - a.stakeStart, LibBonanzaStaking.STAKE_LOCK);
        }
        a.stakeStart =
            SafeCast.toUint64(block.timestamp - Math.mulDiv(prior, credit, prior + amount));
        a.staked = prior + amount;
        LibBonanzaStaking.updateWeight(id);
        LibBonanza.touch(id);
        emit BonanzaStaked(id, amount, a.weight, a.stakeStart);
    }

    function unstakeBonanza(uint256 id, uint256 amount) external guarded {
        LibBonanza.enforceOwner(id);
        if (amount == 0) revert Errors.ZeroAmount();
        BonanzaAccount storage a = LibBonanzaStorage.state().accounts[id];
        if (amount > a.staked) revert BonanzaErrors.InsufficientBonanza();
        uint256 unlockAt = uint256(a.stakeStart) + LibBonanzaStaking.STAKE_LOCK;
        if (block.timestamp < unlockAt) revert BonanzaErrors.StakeLocked(unlockAt);
        LibBonanzaStaking.sync(id);
        a.staked -= amount;
        LibBonanzaStaking.updateWeight(id);
        LibBonanza.touch(id);
        emit BonanzaUnstaked(id, amount, a.weight);
    }

    /// @notice Register, switch or explicitly refresh the boost from a caller-owned Operator. An
    /// Operator still registered to another account is taken over only if that boost is invalid.
    function registerBonanzaOperator(uint256 id, uint256 operatorId) external guarded {
        LibBonanza.enforceOwner(id);
        _active();
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        if (!s.boostsEnabled) revert BonanzaErrors.InvalidRegistration();
        if (IERC721(s.operators).ownerOf(operatorId) != msg.sender) {
            revert BonanzaErrors.InvalidRegistration();
        }
        uint256 multiplier = IBonanzaActivation(s.registry).multiplierBps(operatorId);
        if (multiplier < 10_000 || multiplier > 12_500) revert BonanzaErrors.InvalidRegistration();
        uint256 occupied = s.operatorAccount[operatorId];
        if (occupied != 0 && occupied != id) {
            if (LibBonanzaStaking.boostValid(occupied)) {
                revert BonanzaErrors.OperatorAlreadyRegistered();
            }
            LibBonanzaStaking.forfeit(occupied);
        }
        LibBonanza.attach(id);
        // Checkpoint after an eviction moves the index, so this account books at its old weight.
        LibBonanzaStaking.sync(id);
        LibBonanzaStaking.clearRegistration(id);
        BonanzaAccount storage a = s.accounts[id];
        a.registered = true;
        a.operatorId = operatorId;
        a.multiplierBps = multiplier;
        s.operatorAccount[operatorId] = id;
        LibBonanzaStaking.updateWeight(id);
        LibBonanza.touch(id);
        emit BonanzaOperatorRegistered(id, operatorId, multiplier);
    }

    function removeBonanzaOperator(uint256 id) external guarded {
        LibBonanza.enforceOwner(id);
        LibBonanzaStaking.sync(id);
        LibBonanzaStaking.clearRegistration(id);
        LibBonanzaStaking.updateWeight(id);
        LibBonanza.touch(id);
        emit BonanzaOperatorRemoved(id);
    }

    function claimBonanzaRevenue(uint256 id, address asset, address receiver)
        external
        guarded
        returns (uint256 amount)
    {
        LibBonanza.enforceOwner(id);
        if (receiver == address(0) || receiver == address(this)) revert Errors.InvalidAddress();
        LibBonanzaStaking.sync(id);
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        BonanzaCredit storage c = s.credits[id][asset];
        amount = c.claimable;
        if (amount == 0) return 0;
        c.claimable = 0;
        s.assets[asset].reserved -= amount;
        LibBonanza.touch(id);
        LibExactToken.pushExact(asset, receiver, amount);
        emit BonanzaRevenueClaimed(id, asset, receiver, amount);
    }

    /// @notice Detach an empty account; explicitly surrender only sub-unit revenue dust.
    function cleanupBonanzaAccount(uint256 id) external guarded {
        LibBonanza.enforceOwner(id);
        LibBonanzaStorage.State storage s = LibBonanzaStorage.state();
        BonanzaAccount storage a = s.accounts[id];
        if (a.balance != 0 || a.staked != 0) revert BonanzaErrors.AccountNotEmpty();
        LibBonanzaStaking.sync(id);
        uint256 count = s.revenueAssets.length;
        for (uint256 i; i < count; ++i) {
            address asset = s.revenueAssets[i];
            BonanzaCredit storage c = s.credits[id][asset];
            if (c.claimable != 0) revert BonanzaErrors.AccountNotEmpty();
            uint256 fraction = c.remainderRay;
            c.remainderRay = 0;
            LibBonanzaStaking.dust(asset, fraction);
        }
        LibBonanzaStaking.clearRegistration(id);
        LibBonanza.touch(id);
        if (a.attached) {
            a.attached = false;
            IStaticsExternalModules(s.positionNFT)
                .detachExternalAccountLeg(id, LibBonanza.MODULE, bytes32(id));
        }
        emit BonanzaAccountClosed(id);
    }

    /// @notice Revenue a claim would pay now, after any pending boost forfeit.
    function indexedBonanzaRevenue(uint256 id, address asset)
        external
        view
        returns (uint256 amount, uint256 remainderRay)
    {
        BonanzaAccount storage a = LibBonanzaStorage.state().accounts[id];
        uint256 weight = LibBonanzaStaking.boostValid(id) ? a.weight : a.staked;
        return LibBonanzaStaking.accrued(id, asset, weight);
    }

    function _active() private view {
        if (LibLotteryStorage.governanceStorage().paused) revert Errors.ProtocolPaused();
    }
}
