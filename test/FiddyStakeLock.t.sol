// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import { FiddyRevenueSetup } from "./FiddyStaking.t.sol";
import { FiddyStaticsIntegrationTest } from "./FiddyStaticsIntegration.t.sol";
import { FiddyTokenFacet } from "../src/facets/FiddyTokenFacet.sol";
import { FiddyStakingFacet } from "../src/facets/FiddyStakingFacet.sol";
import { ILottery } from "../src/interfaces/ILottery.sol";
import { LibFiddyStaking } from "../src/libraries/LibFiddyStaking.sol";
import { FiddyConfig } from "../src/shared/FiddyTypes.sol";
import { FiddyErrors } from "../src/shared/FiddyErrors.sol";
import { LotteryConfig } from "../src/shared/Types.sol";

/// @dev Same-transaction liquidity, as an approved FIDDY consumer or a plain STATICS lender.
contract SameTransactionLender {
    IERC20 internal immutable asset;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function lend(uint256 amount, bytes calldata data) external {
        uint256 before = asset.balanceOf(address(this));
        asset.transfer(msg.sender, amount);
        (bool ok, bytes memory reason) = msg.sender.call(data);
        if (!ok) {
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
        require(asset.balanceOf(address(this)) >= before, "not repaid");
    }
}

/// @dev Owns a PositionNFT and tries to stake borrowed FIDDY around its own ticket purchase.
contract SelfRebateStaker {
    address internal immutable diamond;
    SameTransactionLender internal immutable lender;
    IERC20 internal immutable payment;
    uint256 internal immutable position;

    constructor(
        address diamond_,
        SameTransactionLender lender_,
        IERC20 payment_,
        uint256 position_
    ) {
        diamond = diamond_;
        lender = lender_;
        payment = payment_;
        position = position_;
        payment_.approve(diamond_, type(uint256).max);
    }

    function viaConsumer(uint256 roundId, uint32 tickets, uint256 amount) external {
        lender.lend(amount, abi.encodeCall(this.consumerLeg, (roundId, tickets, amount)));
    }

    function viaWrap(uint256 roundId, uint32 tickets, uint256 amount) external {
        lender.lend(amount, abi.encodeCall(this.wrapLeg, (roundId, tickets, amount)));
    }

    function consumerLeg(uint256 roundId, uint32 tickets, uint256 amount) external {
        require(msg.sender == address(lender));
        FiddyTokenFacet token = FiddyTokenFacet(diamond);
        token.approve(diamond, amount);
        token.depositFiddy(position, amount);
        _stakeBuyAndExit(roundId, tickets, amount);
        token.withdrawFiddy(position, amount, address(this));
        token.transfer(address(lender), amount);
    }

    function wrapLeg(uint256 roundId, uint32 tickets, uint256 amount) external {
        require(msg.sender == address(lender));
        IERC20 underlying = IERC20(_underlying());
        underlying.approve(diamond, amount);
        FiddyTokenFacet(diamond).wrapFiddy(position, amount);
        _stakeBuyAndExit(roundId, tickets, amount);
        FiddyTokenFacet(diamond).unwrapFiddy(position, amount, address(this));
        underlying.transfer(address(lender), amount);
    }

    function _stakeBuyAndExit(uint256 roundId, uint32 tickets, uint256 amount) private {
        FiddyStakingFacet staking = FiddyStakingFacet(diamond);
        staking.stakeFiddy(position, amount);
        ILottery(diamond).buyTickets(roundId, tickets);
        staking.unstakeFiddy(position, amount);
        staking.claimFiddyRevenue(position, address(payment), address(this));
    }

    function _underlying() private view returns (address underlying) {
        (bool ok, bytes memory data) =
            diamond.staticcall(abi.encodeWithSignature("fiddyBindings()"));
        require(ok);
        (underlying,,,) = abi.decode(data, (address, address, address, address));
    }
}

contract FiddyStakeLockTest is FiddyRevenueSetup {
    address internal lp = makeAddr("lp");

    function _flashRound() internal returns (uint256 id) {
        uint64 version = _rewardVersion(address(tokenB));
        vm.prank(alice);
        id = lottery.openRound(version, 1);
    }

    function testFlashConsumerStakeAroundOwnPurchaseRevertsOnLock() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeFiddy(1, 100);
        SameTransactionLender pool = new SameTransactionLender(IERC20(address(diamond)));
        vm.prank(authority);
        fiddy.setFiddyConsumer(address(pool), true);
        positions.mint(lp, 5);
        tokenA.mint(lp, 1_000_000);
        vm.prank(lp);
        tokenA.approve(address(diamond), type(uint256).max);
        _wrap(5, lp, 1_000_000);
        vm.startPrank(lp);
        fiddy.withdrawFiddy(5, 1_000_000, lp);
        IERC20(address(diamond)).transfer(address(pool), 1_000_000);
        vm.stopPrank();

        uint256 id = _flashRound();
        SelfRebateStaker attacker =
            new SelfRebateStaker(address(diamond), pool, IERC20(address(tokenB)), 7);
        positions.mint(address(attacker), 7);
        tokenB.mint(address(attacker), 10_000);
        uint256 unlockAt = block.timestamp + LibFiddyStaking.STAKE_LOCK;
        vm.expectRevert(abi.encodeWithSelector(FiddyErrors.StakeLocked.selector, unlockAt));
        attacker.viaConsumer(id, 9, 1_000_000);

        assertEq(IERC20(address(diamond)).balanceOf(address(pool)), 1_000_000);
        assertEq(fiddyView.fiddyAccount(7).staked, 0);
        assertEq(fiddyView.fiddyRoundRevenue(id), 10);
        assertEq(_earned(1, address(tokenB)), 10);
    }

    function testWrapFlashStakeAroundOwnPurchaseRevertsOnLock() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeFiddy(1, 100);
        vm.prank(authority);
        fiddy.setFiddyConversions(true, true, type(uint128).max);
        SameTransactionLender lender = new SameTransactionLender(IERC20(address(tokenA)));
        tokenA.mint(address(lender), 1_000_000);
        uint256 id = _flashRound();
        SelfRebateStaker attacker =
            new SelfRebateStaker(address(diamond), lender, IERC20(address(tokenB)), 8);
        positions.mint(address(attacker), 8);
        tokenB.mint(address(attacker), 10_000);
        (,,,,,, uint256 outstanding) = fiddyView.fiddyReserve();
        uint256 unlockAt = block.timestamp + LibFiddyStaking.STAKE_LOCK;
        vm.expectRevert(abi.encodeWithSelector(FiddyErrors.StakeLocked.selector, unlockAt));
        attacker.viaWrap(id, 9, 1_000_000);

        (,,,,,, uint256 outstandingAfter) = fiddyView.fiddyReserve();
        assertEq(outstandingAfter, outstanding);
        assertEq(tokenA.balanceOf(address(lender)), 1_000_000);
        assertEq(fiddyView.fiddyAccount(8).balance, 0);
        assertEq(_earned(1, address(tokenB)), 10);
    }

    function testWeightedTopUpOnOldSmallStakeRelocksAlmostFully() public {
        _wrap(1, alice, 1000);
        vm.prank(alice);
        staking.stakeFiddy(1, 1);
        uint256 started = block.timestamp;
        assertEq(fiddyView.fiddyAccount(1).stakeStart, started);
        vm.warp(started + 30 days);
        vm.prank(alice);
        staking.stakeFiddy(1, 999);
        // Credit is capped at the lock: 1 * 24h / 1000 = 86 seconds, rounded down.
        uint256 unlockAt = block.timestamp - 86 + LibFiddyStaking.STAKE_LOCK;
        assertEq(fiddyView.fiddyAccount(1).stakeStart, block.timestamp - 86);
        vm.warp(unlockAt - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FiddyErrors.StakeLocked.selector, unlockAt));
        staking.unstakeFiddy(1, 1);
        vm.warp(unlockAt);
        vm.prank(alice);
        staking.unstakeFiddy(1, 400);
        assertEq(fiddyView.fiddyAccount(1).stakeStart, unlockAt - LibFiddyStaking.STAKE_LOCK);
        vm.prank(alice);
        staking.unstakeFiddy(1, 600);
    }

    function testHalfServedTopUpKeepsProportionalCreditAndLockFollowsSale() public {
        _wrap(1, alice, 200);
        vm.prank(alice);
        staking.stakeFiddy(1, 100);
        vm.warp(block.timestamp + 12 hours);
        vm.prank(alice);
        staking.stakeFiddy(1, 100);
        uint256 unlockAt = block.timestamp + 18 hours;
        assertEq(fiddyView.fiddyAccount(1).stakeStart + LibFiddyStaking.STAKE_LOCK, unlockAt);

        vm.prank(alice);
        positions.transferFrom(alice, bob, 1);
        vm.warp(unlockAt - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FiddyErrors.StakeLocked.selector, unlockAt));
        staking.unstakeFiddy(1, 200);
        vm.warp(unlockAt);
        vm.prank(bob);
        staking.unstakeFiddy(1, 200);

        // A fresh stake after a full exit receives no credit for the earlier stake.
        vm.prank(bob);
        staking.stakeFiddy(1, 50);
        assertEq(fiddyView.fiddyAccount(1).stakeStart, block.timestamp);
    }

    function testFuzzTopUpLockNeverShortensAndMatchesWeightedCredit(
        uint256 rawPrior,
        uint256 rawAmount,
        uint256 rawElapsed
    ) public {
        uint256 prior = bound(rawPrior, 1, 1e24);
        uint256 amount = bound(rawAmount, 1, 1e24);
        uint256 elapsed = bound(rawElapsed, 0, 90 days);
        tokenA.mint(alice, prior + amount);
        _wrap(1, alice, prior + amount);
        vm.prank(alice);
        staking.stakeFiddy(1, prior);
        uint256 first = fiddyView.fiddyAccount(1).stakeStart;
        vm.warp(block.timestamp + elapsed);
        vm.prank(alice);
        staking.stakeFiddy(1, amount);
        uint256 credit = elapsed < LibFiddyStaking.STAKE_LOCK ? elapsed : LibFiddyStaking.STAKE_LOCK;
        uint256 start = fiddyView.fiddyAccount(1).stakeStart;
        assertEq(start, block.timestamp - prior * credit / (prior + amount));
        assertGe(start, first);
        assertGe(start + LibFiddyStaking.STAKE_LOCK, block.timestamp);
    }
}

