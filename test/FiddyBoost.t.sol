// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { FiddyRevenueSetup } from "./FiddyStaking.t.sol";
import { LibFiddyStaking } from "../src/libraries/LibFiddyStaking.sol";
import { FiddyAsset, FiddyCredit } from "../src/shared/FiddyTypes.sol";
import { FiddyErrors } from "../src/shared/FiddyErrors.sol";

contract FiddyBoostTest is FiddyRevenueSetup {
    uint256 internal constant RAY = 1e27;
    address internal carol = makeAddr("carol");

    /// @dev Alice holds a 12,500 BPS boost and 125 weight against Bob's 100; one sold-out round
    /// books 100 staker units, 55.5 to Alice and 44.4 to Bob.
    function _bookedWithBoost() internal {
        _start();
        skip(LibFiddyStaking.STAKE_LOCK);
        _settle(address(tokenB), false);
        assertEq(_earned(1, address(tokenB)), 55);
        assertEq(_earned(2, address(tokenB)), 44);
    }

    function testOperatorTransferForfeitsBoostExcessToOtherStakers() public {
        _bookedWithBoost();
        vm.prank(alice);
        operators.transferFrom(alice, carol, 1);
        assertEq(operators.multiplierBps(1), 10_000);
        // The view already reports what a claim would pay after the forfeit.
        assertEq(_earned(1, address(tokenB)), 44);

        vm.expectEmit(true, true, true, false, address(diamond));
        emit LibFiddyStaking.FiddyBoostForfeited(1, 1, address(tokenB), 0, 0);
        vm.expectEmit(true, true, false, false, address(diamond));
        emit LibFiddyStaking.FiddyBoostRevoked(1, 1);
        vm.prank(carol);
        staking.checkpointFiddyAccount(1);

        assertFalse(fiddyView.fiddyAccount(1).registered);
        assertEq(fiddyView.fiddyAccount(1).weight, 100);
        assertEq(fiddyView.fiddyOperatorAccount(1), 0);
        (uint256 totalWeight,,) = fiddyView.fiddyStaking();
        assertEq(totalWeight, 200);
        assertEq(fiddyView.fiddyCredit(1, address(tokenB)).claimable, 44);
        assertEq(_earned(2, address(tokenB)), 55);
        assertEq(fiddyView.fiddyAsset(address(tokenB)).reserved, 100);
        _assertConserved(address(tokenB));

        _settle(address(tokenB), false); // 100 more units at 100:100
        vm.prank(alice);
        assertEq(staking.claimFiddyRevenue(1, address(tokenB), alice), 94);
        vm.prank(bob);
        assertEq(staking.claimFiddyRevenue(2, address(tokenB), bob), 105);
        assertEq(fiddyView.fiddyAsset(address(tokenB)).reserved, 1);
        _assertConserved(address(tokenB));
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
    }

    function testPositionSaleDropsBoost() public {
        _bookedWithBoost();
        vm.prank(alice);
        positions.transferFrom(alice, carol, 1);
        assertEq(operators.multiplierBps(1), 12_500); // the Operator itself did not move
        assertEq(_earned(1, address(tokenB)), 44);
        uint256 before = tokenB.balanceOf(carol);
        vm.prank(carol);
        assertEq(staking.claimFiddyRevenue(1, address(tokenB), carol), 44);
        assertEq(tokenB.balanceOf(carol), before + 44);
        assertFalse(fiddyView.fiddyAccount(1).registered);
        assertEq(fiddyView.fiddyAccount(1).weight, 100);
        assertEq(_earned(2, address(tokenB)), 55);
        _assertConserved(address(tokenB));
    }

    function testNewOperatorOwnerEvictsInvalidBoostAndRegisters() public {
        _bookedWithBoost();
        vm.prank(alice);
        operators.transferFrom(alice, bob, 1);
        vm.prank(bob);
        operators.activate(1, 11_000);
        vm.prank(bob);
        staking.registerFiddyOperator(2, 1);

        assertEq(fiddyView.fiddyOperatorAccount(1), 2);
        assertFalse(fiddyView.fiddyAccount(1).registered);
        assertEq(fiddyView.fiddyAccount(1).weight, 100);
        assertEq(fiddyView.fiddyAccount(2).weight, 110);
        (uint256 totalWeight,,) = fiddyView.fiddyStaking();
        assertEq(totalWeight, 210);
        assertEq(fiddyView.fiddyCredit(1, address(tokenB)).claimable, 44);
        // Bob receives Alice's forfeited excess at his pre-registration weight.
        assertEq(fiddyView.fiddyCredit(2, address(tokenB)).claimable, 55);
        _assertConserved(address(tokenB));
    }

    /// @dev Accepted residual: re-activating to the stored tier before any checkpoint hides the
    /// transfer. Here one buyer acquires both NFTs, so the boost continues for that buyer.
    function testReactivationToStoredTierBetweenCheckpointsKeepsBoost() public {
        _bookedWithBoost();
        positions.mint(carol, 3);
        vm.prank(alice);
        positions.transferFrom(alice, carol, 1);
        vm.prank(alice);
        operators.transferFrom(alice, carol, 1);
        vm.prank(carol);
        operators.activate(1, 12_500);
        assertEq(_earned(1, address(tokenB)), 55);
        vm.prank(carol);
        vm.expectRevert(FiddyErrors.OperatorAlreadyRegistered.selector);
        staking.registerFiddyOperator(3, 1);
        assertEq(fiddyView.fiddyOperatorAccount(1), 1);
    }

    function testMultiplierIncreaseKeepsStoredValueAndBoost() public {
        _wrap(2, bob, 100);
        vm.prank(bob);
        staking.stakeFiddy(2, 100);
        vm.prank(authority);
        staking.setFiddyBoostsEnabled(true);
        vm.prank(bob);
        operators.activate(2, 11_000);
        vm.prank(bob);
        staking.registerFiddyOperator(2, 2);
        vm.prank(bob);
        operators.activate(2, 12_500);
        staking.checkpointFiddyAccount(2);
        assertTrue(fiddyView.fiddyAccount(2).registered);
        assertEq(fiddyView.fiddyAccount(2).multiplierBps, 11_000);
        assertEq(fiddyView.fiddyAccount(2).weight, 110);
        vm.prank(bob);
        staking.registerFiddyOperator(2, 2);
        assertEq(fiddyView.fiddyAccount(2).weight, 125);
    }

    function testForfeitWithoutOtherWeightGoesToTreasury() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeFiddy(1, 100);
        vm.prank(authority);
        staking.setFiddyBoostsEnabled(true);
        vm.prank(alice);
        operators.activate(1, 12_500);
        vm.prank(alice);
        staking.registerFiddyOperator(1, 1);
        _settle(address(tokenB), false); // sole staker, 100 units
        uint256 treasuryBefore = stateView.assetAccounting(address(tokenB)).treasuryAvailable;
        vm.prank(alice);
        operators.transferFrom(alice, carol, 1);
        staking.checkpointFiddyAccount(1);
        assertEq(fiddyView.fiddyCredit(1, address(tokenB)).claimable, 80);
        assertEq(stateView.assetAccounting(address(tokenB)).treasuryAvailable, treasuryBefore + 20);
        assertEq(fiddyView.fiddyAsset(address(tokenB)).reserved, 80);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
    }

    function testStaleBoostIsNeverClaimableThroughAnyCheckpointPath() public {
        _bookedWithBoost();
        operators.mint(alice, 3);
        vm.prank(alice);
        operators.transferFrom(alice, carol, 1);
        positions.mint(carol, 3);
        uint256 snapshot = vm.snapshotState();
        for (uint256 path; path < 7; ++path) {
            vm.revertToState(snapshot);
            _checkpointThrough(path);
            assertEq(fiddyView.fiddyAccount(1).registered, path == 4);
            assertNotEq(fiddyView.fiddyOperatorAccount(1), 1);
            FiddyCredit memory credit = fiddyView.fiddyCredit(1, address(tokenB));
            assertEq(credit.claimable + tokenB.balanceOf(address(0xA11CE)), 44);
            assertEq(_earned(2, address(tokenB)), 55);
            _assertConserved(address(tokenB));
        }
    }

    function _checkpointThrough(uint256 path) internal {
        if (path == 0) {
            vm.prank(alice);
            staking.claimFiddyRevenue(1, address(tokenB), address(0xA11CE));
        } else if (path == 1) {
            _wrap(1, alice, 10);
            vm.prank(alice);
            staking.stakeFiddy(1, 10);
        } else if (path == 2) {
            vm.prank(alice);
            staking.unstakeFiddy(1, 10);
        } else if (path == 3) {
            vm.prank(carol);
            staking.checkpointFiddyAccount(1);
        } else if (path == 4) {
            vm.prank(alice);
            operators.activate(3, 11_000);
            vm.prank(alice);
            staking.registerFiddyOperator(1, 3);
            assertEq(fiddyView.fiddyAccount(1).operatorId, 3);
        } else if (path == 5) {
            vm.prank(alice);
            staking.removeFiddyOperator(1);
        } else {
            vm.prank(carol);
            operators.activate(1, 11_000);
            vm.prank(carol);
            staking.registerFiddyOperator(3, 1);
            assertEq(fiddyView.fiddyOperatorAccount(1), 3);
        }
    }

    function testCleanupClearsStaleRegistration() public {
        _bookedWithBoost();
        vm.prank(alice);
        operators.transferFrom(alice, carol, 1);
        vm.startPrank(alice);
        staking.unstakeFiddy(1, 100);
        fiddy.withdrawFiddy(1, 100, alice);
        staking.claimFiddyRevenue(1, address(tokenB), alice);
        staking.cleanupFiddyAccount(1);
        vm.stopPrank();
        assertEq(tokenB.balanceOf(alice), 10_000 - 1000 + 44);
        assertFalse(fiddyView.fiddyAccount(1).registered);
        assertEq(positions.legs(1), 0);
    }

    function _assertConserved(address asset) internal view {
        FiddyAsset memory book = fiddyView.fiddyAsset(asset);
        uint256 scaled = book.dustRay;
        for (uint256 id = 1; id <= 3; ++id) {
            FiddyCredit memory c = fiddyView.fiddyCredit(id, asset);
            scaled += c.claimable * RAY + c.remainderRay + fiddyView.fiddyAccount(id).weight
            * (book.indexRay - c.paidIndex);
        }
        assertEq(book.reserved * RAY, scaled);
        (uint256 totalWeight,,) = fiddyView.fiddyStaking();
        assertEq(
            totalWeight,
            fiddyView.fiddyAccount(1).weight + fiddyView.fiddyAccount(2).weight
                + fiddyView.fiddyAccount(3).weight
        );
    }
}
