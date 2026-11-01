// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { FiddySetup } from "./utils/FiddySetup.sol";
import { FiddyConfig } from "../src/shared/FiddyTypes.sol";
import { FiddyErrors } from "../src/shared/FiddyErrors.sol";
import { LibFiddyStaking } from "../src/libraries/LibFiddyStaking.sol";

abstract contract FiddyRevenueSetup is FiddySetup {
    function _start() internal {
        _wrap(1, alice, 100);
        _wrap(2, bob, 100);
        vm.prank(alice);
        staking.stakeFiddy(1, 100);
        vm.prank(bob);
        staking.stakeFiddy(2, 100);
        vm.prank(authority);
        staking.setFiddyBoostsEnabled(true);
        vm.prank(alice);
        operators.activate(1, 12_500);
        vm.prank(alice);
        staking.registerFiddyOperator(1, 1);
    }

    function _rewardVersion(address asset) internal returns (uint64 version) {
        vm.startPrank(authority);
        version = governance.createRewardLotteryConfig(
            _config(asset, 100, 10, 10, 1 days, 0), FiddyConfig(0, 5000, false)
        );
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
    }

    /// @dev Default economics: 80% winner and a 50/50 Operator/staker split of the remainder,
    /// so each 100-unit ticket books 10 units to stakers.
    function _settle(address asset, bool deadline) internal returns (uint256 id) {
        uint64 version = _rewardVersion(asset);
        vm.prank(alice);
        id = lottery.openRound(version, deadline ? 5 : 10);
        _settleRound(id);
    }

    function _settleRound(uint256 id) internal {
        bytes memory proof = abi.encode(id);
        _prepareProof(id, proof);
        vm.prank(finalizer);
        settlement.settleRound(id, proof);
    }

    function _checkpoint(uint256 id) internal {
        staking.checkpointFiddyAccount(id);
    }

    function _earned(uint256 id, address asset) internal view returns (uint256 amount) {
        (amount,) = staking.indexedFiddyRevenue(id, asset);
    }
}

