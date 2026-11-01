// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";

import { IClaims } from "../src/interfaces/IClaims.sol";
import { IGovernance } from "../src/interfaces/IGovernance.sol";
import { ILottery } from "../src/interfaces/ILottery.sol";
import { ILotteryView } from "../src/interfaces/ILotteryView.sol";
import { IRevenue } from "../src/interfaces/IRevenue.sol";
import { ISettlement } from "../src/interfaces/ISettlement.sol";
import {
    AssetAccounting,
    IntegrationConfig,
    LotteryConfig,
    Round,
    RoundStatus
} from "../src/shared/Types.sol";
import {
    ConfiguredDrandRegistry,
    IntegrationEndpoint,
    IntegrationToken,
    LotteryIntegrationSetup
} from "./utils/LotteryIntegrationSetup.sol";
import { FiddySetup } from "./utils/FiddySetup.sol";
import { FiddyAsset, FiddyConfig, FiddyCredit } from "../src/shared/FiddyTypes.sol";

contract LotteryRevenueFuzzTest is LotteryIntegrationSetup {
    function testFuzz_RevenueConservation(
        uint256 rawPrice,
        uint256 rawTicketCount,
        uint256 rawWinnerBps,
        uint256 rawOperatorBps,
        uint256 rawFinalizerTip
    ) public {
        LotteryConfig memory config = _fuzzConfig(
            rawPrice, rawTicketCount, rawWinnerBps, rawOperatorBps, rawFinalizerTip
        );
        uint256 roundId = _settle(config);

        AssetAccounting memory accounting = stateView.assetAccounting(address(tokenA));
        uint256 gross = uint256(config.ticketPrice) * config.ticketCount;
        assertEq(stateView.round(roundId).receipts, gross);
        assertEq(
            accounting.winnerLiability + accounting.pendingOperatorRevenueTotal
                + accounting.treasuryAvailable + accounting.finalizerLiability,
            gross
        );
        assertEq(accounting.activeRoundEscrow, 0);
        assertEq(accounting.refundLiability, 0);
        assertEq(tokenA.balanceOf(address(diamond)), gross);
    }

    function _settle(LotteryConfig memory config) private returns (uint256 roundId) {
        vm.startPrank(authority);
        uint64 version = governance.createLotteryConfig(config);
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();

        vm.prank(alice);
        roundId = lottery.openRound(version, config.ticketCount);
        Round memory soldOut = stateView.round(roundId);
        registry.cache(soldOut.drandRound, keccak256("fuzz randomness"), soldOut.selloutAt + 1);
        vm.prank(finalizer);
        settlement.settleRound(roundId, "");
    }

    function _fuzzConfig(
        uint256 rawPrice,
        uint256 rawTicketCount,
        uint256 rawWinnerBps,
        uint256 rawOperatorBps,
        uint256 rawFinalizerTip
    ) private view returns (LotteryConfig memory config) {
        uint32 ticketCount = uint32(bound(rawTicketCount, 1, 20));
        config = _config(
            address(tokenA), uint96(bound(rawPrice, 1, 500)), ticketCount, ticketCount, 1 days, 0
        );
        config.winnerBps = uint16(bound(rawWinnerBps, 0, 10_000));
        config.operatorProtocolBps = uint16(bound(rawOperatorBps, 0, 10_000));
        config.finalizerTip = uint96(bound(rawFinalizerTip, 0, 20_000));
    }
}

