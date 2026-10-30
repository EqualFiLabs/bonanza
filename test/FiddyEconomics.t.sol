// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { FiddyRevenueSetup } from "./FiddyStaking.t.sol";

contract FiddyEconomicsTest is FiddyRevenueSetup {
    function testDominantBuyerBoostAndAllOperatorProceedsCannotCreateUnfundedProfit() public {
        _start(); // Alice owns Operator 1, all tickets and boosted 125/225 staking weight.
        uint256 before = tokenB.balanceOf(alice);
        uint256 roundId = _settle(address(tokenB), false);
        assertEq(stateView.round(roundId).winner, alice);
        vm.prank(alice);
        uint256 prize = claims.claimWinner(roundId, alice);
        vm.prank(alice);
        uint256 stakeRevenue = staking.claimFiddyRevenue(1, address(tokenB), alice);
        uint256 operatorRevenue = revenue.flushOperatorRevenue(1, address(tokenB), 100);
        // Give the dominant player the conservative upper bound of ALL Router proceeds.
        // Router's internal allocation remains a separate protocol boundary.
        assertEq(prize, 800);
        assertEq(stakeRevenue, 55);
        assertEq(operatorRevenue, 100);
        assertEq(before - tokenB.balanceOf(alice), 145);
        assertLe(prize + stakeRevenue + operatorRevenue, 1000);
        (uint256 otherStakeRevenue,) = staking.indexedFiddyRevenue(2, address(tokenB));
        assertEq(otherStakeRevenue, 44);
        assertEq(fiddy.totalSupply(), 200);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
    }

    function testAllStakeAndAllTicketOwnershipOnlyRecoverFundedAllocations() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeFiddy(1, 100);
        uint256 roundId = _settle(address(tokenB), false);
        vm.prank(alice);
        uint256 prize = claims.claimWinner(roundId, alice);
        vm.prank(alice);
        uint256 stakeRevenue = staking.claimFiddyRevenue(1, address(tokenB), alice);
        uint256 operatorRevenue = revenue.flushOperatorRevenue(1, address(tokenB), 100);
        assertEq(prize + stakeRevenue + operatorRevenue, 1000);
        assertEq(fiddy.totalSupply(), 100);
        assertEq(fiddyView.fiddyAccount(1).staked, 100);
    }
}
