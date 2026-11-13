// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { BonanzaSetup } from "./utils/BonanzaSetup.sol";
import { IntegrationToken } from "./utils/LotteryIntegrationSetup.sol";
import { IRevenue } from "../src/interfaces/IRevenue.sol";
import { Errors } from "../src/shared/Errors.sol";
import { BonanzaErrors } from "../src/shared/BonanzaErrors.sol";
import { BonanzaConfig } from "../src/shared/BonanzaTypes.sol";
import { AssetAccounting, LotteryConfig, Round, RoundStatus } from "../src/shared/Types.sol";

contract RecipientToken is IntegrationToken {
    address public blocked;
    address public callback;
    uint256 public callbackRound;
    uint8 public feeMode;

    constructor() IntegrationToken("Recipient payment", "RPAY") { }

    function configure(address blocked_, uint8 feeMode_, address callback_, uint256 roundId)
        external
    {
        blocked = blocked_;
        feeMode = feeMode_;
        callback = callback_;
        callbackRound = roundId;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(to != blocked, "recipient blocked");
        if (callback != address(0) && from == callback) {
            IRevenue(callback).flushRecipientRevenue(callbackRound);
        }
        super._update(from, to, amount);
        if (from != address(0) && to != address(0) && amount != 0) {
            if (feeMode == 1) super._update(to, address(0), 1);
            if (feeMode == 2) super._update(from, address(0), 1);
        }
    }
}

