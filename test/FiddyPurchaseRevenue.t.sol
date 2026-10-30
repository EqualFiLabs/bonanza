// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { FiddyRevenueSetup } from "./FiddyStaking.t.sol";
import { IntegrationToken } from "./utils/LotteryIntegrationSetup.sol";
import { SettlementFacet } from "../src/facets/SettlementFacet.sol";
import { ISettlement } from "../src/interfaces/ISettlement.sol";
import { IStaticsExternalModules } from "../src/interfaces/IStaticsExternalModules.sol";
import { LibFiddyStaking } from "../src/libraries/LibFiddyStaking.sol";
import { FiddyAsset, FiddyConfig, FiddyCredit } from "../src/shared/FiddyTypes.sol";
import { FiddyErrors } from "../src/shared/FiddyErrors.sol";
import { AssetAccounting, LotteryConfig } from "../src/shared/Types.sol";

contract StakerAllocationHarness is SettlementFacet {
    function share(uint256 amount, uint16 winnerBps, uint16 stakerBps)
        external
        pure
        returns (uint256)
    {
        return LibFiddyStaking.stakerShare(amount, winnerBps, stakerBps);
    }

    function allocate(
        uint128 gross,
        uint16 winnerBps,
        uint16 operatorBps,
        uint256 staker,
        uint96 finalizerTip
    ) external pure returns (SettlementAmounts memory) {
        return _allocateValues(gross, winnerBps, operatorBps, staker, finalizerTip);
    }
}

contract FiddyStakerShareFuzzTest is FiddyRevenueSetup {
    StakerAllocationHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new StakerAllocationHarness();
    }

    function testFuzzPerPurchaseSharesNeverExceedProtocolRemainder(
        uint256 rawPrice,
        uint256 rawCount,
        uint256 rawWinner,
        uint256 rawOperator,
        uint256 rawStaker,
        uint256 rawTip,
        uint256 seed
    ) public view {
        uint16 operatorBps = uint16(bound(rawOperator, 0, 10_000));
        uint16 stakerBps = uint16(bound(rawStaker, 0, 10_000 - operatorBps));
        _assertSharesCovered(rawPrice, rawCount, rawWinner, operatorBps, stakerBps, rawTip, seed);
    }

    function testFuzzFullProtocolSplitSharesNeverExceedProtocolRemainder(
        uint256 rawPrice,
        uint256 rawCount,
        uint256 rawWinner,
        uint256 rawOperator,
        uint256 rawTip,
        uint256 seed
    ) public view {
        uint16 operatorBps = uint16(bound(rawOperator, 0, 10_000));
        _assertSharesCovered(
            rawPrice, rawCount, rawWinner, operatorBps, 10_000 - operatorBps, rawTip, seed
        );
    }

    /// @dev Small prices and one-ticket purchases maximize the number of floors taken.
    function testFuzzOneTicketPurchasesNeverExceedProtocolRemainder(
        uint256 rawPrice,
        uint256 rawCount,
        uint256 rawWinner,
        uint256 rawOperator
    ) public view {
        uint256 price = bound(rawPrice, 1, 1000);
        uint256 count = bound(rawCount, 1, 200);
        uint16 winnerBps = uint16(bound(rawWinner, 0, 10_000));
        uint16 operatorBps = uint16(bound(rawOperator, 0, 10_000));
        uint16 stakerBps = 10_000 - operatorBps;
        uint256 booked;
        for (uint256 i; i < count; ++i) {
            booked += harness.share(price, winnerBps, stakerBps);
        }
        _assertAllocation(price * count, winnerBps, operatorBps, booked, 0);
    }

    function _assertSharesCovered(
        uint256 rawPrice,
        uint256 rawCount,
        uint256 rawWinner,
        uint16 operatorBps,
        uint16 stakerBps,
        uint256 rawTip,
        uint256 seed
    ) internal view {
        uint256 price = bound(rawPrice, 1, type(uint96).max);
        uint256 count = bound(rawCount, 1, type(uint32).max);
        uint16 winnerBps = uint16(bound(rawWinner, 0, 10_000));
        uint256 booked;
        uint256 remaining = count;
        for (uint256 i; remaining != 0; ++i) {
            uint256 quantity =
                i == 15 ? remaining : bound(uint256(keccak256(abi.encode(seed, i))), 1, remaining);
            booked += harness.share(price * quantity, winnerBps, stakerBps);
            remaining -= quantity;
        }
        assertLe(booked, harness.share(price * count, winnerBps, stakerBps));
        _assertAllocation(
            price * count, winnerBps, operatorBps, booked, bound(rawTip, 0, type(uint96).max)
        );
    }

    function _assertAllocation(
        uint256 gross,
        uint16 winnerBps,
        uint16 operatorBps,
        uint256 booked,
        uint256 tip
    ) internal view {
        SettlementFacet.SettlementAmounts memory amounts = harness.allocate(
            uint128(gross), winnerBps, operatorBps, booked, uint96(tip)
        );
        assertLe(booked, gross - amounts.winner - amounts.operator);
        assertEq(amounts.staker, booked);
        assertEq(
            amounts.winner + amounts.operator + amounts.staker + amounts.treasury
                + amounts.finalizer,
            gross
        );
    }
}