contract LotteryTicketFuzzTest is LotteryIntegrationSetup {
    function testFuzz_ArbitraryPurchasesNeverOversellAndResolveEveryTicket(
        uint256 seed,
        uint256 rawPurchaseCount
    ) public {
        uint256 purchaseCount = bound(rawPurchaseCount, 1, 10);
        address[] memory expectedOwners = new address[](10);
        uint32 sold;

        uint32 firstQuantity = uint32(bound(uint256(keccak256(abi.encode(seed, sold))), 1, 5));
        vm.prank(alice);
        uint256 roundId = lottery.openRound(1, firstQuantity);
        for (uint32 ticket; ticket < firstQuantity; ++ticket) {
            expectedOwners[ticket] = alice;
        }
        sold = firstQuantity;

        for (uint256 i = 1; i < purchaseCount && sold < 10; ++i) {
            address buyer = i % 2 == 0 ? alice : bob;
            uint32 remaining = 10 - sold;
            uint32 limit = remaining < 5 ? remaining : 5;
            uint32 quantity =
                uint32(bound(uint256(keccak256(abi.encode(seed, i))), 1, uint256(limit)));
            vm.prank(buyer);
            lottery.buyTickets(roundId, quantity);
            for (uint32 ticket = sold; ticket < sold + quantity; ++ticket) {
                expectedOwners[ticket] = buyer;
            }
            sold += quantity;
        }

        Round memory current = stateView.round(roundId);
        assertEq(current.soldTickets, sold);
        assertLe(current.soldTickets, current.config.ticketCount);
        for (uint32 ticket; ticket < sold; ++ticket) {
            assertEq(stateView.ticketOwner(roundId, ticket), expectedOwners[ticket]);
        }
    }
}

