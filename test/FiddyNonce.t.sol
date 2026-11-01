// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { FiddyRevenueSetup } from "./FiddyStaking.t.sol";
import { LibFiddyStaking } from "../src/libraries/LibFiddyStaking.sol";
import { FiddyConfig } from "../src/shared/FiddyTypes.sol";

contract FiddyNonceTest is FiddyRevenueSetup {
    address internal carol = makeAddr("carol");
    uint64 internal expected;

    function _assertBumped(uint256 id) internal {
        ++expected;
        assertEq(fiddyView.fiddyAccount(id).nonce, expected);
    }

    function _assertUnchanged(uint256 id) internal view {
        assertEq(fiddyView.fiddyAccount(id).nonce, expected);
    }

    function testNonceIncrementsOnEveryOwnerAction() public {
        vm.prank(authority);
        fiddy.setFiddyConversions(true, true, type(uint128).max);
        vm.startPrank(alice);
        fiddy.wrapFiddy(1, 300);
        _assertBumped(1);
        fiddy.withdrawFiddy(1, 50);
        _assertBumped(1);
        fiddy.approve(address(diamond), 50);
        fiddy.depositFiddy(1, 50);
        _assertBumped(1);
        fiddy.unwrapFiddy(1, 100, alice);
        _assertBumped(1);
        staking.stakeFiddy(1, 100);
        _assertBumped(1);
        vm.stopPrank();

        vm.prank(authority);
        staking.setFiddyBoostsEnabled(true);
        vm.prank(alice);
        operators.activate(1, 12_500);
        vm.prank(alice);
        staking.registerFiddyOperator(1, 1);
        _assertBumped(1);

        // Participation credits the selected account; an empty inventory credits nothing.
        vm.startPrank(authority);
        uint64 version = governance.createRewardLotteryConfig(
            _config(address(tokenB), 100, 10, 10, 1 days, 0), FiddyConfig(5, 5000, true)
        );
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
        vm.prank(alice);
        uint256 id = lottery.openRoundForPosition(version, 2, 1);
        _assertUnchanged(1);
        vm.prank(alice);
        fiddy.fundFiddyReserve(20);
        vm.prank(alice);
        lottery.buyTicketsForPosition(id, 3, 1);
        _assertBumped(1);

        vm.prank(alice);
        assertEq(staking.claimFiddyRevenue(1, address(tokenB), alice), 50);
        _assertBumped(1);
        vm.prank(alice);
        assertEq(staking.claimFiddyRevenue(1, address(tokenB), alice), 0);
        _assertUnchanged(1);

        vm.prank(alice);
        staking.removeFiddyOperator(1);
        _assertBumped(1);
        skip(LibFiddyStaking.STAKE_LOCK);
        vm.prank(alice);
        staking.unstakeFiddy(1, 100);
        _assertBumped(1);
        vm.prank(alice);
        fiddy.withdrawFiddy(1, 215);
        _assertBumped(1);
        vm.prank(alice);
        staking.cleanupFiddyAccount(1);
        _assertBumped(1);
    }

    function testThirdPartyCheckpointDoesNotIncrementNonce() public {
        _start();
        expected = fiddyView.fiddyAccount(1).nonce;
        _settle(address(tokenB), false);
        vm.prank(carol);
        staking.checkpointFiddyAccount(1);
        assertEq(fiddyView.fiddyCredit(1, address(tokenB)).claimable, 55);
        _assertUnchanged(1);
        vm.prank(carol);
        staking.checkpointFiddyAccount(1);
        _assertUnchanged(1);
    }

    function testBoostForfeitIncrementsNonce() public {
        _start();
        expected = fiddyView.fiddyAccount(1).nonce;
        _settle(address(tokenB), false);
        vm.prank(alice);
        operators.transferFrom(alice, carol, 1);
        vm.prank(carol);
        staking.checkpointFiddyAccount(1);
        _assertBumped(1);
        vm.prank(carol);
        staking.checkpointFiddyAccount(1);
        _assertUnchanged(1);
    }

    function testEvictionIncrementsTheEvictedAccountNonce() public {
        _start();
        expected = fiddyView.fiddyAccount(1).nonce;
        uint64 bobNonce = fiddyView.fiddyAccount(2).nonce;
        vm.prank(alice);
        operators.transferFrom(alice, bob, 1);
        vm.prank(bob);
        staking.registerFiddyOperator(2, 1);
        _assertBumped(1);
        assertEq(fiddyView.fiddyAccount(2).nonce, bobNonce + 1);
    }
}
