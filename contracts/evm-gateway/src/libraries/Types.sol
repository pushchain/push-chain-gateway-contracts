// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Transaction Types in Universal Gateway
enum TX_TYPE {
    /// @dev        only for funding the UEA on Push Chain with GAS
    ///             doesn't support movement of high value funds or payload for execution.
    GAS,
    /// @dev        for funding UEA and execute a payload instantly via UEA on Push Chain. versal transaction route.
    ///             allows movement of funds between CAP_RANGES ( low fund size ) & requires lower block confirmations.
    GAS_AND_PAYLOAD,
    /// @dev        for bridging of large funds only from external chain to Push Chain.
    ///             doesn't support arbitrary payload movement and requires longer block confirmations.
    FUNDS,
    /// @dev        for bridging both funds and payload to Push Chain for execution.
    ///             no strict cap ranges for fund amount and requires longer block confirmations.
    FUNDS_AND_PAYLOAD
}

struct RevertInstructions {
    ///             where funds go in revert / refund cases
    address fundRecipient;
    ///             arbitrary message for relayers/UEA
    bytes revertMsg;
}

/// @notice         Packed per-token usage for the current epoch only (no on-chain history kept).
struct EpochUsage {
    uint64 epoch;   // epoch index = block.timestamp / epochDurationSec
    uint192 used;   // amount consumed in this epoch (token's natural units)
}

/// @notice         Signature verification types
enum VerificationType {
    signedVerification,
    universalTxVerification
}

/// @notice         Universal payload for execution on Push Chain
struct UniversalPayload {
    address to;                     // Target contract address to call
    uint256 value;                  // Native token amount to send
    bytes data;                     // Call data for the function execution
    uint256 gasLimit;               // Maximum gas to be used for this tx (caps refund amount)
    uint256 maxFeePerGas;           // Maximum fee per gas unit
    uint256 maxPriorityFeePerGas;   // Maximum priority fee per gas unit
    uint256 nonce;                  // Nonce for the transaction
    uint256 deadline;               // Timestamp after which this payload is invalid
    VerificationType vType;         // Type of verification (signedVerification or universalTxVerification)
}
