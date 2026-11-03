// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20Errors } from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import { StaticsLotteryDiamond } from "../src/StaticsLotteryDiamond.sol";
import { DiamondCutFacet } from "../src/facets/DiamondCutFacet.sol";
import { GovernanceFacet } from "../src/facets/GovernanceFacet.sol";
import { LotteryFacet } from "../src/facets/LotteryFacet.sol";
import { IDiamondCut } from "../src/interfaces/IDiamondCut.sol";
import { IEqualFiDrandRegistry } from "../src/interfaces/IEqualFiDrandRegistry.sol";
import { IGovernance } from "../src/interfaces/IGovernance.sol";
import { ILottery } from "../src/interfaces/ILottery.sol";
import { LibLotteryStorage } from "../src/libraries/LibLotteryStorage.sol";
import { LibReentrancy } from "../src/libraries/LibReentrancy.sol";
import { LibTicketRanges } from "../src/libraries/LibTicketRanges.sol";
import { Errors } from "../src/shared/Errors.sol";
import { FacetCut, FacetCutAction } from "../src/shared/DiamondTypes.sol";
import {
    AssetAccounting,
    IntegrationConfig,
    LotteryConfig,
    Round,
    RoundStatus,
    TicketRange
} from "../src/shared/Types.sol";

contract LifecycleToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) { }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}

contract LifecycleReceiverFeeToken is LifecycleToken {
    constructor() LifecycleToken("Receiver Fee", "RFEE") { }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value != 0) {
            super._update(from, to, value - 1);
            super._update(from, address(0), 1);
        } else {
            super._update(from, to, value);
        }
    }
}

contract LifecycleSenderFeeToken is LifecycleToken {
    constructor() LifecycleToken("Sender Fee", "SFEE") { }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && value != 0) {
            super._update(from, address(0), 1);
        }
    }
}

contract LifecycleReentrantToken is LifecycleToken {
    address internal target;
    uint256 internal attackedRound;
    bool internal attackEnabled;

    constructor() LifecycleToken("Reentrant Token", "REENTER") { }

    function configureAttack(address target_, uint256 roundId) external {
        target = target_;
        attackedRound = roundId;
        attackEnabled = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (attackEnabled && to == target && from != address(0)) {
            ILottery(target).buyTickets(attackedRound, 1);
        }
    }
}

contract LifecycleDrandRegistry is IEqualFiDrandRegistry {
    mapping(uint64 round => bool cached) internal signatures;

    function setCached(uint64 round, bool cached) external {
        signatures[round] = cached;
    }

    function firstRoundAfter(uint256 timestamp) external pure returns (uint64) {
        return uint64(timestamp / 3 + 1);
    }

    function roundTime(uint64 round) external pure returns (uint64) {
        return round * 3;
    }

    function hasSig(uint64 round) external view returns (bool) {
        return signatures[round];
    }

    function randomnessOf(uint64) external pure returns (bytes32) {
        return bytes32(0);
    }

    function postedAt(uint64) external pure returns (uint64) {
        return 0;
    }

    function postSig(uint64, bytes calldata) external pure returns (bool) {
        return false;
    }
}

contract InvalidScheduleRegistry is IEqualFiDrandRegistry {
    function firstRoundAfter(uint256) external pure returns (uint64) {
        return 1;
    }

    function roundTime(uint64) external pure returns (uint64) {
        return 1;
    }

    function hasSig(uint64) external pure returns (bool) {
        return false;
    }

    function randomnessOf(uint64) external pure returns (bytes32) {
        return bytes32(0);
    }

    function postedAt(uint64) external pure returns (uint64) {
        return 0;
    }

    function postSig(uint64, bytes calldata) external pure returns (bool) {
        return false;
    }
}

contract LifecycleEndpoint {
    function bootstrapFinalized() external pure returns (bool) {
        return true;
    }

    function totalEffectiveWeight() external pure returns (uint256) {
        return 1;
    }

    function isRewardAsset(address) external pure returns (bool) {
        return true;
    }

    function rewardAssetEnabled(address) external pure returns (bool) {
        return true;
    }
}

