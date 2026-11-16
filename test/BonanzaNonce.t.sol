// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { BonanzaRevenueSetup } from "./BonanzaStaking.t.sol";
import { LibBonanzaStaking } from "../src/libraries/LibBonanzaStaking.sol";
import { BonanzaConfig } from "../src/shared/BonanzaTypes.sol";

contract BonanzaNonceTest is BonanzaRevenueSetup {
    address internal carol = makeAddr("carol");
    uint64 internal expected;

    function _assertBumped(uint256 id) internal {
        ++expected;
        assertEq(bonanzaView.bonanzaAccount(id).nonce, expected);
    }

    function _assertUnchanged(uint256 id) internal view {
        assertEq(bonanzaView.bonanzaAccount(id).nonce, expected);
    }

    function testNonceIncrementsOnEveryOwnerAction() public {
        vm.prank(authority);
        bonanza.setBonanzaConversions(true, true, type(uint128).max);
        vm.startPrank(alice);
        bonanza.wrapBonanza(1, 300);
        _assertBumped(1);
        bonanza.withdrawBonanza(1, 50);
        _assertBumped(1);
        bonanza.approve(address(diamond), 50);
        bonanza.depositBonanza(1, 50);
        _assertBumped(1);
        bonanza.unwrapBonanza(1, 100, alice);
        _assertBumped(1);
        staking.stakeBonanza(1, 100);
        _assertBumped(1);
        vm.stopPrank();

        vm.prank(authority);
        staking.setBonanzaBoostsEnabled(true);
        vm.prank(alice);
        operators.activate(1, 12_500);
        vm.prank(alice);
        staking.registerBonanzaOperator(1, 1);
        _assertBumped(1);

        // Participation credits the selected account; an empty inventory credits nothing.
        vm.startPrank(authority);
        uint64 version = governance.createRewardLotteryConfig(
            _config(address(tokenB), 100, 10, 10, 1 days, 0), BonanzaConfig(5, 5000, true)
        );
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
        vm.prank(alice);
        uint256 id = lottery.openRoundForPosition(version, 2, 1);
        _assertUnchanged(1);
        vm.prank(alice);
        bonanza.fundBonanzaReserve(20);
        vm.prank(alice);
        lottery.buyTicketsForPosition(id, 3, 1);
        _assertBumped(1);

        vm.prank(alice);
        assertEq(staking.claimBonanzaRevenue(1, address(tokenB), alice), 50);
        _assertBumped(1);
        vm.prank(alice);
        assertEq(staking.claimBonanzaRevenue(1, address(tokenB), alice), 0);
        _assertUnchanged(1);

        vm.prank(alice);
        staking.removeBonanzaOperator(1);
        _assertBumped(1);
        skip(LibBonanzaStaking.STAKE_LOCK);
        vm.prank(alice);
        staking.unstakeBonanza(1, 100);
        _assertBumped(1);
        vm.prank(alice);
        bonanza.withdrawBonanza(1, 215);
        _assertBumped(1);
        vm.prank(alice);
        staking.cleanupBonanzaAccount(1);
        _assertBumped(1);
    }

    function testThirdPartyCheckpointDoesNotIncrementNonce() public {
        _start();
        expected = bonanzaView.bonanzaAccount(1).nonce;
        _settle(address(tokenB), false);
        vm.prank(carol);
        staking.checkpointBonanzaAccount(1);
        assertEq(bonanzaView.bonanzaCredit(1, address(tokenB)).claimable, 55);
        _assertUnchanged(1);
        vm.prank(carol);
        staking.checkpointBonanzaAccount(1);
        _assertUnchanged(1);
    }

    function testBoostForfeitIncrementsNonce() public {
        _start();
        expected = bonanzaView.bonanzaAccount(1).nonce;
        _settle(address(tokenB), false);
        vm.prank(alice);
        operators.transferFrom(alice, carol, 1);
        vm.prank(carol);
        staking.checkpointBonanzaAccount(1);
        _assertBumped(1);
        vm.prank(carol);
        staking.checkpointBonanzaAccount(1);
        _assertUnchanged(1);
    }

    function testEvictionIncrementsTheEvictedAccountNonce() public {
        _start();
        expected = bonanzaView.bonanzaAccount(1).nonce;
        uint64 bobNonce = bonanzaView.bonanzaAccount(2).nonce;
        vm.prank(alice);
        operators.transferFrom(alice, bob, 1);
        vm.prank(bob);
        staking.registerBonanzaOperator(2, 1);
        _assertBumped(1);
        assertEq(bonanzaView.bonanzaAccount(2).nonce, bobNonce + 1);
    }
}
