// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { FiddyRevenueSetup } from "./FiddyStaking.t.sol";
import { IntegrationEndpoint } from "./utils/LotteryIntegrationSetup.sol";
import { FiddyConfig } from "../src/shared/FiddyTypes.sol";
import { FiddyErrors } from "../src/shared/FiddyErrors.sol";
import { Errors } from "../src/shared/Errors.sol";
import { AssetAccounting, IntegrationConfig, LotteryConfig } from "../src/shared/Types.sol";

contract FiddyTransferRulesTest is FiddyRevenueSetup {
    address internal carol = makeAddr("carol");

    function testWithdrawPaysOnlyThePositionOwner() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        positions.approve(bob, 1);
        vm.prank(bob);
        vm.expectRevert(FiddyErrors.NotPositionOwner.selector);
        fiddy.withdrawFiddy(1, 10);
        vm.prank(alice);
        fiddy.withdrawFiddy(1, 40);
        assertEq(fiddy.balanceOf(alice), 40);

        vm.prank(alice);
        positions.transferFrom(alice, carol, 1);
        vm.prank(alice);
        vm.expectRevert(FiddyErrors.NotPositionOwner.selector);
        fiddy.withdrawFiddy(1, 10);
        vm.prank(carol);
        fiddy.withdrawFiddy(1, 60);
        assertEq(fiddy.balanceOf(carol), 60);
        assertEq(fiddyView.fiddyAccount(1).balance, 0);
        (,, uint256 custody,,,,) = fiddyView.fiddyReserve();
        assertEq(custody, 0);
    }

    function testFiddyPricedOperatorShareRequiresConsumerRouter() public {
        router.setAsset(address(diamond), true, true);
        LotteryConfig memory config = _config(address(diamond), 10, 10, 10, 1 days, 3);
        bytes memory unavailable = abi.encodeWithSelector(
            Errors.OperatorRouterUnavailable.selector, address(router), address(diamond)
        );
        vm.startPrank(authority);
        vm.expectRevert(unavailable);
        governance.createLotteryConfig(config);
        vm.expectRevert(unavailable);
        governance.createRewardLotteryConfig(config, FiddyConfig(0, 1000, false));
        config.operatorProtocolBps = 0;
        governance.createLotteryConfig(config);
        config.operatorProtocolBps = 5000;
        fiddy.setFiddyConsumer(address(router), true);
        governance.createLotteryConfig(config);
        governance.createRewardLotteryConfig(config, FiddyConfig(0, 1000, false));

        IntegrationEndpoint other = new IntegrationEndpoint();
        governance.setIntegrationConfig(IntegrationConfig(address(registry), address(other)));
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.OperatorRouterUnavailable.selector, address(other), address(diamond)
            )
        );
        governance.createLotteryConfig(config);
        config.paymentToken = address(tokenB);
        governance.createLotteryConfig(config);
        vm.stopPrank();
    }

    function testFiddyOperatorFundingWaitsUntilRouterIsConsumer() public {
        _fiddyBuyer(1000);
        router.setAsset(address(diamond), true, true);
        vm.startPrank(authority);
        fiddy.setFiddyConsumer(address(router), true);
        uint64 version =
            governance.createLotteryConfig(_config(address(diamond), 10, 10, 10, 1 days, 3));
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
        vm.prank(alice);
        uint256 id = lottery.openRound(version, 10);
        _settleRound(id);
        assertEq(stateView.pendingOperatorRevenue(1, address(diamond)), 10);

        vm.prank(authority);
        fiddy.setFiddyConsumer(address(router), false);
        bytes memory unavailable = abi.encodeWithSelector(
            Errors.OperatorRouterUnavailable.selector, address(router), address(diamond)
        );
        uint256 held = fiddy.balanceOf(address(diamond));
        vm.expectRevert(unavailable);
        revenue.flushOperatorRevenue(1, address(diamond), 10);
        assertEq(stateView.pendingOperatorRevenue(1, address(diamond)), 10);
        assertEq(fiddy.balanceOf(address(diamond)), held);
        vm.prank(alice);
        vm.expectRevert(unavailable);
        lottery.openRound(version, 1);

        vm.prank(authority);
        fiddy.setFiddyConsumer(address(router), true);
        assertEq(revenue.flushOperatorRevenue(1, address(diamond), 10), 10);
        assertEq(fiddy.balanceOf(address(router)), 10);
        // An approved consumer Router can pay an Operator.
        vm.prank(address(router));
        fiddy.transfer(carol, 10);
        assertEq(fiddy.balanceOf(carol), 10);
    }

    function testFiddyPayoutsGoOnlyToCallerOrTreasury() public {
        _fiddyBuyer(1000);
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeFiddy(1, 100);
        router.setAsset(address(diamond), true, true);
        LotteryConfig memory config = _config(address(diamond), 10, 10, 10, 1 days, 3);
        config.operatorProtocolBps = 2500;
        vm.startPrank(authority);
        fiddy.setFiddyConsumer(address(router), true);
        uint64 version = governance.createRewardLotteryConfig(config, FiddyConfig(0, 2500, false));
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
        vm.prank(alice);
        uint256 id = lottery.openRound(version, 10); // 100 FIDDY: 80/5/5/7 and a 3 tip
        _settleRound(id);
        assertEq(stateView.round(id).winner, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FiddyErrors.ReceiverRestricted.selector, carol));
        claims.claimWinner(id, carol);
        vm.prank(alice);
        assertEq(claims.claimWinner(id, alice), 80);

        vm.prank(finalizer);
        vm.expectRevert(abi.encodeWithSelector(FiddyErrors.ReceiverRestricted.selector, carol));
        claims.claimFinalizerTips(address(diamond), carol);
        vm.prank(finalizer);
        assertEq(claims.claimFinalizerTips(address(diamond), treasury), 3);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FiddyErrors.ReceiverRestricted.selector, carol));
        staking.claimFiddyRevenue(1, address(diamond), carol);
        vm.prank(alice);
        assertEq(staking.claimFiddyRevenue(1, address(diamond), alice), 5);

        assertEq(revenue.flushTreasury(address(diamond), 7), 7);
        assertEq(fiddy.balanceOf(treasury), 10);
        assertEq(fiddy.balanceOf(alice), 1000 - 100 + 80 + 5);
        AssetAccounting memory accounting = stateView.assetAccounting(address(diamond));
        (uint256 inventory,, uint256 custody,,,,) = fiddyView.fiddyReserve();
        assertEq(
            fiddy.balanceOf(address(diamond)),
            inventory + custody + accounting.pendingOperatorRevenueTotal
                + fiddyView.fiddyAsset(address(diamond)).reserved
        );
        assertEq(revenue.availableTokenSurplus(address(diamond)), 0);
    }

    function testOtherTokenPayoutsKeepArbitraryReceivers() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeFiddy(1, 100);
        uint256 id = _settle(address(tokenB), false);
        vm.prank(alice);
        assertEq(claims.claimWinner(id, carol), 800);
        vm.prank(alice);
        assertEq(staking.claimFiddyRevenue(1, address(tokenB), carol), 100);
        assertEq(tokenB.balanceOf(carol), 900);
    }

    /// @dev Alice holds `amount` FIDDY in her wallet and approves the Diamond to spend it.
    function _fiddyBuyer(uint256 amount) internal {
        positions.mint(alice, 4);
        _wrap(4, alice, amount);
        vm.startPrank(alice);
        fiddy.withdrawFiddy(4, amount);
        fiddy.approve(address(diamond), type(uint256).max);
        vm.stopPrank();
    }
}