contract LifecycleInitializer {
    function initialize() external {
        LibReentrancy.initialize();
    }
}

contract LifecycleStateFacet {
    function roundState(uint256 roundId) external view returns (Round memory) {
        return LibLotteryStorage.gameStorage().rounds[roundId];
    }

    function activeRoundCount() external view returns (uint256) {
        return LibLotteryStorage.gameStorage().activeRoundCount;
    }

    function refundCredit(uint256 roundId, address account) external view returns (uint256) {
        return LibLotteryStorage.gameStorage().refundCredit[roundId][account];
    }

    function purchaseEntryCount(uint256 roundId) external view returns (uint256) {
        return LibLotteryStorage.gameStorage().entries[roundId].length;
    }

    function purchaseEntry(uint256 roundId, uint256 index)
        external
        view
        returns (TicketRange memory)
    {
        return LibLotteryStorage.gameStorage().entries[roundId][index];
    }

    function ticketOwner(uint256 roundId, uint32 ticket) external view returns (address) {
        return
            LibTicketRanges.ownerOfTicket(LibLotteryStorage.gameStorage().entries[roundId], ticket);
    }

    function assetAccounting(address asset) external view returns (AssetAccounting memory) {
        return LibLotteryStorage.accountingStorage().assetAccounting[asset];
    }
}