contract LotteryStateHandler is Test {
    IGovernance internal immutable governance;
    ILottery internal immutable lottery;
    ILotteryView internal immutable lotteryView;
    ISettlement internal immutable settlement;
    IClaims internal immutable claims;
    IRevenue internal immutable revenue;
    ConfiguredDrandRegistry internal immutable registry;
    IntegrationEndpoint internal immutable router;
    IntegrationToken internal immutable tokenA;
    IntegrationToken internal immutable tokenB;
    address internal immutable authority;
    address internal immutable alice;
    address internal immutable bob;
    uint64 internal immutable firstVersion;

    uint256[] internal openedRounds;
    mapping(uint256 roundId => bytes32 snapshotHash) internal initialSnapshotHash;
    mapping(uint256 roundId => RoundStatus status) internal observedTerminalStatus;

    constructor(
        address diamond,
        address authority_,
        address alice_,
        address bob_,
        ConfiguredDrandRegistry registry_,
        IntegrationEndpoint router_,
        IntegrationToken tokenA_,
        IntegrationToken tokenB_,
        uint64 firstVersion_
    ) {
        governance = IGovernance(diamond);
        lottery = ILottery(diamond);
        lotteryView = ILotteryView(diamond);
        settlement = ISettlement(diamond);
        claims = IClaims(diamond);
        revenue = IRevenue(diamond);
        authority = authority_;
        alice = alice_;
        bob = bob_;
        registry = registry_;
        router = router_;
        tokenA = tokenA_;
        tokenB = tokenB_;
        firstVersion = firstVersion_;
    }

    function openRound(uint256 rawConfig, uint256 rawQuantity, uint256 actorSeed) external {
        if (governance.paused()) return;
        if (lotteryView.maxActiveRounds() == 0) return;
        if (lotteryView.activeRoundCount() >= lotteryView.maxActiveRounds()) return;

        uint64 version = uint64(bound(rawConfig, firstVersion, firstVersion + 1));
        if (lotteryView.activeRoundForConfig(version) != 0) return;
        (LotteryConfig memory config, bool enabled) = lotteryView.lotteryConfig(version);
        if (!enabled) return;
        uint32 limit =
            config.maxTicketsPerPurchase == 0 ? config.ticketCount : config.maxTicketsPerPurchase;
        uint32 quantity = uint32(bound(rawQuantity, 1, limit));
        address actor = actorSeed % 2 == 0 ? alice : bob;

        vm.prank(actor);
        try lottery.openRound(version, quantity) returns (uint256 roundId) {
            openedRounds.push(roundId);
            Round memory created = lotteryView.round(roundId);
            initialSnapshotHash[roundId] = _immutableRoundHash(created);
            _rememberTerminal(roundId, created.status);
        } catch { }
    }

    function buyTickets(uint256 rawRound, uint256 rawQuantity, uint256 actorSeed) external {
        uint256 roundId = _selectRound(rawRound);
        if (roundId == 0) return;
        Round memory current = lotteryView.round(roundId);
        if (current.status != RoundStatus.Open || block.timestamp >= current.expiresAt) return;
        uint32 remaining = current.config.ticketCount - current.soldTickets;
        uint32 limit = current.config.maxTicketsPerPurchase == 0
            ? remaining
            : current.config.maxTicketsPerPurchase;
        if (limit > remaining) limit = remaining;
        uint32 quantity = uint32(bound(rawQuantity, 1, limit));
        address actor = actorSeed % 2 == 0 ? alice : bob;

        vm.prank(actor);
        try lottery.buyTickets(roundId, quantity) {
            _rememberTerminal(roundId, lotteryView.round(roundId).status);
        } catch { }
    }

    function advanceTime(uint256 rawSeconds) external {
        vm.warp(block.timestamp + bound(rawSeconds, 0, 3 days));
    }

    function settleRound(uint256 rawRound, uint256 randomnessSeed) external {
        uint256 roundId = _selectRound(rawRound);
        if (roundId == 0) return;
        Round memory current = lotteryView.round(roundId);
        if (
            current.status != RoundStatus.SoldOut
                && !(current.status == RoundStatus.Open && block.timestamp >= current.expiresAt)
        ) return;
        registry.cache(
            current.drandRound,
            keccak256(abi.encode(roundId, randomnessSeed)),
            (current.status == RoundStatus.SoldOut ? current.selloutAt : current.expiresAt) + 1
        );
        try settlement.settleRound(roundId, "") {
            _rememberTerminal(roundId, RoundStatus.Settled);
        } catch { }
    }

    function claimWinner(uint256 rawRound) external {
        uint256 roundId = _selectRound(rawRound);
        if (roundId == 0) return;
        Round memory current = lotteryView.round(roundId);
        if (current.status != RoundStatus.Settled || current.winnerClaimable == 0) return;
        vm.prank(current.winner);
        try claims.claimWinner(roundId, current.winner) { } catch { }
    }

    function flushRecipient(uint256 rawRound) external {
        uint256 roundId = _selectRound(rawRound);
        if (roundId == 0 || lotteryView.round(roundId).recipientClaimable == 0) return;
        revenue.flushRecipientRevenue(roundId);
    }

    function claimFinalizer(uint256 rawAsset) external {
        address asset = _asset(rawAsset);
        if (lotteryView.finalizerCredit(asset, address(this)) == 0) return;
        try claims.claimFinalizerTips(asset, address(this)) { } catch { }
    }

    function flushOperator(uint256 rawVersion, uint256 rawAsset, uint256 rawAmount) external {
        (, uint64 currentVersion) = lotteryView.currentIntegration();
        if (currentVersion == 0) return;
        uint64 version = uint64(bound(rawVersion, 1, currentVersion));
        address asset = _asset(rawAsset);
        uint256 available = lotteryView.pendingOperatorRevenue(version, asset);
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        try revenue.flushOperatorRevenue(version, asset, amount) { } catch { }
    }

    function flushTreasury(uint256 rawAsset, uint256 rawAmount) external {
        address asset = _asset(rawAsset);
        uint256 available = lotteryView.assetAccounting(asset).treasuryAvailable;
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        try revenue.flushTreasury(asset, amount) { } catch { }
    }

    function setPaused(uint256 rawPaused) external {
        vm.prank(authority);
        governance.setPaused(rawPaused % 2 == 0);
    }

    function setConfigEnabled(uint256 rawConfig, uint256 rawEnabled) external {
        uint64 version = uint64(bound(rawConfig, firstVersion, firstVersion + 1));
        vm.prank(authority);
        governance.setLotteryConfigEnabled(version, rawEnabled % 2 == 0);
    }

    function setMaxActiveRounds(uint256 rawLimit) external {
        uint256 active = lotteryView.activeRoundCount();
        uint16 limit = uint16(bound(rawLimit, active, 4));
        vm.prank(authority);
        governance.setMaxActiveRounds(limit);
    }

    function updateIntegration() external {
        vm.prank(authority);
        governance.setIntegrationConfig(IntegrationConfig(address(registry), address(router)));
    }

    function roundCount() external view returns (uint256) {
        return openedRounds.length;
    }

    function roundIdAt(uint256 index) external view returns (uint256) {
        return openedRounds[index];
    }

    function recordedSnapshotHash(uint256 roundId) external view returns (bytes32) {
        return initialSnapshotHash[roundId];
    }

    function terminalStatus(uint256 roundId) external view returns (RoundStatus) {
        return observedTerminalStatus[roundId];
    }

    function _selectRound(uint256 rawRound) private view returns (uint256) {
        if (openedRounds.length == 0) return 0;
        return openedRounds[rawRound % openedRounds.length];
    }

    function _asset(uint256 rawAsset) private view returns (address) {
        return rawAsset % 2 == 0 ? address(tokenA) : address(tokenB);
    }

    function _rememberTerminal(uint256 roundId, RoundStatus status) private {
        if (observedTerminalStatus[roundId] == RoundStatus.None && status == RoundStatus.Settled) {
            observedTerminalStatus[roundId] = status;
        }
    }

    function _immutableRoundHash(Round memory value) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                value.config,
                value.configVersion,
                value.integrationVersion,
                value.openedAt,
                value.expiresAt
            )
        );
    }
}

