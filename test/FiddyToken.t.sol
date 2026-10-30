// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { FiddySetup } from "./utils/FiddySetup.sol";
import { FiddyErrors } from "../src/shared/FiddyErrors.sol";

contract FiddyTokenTest is FiddySetup {
    function testLaunchConversionsDisabledAndFundingIsReservedFromSurplus() public {
        vm.prank(alice);
        fiddy.fundFiddyReserve(100);
        assertEq(fiddy.totalSupply(), 100);
        assertEq(fiddy.balanceOf(address(diamond)), 100);
        (uint256 inventory, uint256 backing, uint256 custody,,,, uint256 outstanding) =
            fiddyView.fiddyReserve();
        assertEq(inventory, 100);
        assertEq(backing, 100);
        assertEq(custody, 0);
        assertEq(outstanding, 0);
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
        vm.startPrank(alice);
        vm.expectRevert(FiddyErrors.InsufficientFiddy.selector);
        fiddy.withdrawFiddy(1, 100);
        vm.expectRevert(FiddyErrors.ConversionDisabled.selector);
        fiddy.wrapFiddy(1, 1);
        vm.expectRevert(FiddyErrors.ConversionDisabled.selector);
        fiddy.unwrapFiddy(1, 1, alice);
        vm.stopPrank();
    }

    function testInventoryRemainsBackedWhileAccountWrapIsRedeemed() public {
        vm.prank(alice);
        fiddy.fundFiddyReserve(100);
        _wrap(1, alice, 40);
        vm.prank(authority);
        fiddy.setFiddyConversions(false, true, 0);
        vm.prank(alice);
        fiddy.unwrapFiddy(1, 40, alice);
        (uint256 inventory, uint256 backing, uint256 custody,,,, uint256 outstanding) =
            fiddyView.fiddyReserve();
        assertEq(inventory, 100);
        assertEq(backing, 100);
        assertEq(custody, 0);
        assertEq(outstanding, 0);
        assertEq(fiddy.totalSupply(), 100);
        assertEq(fiddy.balanceOf(address(diamond)), 100);
        assertEq(tokenA.balanceOf(address(diamond)), 100);
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
    }

    function testConsumerRoutesAndAccountOwnershipConserveBacking() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        fiddy.withdrawFiddy(1, 40);
        assertEq(fiddyView.fiddyAccount(1).balance, 60);
        vm.startPrank(alice);
        vm.expectRevert(FiddyErrors.TransferRestricted.selector);
        fiddy.transfer(bob, 1);
        fiddy.approve(bob, 10);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(FiddyErrors.TransferRestricted.selector);
        fiddy.transferFrom(alice, bob, 10);
        vm.prank(authority);
        fiddy.setFiddyConsumer(bob, true);
        vm.prank(bob);
        fiddy.transferFrom(alice, bob, 10);
        vm.prank(bob);
        fiddy.transfer(alice, 10);
        vm.prank(authority);
        fiddy.setFiddyConsumer(bob, false);
        vm.prank(alice);
        fiddy.approve(address(diamond), 40);
        vm.prank(alice);
        fiddy.depositFiddy(1, 40);
        assertEq(fiddyView.fiddyAccount(1).balance, 100);
        assertEq(fiddy.balanceOf(address(diamond)), 100);
        assertEq(fiddy.totalSupply(), 100);
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
        vm.prank(alice);
        positions.transferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(FiddyErrors.NotPositionOwner.selector);
        fiddy.withdrawFiddy(1, 1);
        vm.prank(bob);
        fiddy.withdrawFiddy(1, 100);
        assertEq(fiddy.balanceOf(bob), 100);
    }

    function testIndependentUnwrapAndCapAccounting() public {
        _wrap(1, alice, 100);
        vm.prank(authority);
        fiddy.setFiddyConversions(false, true, 0);
        vm.prank(authority);
        governance.setPaused(true);
        uint256 before = tokenA.balanceOf(alice);
        vm.prank(alice);
        fiddy.unwrapFiddy(1, 100, alice);
        assertEq(tokenA.balanceOf(alice), before + 100);
        assertEq(fiddy.totalSupply(), 0);
        (uint256 inventory, uint256 backing, uint256 custody,,, uint256 cap, uint256 outstanding) =
            fiddyView.fiddyReserve();
        assertEq(inventory + backing + custody + cap + outstanding, 0);
    }

    function testBridgeFailureRollsBackExactWrap() public {
        vm.prank(authority);
        fiddy.setFiddyConversions(true, false, 100);
        positions.setRejectAttach(true);
        uint256 before = tokenA.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        fiddy.wrapFiddy(1, 100);
        assertEq(tokenA.balanceOf(alice), before);
        assertEq(fiddy.totalSupply(), 0);
    }

    function testFuzzWrapUnwrapPreservesOneToOne(uint256 amount) public {
        amount = bound(amount, 1, 10_000);
        _wrap(1, alice, amount);
        vm.prank(authority);
        fiddy.setFiddyConversions(false, true, amount);
        vm.prank(alice);
        fiddy.unwrapFiddy(1, amount, bob);
        assertEq(fiddy.totalSupply(), 0);
        assertEq(tokenA.balanceOf(bob), 10_000 + amount);
    }

    function testWrapCapacityBoundaryAndLoweredCapNeverIncreaseOnRedemption() public {
        vm.prank(authority);
        fiddy.setFiddyConversions(true, false, 100);
        vm.prank(alice);
        fiddy.wrapFiddy(1, 100);
        vm.prank(alice);
        vm.expectRevert(FiddyErrors.WrapCapacityExceeded.selector);
        fiddy.wrapFiddy(1, 1);
        vm.prank(authority);
        fiddy.setFiddyConversions(true, false, 99);
        vm.prank(alice);
        vm.expectRevert(FiddyErrors.WrapCapacityExceeded.selector);
        fiddy.wrapFiddy(1, 1);
        vm.prank(alice);
        vm.expectRevert(FiddyErrors.ConversionDisabled.selector);
        fiddy.unwrapFiddy(1, 1, alice);
        vm.prank(authority);
        fiddy.setFiddyConversions(true, true, 99);
        vm.prank(alice);
        fiddy.unwrapFiddy(1, 50, alice);
        vm.prank(alice);
        fiddy.wrapFiddy(1, 49);
        (,,,,, uint256 cap, uint256 outstanding) = fiddyView.fiddyReserve();
        assertEq(cap, 99);
        assertEq(outstanding, 99);
    }

    function testDepositAllowanceAndRawCustodyRestrictionSurviveConsumerApproval() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        fiddy.withdrawFiddy(1, 100);
        vm.prank(authority);
        fiddy.setFiddyConsumer(alice, true);
        vm.prank(alice);
        vm.expectRevert(FiddyErrors.TransferRestricted.selector);
        fiddy.transfer(address(diamond), 1);
        vm.prank(alice);
        vm.expectRevert();
        fiddy.depositFiddy(1, 1);
        assertEq(fiddyView.fiddyAccount(1).balance, 0);
        vm.prank(authority);
        fiddy.setFiddyConsumer(alice, false);
        vm.prank(alice);
        vm.expectRevert(FiddyErrors.TransferRestricted.selector);
        fiddy.transfer(bob, 1);
        vm.prank(alice);
        fiddy.approve(address(diamond), 1);
        vm.prank(alice);
        fiddy.depositFiddy(1, 1);
        vm.prank(alice);
        vm.expectRevert();
        fiddy.depositFiddy(1, 1);
        assertEq(fiddyView.fiddyAccount(1).balance, 1);
        assertEq(fiddy.balanceOf(alice), 99);
    }
}