contract LotteryRecipientTest is BonanzaSetup {
    address internal beneficiary = makeAddr("beneficiary");

    function _recipientConfig(address asset) internal view returns (LotteryConfig memory config) {
        config = _config(asset, 100, 100, 100, 1 days, 0);
        config.winnerBps = 5000;
        config.operatorProtocolBps = 500;
        config.recipientBps = 4500;
        config.recipient = beneficiary;
    }

    function _enable(LotteryConfig memory config, uint16 stakerBps)
        internal
        returns (uint64 version)
    {
        vm.startPrank(authority);
        version = stakerBps == 0
            ? governance.createLotteryConfig(config)
            : governance.createRewardLotteryConfig(config, BonanzaConfig(0, stakerBps, false));
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
    }

    function _open(LotteryConfig memory config, uint16 stakerBps, uint32 quantity)
        internal
        returns (uint256 roundId)
    {
        uint64 version = _enable(config, stakerBps);
        vm.prank(alice);
        roundId = lottery.openRound(version, quantity);
    }

    function _settle(uint256 roundId) internal {
        _prepareProof(roundId, hex"abcd");
        vm.prank(finalizer);
        settlement.settleRound(roundId, hex"abcd");
    }

    function _close(uint256 roundId) internal {
        Round memory current = stateView.round(roundId);
        if (current.winnerClaimable != 0) {
            vm.prank(current.winner);
            claims.claimWinner(roundId, current.winner);
        }
        if (current.recipientClaimable != 0) revenue.flushRecipientRevenue(roundId);
        address asset = current.config.paymentToken;
        uint256 pending = stateView.pendingOperatorRevenue(current.integrationVersion, asset);
        if (pending != 0) revenue.flushOperatorRevenue(current.integrationVersion, asset, pending);
        uint256 available = stateView.assetAccounting(asset).treasuryAvailable;
        if (available != 0) revenue.flushTreasury(asset, available);
        if (stateView.finalizerCredit(asset, finalizer) != 0) {
            vm.prank(finalizer);
            claims.claimFinalizerTips(asset, finalizer);
        }
    }

    function testRecipientSplitPaysEveryAllocationExactlyAndOnlyOnce() public {
        uint256 id = _open(_recipientConfig(address(tokenB)), 0, 100);
        _settle(id);
        AssetAccounting memory a = stateView.assetAccounting(address(tokenB));
        assertEq(a.winnerLiability, 5000);
        assertEq(a.recipientLiability, 4500);
        assertEq(a.pendingOperatorRevenueTotal, 250);
        assertEq(a.treasuryAvailable, 247);
        assertEq(a.finalizerLiability, 3);
        assertEq(tokenB.balanceOf(beneficiary), 0);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
        vm.expectRevert(Errors.NoTokenSurplus.selector);
        revenue.absorbTokenSurplus(address(tokenB));
        vm.prank(guardian);
        governance.setPaused(true);
        vm.expectEmit(true, true, true, true, address(diamond));
        emit IRevenue.RecipientRevenueFlushed(id, address(tokenB), beneficiary, 4500);
        vm.prank(bob);
        assertEq(revenue.flushRecipientRevenue(id), 4500);
        assertEq(tokenB.balanceOf(beneficiary), 4500);
        assertEq(stateView.assetAccounting(address(tokenB)).recipientLiability, 0);
        vm.expectRevert(Errors.NoRecipientRevenue.selector);
        revenue.flushRecipientRevenue(id);
        _close(id);
        assertEq(tokenB.balanceOf(address(diamond)), 0);
    }

    function testDeadlineUsesActualReceiptsAndCappedTipWithoutReducingRecipient() public {
        LotteryConfig memory config = _recipientConfig(address(tokenB));
        config.finalizerTip = type(uint96).max;
        uint256 id = _open(config, 0, 4);
        vm.warp(stateView.round(id).expiresAt);
        _settle(id);
        AssetAccounting memory a = stateView.assetAccounting(address(tokenB));
        assertEq(a.winnerLiability, 200);
        assertEq(a.recipientLiability, 180);
        assertEq(a.pendingOperatorRevenueTotal, 10);
        assertEq(a.finalizerLiability, 10);
        assertEq(a.treasuryAvailable, 0);
        _close(id);
        assertEq(tokenB.balanceOf(address(diamond)), 0);
    }

    function testRecipientRoundingAndFullGrossBoundary() public {
        LotteryConfig memory config = _recipientConfig(address(tokenB));
        config.ticketPrice = 1;
        config.ticketCount = 7;
        config.maxTicketsPerPurchase = 7;
        config.winnerBps = 3333;
        config.operatorProtocolBps = 3333;
        config.recipientBps = 2000;
        config.finalizerTip = 1;
        uint256 id = _open(config, 0, 7);
        _settle(id);
        AssetAccounting memory a = stateView.assetAccounting(address(tokenB));
        assertEq(a.winnerLiability, 2);
        assertEq(a.pendingOperatorRevenueTotal, 1);
        assertEq(a.recipientLiability, 1);
        assertEq(a.treasuryAvailable, 2);
        assertEq(a.finalizerLiability, 1);
        _close(id);
        config.winnerBps = 0;
        config.operatorProtocolBps = 0;
        config.recipientBps = 10_000;
        id = _open(config, 0, 7);
        _settle(id);
        assertEq(stateView.assetAccounting(address(tokenB)).recipientLiability, 7);
        assertEq(stateView.assetAccounting(address(tokenB)).finalizerLiability, 0);
        _close(id);
        assertEq(tokenB.balanceOf(address(diamond)), 0);
    }

    function testDisabledRecipientAndPrematureOrMissingRoundPayouts() public {
        LotteryConfig memory config = _recipientConfig(address(tokenB));
        config.recipientBps = 0;
        config.recipient = address(0);
        uint256 id = _open(config, 0, 100);
        vm.expectRevert(abi.encodeWithSelector(Errors.RoundNotFound.selector, 999));
        revenue.flushRecipientRevenue(999);
        vm.expectRevert(abi.encodeWithSelector(Errors.RoundNotSettled.selector, id));
        revenue.flushRecipientRevenue(id);
        _settle(id);
        vm.expectRevert(Errors.NoRecipientRevenue.selector);
        revenue.flushRecipientRevenue(id);
        _close(id);
        assertEq(tokenB.balanceOf(address(diamond)), 0);
    }

    function testRejectsInvalidRecipientAndCombinedAllocationBudget() public {
        LotteryConfig memory config = _recipientConfig(address(tokenB));
        config.recipient = address(0);
        vm.startPrank(authority);
        vm.expectRevert(Errors.InvalidAddress.selector);
        governance.createLotteryConfig(config);
        config.recipient = address(diamond);
        vm.expectRevert(Errors.InvalidAddress.selector);
        governance.createLotteryConfig(config);
        config.recipient = beneficiary;
        config.recipientBps = 10_001;
        vm.expectRevert(Errors.InvalidConfig.selector);
        governance.createLotteryConfig(config);
        config.recipientBps = 4751; // 4750 BPS is the exact remaining gross budget.
        vm.expectRevert(Errors.InvalidConfig.selector);
        governance.createLotteryConfig(config);
        config.recipientBps = 4750;
        governance.createLotteryConfig(config);
        config.recipientBps = 4500;
        vm.expectRevert(Errors.InvalidConfig.selector);
        governance.createRewardLotteryConfig(config, BonanzaConfig(0, 501, false));
        governance.createRewardLotteryConfig(config, BonanzaConfig(0, 500, false));
        config.recipientBps = 0;
        config.recipient = address(0);
        governance.createLotteryConfig(config);
        // A nonzero address is ignored when its allocation is disabled.
        config.recipient = beneficiary;
        governance.createLotteryConfig(config);
        vm.stopPrank();
    }

    function testRecipientSnapshotAndConcurrentRoundLiabilitiesStayIsolated() public {
        LotteryConfig memory config = _recipientConfig(address(tokenB));
        tokenB.mint(alice, 10_000);
        uint256 first = _open(config, 0, 40);
        config.recipient = makeAddr("other beneficiary");
        uint256 second = _open(config, 0, 100);
        vm.startPrank(authority);
        governance.setLotteryConfigEnabled(stateView.round(first).configVersion, false);
        governance.setTreasuryRecipient(config.recipient);
        vm.stopPrank();
        vm.prank(alice);
        lottery.buyTickets(first, 60);
        _settle(second);
        _settle(first);
        assertEq(stateView.round(first).config.recipient, beneficiary);
        assertEq(stateView.roundConfig(first).recipientBps, 4500);
        assertEq(stateView.assetAccounting(address(tokenB)).recipientLiability, 9000);
        revenue.flushRecipientRevenue(first);
        assertEq(tokenB.balanceOf(beneficiary), 4500);
        assertEq(stateView.round(second).recipientClaimable, 4500);
        assertEq(stateView.assetAccounting(address(tokenB)).recipientLiability, 4500);
        _close(first);
        _close(second);
        assertEq(tokenB.balanceOf(address(diamond)), 0);
    }

    function testRecipientTokenFailureAndReentrancyRollBackOnlyItsPayout() public {
        RecipientToken asset = new RecipientToken();
        _fundAndApprove(asset, alice);
        router.setAsset(address(asset), true, true);
        uint256 id = _open(_recipientConfig(address(asset)), 0, 100);
        asset.configure(beneficiary, 0, address(0), 0);
        _settle(id); // Settlement never calls the Payment Token.
        vm.expectRevert("recipient blocked");
        revenue.flushRecipientRevenue(id);
        assertEq(stateView.round(id).recipientClaimable, 4500);
        assertEq(stateView.assetAccounting(address(asset)).recipientLiability, 4500);
        Round memory current = stateView.round(id);
        vm.prank(current.winner);
        assertEq(claims.claimWinner(id, current.winner), 5000);
        for (uint8 mode = 1; mode <= 2; ++mode) {
            asset.configure(address(0), mode, address(0), 0);
            vm.expectPartialRevert(Errors.InexactTokenTransfer.selector);
            revenue.flushRecipientRevenue(id);
            assertEq(stateView.round(id).recipientClaimable, 4500);
            assertEq(asset.balanceOf(beneficiary), 0);
        }
        asset.configure(address(0), 0, address(diamond), id);
        vm.expectRevert(Errors.Reentrancy.selector);
        revenue.flushRecipientRevenue(id);
        asset.configure(address(0), 0, address(0), 0);
        _close(id);
        assertEq(asset.balanceOf(address(diamond)), 0);
    }

    function testBlockedRecipientClaimsToChosenReceiverWhilePaused() public {
        RecipientToken asset = new RecipientToken();
        _fundAndApprove(asset, alice);
        router.setAsset(address(asset), true, true);
        uint256 id = _open(_recipientConfig(address(asset)), 0, 100);
        address recovery = makeAddr("recipient recovery");
        vm.startPrank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(Errors.RoundNotFound.selector, 999));
        revenue.claimRecipientRevenue(999, recovery);
        vm.expectRevert(abi.encodeWithSelector(Errors.RoundNotSettled.selector, id));
        revenue.claimRecipientRevenue(id, recovery);
        vm.stopPrank();

        _settle(id);
        asset.configure(beneficiary, 0, address(0), 0);
        vm.expectRevert("recipient blocked");
        revenue.flushRecipientRevenue(id);
        address[3] memory outsiders = [stateView.round(id).winner, bob, authority];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(abi.encodeWithSelector(Errors.NotRecipient.selector, outsiders[i]));
            revenue.claimRecipientRevenue(id, outsiders[i]);
        }
        vm.startPrank(beneficiary);
        vm.expectRevert(Errors.InvalidAddress.selector);
        revenue.claimRecipientRevenue(id, address(0));
        vm.expectRevert(Errors.InvalidAddress.selector);
        revenue.claimRecipientRevenue(id, address(diamond));
        for (uint8 mode = 1; mode <= 2; ++mode) {
            asset.configure(beneficiary, mode, address(0), 0);
            vm.expectPartialRevert(Errors.InexactTokenTransfer.selector);
            revenue.claimRecipientRevenue(id, recovery);
        }
        asset.configure(beneficiary, 0, address(diamond), id);
        vm.expectRevert(Errors.Reentrancy.selector);
        revenue.claimRecipientRevenue(id, recovery);
        vm.stopPrank();
        assertEq(stateView.round(id).recipientClaimable, 4500);
        assertEq(stateView.assetAccounting(address(asset)).recipientLiability, 4500);
        assertEq(asset.balanceOf(recovery), 0);

        asset.configure(beneficiary, 0, address(0), 0);
        vm.prank(guardian);
        governance.setPaused(true);
        vm.expectEmit(true, true, true, true, address(diamond));
        emit IRevenue.RecipientRevenueClaimed(id, address(asset), beneficiary, recovery, 4500);
        vm.prank(beneficiary);
        assertEq(revenue.claimRecipientRevenue(id, recovery), 4500);
        assertEq(asset.balanceOf(recovery), 4500);
        assertEq(asset.balanceOf(beneficiary), 0);
        assertEq(stateView.round(id).recipientClaimable, 0);
        assertEq(stateView.assetAccounting(address(asset)).recipientLiability, 0);
        vm.prank(beneficiary);
        vm.expectRevert(Errors.NoRecipientRevenue.selector);
        revenue.claimRecipientRevenue(id, recovery);
        vm.expectRevert(Errors.NoRecipientRevenue.selector);
        revenue.flushRecipientRevenue(id);
        _close(id);
        assertEq(asset.balanceOf(address(diamond)), 0);
    }

    function testBonanzaRecipientClaimKeepsCallerOrTreasuryReceiver() public {
        _wrap(1, alice, 10_000);
        vm.prank(alice);
        bonanza.withdrawBonanza(1, 10_000);
        vm.prank(alice);
        bonanza.approve(address(diamond), 10_000);
        LotteryConfig memory config = _recipientConfig(address(diamond));
        config.operatorProtocolBps = 0;
        uint256 id = _open(config, 0, 100);
        _settle(id);
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(BonanzaErrors.ReceiverRestricted.selector, bob));
        revenue.claimRecipientRevenue(id, bob);
        vm.prank(beneficiary);
        assertEq(revenue.claimRecipientRevenue(id, beneficiary), 4500);
        assertEq(bonanza.balanceOf(beneficiary), 4500);
        _close(id);
        assertEq(bonanza.balanceOf(address(diamond)), 0);
        assertEq(bonanza.totalSupply(), 10_000);
    }

    function testRestrictedBonanzaRecipientExitDoesNotRelaxWinnerTransfers() public {
        _wrap(1, alice, 10_000);
        vm.prank(alice);
        bonanza.withdrawBonanza(1, 10_000);
        vm.prank(alice);
        bonanza.approve(address(diamond), 10_000);
        LotteryConfig memory config = _recipientConfig(address(diamond));
        config.operatorProtocolBps = 0;
        uint256 id = _open(config, 0, 100);
        _settle(id);
        Round memory current = stateView.round(id);
        vm.prank(current.winner);
        vm.expectRevert(
            abi.encodeWithSelector(BonanzaErrors.ReceiverRestricted.selector, beneficiary)
        );
        claims.claimWinner(id, beneficiary);
        vm.prank(bob);
        revenue.flushRecipientRevenue(id);
        assertEq(bonanza.balanceOf(beneficiary), 4500);
        assertEq(revenue.availableTokenSurplus(address(diamond)), 0);
        assertEq(revenue.availableTokenSurplus(address(tokenA)), 0);
        vm.prank(beneficiary);
        vm.expectRevert(BonanzaErrors.TransferRestricted.selector);
        bonanza.transfer(bob, 1);
        _close(id);
        assertEq(bonanza.balanceOf(address(diamond)), 0);
        assertEq(bonanza.totalSupply(), 10_000);
        assertEq(tokenA.balanceOf(address(diamond)), 10_000);
    }

    function testFuzzRecipientAndStakerAllocationsConserveAcrossPurchases(uint256[8] memory seeds)
        public
    {
        _wrap(1, alice, 100);
        vm.prank(alice);
        staking.stakeBonanza(1, 100);
        LotteryConfig memory config = _recipientConfig(address(tokenB));
        config.ticketPrice = uint96(bound(seeds[0], 1, type(uint96).max));
        config.ticketCount = uint32(bound(seeds[1], 1, type(uint32).max));
        config.maxTicketsPerPurchase = 0;
        config.winnerBps = uint16(bound(seeds[2], 0, 10_000));
        config.operatorProtocolBps = uint16(bound(seeds[3], 0, 10_000));
        uint16 stakerBps = uint16(bound(seeds[4], 0, 10_000 - config.operatorProtocolBps));
        uint256 maximum = (10_000 - uint256(config.winnerBps))
            * (10_000 - uint256(config.operatorProtocolBps) - stakerBps) / 10_000;
        config.recipientBps = uint16(bound(seeds[5], 0, maximum));
        config.finalizerTip = uint96(bound(seeds[6], 0, type(uint96).max));
        uint256 gross = uint256(config.ticketPrice) * config.ticketCount;
        tokenB.mint(alice, gross);
        uint32 first = uint32(bound(seeds[7], 1, config.ticketCount));
        uint256 id = _open(config, stakerBps, first);
        if (first != config.ticketCount) {
            vm.prank(alice);
            lottery.buyTickets(id, config.ticketCount - first);
        }
        _settle(id);
        AssetAccounting memory a = stateView.assetAccounting(address(tokenB));
        uint256 reserved = bonanzaView.bonanzaAsset(address(tokenB)).reserved;
        assertEq(a.activeRoundEscrow, 0);
        assertEq(
            a.winnerLiability + a.recipientLiability + a.pendingOperatorRevenueTotal
                + a.treasuryAvailable + a.finalizerLiability + reserved,
            gross
        );
        assertEq(tokenB.balanceOf(address(diamond)), gross);
        assertEq(revenue.availableTokenSurplus(address(tokenB)), 0);
        _close(id);
        if (reserved != 0) {
            vm.prank(alice);
            staking.claimBonanzaRevenue(1, address(tokenB), alice);
        }
        assertEq(tokenB.balanceOf(address(diamond)), 0);
    }
}
