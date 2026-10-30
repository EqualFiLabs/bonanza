// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { SafeCast } from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

import { IEqualFiDrandRegistry } from "../interfaces/IEqualFiDrandRegistry.sol";
import { ILottery } from "../interfaces/ILottery.sol";
import { LibFiddy } from "../libraries/LibFiddy.sol";
import { LibFiddyStaking } from "../libraries/LibFiddyStaking.sol";
import { LibFiddyStorage } from "../libraries/LibFiddyStorage.sol";
import { LibExactToken } from "../libraries/LibExactToken.sol";
import { LibLotteryConfig } from "../libraries/LibLotteryConfig.sol";
import { LibLotteryStorage } from "../libraries/LibLotteryStorage.sol";
import { LibOperatorFeeRouter } from "../libraries/LibOperatorFeeRouter.sol";
import { LibReentrancy } from "../libraries/LibReentrancy.sol";
import { LibTicketRanges } from "../libraries/LibTicketRanges.sol";
import { Errors } from "../shared/Errors.sol";
import {
    IntegrationConfig,
    LotteryConfig,
    Round,
    RoundStatus,
    TicketRange
} from "../shared/Types.sol";

contract LotteryFacet is ILottery {
    using SafeCast for uint256;

    modifier nonReentrant() {
        LibReentrancy.enter();
        _;
        LibReentrancy.exit();
    }

    function openRound(uint64 configVersion, uint32 ticketQuantity)
        external
        nonReentrant
        returns (uint256 roundId)
    {
        return _openRound(configVersion, ticketQuantity, 0);
    }

    function openRoundForPosition(uint64 configVersion, uint32 ticketQuantity, uint256 positionId)
        external
        nonReentrant
        returns (uint256 roundId)
    {
        return _openRound(configVersion, ticketQuantity, positionId);
    }

    function _openRound(uint64 configVersion, uint32 ticketQuantity, uint256 positionId)
        private
        returns (uint256 roundId)
    {
        _enforceParticipationActive();
        LibLotteryStorage.GameStorage storage gs = LibLotteryStorage.gameStorage();
        if (gs.maxActiveRounds == 0 || gs.activeRoundCount >= gs.maxActiveRounds) {
            revert Errors.ActiveRoundLimitReached();
        }
        if (configVersion == 0 || configVersion > gs.nextConfigVersion) {
            revert Errors.ConfigNotFound(configVersion);
        }
        if (!gs.configEnabled[configVersion]) revert Errors.ConfigDisabled(configVersion);
        uint256 existingRoundId = gs.activeRoundForConfig[configVersion];
        if (existingRoundId != 0) {
            revert Errors.ConfigAlreadyActive(configVersion, existingRoundId);
        }

        LibLotteryStorage.IntegrationStorage storage integrations =
            LibLotteryStorage.integrationStorage();
        uint64 integrationVersion = integrations.currentVersion;
        if (integrationVersion == 0) revert Errors.IntegrationNotConfigured();

        LotteryConfig storage config = gs.configs[configVersion];
        if (config.operatorProtocolBps != 0) {
            LibOperatorFeeRouter.enforceReady(
                integrations.integrations[integrationVersion].operatorFeeRouter, config.paymentToken
            );
        }
        _validateQuantity(ticketQuantity, config.ticketCount, config.maxTicketsPerPurchase);

        uint256 expiration = block.timestamp + config.salesDuration;

        roundId = ++gs.nextRoundId;
        Round storage round = gs.rounds[roundId];
        round.config = LibLotteryConfig.snapshot(config);
        round.configVersion = configVersion;
        LibFiddyStorage.state().rounds[roundId] = LibFiddyStorage.state().configs[configVersion];
        round.integrationVersion = integrationVersion;
        round.openedAt = block.timestamp.toUint64();
        round.expiresAt = expiration.toUint64();
        round.status = RoundStatus.Open;
        gs.activeRoundForConfig[configVersion] = roundId;
        ++gs.activeRoundCount;

        emit RoundOpened(
            roundId,
            configVersion,
            integrationVersion,
            config.paymentToken,
            round.openedAt,
            round.expiresAt
        );

        _scheduleDraw(
            round,
            roundId,
            IEqualFiDrandRegistry(integrations.integrations[integrationVersion].drandRegistry),
            round.expiresAt,
            round.config.randomnessDelay
        );
        _recordPurchase(gs, round, roundId, ticketQuantity, positionId);
    }

    function buyTickets(uint256 roundId, uint32 ticketQuantity) external nonReentrant {
        _buyTickets(roundId, ticketQuantity, 0);
    }

    function buyTicketsForPosition(uint256 roundId, uint32 ticketQuantity, uint256 positionId)
        external
        nonReentrant
    {
        _buyTickets(roundId, ticketQuantity, positionId);
    }

    function _buyTickets(uint256 roundId, uint32 ticketQuantity, uint256 positionId) private {
        _enforceParticipationActive();
        LibLotteryStorage.GameStorage storage gs = LibLotteryStorage.gameStorage();
        Round storage round = gs.rounds[roundId];
        if (round.status == RoundStatus.None) revert Errors.RoundNotFound(roundId);
        if (round.status != RoundStatus.Open) revert Errors.RoundNotOpen(roundId);
        if (block.timestamp >= round.expiresAt) revert Errors.RoundExpired(roundId);

        uint32 remaining = round.config.ticketCount - round.soldTickets;
        _validateQuantity(ticketQuantity, remaining, round.config.maxTicketsPerPurchase);
        _recordPurchase(gs, round, roundId, ticketQuantity, positionId);
    }

    function _recordPurchase(
        LibLotteryStorage.GameStorage storage gs,
        Round storage round,
        uint256 roundId,
        uint32 ticketQuantity,
        uint256 positionId
    ) private {
        uint32 startTicket = round.soldTickets;
        uint32 endExclusive = startTicket + ticketQuantity;
        uint256 amount = uint256(round.config.ticketPrice) * ticketQuantity;
        address paymentToken = round.config.paymentToken;

        round.soldTickets = endExclusive;
        round.receipts += amount;
        TicketRange[] storage entries = gs.entries[roundId];
        LibTicketRanges.append(entries, msg.sender, endExclusive);
        // Sales are final, so the staker share is booked now and leaves round escrow.
        uint256 stakerShare =
            LibFiddyStaking.book(roundId, paymentToken, amount, round.config.winnerBps);
        LibLotteryStorage.accountingStorage()
                .assetAccounting[paymentToken]
                .activeRoundEscrow += amount - stakerShare;

        LibFiddy.issue(roundId, positionId, ticketQuantity);
        LibExactToken.pullExact(paymentToken, msg.sender, amount);
        emit TicketsPurchased(
            roundId, msg.sender, paymentToken, startTicket, ticketQuantity, endExclusive, amount
        );

        if (endExclusive == round.config.ticketCount) _commitSellout(round, roundId);
    }

    function _commitSellout(Round storage round, uint256 roundId) private {
        IntegrationConfig storage integration =
            LibLotteryStorage.integrationStorage().integrations[round.integrationVersion];
        _commitSelloutTarget(
            round,
            roundId,
            IEqualFiDrandRegistry(integration.drandRegistry),
            round.config.randomnessDelay
        );
    }

    function _commitSelloutTarget(
        Round storage round,
        uint256 roundId,
        IEqualFiDrandRegistry registry,
        uint32 randomnessDelay
    ) internal returns (uint256 commitmentBoundary, uint64 target) {
        round.status = RoundStatus.SoldOut;
        round.selloutAt = block.timestamp.toUint64();

        (commitmentBoundary, target) =
            _scheduleDraw(round, roundId, registry, round.selloutAt, randomnessDelay);
        emit RoundSoldOut(roundId, round.selloutAt, target);
    }

    /// @dev The opening deadline target can only be superseded by an atomic early sellout.
    function _scheduleDraw(
        Round storage round,
        uint256 roundId,
        IEqualFiDrandRegistry registry,
        uint64 salesCloseAt,
        uint32 randomnessDelay
    ) internal returns (uint256 commitmentBoundary, uint64 target) {
        commitmentBoundary = uint256(salesCloseAt) + randomnessDelay;
        target = registry.firstRoundAfter(commitmentBoundary);
        if (target == 0 || registry.roundTime(target) <= commitmentBoundary) {
            revert Errors.InvalidRandomnessRound(target);
        }
        if (registry.hasSig(target)) revert Errors.StaleRandomnessRound(target);
        round.drandRound = target;
        emit RoundDrawScheduled(roundId, salesCloseAt, target);
    }

    function _validateQuantity(uint32 quantity, uint32 available, uint32 purchaseLimit)
        private
        pure
    {
        if (quantity == 0 || quantity > available) revert Errors.InvalidTicketQuantity();
        if (purchaseLimit != 0 && quantity > purchaseLimit) {
            revert Errors.TicketLimitExceeded();
        }
    }

    function _enforceParticipationActive() private view {
        if (LibLotteryStorage.governanceStorage().paused) revert Errors.ProtocolPaused();
    }
}
