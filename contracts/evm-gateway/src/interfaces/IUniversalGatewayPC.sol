// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RevertInstructions} from "../libraries/Types.sol";

/**
 * @title   IUniversalGatewayPC
 * @notice  Interface for UniversalGatewayPC contract
 * @dev     Defines all public functions and events for the Push Chain outbound gateway
 */
interface IUniversalGatewayPC {
    // ========= Events =========
    /// @notice Single event covering both flows (funds-only and funds+payload).
    /// @param sender      EVM sender on Push Chain (burn initiator)
    /// @param chainId     Origin chain id string, fetched from PRC20
    /// @param token       PRC20 token address being withdrawn (represents origin ERC20/native)
    /// @param target      Raw destination address on origin chain (bytes)
    /// @param amount      Amount burned on Push Chain
    /// @param gasToken    PRC20 gas coin used to pay cross-chain execution fees
    /// @param gasFee      Amount of gasToken charged
    /// @param gasLimit    Gas limit used for fee quote
    /// @param payload     Optional payload for arbitrary call on origin chain (empty for funds-only)
    /// @param protocolFee Flat protocol fee portion (as defined by PRC20), included inside gasFee
    event UniversalTxWithdraw(
        address indexed sender,
        string indexed chainId,
        address indexed token,
        bytes target,
        uint256 amount,
        address gasToken,
        uint256 gasFee,
        uint256 gasLimit,
        bytes payload,
        uint256 protocolFee,
        RevertInstructions revertInstruction
    );

    /// @notice Emitted when VaultPC address is updated
    /// @param oldVaultPC Previous VaultPC address
    /// @param newVaultPC New VaultPC address
    event VaultPCUpdated(address indexed oldVaultPC, address indexed newVaultPC);

    // ========= Admin Functions =========
    function setVaultPC(address vaultPC) external;
    function pause() external;
    function unpause() external;

    /**
     * @notice                   Withdraw PRC20 back to origin chain (funds only).
     * @dev                      Uses UniversalCore to fetch gasToken, gasFee and protocolFee.
     * @param to                 raw destination address on origin chain.
     * @param token              PRC20 token address on Push Chain.
     * @param amount             amount to withdraw (burn on Push, unlock at origin).
     * @param gasLimit           gas limit to use for fee quote; if 0, uses token's default GAS_LIMIT().
     * @param revertInstruction  revert configuration (fundRecipient, revertMsg) for off-chain use.
     */
    function withdraw(
        bytes calldata to,
        address token,
        uint256 amount,
        uint256 gasLimit,
        RevertInstructions calldata revertInstruction
    ) external;

    /**
     * @notice                   Withdraw PRC20 and attach an arbitrary payload to be executed on the origin chain.
     * @dev                      Uses UniversalCore to fetch gasToken, gasFee and protocolFee.
     * @param target             raw destination (contract) address on origin chain.
     * @param token              PRC20 token address on Push Chain.
     * @param amount             amount to withdraw (burn on Push, unlock at origin).
     * @param payload            ABI-encoded calldata to execute on the origin chain.   
     * @param gasLimit           gas limit to use for fee quote; if 0, uses token's default GAS_LIMIT().
     * @param revertInstruction  revert configuration (fundRecipient, revertMsg) for off-chain use.
     */
    function withdrawAndExecute(
        bytes calldata target,
        address token,
        uint256 amount,
        bytes calldata payload,
        uint256 gasLimit,
        RevertInstructions calldata revertInstruction
    ) external;

    // ========= View Functions =========
    function UNIVERSAL_CORE() external view returns (address);
    function PAUSER_ROLE() external view returns (bytes32);
}
