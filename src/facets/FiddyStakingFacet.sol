// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IERC721 } from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import { Math } from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { LibFiddy } from "../libraries/LibFiddy.sol";
import { LibFiddyStorage } from "../libraries/LibFiddyStorage.sol";
import { LibFiddyStaking } from "../libraries/LibFiddyStaking.sol";
import { LibDiamond } from "../libraries/LibDiamond.sol";
import { LibReentrancy } from "../libraries/LibReentrancy.sol";
import { LibLotteryStorage } from "../libraries/LibLotteryStorage.sol";
import { LibExactToken } from "../libraries/LibExactToken.sol";
import { IFiddyActivation } from "../interfaces/IFiddyProtocol.sol";
import { IStaticsExternalModules } from "../interfaces/IStaticsExternalModules.sol";
import { FiddyAccount, FiddyCredit } from "../shared/FiddyTypes.sol";
import { FiddyErrors } from "../shared/FiddyErrors.sol";
import { Errors } from "../shared/Errors.sol";

contract FiddyStakingFacet {
    event FiddyStaked(
        uint256 indexed positionId, uint256 amount, uint256 weight, uint256 stakeStart
    );
    event FiddyUnstaked(uint256 indexed positionId, uint256 amount, uint256 weight);
    event FiddyOperatorRegistered(
        uint256 indexed positionId, uint256 indexed operatorId, uint256 multiplierBps
    );
    event FiddyOperatorRemoved(uint256 indexed positionId);
    event FiddyBoostsEnabled(bool enabled);
    event FiddyRevenueClaimed(
        uint256 indexed positionId, address indexed asset, address indexed receiver, uint256 amount
    );
    event FiddyAccountClosed(uint256 indexed positionId);
    modifier guarded() {
        LibReentrancy.enter();
        _;
        LibReentrancy.exit();
    }

    /// @notice Gates new registrations only; existing boosts are validated at checkpoints.
    function setFiddyBoostsEnabled(bool enabled) external {
        LibDiamond.enforceAuthority();
        LibFiddy.enforceInitialized();
        LibFiddyStorage.state().boostsEnabled = enabled;
        emit FiddyBoostsEnabled(enabled);
    }

    /// @notice Permissionlessly books an account's accrued revenue across every listed asset.
    function checkpointFiddyAccount(uint256 id) external guarded {
        LibFiddy.enforceInitialized();
        IERC721(LibFiddyStorage.state().positionNFT).ownerOf(id);
        LibFiddyStaking.checkpointAll(id);
    }

    function stakeFiddy(uint256 id, uint256 amount) external guarded {
        LibFiddy.enforceOwner(id);
        _active();
        if (amount == 0) revert Errors.ZeroAmount();
        FiddyAccount storage a = LibFiddyStorage.state().accounts[id];
        if (amount > a.balance - a.staked) revert FiddyErrors.InsufficientFiddy();
        LibFiddyStaking.checkpointAll(id);
        // Credit time already served by the prior stake, weighted by size and rounded toward a
        // longer lock, as Statics does for pending reward eligibility.
        uint256 prior = a.staked;
        uint256 credit;
        if (prior != 0) {
            credit = Math.min(block.timestamp - a.stakeStart, LibFiddyStaking.STAKE_LOCK);
        }
        a.stakeStart =
            SafeCast.toUint64(block.timestamp - Math.mulDiv(prior, credit, prior + amount));
        a.staked = prior + amount;
        LibFiddyStaking.updateWeight(id);
        emit FiddyStaked(id, amount, a.weight, a.stakeStart);
    }

    function unstakeFiddy(uint256 id, uint256 amount) external guarded {
        LibFiddy.enforceOwner(id);
        if (amount == 0) revert Errors.ZeroAmount();
        FiddyAccount storage a = LibFiddyStorage.state().accounts[id];
        if (amount > a.staked) revert FiddyErrors.InsufficientFiddy();
        uint256 unlockAt = uint256(a.stakeStart) + LibFiddyStaking.STAKE_LOCK;
        if (block.timestamp < unlockAt) revert FiddyErrors.StakeLocked(unlockAt);
        LibFiddyStaking.checkpointAll(id);
        a.staked -= amount;
        LibFiddyStaking.updateWeight(id);
        emit FiddyUnstaked(id, amount, a.weight);
    }

    /// @notice Register, switch or explicitly refresh the boost from a caller-owned Operator.
    function registerFiddyOperator(uint256 id, uint256 operatorId) external guarded {
        LibFiddy.enforceOwner(id);
        _active();
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        if (!s.boostsEnabled) revert FiddyErrors.InvalidRegistration();
        if (IERC721(s.operators).ownerOf(operatorId) != msg.sender) {
            revert FiddyErrors.InvalidRegistration();
        }
        uint256 occupied = s.operatorAccount[operatorId];
        if (occupied != 0 && occupied != id) revert FiddyErrors.OperatorAlreadyRegistered();
        uint256 multiplier = IFiddyActivation(s.registry).multiplierBps(operatorId);
        if (multiplier < 10_000 || multiplier > 12_500) revert FiddyErrors.InvalidRegistration();
        LibFiddy.attach(id);
        LibFiddyStaking.checkpointAll(id);
        LibFiddyStaking.clearRegistration(id);
        FiddyAccount storage a = s.accounts[id];
        a.registered = true;
        a.operatorId = operatorId;
        a.multiplierBps = multiplier;
        s.operatorAccount[operatorId] = id;
        LibFiddyStaking.updateWeight(id);
        emit FiddyOperatorRegistered(id, operatorId, multiplier);
    }

    function removeFiddyOperator(uint256 id) external guarded {
        LibFiddy.enforceOwner(id);
        LibFiddyStaking.checkpointAll(id);
        LibFiddyStaking.clearRegistration(id);
        LibFiddyStaking.updateWeight(id);
        emit FiddyOperatorRemoved(id);
    }

    function claimFiddyRevenue(uint256 id, address asset, address receiver)
        external
        guarded
        returns (uint256 amount)
    {
        LibFiddy.enforceOwner(id);
        if (receiver == address(0) || receiver == address(this)) revert Errors.InvalidAddress();
        LibFiddyStaking.checkpointAll(id);
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        FiddyCredit storage c = s.credits[id][asset];
        amount = c.claimable;
        if (amount == 0) return 0;
        c.claimable = 0;
        s.assets[asset].reserved -= amount;
        LibExactToken.pushExact(asset, receiver, amount);
        emit FiddyRevenueClaimed(id, asset, receiver, amount);
    }

    /// @notice Detach an empty account; explicitly surrender only sub-unit revenue dust.
    function cleanupFiddyAccount(uint256 id) external guarded {
        LibFiddy.enforceOwner(id);
        LibFiddyStorage.State storage s = LibFiddyStorage.state();
        FiddyAccount storage a = s.accounts[id];
        if (a.balance != 0 || a.staked != 0) revert FiddyErrors.AccountNotEmpty();
        LibFiddyStaking.checkpointAll(id);
        uint256 count = s.revenueAssets.length;
        for (uint256 i; i < count; ++i) {
            address asset = s.revenueAssets[i];
            FiddyCredit storage c = s.credits[id][asset];
            if (c.claimable != 0) revert FiddyErrors.AccountNotEmpty();
            uint256 fraction = c.remainderRay;
            c.remainderRay = 0;
            LibFiddyStaking.dust(asset, fraction);
        }
        LibFiddyStaking.clearRegistration(id);
        if (a.attached) {
            a.attached = false;
            IStaticsExternalModules(s.positionNFT)
                .detachExternalAccountLeg(id, LibFiddy.MODULE, bytes32(id));
        }
        emit FiddyAccountClosed(id);
    }

    function indexedFiddyRevenue(uint256 id, address asset)
        external
        view
        returns (uint256 amount, uint256 remainderRay)
    {
        return LibFiddyStaking.accrued(id, asset);
    }

    function _active() private view {
        if (LibLotteryStorage.governanceStorage().paused) revert Errors.ProtocolPaused();
    }
}