contract LotteryInvariantTest is StdInvariant, LotteryIntegrationSetup {
    LotteryStateHandler internal handler;

    function setUp() public override {
        super.setUp();
        LotteryConfig memory first = _config(address(tokenA), 10, 10, 5, 1 days, 30);
        first.recipientBps = 1000;
        first.recipient = makeAddr("first recipient");
        LotteryConfig memory second = _config(address(tokenB), 7, 6, 0, 2 days, 0);
        second.recipientBps = 500;
        second.recipient = makeAddr("second recipient");
        vm.startPrank(authority);
        uint64 version = governance.createLotteryConfig(first);
        governance.createLotteryConfig(second);
        governance.setLotteryConfigEnabled(version, true);
        governance.setLotteryConfigEnabled(version + 1, true);
        vm.stopPrank();
        handler = new LotteryStateHandler(
            address(diamond), authority, alice, bob, registry, router, tokenA, tokenB, version
        );

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = LotteryStateHandler.openRound.selector;
        selectors[1] = LotteryStateHandler.buyTickets.selector;
        selectors[2] = LotteryStateHandler.advanceTime.selector;
        selectors[3] = LotteryStateHandler.settleRound.selector;
        selectors[4] = LotteryStateHandler.claimWinner.selector;
        selectors[5] = LotteryStateHandler.claimFinalizer.selector;
        selectors[6] = LotteryStateHandler.flushOperator.selector;
        selectors[7] = LotteryStateHandler.flushTreasury.selector;
        selectors[8] = LotteryStateHandler.setPaused.selector;
        selectors[9] = LotteryStateHandler.setConfigEnabled.selector;
        selectors[10] = LotteryStateHandler.updateIntegration.selector;
        selectors[11] = LotteryStateHandler.setMaxActiveRounds.selector;
        selectors[12] = LotteryStateHandler.flushRecipient.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_PerTokenSolvencyAndAccountingIsolation() public view {
        _assertAssetSolventAndExact(address(tokenA));
        _assertAssetSolventAndExact(address(tokenB));
        _assertLedgerAggregates(address(tokenA));
        _assertLedgerAggregates(address(tokenB));
    }

    function invariant_RoundSupplyOwnershipSnapshotsAndTerminalStates() public view {
        uint256 expectedActive;
        uint256 count = handler.roundCount();
        for (uint256 i; i < count; ++i) {
            uint256 roundId = handler.roundIdAt(i);
            Round memory current = stateView.round(roundId);
            assertLe(current.soldTickets, current.config.ticketCount);
            assertGt(current.soldTickets, 0);
            uint64 cutoff = current.selloutAt == 0 ? current.expiresAt : current.selloutAt;
            assertEq(
                current.drandRound,
                registry.firstRoundAfter(uint256(cutoff) + current.config.randomnessDelay)
            );
            assertTrue(current.status != RoundStatus.Expired);
            if (current.status == RoundStatus.Settled) {
                assertLt(current.winningTicket, current.soldTickets);
                assertEq(current.winner, stateView.ticketOwner(roundId, current.winningTicket));
            }
            assertEq(_immutableRoundHash(current), handler.recordedSnapshotHash(roundId));

            if (current.status == RoundStatus.Open || current.status == RoundStatus.SoldOut) {
                ++expectedActive;
            }
            RoundStatus terminal = handler.terminalStatus(roundId);
            if (terminal != RoundStatus.None) assertEq(uint8(current.status), uint8(terminal));
            for (uint32 ticket; ticket < current.soldTickets; ++ticket) {
                assertNotEq(stateView.ticketOwner(roundId, ticket), address(0));
            }
        }
        assertEq(stateView.activeRoundCount(), expectedActive);
    }

    function _assertAssetSolventAndExact(address asset) private view {
        AssetAccounting memory accounting = stateView.assetAccounting(asset);
        uint256 accounted = accounting.activeRoundEscrow + accounting.winnerLiability
            + accounting.refundLiability + accounting.finalizerLiability
            + accounting.pendingOperatorRevenueTotal + accounting.treasuryAvailable
            + accounting.recipientLiability;
        uint256 balance = IntegrationToken(asset).balanceOf(address(diamond));
        assertGe(balance, accounted);
        assertEq(balance, accounted);
    }

    function _assertLedgerAggregates(address asset) private view {
        uint256 activeEscrow;
        uint256 winnerLiability;
        uint256 recipientLiability;
        uint256 count = handler.roundCount();
        for (uint256 i; i < count; ++i) {
            uint256 roundId = handler.roundIdAt(i);
            Round memory current = stateView.round(roundId);
            if (current.config.paymentToken != asset) continue;
            if (current.status == RoundStatus.Open || current.status == RoundStatus.SoldOut) {
                activeEscrow += current.receipts;
            } else if (current.status == RoundStatus.Settled) {
                winnerLiability += current.winnerClaimable;
                recipientLiability += current.recipientClaimable;
            }
        }

        AssetAccounting memory accounting = stateView.assetAccounting(asset);
        assertEq(accounting.activeRoundEscrow, activeEscrow);
        assertEq(accounting.winnerLiability, winnerLiability);
        assertEq(accounting.recipientLiability, recipientLiability);
        assertEq(accounting.refundLiability, 0);
        assertEq(accounting.finalizerLiability, stateView.finalizerCredit(asset, address(handler)));

        (, uint64 currentVersion) = stateView.currentIntegration();
        uint256 pendingOperatorRevenue;
        for (uint64 version = 1; version <= currentVersion; ++version) {
            pendingOperatorRevenue += stateView.pendingOperatorRevenue(version, asset);
        }
        assertEq(accounting.pendingOperatorRevenueTotal, pendingOperatorRevenue);
    }

    function _immutableRoundHash(Round memory value) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                value.config,
                value.configVersion,
                value.integrationVersion,
                value.openedAt,
                value.expiresAt
            )
        );
    }
}

