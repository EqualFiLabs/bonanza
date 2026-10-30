// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { SafeCast } from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

import { IEqualFiDrandRegistry } from "../interfaces/IEqualFiDrandRegistry.sol";
import { ISettlement } from "../interfaces/ISettlement.sol";
import { LibFiddyStorage } from "../libraries/LibFiddyStorage.sol";
import { LibLotteryStorage } from "../libraries/LibLotteryStorage.sol";
import { LibReentrancy } from "../libraries/LibReentrancy.sol";
import { LibTicketRanges } from "../libraries/LibTicketRanges.sol";
import { Errors } from "../shared/Errors.sol";
import { AssetAccounting, IntegrationConfig, Round, RoundStatus } from "../shared/Types.sol";

contract SettlementFacet is ISettlement {
    using SafeCast for uint256;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    struct SettlementAmounts {
        uint256 winner;
        uint256 operator;
        uint256 treasury;
        uint256 finalizer;
        uint256 staker;
    }

    modifier nonReentrant() {
        LibReentrancy.enter();
        _;
        LibReentrancy.exit();
    }

    function settleRound(uint256 roundId, bytes calldata quicknetSignature)
        external
        nonReentrant
        returns (uint32 winningTicket, address winner)
    {
        LibLotteryStorage.GameStorage storage gs = LibLotteryStorage.gameStorage();
        Round storage round = gs.rounds[roundId];
        if (round.status == RoundStatus.None) revert Errors.RoundNotFound(roundId);
        bool soldOut = round.status == RoundStatus.SoldOut;
        bool deadlineReached =
            round.status == RoundStatus.Open && block.timestamp >= round.expiresAt;
        if ((!soldOut && !deadlineReached) || round.drandRound == 0 || round.soldTickets == 0) {
            revert Errors.RoundNotReady(roundId);
        }

        bytes32 applicationSeed = _acquireApplicationSeed(round, roundId, quicknetSignature);
        winningTicket = (uint256(applicationSeed) % round.soldTickets).toUint32();
        winner = LibTicketRanges.ownerOfTicket(gs.entries[roundId], winningTicket);
        SettlementAmounts memory amounts = _allocate(round, roundId);

        _recordSettlement(gs, round, winningTicket, winner, applicationSeed, amounts);

        emit RoundSettled(
            roundId,
            winningTicket,
            winner,
            round.config.paymentToken,
            msg.sender,
            applicationSeed,
            amounts.winner,
            amounts.operator,
            amounts.treasury,
            amounts.finalizer
        );
        if (amounts.staker != 0) {
            emit StakerRevenueSettled(roundId, round.config.paymentToken, amounts.staker);
        }
    }

    function _acquireApplicationSeed(
        Round storage round,
        uint256 roundId,
        bytes calldata quicknetSignature
    ) private returns (bytes32) {
        IntegrationConfig storage integration = LibLotteryStorage.integrationStorage()
        .integrations[round.integrationVersion];
        IEqualFiDrandRegistry registry = IEqualFiDrandRegistry(integration.drandRegistry);
        uint64 drandRound = round.drandRound;
        if (!registry.hasSig(drandRound)) {
            registry.postSig(drandRound, quicknetSignature);
            if (!registry.hasSig(drandRound)) {
                revert Errors.RandomnessUnavailable(drandRound);
            }
        }

        uint64 postedAt = registry.postedAt(drandRound);
        uint64 salesCloseAt =
            round.status == RoundStatus.SoldOut ? round.selloutAt : round.expiresAt;
        if (postedAt <= salesCloseAt) {
            revert Errors.RandomnessPredatesClose(drandRound, postedAt, salesCloseAt);
        }

        return keccak256(
            abi.encode(registry.randomnessOf(drandRound), block.chainid, address(this), roundId)
        );
    }

    function _allocate(Round storage round, uint256 roundId)
        private
        view
        returns (SettlementAmounts memory amounts)
    {
        return _allocateValues(
            round.receipts.toUint128(),
            round.config.winnerBps,
            round.config.operatorProtocolBps,
            LibFiddyStorage.state().stakerAccrued[roundId],
            round.config.finalizerTip
        );
    }

    function _allocateValues(
        uint128 gross,
        uint16 winnerBps,
        uint16 operatorProtocolBps,
        uint256 stakerAccrued,
        uint96 finalizerTip
    ) internal pure returns (SettlementAmounts memory amounts) {
        uint256 protocolAmount;
        // Reachable receipts are bounded by uint96 ticket price * uint32 ticket count, and config
        // validation caps winner and Operator BPS at the denominator, so these steps cannot wrap.
        // The live caller checks the gross cast.
        unchecked {
            amounts.winner = uint256(gross) * winnerBps / BPS_DENOMINATOR;
            protocolAmount = uint256(gross) - amounts.winner;
            amounts.operator = protocolAmount * operatorProtocolBps / BPS_DENOMINATOR;
        }
        // Purchase-time staker floors sum to at most protocolAmount - operator whenever Operator
        // and staker BPS sum to at most the denominator. Checked arithmetic fails closed.
        amounts.staker = stakerAccrued;
        uint256 treasuryGross = protocolAmount - amounts.operator - stakerAccrued;
        amounts.finalizer = finalizerTip < treasuryGross ? finalizerTip : treasuryGross;
        amounts.treasury = treasuryGross - amounts.finalizer;
    }

    function _recordSettlement(
        LibLotteryStorage.GameStorage storage gs,
        Round storage round,
        uint32 winningTicket,
        address winner,
        bytes32 applicationSeed,
        SettlementAmounts memory amounts
    ) internal {
        round.status = RoundStatus.Settled;
        round.settledAt = block.timestamp.toUint64();
        round.winningTicket = winningTicket;
        round.winner = winner;
        round.applicationSeed = applicationSeed;
        round.winnerClaimable = amounts.winner;
        gs.activeRoundForConfig[round.configVersion] = 0;
        --gs.activeRoundCount;

        address paymentToken = round.config.paymentToken;
        LibLotteryStorage.AccountingStorage storage accountingStorage =
            LibLotteryStorage.accountingStorage();
        AssetAccounting storage accounting = accountingStorage.assetAccounting[paymentToken];
        accounting.activeRoundEscrow -= round.receipts - amounts.staker;
        accounting.winnerLiability += amounts.winner;
        accountingStorage.pendingOperatorRevenue[
            round.integrationVersion
        ][paymentToken] += amounts.operator;
        accounting.pendingOperatorRevenueTotal += amounts.operator;
        accounting.treasuryAvailable += amounts.treasury;
        accountingStorage.finalizerCredits[paymentToken][msg.sender] += amounts.finalizer;
        accounting.finalizerLiability += amounts.finalizer;
    }
}