interface IStaticsPositionFactory {
    function createPosition(address receiver) external payable returns (uint256);
    function positionCreationFee() external view returns (uint256);
}

/// @notice The same flash routes against the actual pinned Statics artifacts.
contract FiddyStakeLockActualStaticsTest is FiddyStaticsIntegrationTest {
    function _attacker(SameTransactionLender lender) internal returns (SelfRebateStaker attacker) {
        address mallory = makeAddr("mallory");
        IStaticsPositionFactory factory = IStaticsPositionFactory(address(core));
        uint256 fee = factory.positionCreationFee();
        vm.deal(mallory, fee);
        vm.prank(mallory);
        uint256 id = factory.createPosition{ value: fee }(mallory);
        attacker = new SelfRebateStaker(address(diamond), lender, IERC20(address(tokenB)), id);
        vm.prank(mallory);
        IERC721(address(core)).transferFrom(mallory, address(attacker), id);
        tokenB.mint(address(attacker), 10_000);
    }

    function _round() internal returns (uint256 id) {
        router.setAsset(address(tokenB), true, true);
        vm.startPrank(authority);
        uint64 version = governance.createRewardLotteryConfig(
            _config(address(tokenB), 100, 10, 10, 1 days, 0), FiddyConfig(0, 5000, false)
        );
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
        vm.prank(bob);
        id = lottery.openRound(version, 1);
    }

    function _honestStake() internal {
        vm.prank(authority);
        fiddy.setFiddyConversions(true, true, type(uint128).max);
        vm.startPrank(alice);
        statics.approve(address(diamond), type(uint256).max);
        fiddy.wrapFiddy(positionId, 100 ether);
        staking.stakeFiddy(positionId, 100 ether);
        vm.stopPrank();
    }

    function testActualStaticsWrapFlashStakeRevertsOnLock() public {
        _honestStake();
        uint256 id = _round();
        SameTransactionLender lender = new SameTransactionLender(statics);
        deal(address(statics), address(lender), 1_000_000 ether);
        SelfRebateStaker attacker = _attacker(lender);
        uint256 unlockAt = block.timestamp + LibFiddyStaking.STAKE_LOCK;
        vm.expectRevert(abi.encodeWithSelector(FiddyErrors.StakeLocked.selector, unlockAt));
        attacker.viaWrap(id, 9, 1_000_000 ether);
        assertEq(statics.balanceOf(address(lender)), 1_000_000 ether);
        (uint256 honest,) = staking.indexedFiddyRevenue(positionId, address(tokenB));
        assertEq(honest, 10);
    }

    function testActualStaticsConsumerFlashStakeRevertsOnLock() public {
        _honestStake();
        uint256 id = _round();
        SameTransactionLender pool = new SameTransactionLender(IERC20(address(diamond)));
        vm.prank(authority);
        fiddy.setFiddyConsumer(address(pool), true);
        vm.startPrank(alice);
        fiddy.wrapFiddy(positionId, 50 ether);
        fiddy.withdrawFiddy(positionId, 50 ether, alice);
        IERC20(address(diamond)).transfer(address(pool), 50 ether);
        vm.stopPrank();
        SelfRebateStaker attacker = _attacker(pool);
        uint256 unlockAt = block.timestamp + LibFiddyStaking.STAKE_LOCK;
        vm.expectRevert(abi.encodeWithSelector(FiddyErrors.StakeLocked.selector, unlockAt));
        attacker.viaConsumer(id, 9, 50 ether);
        assertEq(IERC20(address(diamond)).balanceOf(address(pool)), 50 ether);
        (uint256 honest,) = staking.indexedFiddyRevenue(positionId, address(tokenB));
        assertEq(honest, 10);
    }
}
