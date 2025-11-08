// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    RevertInstructions,
    UniversalPayload,
    TX_TYPE,
    UniversalTxRequest,
    UniversalTxRequestToken
} from "../libraries/Types.sol";

interface IUniversalGatewayV0 {
    // =========================
    //           EVENTS
    // =========================

    /// @notice         Universal tx deposit (gas funding). Emits for both gas refill and funds+payload movement.
    event UniversalTx(
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        bytes payload,
        RevertInstructions revertInstruction,
        TX_TYPE txType,
        bytes signatureData
    );

    /// @notice         Caps updated event
    event CapsUpdated(uint256 minCapUsd, uint256 maxCapUsd);

    /// @notice         Rate-limit / config events
    event EpochDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event TokenLimitThresholdUpdated(address indexed token, uint256 newThreshold);

    /// @notice         Revert universal transaction event
    event RevertUniversalTx(
        bytes32 indexed txID,
        address indexed to,
        address indexed token,
        uint256 amount,
        RevertInstructions revertInstruction
    );

    /// @notice         Withdraw token event (native token is represented with token = address(0))
    event WithdrawToken(
        bytes32 indexed txID,
        address indexed originCaller,
        address indexed token,
        address to,
        uint256 amount
    );

    // =========================
    //           PUBLIC HELPERS
    // =========================

    function isSupportedToken(address token) external view returns (bool);

    // =========================
    //       sendUniversalTx - Unified Route
    // =========================

    function sendUniversalTx(UniversalTxRequest calldata req) external payable;

    function sendUniversalTx(UniversalTxRequestToken calldata reqToken) external payable;

    // =========================
    //     sendTxWithGas - Fee Abstraction Route
    // =========================

    function sendTxWithGas(
        UniversalPayload calldata payload,
        RevertInstructions calldata revertCFG,
        bytes memory signatureData
    ) external payable;

    function sendTxWithGas(
        address tokenIn,
        uint256 amountIn,
        UniversalPayload calldata payload,
        RevertInstructions calldata revertCFG,
        uint256 amountOutMinETH,
        uint256 deadline,
        bytes memory signatureData
    ) external;

    // =========================
    //       sendTxWithFunds - Universal Transaction Route
    // =========================

    function sendFunds(
        address recipient,
        address bridgeToken,
        uint256 bridgeAmount,
        RevertInstructions calldata revertCFG
    ) external payable;

    function sendTxWithFunds(
        address bridgeToken,
        uint256 bridgeAmount,
        UniversalPayload calldata payload,
        RevertInstructions calldata revertCFG,
        bytes memory signatureData
    ) external payable;

    function sendTxWithFunds(
        address bridgeToken,
        uint256 bridgeAmount,
        address gasToken,
        uint256 gasAmount,
        uint256 amountOutMinETH,
        uint256 deadline,
        UniversalPayload calldata payload,
        RevertInstructions calldata revertCFG,
        bytes memory signatureData
    ) external;

    function sendTxWithFunds_new(
        address bridgeToken,
        uint256 bridgeAmount,
        UniversalPayload calldata payload,
        RevertInstructions calldata revertCFG,
        bytes memory signatureData
    ) external payable;

    function sendTxWithFunds_new(
        address bridgeToken,
        uint256 bridgeAmount,
        address gasToken,
        uint256 gasAmount,
        uint256 amountOutMinETH,
        uint256 deadline,
        UniversalPayload calldata payload,
        RevertInstructions calldata revertCFG,
        bytes memory signatureData
    ) external;

    // =========================
    //      REVERT & WITHDRAW
    // =========================

    function revertUniversalTx(bytes32 txID, uint256 amount, RevertInstructions calldata revertCFG)
        external
        payable;

    function revertUniversalTxToken(bytes32 txID, address token, uint256 amount, RevertInstructions calldata revertCFG)
        external;

    function withdraw(bytes32 txID, address originCaller, address to, uint256 amount) external payable;

    function withdrawTokens(bytes32 txID, address originCaller, address token, address to, uint256 amount) external;
}