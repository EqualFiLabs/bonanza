// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { BonanzaSetup } from "./utils/BonanzaSetup.sol";
import { BonanzaErrors } from "../src/shared/BonanzaErrors.sol";

contract BonanzaPaymentTest is BonanzaSetup {
    function testBonanzaPaymentOperatorFlushConsumesExactCapability() public {
        vm.prank(alice);
        bonanza.fundBonanzaReserve(37);
        _wrap(1, alice, 100);
        vm.prank(alice);
        bonanza.withdrawBonanza(1, 100);
        router.setAsset(address(diamond), true, true);
        vm.startPrank(authority);
        bonanza.setBonanzaConsumer(address(router), true);
        uint64 version =
            governance.createLotteryConfig(_config(address(diamond), 10, 10, 10, 1 days, 30));
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
        vm.startPrank(alice);
        bonanza.approve(address(diamond), 100);
        uint256 roundId = lottery.openRound(version, 10);
        vm.stopPrank();
        bytes memory proof = hex"1234";
        _prepareProof(roundId, proof);
        settlement.settleRound(roundId, proof);
        assertEq(stateView.pendingOperatorRevenue(1, address(diamond)), 10);
        revenue.flushOperatorRevenue(1, address(diamond), 10);
        assertEq(stateView.pendingOperatorRevenue(1, address(diamond)), 0);
        assertEq(router.totalAdded(address(diamond)), 10);
        assertEq(bonanza.allowance(address(diamond), address(router)), 0);
        assertEq(bonanza.totalSupply(), 137);
        (uint256 inventory, uint256 backing, uint256 custody,,,,) = bonanzaView.bonanzaReserve();
        assertEq(inventory, 37);
        assertEq(backing, 137);
        assertEq(custody, 0);
        assertEq(revenue.availableTokenSurplus(address(diamond)), 0);
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
        vm.prank(address(router));
        vm.expectRevert(BonanzaErrors.TransferRestricted.selector);
        bonanza.transfer(address(diamond), 1);
    }
}
