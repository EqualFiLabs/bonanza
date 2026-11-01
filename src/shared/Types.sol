// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

struct LotteryConfig {
    address paymentToken;
    uint96 ticketPrice;
    uint32 ticketCount;
    uint32 salesDuration;
    uint32 randomnessDelay;
    uint32 maxTicketsPerPurchase;
    uint16 winnerBps;
    uint16 operatorProtocolBps;
    uint16 recipientBps; // Share of gross receipts; zero disables the allocation.
    address recipient;
    uint96 finalizerTip;
}

struct IntegrationConfig {
    address drandRegistry;
    address operatorFeeRouter;
}

enum RoundStatus {
    None,
    Open,
    SoldOut,
    Settled,
    Expired // Reserved legacy ordinal; new rounds never expire into refunds.
}

struct RoundConfigSnapshot {
    address paymentToken;
    uint96 ticketPrice;
    uint32 ticketCount;
    uint32 salesDuration;
    uint32 randomnessDelay;
    uint32 maxTicketsPerPurchase;
    uint16 winnerBps;
    uint16 operatorProtocolBps;
    uint16 recipientBps; // Share of gross receipts; zero disables the allocation.
    address recipient;
    uint96 finalizerTip;
}

struct Round {
    RoundConfigSnapshot config;
    uint64 configVersion;
    uint64 integrationVersion;
    uint64 openedAt;
    uint64 expiresAt;
    uint64 selloutAt;
    uint64 settledAt;
    uint64 drandRound;
    uint32 soldTickets;
    uint32 winningTicket;
    RoundStatus status;
    address winner;
    uint256 receipts;
    uint256 winnerClaimable;
    uint256 recipientClaimable;
    bytes32 applicationSeed;
}

struct TicketRange {
    address buyer;
    uint32 endExclusive;
}

struct AssetAccounting {
    uint256 activeRoundEscrow;
    uint256 winnerLiability;
    uint256 recipientLiability;
    uint256 refundLiability; // Unused and always zero; not a preserved slot in this layout.
    uint256 finalizerLiability;
    uint256 pendingOperatorRevenueTotal;
    uint256 treasuryAvailable;
}
