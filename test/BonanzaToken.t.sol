// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { BonanzaSetup } from "./utils/BonanzaSetup.sol";
import { BonanzaErrors } from "../src/shared/BonanzaErrors.sol";

contract BonanzaTokenTest is BonanzaSetup {
    function testLaunchConversionsDisabledAndFundingIsReservedFromSurplus() public {
        vm.prank(alice);
        bonanza.fundBonanzaReserve(100);
        assertEq(bonanza.totalSupply(), 100);
        assertEq(bonanza.balanceOf(address(diamond)), 100);
        (uint256 inventory, uint256 backing, uint256 custody,,,, uint256 outstanding) =
            bonanzaView.bonanzaReserve();
        assertEq(inventory, 100);
        assertEq(backing, 100);
        assertEq(custody, 0);
        assertEq(outstanding, 0);
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
        vm.startPrank(alice);
        vm.expectRevert(BonanzaErrors.InsufficientBonanza.selector);
        bonanza.withdrawBonanza(1, 100);
        vm.expectRevert(BonanzaErrors.ConversionDisabled.selector);
        bonanza.wrapBonanza(1, 1);
        vm.expectRevert(BonanzaErrors.ConversionDisabled.selector);
        bonanza.unwrapBonanza(1, 1, alice);
        vm.stopPrank();
    }

    function testInventoryRemainsBackedWhileAccountWrapIsRedeemed() public {
        vm.prank(alice);
        bonanza.fundBonanzaReserve(100);
        _wrap(1, alice, 40);
        vm.prank(authority);
        bonanza.setBonanzaConversions(false, true, 0);
        vm.prank(alice);
        bonanza.unwrapBonanza(1, 40, alice);
        (uint256 inventory, uint256 backing, uint256 custody,,,, uint256 outstanding) =
            bonanzaView.bonanzaReserve();
        assertEq(inventory, 100);
        assertEq(backing, 100);
        assertEq(custody, 0);
        assertEq(outstanding, 0);
        assertEq(bonanza.totalSupply(), 100);
        assertEq(bonanza.balanceOf(address(diamond)), 100);
        assertEq(tokenA.balanceOf(address(diamond)), 100);
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
    }

    function testConsumerRoutesAndAccountOwnershipConserveBacking() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        bonanza.withdrawBonanza(1, 40);
        assertEq(bonanzaView.bonanzaAccount(1).balance, 60);
        vm.startPrank(alice);
        vm.expectRevert(BonanzaErrors.TransferRestricted.selector);
        bonanza.transfer(bob, 1);
        bonanza.approve(bob, 10);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(BonanzaErrors.TransferRestricted.selector);
        bonanza.transferFrom(alice, bob, 10);
        vm.prank(authority);
        bonanza.setBonanzaConsumer(bob, true);
        vm.prank(bob);
        bonanza.transferFrom(alice, bob, 10);
        vm.prank(bob);
        bonanza.transfer(alice, 10);
        vm.prank(authority);
        bonanza.setBonanzaConsumer(bob, false);
        vm.prank(alice);
        bonanza.approve(address(diamond), 40);
        vm.prank(alice);
        bonanza.depositBonanza(1, 40);
        assertEq(bonanzaView.bonanzaAccount(1).balance, 100);
        assertEq(bonanza.balanceOf(address(diamond)), 100);
        assertEq(bonanza.totalSupply(), 100);
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
        vm.prank(alice);
        positions.transferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(BonanzaErrors.NotPositionOwner.selector);
        bonanza.withdrawBonanza(1, 1);
        vm.prank(bob);
        bonanza.withdrawBonanza(1, 100);
        assertEq(bonanza.balanceOf(bob), 100);
    }

    function testIndependentUnwrapAndCapAccounting() public {
        _wrap(1, alice, 100);
        vm.prank(authority);
        bonanza.setBonanzaConversions(false, true, 0);
        vm.prank(authority);
        governance.setPaused(true);
        uint256 before = tokenA.balanceOf(alice);
        vm.prank(alice);
        bonanza.unwrapBonanza(1, 100, alice);
        assertEq(tokenA.balanceOf(alice), before + 100);
        assertEq(bonanza.totalSupply(), 0);
        (uint256 inventory, uint256 backing, uint256 custody,,, uint256 cap, uint256 outstanding) =
            bonanzaView.bonanzaReserve();
        assertEq(inventory + backing + custody + cap + outstanding, 0);
    }

    function testBridgeFailureRollsBackExactWrap() public {
        vm.prank(authority);
        bonanza.setBonanzaConversions(true, false, 100);
        positions.setRejectAttach(true);
        uint256 before = tokenA.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        bonanza.wrapBonanza(1, 100);
        assertEq(tokenA.balanceOf(alice), before);
        assertEq(bonanza.totalSupply(), 0);
    }

    function testFuzzWrapUnwrapPreservesOneToOne(uint256 amount) public {
        amount = bound(amount, 1, 10_000);
        _wrap(1, alice, amount);
        vm.prank(authority);
        bonanza.setBonanzaConversions(false, true, amount);
        vm.prank(alice);
        bonanza.unwrapBonanza(1, amount, bob);
        assertEq(bonanza.totalSupply(), 0);
        assertEq(tokenA.balanceOf(bob), 10_000 + amount);
    }

    function testWrapCapacityBoundaryAndLoweredCapNeverIncreaseOnRedemption() public {
        vm.prank(authority);
        bonanza.setBonanzaConversions(true, false, 100);
        vm.prank(alice);
        bonanza.wrapBonanza(1, 100);
        vm.prank(alice);
        vm.expectRevert(BonanzaErrors.WrapCapacityExceeded.selector);
        bonanza.wrapBonanza(1, 1);
        vm.prank(authority);
        bonanza.setBonanzaConversions(true, false, 99);
        vm.prank(alice);
        vm.expectRevert(BonanzaErrors.WrapCapacityExceeded.selector);
        bonanza.wrapBonanza(1, 1);
        vm.prank(alice);
        vm.expectRevert(BonanzaErrors.ConversionDisabled.selector);
        bonanza.unwrapBonanza(1, 1, alice);
        vm.prank(authority);
        bonanza.setBonanzaConversions(true, true, 99);
        vm.prank(alice);
        bonanza.unwrapBonanza(1, 50, alice);
        vm.prank(alice);
        bonanza.wrapBonanza(1, 49);
        (,,,,, uint256 cap, uint256 outstanding) = bonanzaView.bonanzaReserve();
        assertEq(cap, 99);
        assertEq(outstanding, 99);
    }

    function testDepositAllowanceAndRawCustodyRestrictionSurviveConsumerApproval() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        bonanza.withdrawBonanza(1, 100);
        vm.prank(authority);
        bonanza.setBonanzaConsumer(alice, true);
        vm.prank(alice);
        vm.expectRevert(BonanzaErrors.TransferRestricted.selector);
        bonanza.transfer(address(diamond), 1);
        vm.prank(alice);
        vm.expectRevert();
        bonanza.depositBonanza(1, 1);
        assertEq(bonanzaView.bonanzaAccount(1).balance, 0);
        vm.prank(authority);
        bonanza.setBonanzaConsumer(alice, false);
        vm.prank(alice);
        vm.expectRevert(BonanzaErrors.TransferRestricted.selector);
        bonanza.transfer(bob, 1);
        vm.prank(alice);
        bonanza.approve(address(diamond), 1);
        vm.prank(alice);
        bonanza.depositBonanza(1, 1);
        vm.prank(alice);
        vm.expectRevert();
        bonanza.depositBonanza(1, 1);
        assertEq(bonanzaView.bonanzaAccount(1).balance, 1);
        assertEq(bonanza.balanceOf(alice), 99);
    }
}
