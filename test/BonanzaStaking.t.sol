// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import { BonanzaSetup } from "./utils/BonanzaSetup.sol";
import { BonanzaConfig } from "../src/shared/BonanzaTypes.sol";
import { BonanzaErrors } from "../src/shared/BonanzaErrors.sol";
import { LibBonanzaStaking } from "../src/libraries/LibBonanzaStaking.sol";

abstract contract BonanzaRevenueSetup is BonanzaSetup {
    function _start() internal {
        _wrap(1, alice, 100);
        _wrap(2, bob, 100);
        vm.prank(alice);
        staking.stakeBonanza(1, 100);
        vm.prank(bob);
        staking.stakeBonanza(2, 100);
        vm.prank(authority);
        staking.setBonanzaBoostsEnabled(true);
        vm.prank(alice);
        operators.activate(1, 12_500);
        vm.prank(alice);
        staking.registerBonanzaOperator(1, 1);
    }

    function _rewardVersion(address asset) internal returns (uint64 version) {
        vm.startPrank(authority);
        version = governance.createRewardLotteryConfig(
            _config(asset, 100, 10, 10, 1 days, 0), BonanzaConfig(0, 5000, false)
        );
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
    }

    /// @dev Default economics: 80% winner and a 50/50 Operator/staker split of the remainder,
    /// so each 100-unit ticket books 10 units to stakers.
    function _settle(address asset, bool deadline) internal returns (uint256 id) {
        uint64 version = _rewardVersion(asset);
        vm.prank(alice);
        id = lottery.openRound(version, deadline ? 5 : 10);
        _settleRound(id);
    }

    function _settleRound(uint256 id) internal {
        bytes memory proof = abi.encode(id);
        _prepareProof(id, proof);
        vm.prank(finalizer);
        settlement.settleRound(id, proof);
    }

    function _checkpoint(uint256 id) internal {
        staking.checkpointBonanzaAccount(id);
    }

    function _earned(uint256 id, address asset) internal view returns (uint256 amount) {
        (amount,) = staking.indexedBonanzaRevenue(id, asset);
    }
}

