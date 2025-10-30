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

    /// @notice             Vault withdraw and execute event
    /// @param token        Token address
    /// @param target       Target contract address
    /// @param amount       Amount of token
    /// @param data         Calldata for the target execution
    event VaultWithdrawAndExecute(address indexed token, address indexed target, uint256 amount, bytes data);

    /// @notice             Vault withdraw event
    /// @param txID         Unique transaction identifier
    /// @param originCaller Original caller/user on source chain
    /// @param token        Token address
    /// @param to           Recipient address
    /// @param amount       Amount of token
    event VaultWithdraw(bytes32 indexed txID, address indexed originCaller, address indexed token, address to, uint256 amount);

    /// @notice             Vault revert event
    /// @param token        Token address
    /// @param to           Recipient address
    /// @param amount       Amount of token
    /// @param revertInstruction Revert instructions configuration
    event VaultRevert(address indexed token, address indexed to, uint256 amount, RevertInstructions revertInstruction);

    // =========================
    //          WITHDRAW
    // =========================
    /**
     * @notice              TSS-only withdraw to an external recipient on external chains
     * @dev                 Moves token to gateway contract and then transfers to recipient or executes the payload.
     * @param txID          unique transaction identifier on external chain
     * @param originCaller  original caller/user on source chain ( Push Chain)
     * @param token         ERC20 token to transfer (must be supported by gateway) on external chain
     * @param to            recipient address on external chain
     * @param amount        amount of token to transfer on external chain
     */
    function withdraw(bytes32 txID, address originCaller, address token, address to, uint256 amount) external;

    /**
     * @notice              TSS-only withdraw and execute transaction via gateway on external chains
     * @dev                 Moves token to gateway contract and then transfers to recipient or executes the payload.
     * @param txID          unique transaction identifier on external chain     
     * @param originCaller  original caller/user on source chain ( Push Chain)
     * @param token         ERC20 token to transfer (must be supported by gateway) on external chain
     * @param target        contract to call via gateway on external chain
     * @param amount        token amount to transfer and use in execution on external chain
     * @param data          calldata for the target execution on external chain
     */
    function withdrawAndExecute(bytes32 txID, address originCaller, address token, address target, uint256 amount, bytes calldata data) external;

    /**
     * @notice              TSS-only refund path (e.g., failed outbound flow) to a designated recipient on external chains
     * @dev                 Moves token to gateway contract and then transfers to recipient or executes the payload.
     * @param token         ERC20 token to refund (must be supported) on external chain
     * @param to            recipient of the refund on external chain
     * @param amount        amount to refund on external chain
     */
    function revertWithdraw(address token, address to, uint256 amount, RevertInstructions calldata revertInstruction) external;
}

