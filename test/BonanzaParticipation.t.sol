// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { BonanzaSetup } from "./utils/BonanzaSetup.sol";
import { BonanzaConfig } from "../src/shared/BonanzaTypes.sol";
import { BonanzaErrors } from "../src/shared/BonanzaErrors.sol";

contract BonanzaParticipationTest is BonanzaSetup {
    function _rewardConfig() internal returns (uint64 version) {
        vm.startPrank(authority);
        version = governance.createRewardLotteryConfig(
            _config(address(tokenB), 20, 5, 5, 2 days, 0), BonanzaConfig(10, 0, true)
        );
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
    }

    function testOpeningAndPurchasesIssueOnlyFundedUnits() public {
        uint64 version = _rewardConfig();
        vm.prank(alice);
        bonanza.fundBonanzaReserve(25);
        assertEq(bonanza.totalSupply(), 25);
        assertEq(bonanza.balanceOf(address(diamond)), 25);
        vm.prank(alice);
        uint256 roundId = lottery.openRoundForPosition(version, 2, 1);
        assertEq(bonanzaView.bonanzaAccount(1).balance, 20);
        assertEq(bonanza.totalSupply(), 25);
        (uint256 inventory, uint256 backing, uint256 custody,,,,) = bonanzaView.bonanzaReserve();
        assertEq(inventory, 5);
        assertEq(backing, 25);
        assertEq(custody, 20);
        vm.prank(bob);
        lottery.buyTicketsForPosition(roundId, 3, 2);
        assertEq(bonanzaView.bonanzaAccount(2).balance, 5);
        assertEq(bonanza.totalSupply(), 25);
        assertEq(tokenA.balanceOf(address(diamond)), 25);
        assertEq(stateView.round(roundId).receipts, 100);
        assertEq(stateView.ticketOwner(roundId, 0), alice);
        vm.prank(alice);
        positions.transferFrom(alice, bob, 1);
        assertEq(stateView.ticketOwner(roundId, 0), alice);
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
    }

    function testAccountlessPurchaseCannotBypassAttributionEvenWhenEmptyInventory() public {
        uint64 version = _rewardConfig();
        vm.prank(alice);
        vm.expectRevert(BonanzaErrors.PositionRequired.selector);
        lottery.openRound(version, 1);
        vm.prank(alice);
        uint256 roundId = lottery.openRoundForPosition(version, 1, 1);
        vm.prank(bob);
        vm.expectRevert(BonanzaErrors.PositionRequired.selector);
        lottery.buyTickets(roundId, 1);
        vm.prank(bob);
        vm.expectRevert(BonanzaErrors.NotPositionOwner.selector);
        lottery.buyTicketsForPosition(roundId, 1, 1);
        assertEq(bonanza.totalSupply(), 0);
        assertEq(stateView.round(roundId).soldTickets, 1);
    }

    function testFirstIssuanceBridgeFailureIsAtomic() public {
        uint64 version = _rewardConfig();
        vm.prank(alice);
        bonanza.fundBonanzaReserve(100);
        positions.setRejectAttach(true);
        uint256 before = tokenB.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        lottery.openRoundForPosition(version, 1, 1);
        assertEq(tokenB.balanceOf(alice), before);
        assertEq(stateView.latestRoundId(), 0);
        assertEq(bonanza.totalSupply(), 100);
        (uint256 inventory, uint256 backing, uint256 custody,,,,) = bonanzaView.bonanzaReserve();
        assertEq(inventory, 100);
        assertEq(backing, 100);
        assertEq(custody, 0);
    }

    function testRewardSettingsAreAtomicDisabledAndCannotOversubscribeProtocolShare() public {
        vm.startPrank(authority);
        vm.expectRevert(BonanzaErrors.InvalidRewardsConfig.selector);
        governance.createRewardLotteryConfig(
            _config(address(tokenB), 20, 5, 5, 2 days, 0), BonanzaConfig(1, 5001, true)
        );
        vm.expectRevert(BonanzaErrors.InvalidRewardsConfig.selector);
        governance.createRewardLotteryConfig(
            _config(address(tokenB), 20, 5, 5, 2 days, 0), BonanzaConfig(1, 0, false)
        );
        uint64 version = governance.createRewardLotteryConfig(
            _config(address(tokenB), 20, 5, 5, 2 days, 0), BonanzaConfig(1, 5000, true)
        );
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert();
        lottery.openRoundForPosition(version, 1, 1);
        assertEq(bonanzaView.bonanzaConfig(version).stakerProtocolBps, 5000);
        assertEq(stateView.latestLotteryConfigVersion(), version);
    }

    function testParticipationRedemptionDoesNotRaisePublicWrapCap() public {
        uint64 version = _rewardConfig();
        vm.prank(alice);
        bonanza.fundBonanzaReserve(10);
        vm.prank(authority);
        bonanza.setBonanzaConversions(true, true, 5);
        vm.prank(alice);
        bonanza.wrapBonanza(1, 5);
        vm.prank(alice);
        lottery.openRoundForPosition(version, 1, 1);
        vm.prank(alice);
        bonanza.unwrapBonanza(1, 10, alice);
        (uint256 inventory, uint256 backing,,,, uint256 cap, uint256 outstanding) =
            bonanzaView.bonanzaReserve();
        assertEq(inventory, 0);
        assertEq(backing, 5);
        assertEq(cap, 5);
        assertEq(outstanding, 0);
        assertEq(bonanza.totalSupply(), 5);
    }
}