contract FiddyStakingTest is FiddyRevenueSetup {
    function testPurchaseBooksStakerShareAtCurrentWeights() public {
        _start(); // 125:100 weights
        uint64 version = _rewardVersion(address(tokenB));
        vm.prank(alice);
        uint256 id = lottery.openRound(version, 5); // 500 gross books 50
        assertEq(fiddyView.fiddyRoundRevenue(id), 50);
        assertEq(fiddyView.fiddyAsset(address(tokenB)).reserved, 50);
        assertEq(stateView.assetAccounting(address(tokenB)).activeRoundEscrow, 450);
        assertEq(_earned(1, address(tokenB)), 27);
        assertEq(_earned(2, address(tokenB)), 22);

        // Removing the boost changes only later bookings; earlier ones are already earned.
        vm.prank(alice);
        staking.removeFiddyOperator(1);
        vm.prank(bob);
        lottery.buyTickets(id, 5); // 100:100 weights, books 50
        assertEq(_earned(1, address(tokenB)), 52);
        assertEq(_earned(2, address(tokenB)), 47);
        assertEq(fiddyView.fiddyRoundRevenue(id), 100);

        _settleRound(id);
        assertEq(stateView.assetAccounting(address(tokenB)).activeRoundEscrow, 0);
        // Winner 800, Operators 100, stakers 100: the Treasury remainder and tip are zero.
        assertEq(stateView.assetAccounting(address(tokenB)).treasuryAvailable, 0);
        assertEq(stateView.pendingOperatorRevenue(1, address(tokenB)), 100);
        assertEq(fiddyView.fiddyAsset(address(tokenB)).reserved, 100);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
    }

    function testMultiAssetClaimAndCompleteAccountLifecycle() public {
        _start();
        skip(LibFiddyStaking.STAKE_LOCK);
        _settle(address(tokenA), false);
        _settle(address(tokenB), true);
        vm.prank(alice);
        staking.unstakeFiddy(1, 100);
        vm.prank(alice);
        fiddy.withdrawFiddy(1, 100);
        vm.prank(alice);
        vm.expectRevert(FiddyErrors.AccountNotEmpty.selector);
        staking.cleanupFiddyAccount(1);
        vm.prank(alice);
        assertEq(staking.claimFiddyRevenue(1, address(tokenA), alice), 55);
        vm.prank(alice);
        assertEq(staking.claimFiddyRevenue(1, address(tokenB), alice), 27);
        vm.prank(alice);
        staking.cleanupFiddyAccount(1);
        assertEq(positions.legs(1), 0);
        assertFalse(fiddyView.fiddyAccount(1).attached);
        assertFalse(fiddyView.fiddyAccount(1).registered);
        vm.prank(alice);
        positions.close(1);
        assertEq(fiddy.totalSupply(), 200);
        assertEq(tokenA.balanceOf(address(diamond)), 1145); // backing plus receipts less the 55-unit revenue claim
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
    }

    function testRegistrationOwnershipUniquenessAndExplicitRefresh() public {
        _start();
        positions.mint(alice, 3);
        vm.prank(alice);
        vm.expectRevert(FiddyErrors.OperatorAlreadyRegistered.selector);
        staking.registerFiddyOperator(3, 1);
        vm.prank(bob);
        vm.expectRevert(FiddyErrors.NotPositionOwner.selector);
        staking.registerFiddyOperator(1, 1);
        vm.prank(bob);
        vm.expectRevert(FiddyErrors.InvalidRegistration.selector);
        staking.registerFiddyOperator(2, 1);

        vm.prank(bob);
        operators.activate(2, 11_000);
        vm.prank(bob);
        staking.registerFiddyOperator(2, 2);
        assertEq(fiddyView.fiddyAccount(2).weight, 110);
        vm.prank(bob);
        operators.activate(2, 12_000);
        assertEq(fiddyView.fiddyAccount(2).weight, 110); // activation alone is prospective
        vm.prank(bob);
        staking.registerFiddyOperator(2, 2);
        assertEq(fiddyView.fiddyAccount(2).weight, 120);
        (uint256 totalWeight,,) = fiddyView.fiddyStaking();
        assertEq(totalWeight, 245);

        vm.prank(authority);
        staking.setFiddyBoostsEnabled(false);
        vm.prank(bob);
        vm.expectRevert(FiddyErrors.InvalidRegistration.selector);
        staking.registerFiddyOperator(2, 2);
        assertEq(fiddyView.fiddyAccount(2).weight, 120); // disabling gates new registrations only
    }

    function testZeroWeightRevenueGoesToTreasuryAndCannotBeCaptured() public {
        uint64 version = _rewardVersion(address(tokenB));
        vm.expectEmit(true, true, false, true, address(diamond));
        emit LibFiddyStaking.FiddyZeroWeightRevenue(1, address(tokenB), 100);
        vm.prank(alice);
        uint256 id = lottery.openRound(version, 10);
        assertEq(stateView.assetAccounting(address(tokenB)).treasuryAvailable, 100);
        assertEq(fiddyView.fiddyAsset(address(tokenB)).reserved, 0);
        assertEq(fiddyView.fiddyAsset(address(tokenB)).indexRay, 0);
        _settleRound(id);
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeFiddy(1, 100);
        _checkpoint(1);
        assertEq(_earned(1, address(tokenB)), 0);
        assertEq(stateView.assetAccounting(address(tokenB)).treasuryAvailable, 100);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
    }

    function testApprovalDoesNotGrantFinancialAuthority() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        positions.approve(bob, 1);
        vm.prank(bob);
        vm.expectRevert(FiddyErrors.NotPositionOwner.selector);
        staking.stakeFiddy(1, 100);
        vm.prank(bob);
        vm.expectRevert(FiddyErrors.NotPositionOwner.selector);
        fiddy.withdrawFiddy(1, 100);
    }

    function testCleanupRequiresWholeClaimsAndSurrendersOnlyFractions() public {
        _start();
        skip(LibFiddyStaking.STAKE_LOCK);
        _settle(address(tokenA), false);
        _settle(address(tokenB), false);
        vm.prank(alice);
        staking.unstakeFiddy(1, 100);
        vm.prank(alice);
        fiddy.withdrawFiddy(1, 100);
        vm.prank(alice);
        staking.claimFiddyRevenue(1, address(tokenA), alice);
        vm.prank(alice);
        vm.expectRevert(FiddyErrors.AccountNotEmpty.selector);
        staking.cleanupFiddyAccount(1); // tokenB whole claim still outstanding
        vm.prank(alice);
        staking.claimFiddyRevenue(1, address(tokenB), alice);
        uint256 reservedA = fiddyView.fiddyAsset(address(tokenA)).reserved;
        uint256 remainderA = fiddyView.fiddyCredit(1, address(tokenA)).remainderRay;
        assertGt(remainderA, 0);
        vm.prank(alice);
        staking.cleanupFiddyAccount(1);
        assertEq(fiddyView.fiddyCredit(1, address(tokenA)).remainderRay, 0);
        assertLe(reservedA - fiddyView.fiddyAsset(address(tokenA)).reserved, 1);
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
        // Bob's entitlement is untouched by Alice's cleanup.
        assertEq(_earned(2, address(tokenA)), 44);
        assertEq(_earned(2, address(tokenB)), 44);
    }
}
