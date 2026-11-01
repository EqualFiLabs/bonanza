// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface ISettlement {
    event RoundSettled(
        uint256 indexed roundId,
        uint32 indexed winningTicket,
        address indexed winner,
        address paymentToken,
        address finalizer,
        bytes32 applicationSeed,
        uint256 winnerAmount,
        uint256 operatorAmount,
        uint256 recipientAmount,
        uint256 treasuryAmount,
        uint256 finalizerTip
    );
    /// @notice Staker revenue booked by the round's purchases and excluded from Treasury.
    event StakerRevenueSettled(
        uint256 indexed roundId, address indexed paymentToken, uint256 amount
    );

    function settleRound(uint256 roundId, bytes calldata quicknetSignature)
        external
        returns (uint32 winningTicket, address winner);
}
