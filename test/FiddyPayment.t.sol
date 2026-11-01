// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { FiddySetup } from "./utils/FiddySetup.sol";
import { FiddyErrors } from "../src/shared/FiddyErrors.sol";

contract FiddyPaymentTest is FiddySetup {
    function testFiddyPaymentOperatorFlushConsumesExactCapability() public {
        vm.prank(alice);
        fiddy.fundFiddyReserve(37);
        _wrap(1, alice, 100);
        vm.prank(alice);
        fiddy.withdrawFiddy(1, 100);
        router.setAsset(address(diamond), true, true);
        vm.startPrank(authority);
        fiddy.setFiddyConsumer(address(router), true);
        uint64 version =
            governance.createLotteryConfig(_config(address(diamond), 10, 10, 10, 1 days, 30));
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
        vm.startPrank(alice);
        fiddy.approve(address(diamond), 100);
        uint256 roundId = lottery.openRound(version, 10);
        vm.stopPrank();
        bytes memory proof = hex"1234";
        _prepareProof(roundId, proof);
        settlement.settleRound(roundId, proof);
        assertEq(stateView.pendingOperatorRevenue(1, address(diamond)), 10);
        revenue.flushOperatorRevenue(1, address(diamond), 10);
        assertEq(stateView.pendingOperatorRevenue(1, address(diamond)), 0);
        assertEq(router.totalAdded(address(diamond)), 10);
        assertEq(fiddy.allowance(address(diamond), address(router)), 0);
        assertEq(fiddy.totalSupply(), 137);
        (uint256 inventory, uint256 backing, uint256 custody,,,,) = fiddyView.fiddyReserve();
        assertEq(inventory, 37);
        assertEq(backing, 137);
        assertEq(custody, 0);
        assertEq(revenue.availableTokenSurplus(address(diamond)), 0);
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
        vm.prank(address(router));
        vm.expectRevert(FiddyErrors.TransferRestricted.selector);
        fiddy.transfer(address(diamond), 1);
    }
}
