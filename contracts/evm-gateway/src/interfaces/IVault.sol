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

    // =========================
    //          WITHDRAW
    // =========================
    /**
     * @notice              TSS-only withdraw to an external recipient on external chains
     * @dev                 Moves token to gateway contract and then transfers to recipient or executes the payload.
     * @param txID          unique transaction identifier on external chain
     * @param universalTxID universal transaction identifier
     * @param originCaller  original caller/user on source chain ( Push Chain)
     * @param token         ERC20 token to transfer (must be supported by gateway) on external chain
     * @param to            recipient address on external chain
     * @param amount        amount of token to transfer on external chain
     */
    function withdrawTokens(bytes32 txID, bytes32 universalTxID, address originCaller, address token, address to, uint256 amount) external;

    /**
     * @notice              Handles outbound execution via CEA (the only execution path on source chains)
     * @dev                 Routes all outbound executions through user's CEA contract
     * @param txID          Unique transaction identifier
     * @param universalTxID universal transaction identifier
     * @param originCaller    UEA address on Push Chain
     * @param token         Token address (address(0) for native)
     * @param target        Target contract to execute on
     * @param amount        Amount of token/native to execute with
     * @param data          Calldata to execute on target
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

