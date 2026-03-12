// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Transaction types in Universal Gateway.
enum TX_TYPE {
    /// @dev    Only for funding the UEA on Push Chain with gas.
    ///         Does not support movement of high-value funds or payload execution.
    GAS,
    /// @dev    For funding UEA and executing a payload instantly via UEA on Push Chain.
    ///         Allows movement of funds between cap ranges (low fund size)
    ///         and requires lower block confirmations.
    GAS_AND_PAYLOAD,
    /// @dev    For bridging large funds only from external chain to Push Chain.
    ///         Does not support arbitrary payload and requires longer block confirmations.
    FUNDS,
    /// @dev    For bridging both funds and payload to Push Chain for execution.
    ///         No strict cap ranges for fund amount and requires longer block confirmations.
    FUNDS_AND_PAYLOAD
}

/// @notice Revert/refund instructions for failed transactions.
struct RevertInstructions {
    address revertRecipient;         // where funds go in revert/refund cases
    bytes   revertMsg;               // arbitrary message for relayers/UEA
}

/// @notice Multicall structure for CEA execution.
struct Multicall {
    address to;                      // target contract address
    uint256 value;                   // native token amount to send with call
    bytes   data;                    // call data to execute
}

/// @notice Packed per-token usage for the current epoch only (no on-chain history kept).
struct EpochUsage {
    uint64  epoch;                   // epoch index = block.timestamp / epochDurationSec
    uint192 used;                    // amount consumed in this epoch (token's natural units)
}

/// @notice Signature verification types.
/// @dev    NOT used by any src/ contract — only consumed by tests and UEA contracts.
enum VerificationType {
    signedVerification,
    universalTxVerification
}

/// @notice Universal payload for execution on Push Chain.
/// @dev    NOT used by any src/ contract — only consumed by tests and UEA contracts.
struct UniversalPayload {
    address          to;             // target contract address to call
    uint256          value;          // native token amount to send
    bytes            data;           // call data for the function execution
    uint256          gasLimit;       // maximum gas to be used for this tx
    uint256          maxFeePerGas;   // maximum fee per gas unit
    uint256 maxPriorityFeePerGas;    // maximum priority fee per gas unit
    uint256          nonce;          // nonce for the transaction
    uint256          deadline;       // timestamp after which this payload is invalid
    VerificationType vType;          // signedVerification or universalTxVerification
}

/// @notice Universal transaction request for native token as gas.
struct UniversalTxRequest {
    address recipient;               // address(0) => credit to UEA on Push
    address token;                   // address(0) => native path (gas-only)
    uint256 amount;                  // native amount or ERC20 amount
    bytes   payload;                 // call data / memo = UNIVERSAL PAYLOAD
    address revertRecipient;         // address to receive funds in case of revert
    bytes   signatureData;           // signature data for further verification
}

/// @notice Universal transaction request for ERC20 token as gas.
struct UniversalTokenTxRequest {
    address recipient;               // address(0) => credit to UEA on Push
    address token;                   // address(0) => native path (gas-only)
    uint256 amount;                  // native amount or ERC20 amount
    address gasToken;                // token used for paying gas
    uint256 gasAmount;               // amount of the token to be used as gas
    bytes   payload;                 // call data / memo = UNIVERSAL PAYLOAD
    address revertRecipient;         // address to receive funds in case of revert
    bytes   signatureData;           // signature data for further verification
    uint256 amountOutMinETH;         // minimum amount of ETH to receive
    uint256 deadline;                // timestamp after which this request is invalid
}

/// @notice Universal outbound transaction request for Push Chain.
struct UniversalOutboundTxRequest {
    bytes   recipient;               // raw destination address on source chain (bytes for SVM compat)
                                     // bytes("") => park funds in caller's CEA
    address token;                   // PRC20 token address on Push Chain
    uint256 amount;                  // amount to withdraw (burn on Push, unlock at origin)
    uint256 gasLimit;                // gas limit for fee quote; 0 = default BASE_GAS_LIMIT
    bytes   payload;                 // ABI-encoded calldata to execute on origin chain (empty for funds-only)
    address revertRecipient;         // address to receive funds in case of revert
}
