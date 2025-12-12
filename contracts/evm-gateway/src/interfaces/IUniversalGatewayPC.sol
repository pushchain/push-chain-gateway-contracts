// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RevertInstructions, TX_TYPE} from "../libraries/Types.sol";

/**
 * @title   IUniversalGatewayPC
 * @notice  Interface for UniversalGatewayPC contract
 * @dev     Defines all public functions and events for the Push Chain outbound gateway
 */
interface IUniversalGatewayPC {
    // ========= Events =========

    /// @notice                   Single event covering all flows (funds-only, payload-only and funds+payload).
    /// @param txId               Unique TxId for Outbound Universal Tx
    /// @param sender             EVM sender on Push Chain (burn initiator) on Push Chain
    /// @param token              PRC20 token address being withdrawn (represents origin ERC20/native) on external chain
    /// @param chainNamespace     Origin chain id string, fetched from PRC20 on external chain
    /// @param target             Raw destination address on origin chain (bytes) on external chain
    /// @param amount             Amount burned on Push Chain
    /// @param gasToken           PRC20 gas coin used to pay cross-chain execution fees on external chain
    /// @param gasFee             Amount of gasToken charged on external chain
    /// @param gasLimit           Gas limit used for fee quote on external chain
    /// @param payload            Optional payload for arbitrary call on origin chain (empty for funds-only) on external chain
    /// @param protocolFee        Flat protocol fee portion (as defined by PRC20), included inside gasFee on external chain
    event UniversalTxOutbound(
        bytes32 indexed txId,
        address indexed sender,
        address indexed token,
        string chainNamespace,
        bytes target,
        uint256 amount,
        address gasToken,
        uint256 gasFee,
        uint256 gasLimit,
        bytes payload,
        uint256 protocolFee,
        address revertRecipient,
        TX_TYPE txType
    );

    /// @notice                 Emitted when VaultPC address is updated
    /// @param oldVaultPC       Previous VaultPC address
    /// @param newVaultPC       New VaultPC address
    event VaultPCUpdated(address indexed oldVaultPC, address indexed newVaultPC);

    /**
     * @notice                   Send a universal transaction outbound from Push Chain.
     * @dev                      Supports funds-only, payload-only, and funds+payload flows.
     *                           Handles PRC20, PC20, and PC721 assets.
     * @param target             raw destination address on origin chain.
     * @param token              PRC20 / PC20 / PC721 token address, or address(0) for payload-only.
     * @param amount             fungible amount (for PRC20 / PC20).
     * @param tokenId            NFT id (for PC721).
     * @param gasLimit           gas limit to use for fee quote; if 0, uses BASE_GAS_LIMIT.
     * @param payload            optional payload for arbitrary call execution on origin chain.
     * @param chainNamespace     chain namespace identifier (e.g., "eip155:1").
     * @param revertInstruction  revert configuration (fundRecipient, revertMsg) for off-chain use.
     */
    function sendUniversalTxOutbound(
        bytes calldata target,
        address token,
        uint256 amount,
        uint256 tokenId,
        uint256 gasLimit,
        bytes calldata payload,
        string calldata chainNamespace,
        RevertInstructions calldata revertInstruction
    ) external payable;

    // ========= View Functions =========
    function UNIVERSAL_CORE() external view returns (address);
}
