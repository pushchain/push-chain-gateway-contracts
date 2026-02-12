// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { RevertInstructions } from "../libraries/Types.sol";
/**
 * @title IVault
 * @notice Interface for ERC20 custody vault for outbound flows (withdraw / withdraw+call) managed by TSS.
 */
interface IVault {
    // =========================
    //           EVENTS
    // =========================

    /// @notice             Gateway updated event
    /// @param oldGateway   Previous Gateway address
    /// @param newGateway   New Gateway address
    event GatewayUpdated(address indexed oldGateway, address indexed newGateway);

    /// @notice             TSS updated event
    /// @param oldTss       Previous TSS address
    /// @param newTss       New TSS address
    event TSSUpdated(address indexed oldTss, address indexed newTss);

    /// @notice             Universal tx executed event
    /// @param txID         Unique transaction identifier
    /// @param universalTxID universal transaction identifier
    /// @param originCaller original caller/user on source chain ( Push Chain)
    /// @param target       Target contract address to execute call
    /// @param token        Token address being sent
    /// @param amount       Amount of token being sent
    /// @param data         Calldata to be executed on target contract on external chain
    event VaultUniversalTxExecuted(bytes32 indexed txID, bytes32 indexed universalTxID, address indexed originCaller, address target, address token, uint256 amount, bytes data);
   
    /// @notice             Universal tx reverted event
    /// @param txID         Unique transaction identifier
    /// @param universalTxID universal transaction identifier
    /// @param token        Token address being reverted
    /// @param amount       Amount of token being reverted
    /// @param revertInstruction revert instruction containing revertRecipient and revertMsg
    event VaultUniversalTxReverted(bytes32 indexed txID, bytes32 indexed universalTxID, address indexed token, uint256 amount, RevertInstructions revertInstruction);

    // =========================
    //   WITHDRAW & EXECUTION
    // =========================
    /**
     * @notice              Unified entry point for both withdrawals and executions (TSS-only)
     * @dev                 Routes based on payload:
     *                      - Empty payload (data.length == 0): Withdrawal path via CEA.withdrawTo()
     *                      - Non-empty payload: Execution path via CEA.executeUniversalTx()
     *                      Both paths use CEA (Chain Execution Account) as intermediary.
     * @param txID          Unique transaction identifier
     * @param universalTxID Universal transaction identifier from Push Chain
     * @param originCaller  UEA address on Push Chain
     * @param token         Token address (address(0) for native)
     * @param target        Target address (recipient for withdrawal, contract for execution)
     * @param amount        Amount of token/native
     * @param data          Calldata (empty for withdrawal, non-empty for execution)
     */
    function executeUniversalTx(bytes32 txID, bytes32 universalTxID, address originCaller, address token, address target, uint256 amount, bytes calldata data) external payable;

    /**
     * @notice              TSS-only refund path (e.g., failed outbound flow) to a designated recipient on external chains
     * @dev                 Moves token to gateway contract and then transfers to recipient or executes the payload.
     * @param txID              unique transaction identifier (for replay protection)
     * @param universalTxID     universal transaction identifier
     * @param token             ERC20 token to refund (must be supported) on external chain
     * @param amount            amount to refund on external chain
     * @param revertInstruction revert instruction containing revertRecipient and revertMsg
     */
    function revertUniversalTxToken(bytes32 txID, bytes32 universalTxID, address token, uint256 amount, RevertInstructions calldata revertInstruction) external;
}