/// @notice Concurrent reward rounds in two Payment Tokens, each booking a staker share at purchase.
contract LotteryRewardInvariantTest is StdInvariant, FiddySetup {
    uint256 internal constant RAY = 1e27;
    LotteryStateHandler internal handler;

    function setUp() public override {
        super.setUp();
        _wrap(1, alice, 100);
        _wrap(2, bob, 70);
        vm.prank(alice);
        staking.stakeFiddy(1, 100);
        vm.prank(bob);
        staking.stakeFiddy(2, 70);
        LotteryConfig memory configA = _config(address(tokenA), 10, 10, 10, 1 days, 30);
        configA.winnerBps = 5000;
        configA.operatorProtocolBps = 4000;
        configA.recipientBps = 1000;
        configA.recipient = makeAddr("reward recipient A");
        LotteryConfig memory configB = _config(address(tokenB), 7, 13, 5, 2 days, 0);
        configB.winnerBps = 7000;
        configB.operatorProtocolBps = 2500;
        configB.recipientBps = 750;
        configB.recipient = makeAddr("reward recipient B");
        vm.startPrank(authority);
        uint64 first = governance.createRewardLotteryConfig(configA, FiddyConfig(0, 4000, false));
        governance.createRewardLotteryConfig(configB, FiddyConfig(0, 5000, false));
        governance.setLotteryConfigEnabled(first, true);
        governance.setLotteryConfigEnabled(first + 1, true);
        vm.stopPrank();
        tokenA.mint(alice, 1e24);
        tokenA.mint(bob, 1e24);
        tokenB.mint(alice, 1e24);
        tokenB.mint(bob, 1e24);
        handler = new LotteryStateHandler(
            address(diamond), authority, alice, bob, registry, router, tokenA, tokenB, first
        );

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = LotteryStateHandler.openRound.selector;
        selectors[1] = LotteryStateHandler.buyTickets.selector;
        selectors[2] = LotteryStateHandler.advanceTime.selector;
        selectors[3] = LotteryStateHandler.settleRound.selector;
        selectors[4] = LotteryStateHandler.claimWinner.selector;
        selectors[5] = LotteryStateHandler.claimFinalizer.selector;
        selectors[6] = LotteryStateHandler.flushOperator.selector;
        selectors[7] = LotteryStateHandler.flushTreasury.selector;
        selectors[8] = LotteryStateHandler.setPaused.selector;
        selectors[9] = LotteryStateHandler.setConfigEnabled.selector;
        selectors[10] = LotteryStateHandler.setMaxActiveRounds.selector;
        selectors[11] = LotteryStateHandler.flushRecipient.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_RewardRoundsKeepPerTokenEscrowAndRevenueExact() public view {
        (, uint256 backing,,,,,) = fiddyView.fiddyReserve();
        _assertToken(address(tokenA), backing);
        _assertToken(address(tokenB), 0);
    }

    function _assertToken(address asset, uint256 backing) private view {
        AssetAccounting memory accounting = stateView.assetAccounting(asset);
        FiddyAsset memory book = fiddyView.fiddyAsset(asset);
        uint256 accounted = accounting.activeRoundEscrow + accounting.winnerLiability
            + accounting.finalizerLiability + accounting.pendingOperatorRevenueTotal
            + accounting.treasuryAvailable + accounting.recipientLiability + book.reserved + backing;
        assertEq(IntegrationToken(asset).balanceOf(address(diamond)), accounted);
        assertEq(revenue.availableTokenSurplus(asset), 0);

        uint256 escrow;
        uint256 winnerLiability;
        uint256 recipientLiability;
        uint256 booked;
        uint256 count = handler.roundCount();
        for (uint256 i; i < count; ++i) {
            uint256 roundId = handler.roundIdAt(i);
            Round memory current = stateView.round(roundId);
            if (current.config.paymentToken != asset) continue;
            uint256 staker = fiddyView.fiddyRoundRevenue(roundId);
            booked += staker;
            if (current.status == RoundStatus.Open || current.status == RoundStatus.SoldOut) {
                escrow += current.receipts - staker;
            } else if (current.status == RoundStatus.Settled) {
                winnerLiability += current.winnerClaimable;
                recipientLiability += current.recipientClaimable;
            }
        }
        assertEq(accounting.activeRoundEscrow, escrow);
        assertEq(accounting.winnerLiability, winnerLiability);
        assertEq(accounting.recipientLiability, recipientLiability);
        // Stakers never claim in this handler, so booked revenue is reserved less whole dust.
        assertLe(book.reserved, booked);
        assertLe(booked - book.reserved, accounting.treasuryAvailable);

        uint256 scaled = book.dustRay;
        for (uint256 id = 1; id <= 2; ++id) {
            FiddyCredit memory c = fiddyView.fiddyCredit(id, asset);
            scaled += c.claimable * RAY + c.remainderRay + fiddyView.fiddyAccount(id).weight
            * (book.indexRay - c.paidIndex);
        }
        assertEq(book.reserved * RAY, scaled);
    }
}