contract LotteryPurchasesTest is Test {
    address internal authority = makeAddr("authority");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    StaticsLotteryDiamond internal diamond;
    IGovernance internal governance;
    ILottery internal lottery;
    LifecycleStateFacet internal stateView;
    LifecycleToken internal tokenA;
    LifecycleToken internal tokenB;
    LifecycleDrandRegistry internal registry;
    LifecycleEndpoint internal router;

    function setUp() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        diamond = new StaticsLotteryDiamond(authority, address(cutFacet));
        GovernanceFacet governanceFacet = new GovernanceFacet();
        LotteryFacet lotteryFacet = new LotteryFacet();
        LifecycleStateFacet stateFacet = new LifecycleStateFacet();
        LifecycleInitializer initializer = new LifecycleInitializer();

        FacetCut[] memory cuts = new FacetCut[](3);
        cuts[0] = _cut(address(governanceFacet), _governanceSelectors());
        cuts[1] = _cut(address(lotteryFacet), _lotterySelectors());
        cuts[2] = _cut(address(stateFacet), _stateSelectors());
        vm.prank(authority);
        IDiamondCut(address(diamond))
            .diamondCut(
                cuts, address(initializer), abi.encodeCall(LifecycleInitializer.initialize, ())
            );

        governance = IGovernance(address(diamond));
        lottery = ILottery(address(diamond));
        stateView = LifecycleStateFacet(address(diamond));
        tokenA = new LifecycleToken("Payment A", "PAYA");
        tokenB = new LifecycleToken("Payment B", "PAYB");
        registry = new LifecycleDrandRegistry();
        router = new LifecycleEndpoint();

        vm.startPrank(authority);
        governance.setIntegrationConfig(IntegrationConfig(address(registry), address(router)));
        governance.setMaxActiveRounds(2);
        governance.createLotteryConfig(_config(address(tokenA), 10, 10, 5, 1 days, 30));
        governance.setLotteryConfigEnabled(1, true);
        governance.createLotteryConfig(_config(address(tokenB), 7, 6, 0, 2 days, 0));
        governance.setLotteryConfigEnabled(2, true);
        vm.stopPrank();

        _fundAndApprove(tokenA, alice);
        _fundAndApprove(tokenA, bob);
        _fundAndApprove(tokenB, alice);
        _fundAndApprove(tokenB, bob);
    }

    function test_OpenRoundSnapshotsTermsAndFirstExactPurchase() public {
        vm.prank(alice);
        uint256 roundId = lottery.openRound(1, 3);

        Round memory round = stateView.roundState(roundId);
        assertEq(roundId, 1);
        assertEq(round.configVersion, 1);
        assertEq(round.integrationVersion, 1);
        assertEq(round.config.paymentToken, address(tokenA));
        assertEq(round.config.ticketPrice, 10);
        assertEq(round.config.ticketCount, 10);
        assertEq(round.soldTickets, 3);
        assertEq(round.receipts, 30);
        assertEq(uint8(round.status), uint8(RoundStatus.Open));
        assertEq(stateView.activeRoundCount(), 1);
        assertEq(tokenA.balanceOf(alice), 970);
        assertEq(tokenA.balanceOf(address(diamond)), 30);
        assertEq(stateView.refundCredit(roundId, alice), 0);
        assertEq(stateView.assetAccounting(address(tokenA)).activeRoundEscrow, 30);
        assertEq(stateView.purchaseEntryCount(roundId), 1);
        assertEq(stateView.ticketOwner(roundId, 0), alice);
        assertEq(stateView.ticketOwner(roundId, 2), alice);
    }

    function test_AdditionalPurchasesAppendRangesWithoutRefundCredits() public {
        vm.prank(alice);
        uint256 roundId = lottery.openRound(1, 2);
        vm.prank(bob);
        lottery.buyTickets(roundId, 3);
        vm.prank(alice);
        lottery.buyTickets(roundId, 1);

        Round memory round = stateView.roundState(roundId);
        assertEq(round.soldTickets, 6);
        assertEq(round.receipts, 60);
        assertEq(stateView.purchaseEntryCount(roundId), 3);
        assertEq(stateView.ticketOwner(roundId, 0), alice);
        assertEq(stateView.ticketOwner(roundId, 2), bob);
        assertEq(stateView.ticketOwner(roundId, 4), bob);
        assertEq(stateView.ticketOwner(roundId, 5), alice);
        assertEq(stateView.refundCredit(roundId, alice), 0);
        assertEq(stateView.refundCredit(roundId, bob), 0);
    }

    function test_ConcurrentTokensKeepCustodyAndAccountingIsolated() public {
        vm.prank(alice);
        uint256 roundA = lottery.openRound(1, 2);
        vm.prank(bob);
        uint256 roundB = lottery.openRound(2, 3);

        assertEq(stateView.activeRoundCount(), 2);
        assertEq(stateView.roundState(roundA).config.paymentToken, address(tokenA));
        assertEq(stateView.roundState(roundB).config.paymentToken, address(tokenB));
        assertEq(tokenA.balanceOf(address(diamond)), 20);
        assertEq(tokenB.balanceOf(address(diamond)), 21);
        assertEq(stateView.assetAccounting(address(tokenA)).activeRoundEscrow, 20);
        assertEq(stateView.assetAccounting(address(tokenB)).activeRoundEscrow, 21);

        vm.prank(authority);
        governance.setLotteryConfigEnabled(1, false);
        vm.prank(alice);
        lottery.buyTickets(roundA, 1);
        assertEq(stateView.assetAccounting(address(tokenA)).activeRoundEscrow, 30);
        assertEq(stateView.assetAccounting(address(tokenB)).activeRoundEscrow, 21);

        vm.expectRevert(Errors.ActiveRoundLimitReached.selector);
        vm.prank(alice);
        lottery.openRound(2, 1);
    }

    function test_OneOpenRoundPerConfigurationKeepsCapacityJoinable() public {
        vm.prank(alice);
        uint256 roundId = lottery.openRound(1, 1);

        vm.expectRevert(abi.encodeWithSelector(Errors.ConfigAlreadyActive.selector, 1, roundId));
        vm.prank(bob);
        lottery.openRound(1, 1);

        vm.prank(bob);
        lottery.buyTickets(roundId, 1);
        assertEq(stateView.activeRoundCount(), 1);
        assertEq(stateView.roundState(roundId).soldTickets, 2);
    }

    function test_SelloutCommitsStrictlyFutureUncachedDrandRound() public {
        vm.prank(alice);
        uint256 roundId = lottery.openRound(1, 5);
        vm.prank(bob);
        lottery.buyTickets(roundId, 5);

        Round memory round = stateView.roundState(roundId);
        uint256 commitmentBoundary = uint256(round.selloutAt) + round.config.randomnessDelay;
        assertEq(uint8(round.status), uint8(RoundStatus.SoldOut));
        assertEq(round.drandRound, registry.firstRoundAfter(commitmentBoundary));
        assertGt(registry.roundTime(round.drandRound), commitmentBoundary);
        assertFalse(registry.hasSig(round.drandRound));
        assertEq(stateView.activeRoundCount(), 1);

        vm.expectRevert(abi.encodeWithSelector(Errors.RoundNotOpen.selector, roundId));
        vm.prank(alice);
        lottery.buyTickets(roundId, 1);
    }

    function test_FirstPurchaseCanAtomicallySellOut() public {
        vm.startPrank(authority);
        governance.createLotteryConfig(_config(address(tokenA), 10, 1, 1, 1 days, 30));
        governance.setLotteryConfigEnabled(3, true);
        vm.stopPrank();

        vm.prank(alice);
        uint256 roundId = lottery.openRound(3, 1);
        Round memory round = stateView.roundState(roundId);

        assertEq(uint8(round.status), uint8(RoundStatus.SoldOut));
        assertEq(round.soldTickets, 1);
        assertEq(round.receipts, 10);
        assertGt(round.drandRound, 0);
    }

    function test_RejectsPurchaseAtExpirationBoundary() public {
        vm.prank(alice);
        uint256 roundId = lottery.openRound(1, 2);
        Round memory round = stateView.roundState(roundId);
        vm.warp(round.expiresAt);

        vm.expectRevert(abi.encodeWithSelector(Errors.RoundExpired.selector, roundId));
        vm.prank(bob);
        lottery.buyTickets(roundId, 1);

        assertEq(uint8(stateView.roundState(roundId).status), uint8(RoundStatus.Open));
    }

    function test_RejectsCachedTargetAndRollsBackFinalPurchase() public {
        vm.prank(alice);
        uint256 roundId = lottery.openRound(1, 5);
        uint64 target = registry.firstRoundAfter(block.timestamp + 30);
        registry.setCached(target, true);
        uint256 bobBefore = tokenA.balanceOf(bob);

        vm.expectRevert(abi.encodeWithSelector(Errors.StaleRandomnessRound.selector, target));
        vm.prank(bob);
        lottery.buyTickets(roundId, 5);

        Round memory round = stateView.roundState(roundId);
        assertEq(uint8(round.status), uint8(RoundStatus.Open));
        assertEq(round.soldTickets, 5);
        assertEq(round.receipts, 50);
        assertEq(round.drandRound, registry.firstRoundAfter(uint256(round.expiresAt) + 30));
        assertEq(tokenA.balanceOf(bob), bobBefore);
        assertEq(stateView.assetAccounting(address(tokenA)).activeRoundEscrow, 50);
    }

    function test_RejectsRegistryThatDoesNotReturnStrictlyFutureRound() public {
        InvalidScheduleRegistry invalidRegistry = new InvalidScheduleRegistry();
        vm.prank(authority);
        governance.setIntegrationConfig(
            IntegrationConfig(address(invalidRegistry), address(router))
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRandomnessRound.selector, 1));
        vm.prank(alice);
        lottery.openRound(2, 3);
        assertEq(stateView.activeRoundCount(), 0);
    }

    function test_PauseBlocksParticipation() public {
        vm.prank(alice);
        uint256 roundId = lottery.openRound(1, 1);
        Round memory round = stateView.roundState(roundId);

        vm.prank(authority);
        governance.setPaused(true);
        vm.expectRevert(Errors.ProtocolPaused.selector);
        vm.prank(bob);
        lottery.buyTickets(roundId, 1);
        vm.expectRevert(Errors.ProtocolPaused.selector);
        vm.prank(bob);
        lottery.openRound(2, 1);

        vm.warp(round.expiresAt);
        assertEq(uint8(stateView.roundState(roundId).status), uint8(RoundStatus.Open));
    }

    function test_RejectsInvalidConfigQuantityLimitAndOpeningPolicy() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ConfigNotFound.selector, 3));
        vm.prank(alice);
        lottery.openRound(3, 1);

        vm.prank(authority);
        governance.setLotteryConfigEnabled(1, false);
        vm.expectRevert(abi.encodeWithSelector(Errors.ConfigDisabled.selector, 1));
        vm.prank(alice);
        lottery.openRound(1, 1);

        vm.prank(authority);
        governance.setLotteryConfigEnabled(1, true);
        vm.expectRevert(Errors.InvalidTicketQuantity.selector);
        vm.prank(alice);
        lottery.openRound(1, 0);
        vm.expectRevert(Errors.TicketLimitExceeded.selector);
        vm.prank(alice);
        lottery.openRound(1, 6);

        vm.prank(authority);
        governance.setMaxActiveRounds(0);
        vm.expectRevert(Errors.ActiveRoundLimitReached.selector);
        vm.prank(alice);
        lottery.openRound(1, 1);
    }

    function test_DirectTokenTransferCreatesNoTicketOrCredit() public {
        vm.prank(alice);
        tokenA.transfer(address(diamond), 25);

        assertEq(stateView.activeRoundCount(), 0);
        assertEq(stateView.refundCredit(1, alice), 0);
        assertEq(stateView.assetAccounting(address(tokenA)).activeRoundEscrow, 0);
    }

    function test_InsufficientAllowanceAndBalanceRollbackRoundOpening() public {
        vm.prank(alice);
        tokenA.approve(address(diamond), 19);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(diamond), 19, 20
            )
        );
        vm.prank(alice);
        lottery.openRound(1, 2);

        assertEq(stateView.activeRoundCount(), 0);
        assertEq(uint8(stateView.roundState(1).status), uint8(RoundStatus.None));
        assertEq(stateView.assetAccounting(address(tokenA)).activeRoundEscrow, 0);

        vm.prank(alice);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(alice);
        tokenA.transfer(bob, 995);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5, 10)
        );
        vm.prank(alice);
        lottery.openRound(1, 1);

        assertEq(stateView.activeRoundCount(), 0);
        assertEq(uint8(stateView.roundState(1).status), uint8(RoundStatus.None));
        assertEq(stateView.assetAccounting(address(tokenA)).activeRoundEscrow, 0);
    }

    function test_InexactInboundTokensRollbackTicketsAndAccounting() public {
        LifecycleReceiverFeeToken receiverFee = new LifecycleReceiverFeeToken();
        uint64 receiverFeeVersion = _addTokenConfig(address(receiverFee));
        receiverFee.mint(alice, 100);
        vm.prank(alice);
        receiverFee.approve(address(diamond), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InexactTokenTransfer.selector, address(receiverFee), 20, 20, 19
            )
        );
        vm.prank(alice);
        lottery.openRound(receiverFeeVersion, 2);
        assertEq(receiverFee.balanceOf(alice), 100);
        assertEq(receiverFee.balanceOf(address(diamond)), 0);
        assertEq(stateView.assetAccounting(address(receiverFee)).activeRoundEscrow, 0);

        LifecycleSenderFeeToken senderFee = new LifecycleSenderFeeToken();
        uint64 senderFeeVersion = _addTokenConfig(address(senderFee));
        senderFee.mint(alice, 100);
        vm.prank(alice);
        senderFee.approve(address(diamond), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InexactTokenTransfer.selector, address(senderFee), 20, 21, 20
            )
        );
        vm.prank(alice);
        lottery.openRound(senderFeeVersion, 2);
        assertEq(senderFee.balanceOf(alice), 100);
        assertEq(senderFee.balanceOf(address(diamond)), 0);
        assertEq(stateView.assetAccounting(address(senderFee)).activeRoundEscrow, 0);
        assertEq(stateView.activeRoundCount(), 0);
        assertEq(uint8(stateView.roundState(1).status), uint8(RoundStatus.None));
    }

    function test_RejectsPurchasesBeyondRemainingSupplyWithoutMutation() public {
        vm.prank(alice);
        uint256 roundId = lottery.openRound(1, 5);

        vm.expectRevert(Errors.InvalidTicketQuantity.selector);
        vm.prank(bob);
        lottery.buyTickets(roundId, 6);

        Round memory round = stateView.roundState(roundId);
        assertEq(round.soldTickets, 5);
        assertEq(round.receipts, 50);
        assertEq(stateView.purchaseEntryCount(roundId), 1);
        assertEq(stateView.refundCredit(roundId, bob), 0);
        assertEq(stateView.assetAccounting(address(tokenA)).activeRoundEscrow, 50);
    }

    function test_ReentrantPaymentTokenCannotCreateOrMutateRound() public {
        LifecycleReentrantToken token = new LifecycleReentrantToken();
        uint64 version = _addTokenConfig(address(token));
        token.mint(alice, 100);
        vm.prank(alice);
        token.approve(address(diamond), type(uint256).max);
        token.configureAttack(address(diamond), 1);

        vm.expectRevert(Errors.Reentrancy.selector);
        vm.prank(alice);
        lottery.openRound(version, 2);

        assertEq(stateView.activeRoundCount(), 0);
        assertEq(uint8(stateView.roundState(1).status), uint8(RoundStatus.None));
        assertEq(stateView.refundCredit(1, alice), 0);
        assertEq(stateView.assetAccounting(address(token)).activeRoundEscrow, 0);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(address(diamond)), 0);
    }

    function test_GovernanceChangesDoNotAlterOpenRoundSnapshotOrPurchasing() public {
        vm.prank(alice);
        uint256 roundId = lottery.openRound(1, 2);
        Round memory beforeChanges = stateView.roundState(roundId);

        LifecycleDrandRegistry nextRegistry = new LifecycleDrandRegistry();
        LifecycleEndpoint nextRouter = new LifecycleEndpoint();
        vm.startPrank(authority);
        governance.setIntegrationConfig(
            IntegrationConfig(address(nextRegistry), address(nextRouter))
        );
        governance.setLotteryConfigEnabled(1, false);
        governance.setMaxActiveRounds(5);
        governance.createLotteryConfig(_config(address(tokenB), 99, 50, 2, 7 days, 90));
        vm.stopPrank();

        vm.prank(bob);
        lottery.buyTickets(roundId, 1);
        Round memory afterChanges = stateView.roundState(roundId);

        assertEq(afterChanges.configVersion, beforeChanges.configVersion);
        assertEq(afterChanges.integrationVersion, beforeChanges.integrationVersion);
        assertEq(afterChanges.openedAt, beforeChanges.openedAt);
        assertEq(afterChanges.expiresAt, beforeChanges.expiresAt);
        assertEq(afterChanges.config.paymentToken, beforeChanges.config.paymentToken);
        assertEq(afterChanges.config.ticketPrice, beforeChanges.config.ticketPrice);
        assertEq(afterChanges.config.ticketCount, beforeChanges.config.ticketCount);
        assertEq(afterChanges.config.salesDuration, beforeChanges.config.salesDuration);
        assertEq(afterChanges.config.randomnessDelay, beforeChanges.config.randomnessDelay);
        assertEq(
            afterChanges.config.maxTicketsPerPurchase, beforeChanges.config.maxTicketsPerPurchase
        );
        assertEq(afterChanges.config.winnerBps, beforeChanges.config.winnerBps);
        assertEq(afterChanges.config.operatorProtocolBps, beforeChanges.config.operatorProtocolBps);
        assertEq(afterChanges.config.finalizerTip, beforeChanges.config.finalizerTip);
        assertEq(afterChanges.soldTickets, 3);

        vm.expectRevert(abi.encodeWithSelector(Errors.ConfigDisabled.selector, 1));
        vm.prank(alice);
        lottery.openRound(1, 1);

        vm.prank(authority);
        governance.setMaxActiveRounds(0);
        vm.prank(alice);
        lottery.buyTickets(roundId, 1);
        assertEq(stateView.roundState(roundId).soldTickets, 4);
    }

    function test_RequiresConfiguredIntegration() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        StaticsLotteryDiamond candidate = new StaticsLotteryDiamond(authority, address(cutFacet));
        GovernanceFacet governanceFacet = new GovernanceFacet();
        LotteryFacet lotteryFacet = new LotteryFacet();
        LifecycleInitializer initializer = new LifecycleInitializer();

        FacetCut[] memory cuts = new FacetCut[](2);
        cuts[0] = _cut(address(governanceFacet), _governanceSelectors());
        cuts[1] = _cut(address(lotteryFacet), _lotterySelectors());
        vm.prank(authority);
        IDiamondCut(address(candidate))
            .diamondCut(
                cuts, address(initializer), abi.encodeCall(LifecycleInitializer.initialize, ())
            );
        IGovernance candidateGovernance = IGovernance(address(candidate));
        vm.startPrank(authority);
        candidateGovernance.setMaxActiveRounds(1);
        candidateGovernance.createLotteryConfig(_config(address(tokenA), 10, 10, 5, 1 days, 30));
        candidateGovernance.setLotteryConfigEnabled(1, true);
        vm.stopPrank();

        vm.prank(alice);
        tokenA.approve(address(candidate), type(uint256).max);
        vm.expectRevert(Errors.IntegrationNotConfigured.selector);
        vm.prank(alice);
        ILottery(address(candidate)).openRound(1, 1);
    }

    function _fundAndApprove(LifecycleToken token, address account) private {
        token.mint(account, 1000);
        vm.prank(account);
        token.approve(address(diamond), type(uint256).max);
    }

    function _addTokenConfig(address paymentToken) private returns (uint64 version) {
        vm.startPrank(authority);
        version = governance.createLotteryConfig(_config(paymentToken, 10, 10, 5, 1 days, 30));
        governance.setLotteryConfigEnabled(version, true);
        vm.stopPrank();
    }

    function _config(
        address paymentToken,
        uint96 price,
        uint32 count,
        uint32 limit,
        uint32 duration,
        uint32 delay
    ) private pure returns (LotteryConfig memory) {
        return LotteryConfig({
            paymentToken: paymentToken,
            ticketPrice: price,
            ticketCount: count,
            salesDuration: duration,
            randomnessDelay: delay,
            maxTicketsPerPurchase: limit,
            winnerBps: 8000,
            operatorProtocolBps: 5000,
            recipientBps: 0,
            recipient: address(0),
            finalizerTip: 1
        });
    }

    function _cut(address facet, bytes4[] memory selectors) private pure returns (FacetCut memory) {
        return FacetCut(facet, FacetCutAction.Add, selectors);
    }

    function _governanceSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = IGovernance.createLotteryConfig.selector;
        selectors[1] = IGovernance.setLotteryConfigEnabled.selector;
        selectors[2] = IGovernance.setMaxActiveRounds.selector;
        selectors[3] = IGovernance.setIntegrationConfig.selector;
        selectors[4] = IGovernance.setPaused.selector;
        selectors[5] = IGovernance.setGuardian.selector;
    }

    function _lotterySelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = ILottery.openRound.selector;
        selectors[1] = ILottery.buyTickets.selector;
    }

    function _stateSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](7);
        selectors[0] = LifecycleStateFacet.roundState.selector;
        selectors[1] = LifecycleStateFacet.activeRoundCount.selector;
        selectors[2] = LifecycleStateFacet.refundCredit.selector;
        selectors[3] = LifecycleStateFacet.purchaseEntryCount.selector;
        selectors[4] = LifecycleStateFacet.purchaseEntry.selector;
        selectors[5] = LifecycleStateFacet.ticketOwner.selector;
        selectors[6] = LifecycleStateFacet.assetAccounting.selector;
    }
}
