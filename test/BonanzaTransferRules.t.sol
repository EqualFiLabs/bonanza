// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { BonanzaRevenueSetup } from "./BonanzaStaking.t.sol";
import { IntegrationEndpoint } from "./utils/LotteryIntegrationSetup.sol";
import { BonanzaConfig } from "../src/shared/BonanzaTypes.sol";
import { BonanzaErrors } from "../src/shared/BonanzaErrors.sol";
import { Errors } from "../src/shared/Errors.sol";
import { AssetAccounting, IntegrationConfig, LotteryConfig } from "../src/shared/Types.sol";

contract BonanzaTransferRulesTest is BonanzaRevenueSetup {
    address internal carol = makeAddr("carol");

    function testWithdrawPaysOnlyThePositionOwner() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        positions.approve(bob, 1);
        vm.prank(bob);
        vm.expectRevert(BonanzaErrors.NotPositionOwner.selector);
        bonanza.withdrawBonanza(1, 10);
        vm.prank(alice);
        bonanza.withdrawBonanza(1, 40);
        assertEq(bonanza.balanceOf(alice), 40);

        vm.prank(alice);
        positions.transferFrom(alice, carol, 1);
        vm.prank(alice);
        vm.expectRevert(BonanzaErrors.NotPositionOwner.selector);
        bonanza.withdrawBonanza(1, 10);
        vm.prank(carol);
        bonanza.withdrawBonanza(1, 60);
        assertEq(bonanza.balanceOf(carol), 60);
        assertEq(bonanzaView.bonanzaAccount(1).balance, 0);
        (,, uint256 custody,,,,) = bonanzaView.bonanzaReserve();
        assertEq(custody, 0);
    }

    function testBonanzaPricedOperatorShareRequiresConsumerRouter() public {
        router.setAsset(address(diamond), true, true);
        LotteryConfig memory config = _config(address(diamond), 10, 10, 10, 1 days, 3);
        bytes memory unavailable = abi.encodeWithSelector(
            Errors.OperatorRouterUnavailable.selector, address(router), address(diamond)
        );
        vm.startPrank(authority);
        vm.expectRevert(unavailable);
        governance.createLotteryConfig(config);
        vm.expectRevert(unavailable);
        governance.createRewardLotteryConfig(config, BonanzaConfig(0, 1000, false));
        config.operatorProtocolBps = 0;
        governance.createLotteryConfig(config);
        config.operatorProtocolBps = 5000;
        bonanza.setBonanzaConsumer(address(router), true);
        governance.createLotteryConfig(config);
        governance.createRewardLotteryConfig(config, BonanzaConfig(0, 1000, false));

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

    function testBonanzaOperatorFundingWaitsUntilRouterIsConsumer() public {
        _bonanzaBuyer(1000);
        router.setAsset(address(diamond), true, true);
        vm.startPrank(authority);
        bonanza.setBonanzaConsumer(address(router), true);
        uint64 version =
            governance.createLotteryConfig(_config(address(diamond), 10, 10, 10, 1 days, 3));
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
        vm.prank(alice);
        uint256 id = lottery.openRound(version, 10);
        _settleRound(id);
        assertEq(stateView.pendingOperatorRevenue(1, address(diamond)), 10);

        vm.prank(authority);
        bonanza.setBonanzaConsumer(address(router), false);
        bytes memory unavailable = abi.encodeWithSelector(
            Errors.OperatorRouterUnavailable.selector, address(router), address(diamond)
        );
        uint256 held = bonanza.balanceOf(address(diamond));
        vm.expectRevert(unavailable);
        revenue.flushOperatorRevenue(1, address(diamond), 10);
        assertEq(stateView.pendingOperatorRevenue(1, address(diamond)), 10);
        assertEq(bonanza.balanceOf(address(diamond)), held);
        vm.prank(alice);
        vm.expectRevert(unavailable);
        lottery.openRound(version, 1);

        vm.prank(authority);
        bonanza.setBonanzaConsumer(address(router), true);
        assertEq(revenue.flushOperatorRevenue(1, address(diamond), 10), 10);
        assertEq(bonanza.balanceOf(address(router)), 10);
        // An approved consumer Router can pay an Operator.
        vm.prank(address(router));
        bonanza.transfer(carol, 10);
        assertEq(bonanza.balanceOf(carol), 10);
    }

    function testBonanzaPayoutsGoOnlyToCallerOrTreasury() public {
        _bonanzaBuyer(1000);
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeBonanza(1, 100);
        router.setAsset(address(diamond), true, true);
        LotteryConfig memory config = _config(address(diamond), 10, 10, 10, 1 days, 3);
        config.operatorProtocolBps = 2500;
        vm.startPrank(authority);
        bonanza.setBonanzaConsumer(address(router), true);
        uint64 version = governance.createRewardLotteryConfig(config, BonanzaConfig(0, 2500, false));
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
        vm.prank(alice);
        uint256 id = lottery.openRound(version, 10); // 100 BONANZA: 80/5/5/7 and a 3 tip
        _settleRound(id);
        assertEq(stateView.round(id).winner, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BonanzaErrors.ReceiverRestricted.selector, carol));
        claims.claimWinner(id, carol);
        vm.prank(alice);
        assertEq(claims.claimWinner(id, alice), 80);

        vm.prank(finalizer);
        vm.expectRevert(abi.encodeWithSelector(BonanzaErrors.ReceiverRestricted.selector, carol));
        claims.claimFinalizerTips(address(diamond), carol);
        vm.prank(finalizer);
        assertEq(claims.claimFinalizerTips(address(diamond), treasury), 3);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BonanzaErrors.ReceiverRestricted.selector, carol));
        staking.claimBonanzaRevenue(1, address(diamond), carol);
        vm.prank(alice);
        assertEq(staking.claimBonanzaRevenue(1, address(diamond), alice), 5);

        assertEq(revenue.flushTreasury(address(diamond), 7), 7);
        assertEq(bonanza.balanceOf(treasury), 10);
        assertEq(bonanza.balanceOf(alice), 1000 - 100 + 80 + 5);
        AssetAccounting memory accounting = stateView.assetAccounting(address(diamond));
        (uint256 inventory,, uint256 custody,,,,) = bonanzaView.bonanzaReserve();
        assertEq(
            bonanza.balanceOf(address(diamond)),
            inventory + custody + accounting.pendingOperatorRevenueTotal
                + bonanzaView.bonanzaAsset(address(diamond)).reserved
        );
        assertEq(revenue.availableTokenSurplus(address(diamond)), 0);
    }

    function testOtherTokenPayoutsKeepArbitraryReceivers() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeBonanza(1, 100);
        uint256 id = _settle(address(tokenB), false);
        vm.prank(alice);
        assertEq(claims.claimWinner(id, carol), 800);
        vm.prank(alice);
        assertEq(staking.claimBonanzaRevenue(1, address(tokenB), carol), 100);
        assertEq(tokenB.balanceOf(carol), 900);
    }

    /// @dev Alice holds `amount` BONANZA in her wallet and approves the Diamond to spend it.
    function _bonanzaBuyer(uint256 amount) internal {
        positions.mint(alice, 4);
        _wrap(4, alice, amount);
        vm.startPrank(alice);
        bonanza.withdrawBonanza(4, amount);
        bonanza.approve(address(diamond), type(uint256).max);
        vm.stopPrank();
    }
}