contract FiddyPurchaseRevenueTest is FiddyRevenueSetup {
    uint256 internal constant RAY = 1e27;

    function testFuzzSplitPurchasesConserveReceiptsAndCustody(
        uint256 rawPrice,
        uint256 rawWinner,
        uint256 rawOperator,
        uint256 rawStaker,
        uint256 rawTip,
        uint256 seed
    ) public {
        _start();
        LotteryConfig memory config =
            _config(address(tokenB), uint96(bound(rawPrice, 1, 400)), 20, 20, 1 days, 0);
        config.winnerBps = uint16(bound(rawWinner, 0, 10_000));
        config.operatorProtocolBps = uint16(bound(rawOperator, 0, 10_000));
        config.finalizerTip = uint96(bound(rawTip, 0, 10_000));
        uint16 stakerBps = uint16(bound(rawStaker, 0, 10_000 - config.operatorProtocolBps));
        vm.startPrank(authority);
        uint64 version =
            governance.createRewardLotteryConfig(config, FiddyConfig(0, stakerBps, false));
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();

        uint32 quantity = uint32(bound(seed, 1, 20));
        vm.prank(alice);
        uint256 id = lottery.openRound(version, quantity);
        uint32 sold = quantity;
        for (uint256 i = 1; sold < 20; ++i) {
            quantity = uint32(bound(uint256(keccak256(abi.encode(seed, i))), 1, 20 - sold));
            vm.prank(i % 2 == 0 ? alice : bob);
            lottery.buyTickets(id, quantity);
            sold += quantity;
        }
        uint256 gross = uint256(config.ticketPrice) * 20;
        uint256 booked = fiddyView.fiddyRoundRevenue(id);
        assertEq(stateView.assetAccounting(address(tokenB)).activeRoundEscrow, gross - booked);
        _settleRound(id);

        AssetAccounting memory accounting = stateView.assetAccounting(address(tokenB));
        assertEq(accounting.activeRoundEscrow, 0);
        assertEq(
            accounting.winnerLiability + accounting.pendingOperatorRevenueTotal
                + accounting.treasuryAvailable + accounting.finalizerLiability
                + fiddyView.fiddyAsset(address(tokenB)).reserved,
            gross
        );
        assertEq(tokenB.balanceOf(address(diamond)), gross);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
        _assertReservedMatchesEntitlements(address(tokenB));
    }

    function testStakeJustBeforeSettlementEarnsNothingFromEarlierPurchases() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeFiddy(1, 100);
        vm.startPrank(authority);
        uint64 version = governance.createRewardLotteryConfig(
            _config(address(tokenB), 100, 10, 10, 7 days, 0), FiddyConfig(0, 5000, false)
        );
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
        vm.prank(alice);
        uint256 id = lottery.openRound(version, 5);
        vm.warp(block.timestamp + 6 days);
        vm.prank(bob);
        lottery.buyTickets(id, 4);

        // A large stake arrives just before the deadline and settlement of a week-long round.
        vm.warp(block.timestamp + 1 days - 1);
        tokenA.mint(bob, 1_000_000);
        _wrap(2, bob, 1_000_000);
        vm.prank(bob);
        staking.stakeFiddy(2, 1_000_000);
        _settleRound(id);

        assertEq(fiddyView.fiddyRoundRevenue(id), 90);
        assertEq(_earned(1, address(tokenB)), 90);
        assertEq(_earned(2, address(tokenB)), 0);
        vm.prank(bob);
        assertEq(staking.claimFiddyRevenue(2, address(tokenB), bob), 0);
    }

    function testConcurrentRoundsIsolateEscrowAndStakerRevenueByToken() public {
        _start();
        uint64 versionA = _rewardVersion(address(tokenA));
        uint64 versionB = _rewardVersion(address(tokenB));
        uint256 balanceA = tokenA.balanceOf(address(diamond));
        vm.prank(alice);
        uint256 roundA = lottery.openRound(versionA, 3);
        vm.prank(bob);
        uint256 roundB = lottery.openRound(versionB, 4);
        vm.prank(bob);
        lottery.buyTickets(roundA, 2);
        vm.prank(alice);
        lottery.buyTickets(roundB, 6); // sells out B

        assertEq(fiddyView.fiddyRoundRevenue(roundA), 50);
        assertEq(fiddyView.fiddyRoundRevenue(roundB), 100);
        assertEq(stateView.assetAccounting(address(tokenA)).activeRoundEscrow, 450);
        assertEq(stateView.assetAccounting(address(tokenB)).activeRoundEscrow, 900);
        assertEq(fiddyView.fiddyAsset(address(tokenA)).reserved, 50);
        assertEq(fiddyView.fiddyAsset(address(tokenB)).reserved, 100);
        assertEq(tokenA.balanceOf(address(diamond)), balanceA + 500);
        assertEq(tokenB.balanceOf(address(diamond)), 1000);

        _settleRound(roundB);
        assertEq(stateView.assetAccounting(address(tokenA)).activeRoundEscrow, 450);
        assertEq(fiddyView.fiddyAsset(address(tokenA)).reserved, 50);
        assertEq(stateView.assetAccounting(address(tokenB)).activeRoundEscrow, 0);
        assertEq(stateView.assetAccounting(address(tokenB)).winnerLiability, 800);
        assertEq(stateView.pendingOperatorRevenue(1, address(tokenB)), 100);

        uint256 aliceB = tokenB.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = staking.claimFiddyRevenue(1, address(tokenB), alice);
        assertEq(claimed, 55);
        assertEq(tokenB.balanceOf(alice), aliceB + 55);
        assertEq(tokenB.balanceOf(address(diamond)), 1000 - 55);
        assertEq(tokenA.balanceOf(address(diamond)), balanceA + 500);
        assertEq(fiddyView.fiddyAsset(address(tokenA)).reserved, 50);

        vm.warp(stateView.round(roundA).expiresAt);
        _settleRound(roundA);
        AssetAccounting memory accountingA = stateView.assetAccounting(address(tokenA));
        assertEq(accountingA.activeRoundEscrow, 0);
        assertEq(accountingA.winnerLiability, 400);
        assertEq(stateView.pendingOperatorRevenue(1, address(tokenA)), 50);
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
        _assertReservedMatchesEntitlements(address(tokenA));
        _assertReservedMatchesEntitlements(address(tokenB));
    }

    function testSettlementReportsBookedStakerTotal() public {
        _start();
        uint64 version = _rewardVersion(address(tokenB));
        vm.prank(alice);
        uint256 id = lottery.openRound(version, 3);
        vm.prank(bob);
        lottery.buyTickets(id, 7);
        bytes memory proof = abi.encode(id);
        _prepareProof(id, proof);
        vm.expectEmit(true, true, false, true, address(diamond));
        emit ISettlement.StakerRevenueSettled(id, address(tokenB), 100);
        vm.prank(finalizer);
        settlement.settleRound(id, proof);
    }

    function testRevenueAssetsListAtRewardConfigCreationUpToLimit() public {
        vm.startPrank(authority);
        governance.createRewardLotteryConfig(
            _config(address(tokenB), 100, 10, 10, 1 days, 0), FiddyConfig(0, 0, false)
        );
        governance.createLotteryConfig(_config(address(tokenB), 100, 10, 10, 1 days, 0));
        assertFalse(fiddyView.fiddyAsset(address(tokenB)).listed);
        vm.expectEmit(true, false, false, false, address(diamond));
        emit LibFiddyStaking.FiddyRevenueAssetListed(address(tokenB));
        governance.createRewardLotteryConfig(
            _config(address(tokenB), 100, 10, 10, 1 days, 0), FiddyConfig(0, 1, false)
        );
        governance.createRewardLotteryConfig(
            _config(address(tokenB), 100, 10, 10, 1 days, 0), FiddyConfig(0, 2, false)
        );
        assertEq(fiddyView.fiddyRevenueAssets().length, 1);
        for (uint256 i = 1; i < 64; ++i) {
            IntegrationToken extra = new IntegrationToken("Extra", "EXT");
            governance.createRewardLotteryConfig(
                _config(address(extra), 100, 10, 10, 1 days, 0), FiddyConfig(0, 1, false)
            );
        }
        address[] memory listed = fiddyView.fiddyRevenueAssets();
        assertEq(listed.length, 64);
        assertEq(listed[0], address(tokenB));
        IntegrationToken overflow = new IntegrationToken("Overflow", "OVR");
        vm.expectRevert(FiddyErrors.RevenueAssetLimitReached.selector);
        governance.createRewardLotteryConfig(
            _config(address(overflow), 100, 10, 10, 1 days, 0), FiddyConfig(0, 1, false)
        );
        // Zero staker share and already-listed assets remain configurable at the cap.
        governance.createRewardLotteryConfig(
            _config(address(overflow), 100, 10, 10, 1 days, 0), FiddyConfig(0, 0, false)
        );
        governance.createRewardLotteryConfig(
            _config(address(tokenB), 100, 10, 10, 1 days, 0), FiddyConfig(0, 1, false)
        );
        vm.stopPrank();
        assertFalse(fiddyView.fiddyAsset(address(overflow)).listed);
        (,, uint256 count) = fiddyView.fiddyStaking();
        assertEq(count, 64);
    }

    function testSettlementAndExitsIgnoreStaticsTransferHistory() public {
        _start();
        vm.mockCallRevert(
            address(positions),
            abi.encodeWithSelector(IStaticsExternalModules.transferHead.selector),
            ""
        );
        vm.mockCallRevert(
            address(positions),
            abi.encodeWithSelector(IStaticsExternalModules.transferChanges.selector),
            ""
        );
        vm.mockCallRevert(
            address(positions),
            abi.encodeWithSelector(IStaticsExternalModules.transferState.selector),
            ""
        );
        vm.mockCallRevert(
            address(positions),
            abi.encodeWithSelector(IStaticsExternalModules.historyCoverage.selector),
            ""
        );
        uint256 id = _settle(address(tokenB), false);
        assertEq(uint8(stateView.round(id).status), 3);
        staking.checkpointFiddyAccount(1);
        vm.prank(bob);
        staking.unstakeFiddy(2, 100);
        vm.prank(bob);
        assertEq(staking.claimFiddyRevenue(2, address(tokenB), bob), 44);
        vm.prank(bob);
        operators.activate(2, 11_000);
        vm.prank(bob);
        staking.registerFiddyOperator(2, 2);
        vm.prank(bob);
        staking.removeFiddyOperator(2);
        vm.prank(bob);
        fiddy.withdrawFiddy(2, 100, bob);
        vm.prank(alice);
        staking.unstakeFiddy(1, 100);
        vm.prank(alice);
        staking.claimFiddyRevenue(1, address(tokenB), alice);
        vm.prank(bob);
        staking.cleanupFiddyAccount(2);
        assertEq(positions.legs(2), 0);
    }

    function testUnstakeSucceedsDespiteUnrelatedTransfersAndSettlements() public {
        address mallory = makeAddr("mallory");
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeFiddy(1, 100);
        positions.mint(mallory, 9);
        operators.mint(mallory, 9);
        _settle(address(tokenB), false);
        vm.prank(mallory);
        positions.transferFrom(mallory, bob, 9);
        vm.prank(mallory);
        operators.transferFrom(mallory, bob, 9);
        _settle(address(tokenA), true);
        vm.prank(bob);
        positions.transferFrom(bob, mallory, 9);
        vm.prank(alice);
        staking.unstakeFiddy(1, 100);
        assertEq(fiddyView.fiddyAccount(1).staked, 0);
        (uint256 totalWeight,,) = fiddyView.fiddyStaking();
        assertEq(totalWeight, 0);
        assertEq(fiddyView.fiddyCredit(1, address(tokenB)).claimable, 100);
        assertEq(fiddyView.fiddyCredit(1, address(tokenA)).claimable, 50);
    }

    function _assertReservedMatchesEntitlements(address asset) internal view {
        FiddyAsset memory book = fiddyView.fiddyAsset(asset);
        uint256 scaled = book.dustRay;
        for (uint256 id = 1; id <= 2; ++id) {
            FiddyCredit memory c = fiddyView.fiddyCredit(id, asset);
            scaled += c.claimable * RAY + c.remainderRay + fiddyView.fiddyAccount(id).weight
            * (book.indexRay - c.paidIndex);
        }
        assertEq(book.reserved * RAY, scaled);
    }
}