contract BonanzaStakingTest is BonanzaRevenueSetup {
    function testPurchaseBooksStakerShareAtCurrentWeights() public {
        _start(); // 125:100 weights
        uint64 version = _rewardVersion(address(tokenB));
        vm.prank(alice);
        uint256 id = lottery.openRound(version, 5); // 500 gross books 50
        assertEq(bonanzaView.bonanzaRoundRevenue(id), 50);
        assertEq(bonanzaView.bonanzaAsset(address(tokenB)).reserved, 50);
        assertEq(stateView.assetAccounting(address(tokenB)).activeRoundEscrow, 450);
        assertEq(_earned(1, address(tokenB)), 27);
        assertEq(_earned(2, address(tokenB)), 22);

        // Removing the boost changes only later bookings; earlier ones are already earned.
        vm.prank(alice);
        staking.removeBonanzaOperator(1);
        vm.prank(bob);
        lottery.buyTickets(id, 5); // 100:100 weights, books 50
        assertEq(_earned(1, address(tokenB)), 52);
        assertEq(_earned(2, address(tokenB)), 47);
        assertEq(bonanzaView.bonanzaRoundRevenue(id), 100);

        _settleRound(id);
        assertEq(stateView.assetAccounting(address(tokenB)).activeRoundEscrow, 0);
        // Winner 800, Operators 100, stakers 100: the Treasury remainder and tip are zero.
        assertEq(stateView.assetAccounting(address(tokenB)).treasuryAvailable, 0);
        assertEq(stateView.pendingOperatorRevenue(1, address(tokenB)), 100);
        assertEq(bonanzaView.bonanzaAsset(address(tokenB)).reserved, 100);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
    }

    function testMultiAssetClaimAndCompleteAccountLifecycle() public {
        _start();
        skip(LibBonanzaStaking.STAKE_LOCK);
        _settle(address(tokenA), false);
        _settle(address(tokenB), true);
        vm.prank(alice);
        staking.unstakeBonanza(1, 100);
        vm.prank(alice);
        bonanza.withdrawBonanza(1, 100);
        vm.prank(alice);
        vm.expectRevert(BonanzaErrors.AccountNotEmpty.selector);
        staking.cleanupBonanzaAccount(1);
        vm.prank(alice);
        assertEq(staking.claimBonanzaRevenue(1, address(tokenA), alice), 55);
        vm.prank(alice);
        assertEq(staking.claimBonanzaRevenue(1, address(tokenB), alice), 27);
        vm.prank(alice);
        staking.cleanupBonanzaAccount(1);
        assertEq(positions.legs(1), 0);
        assertFalse(bonanzaView.bonanzaAccount(1).attached);
        assertFalse(bonanzaView.bonanzaAccount(1).registered);
        vm.prank(alice);
        positions.close(1);
        assertEq(bonanza.totalSupply(), 200);
        assertEq(tokenA.balanceOf(address(diamond)), 1145); // backing plus receipts less the 55-unit revenue claim
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
    }

    function testRegistrationOwnershipUniquenessAndExplicitRefresh() public {
        _start();
        positions.mint(alice, 3);
        vm.prank(alice);
        vm.expectRevert(BonanzaErrors.OperatorAlreadyRegistered.selector);
        staking.registerBonanzaOperator(3, 1);
        vm.prank(bob);
        vm.expectRevert(BonanzaErrors.NotPositionOwner.selector);
        staking.registerBonanzaOperator(1, 1);
        vm.prank(bob);
        vm.expectRevert(BonanzaErrors.InvalidRegistration.selector);
        staking.registerBonanzaOperator(2, 1);

        vm.prank(bob);
        operators.activate(2, 11_000);
        vm.prank(bob);
        staking.registerBonanzaOperator(2, 2);
        assertEq(bonanzaView.bonanzaAccount(2).weight, 110);
        vm.prank(bob);
        operators.activate(2, 12_000);
        assertEq(bonanzaView.bonanzaAccount(2).weight, 110); // activation alone is prospective
        vm.prank(bob);
        staking.registerBonanzaOperator(2, 2);
        assertEq(bonanzaView.bonanzaAccount(2).weight, 120);
        (uint256 totalWeight,,) = bonanzaView.bonanzaStaking();
        assertEq(totalWeight, 245);

        vm.prank(authority);
        staking.setBonanzaBoostsEnabled(false);
        vm.prank(bob);
        vm.expectRevert(BonanzaErrors.InvalidRegistration.selector);
        staking.registerBonanzaOperator(2, 2);
        assertEq(bonanzaView.bonanzaAccount(2).weight, 120); // disabling gates new registrations only
    }

    function testZeroWeightRevenueGoesToTreasuryAndCannotBeCaptured() public {
        uint64 version = _rewardVersion(address(tokenB));
        vm.expectEmit(true, true, false, true, address(diamond));
        emit LibBonanzaStaking.BonanzaZeroWeightRevenue(1, address(tokenB), 100);
        vm.prank(alice);
        uint256 id = lottery.openRound(version, 10);
        assertEq(stateView.assetAccounting(address(tokenB)).treasuryAvailable, 100);
        assertEq(bonanzaView.bonanzaAsset(address(tokenB)).reserved, 0);
        assertEq(bonanzaView.bonanzaAsset(address(tokenB)).indexRay, 0);
        _settleRound(id);
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeBonanza(1, 100);
        _checkpoint(1);
        assertEq(_earned(1, address(tokenB)), 0);
        assertEq(stateView.assetAccounting(address(tokenB)).treasuryAvailable, 100);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
    }

    function testApprovalDoesNotGrantFinancialAuthority() public {
        _wrap(1, alice, 100);
        vm.prank(alice);
        positions.approve(bob, 1);
        vm.prank(bob);
        vm.expectRevert(BonanzaErrors.NotPositionOwner.selector);
        staking.stakeBonanza(1, 100);
        vm.prank(bob);
        vm.expectRevert(BonanzaErrors.NotPositionOwner.selector);
        bonanza.withdrawBonanza(1, 100);
    }

    function testCleanupRequiresWholeClaimsAndSurrendersOnlyFractions() public {
        _start();
        skip(LibBonanzaStaking.STAKE_LOCK);
        _settle(address(tokenA), false);
        _settle(address(tokenB), false);
        vm.prank(alice);
        staking.unstakeBonanza(1, 100);
        vm.prank(alice);
        bonanza.withdrawBonanza(1, 100);
        vm.prank(alice);
        staking.claimBonanzaRevenue(1, address(tokenA), alice);
        vm.prank(alice);
        vm.expectRevert(BonanzaErrors.AccountNotEmpty.selector);
        staking.cleanupBonanzaAccount(1); // tokenB whole claim still outstanding
        vm.prank(alice);
        staking.claimBonanzaRevenue(1, address(tokenB), alice);
        uint256 reservedA = bonanzaView.bonanzaAsset(address(tokenA)).reserved;
        uint256 remainderA = bonanzaView.bonanzaCredit(1, address(tokenA)).remainderRay;
        assertGt(remainderA, 0);
        vm.prank(alice);
        staking.cleanupBonanzaAccount(1);
        assertEq(bonanzaView.bonanzaCredit(1, address(tokenA)).remainderRay, 0);
        assertLe(reservedA - bonanzaView.bonanzaAsset(address(tokenA)).reserved, 1);
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
        // Bob's entitlement is untouched by Alice's cleanup.
        assertEq(_earned(2, address(tokenA)), 44);
        assertEq(_earned(2, address(tokenB)), 44);
    }
}
