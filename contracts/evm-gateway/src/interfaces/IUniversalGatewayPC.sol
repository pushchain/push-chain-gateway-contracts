// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RevertInstructions, TX_TYPE, UniversalOutboundTxRequest} from "../libraries/Types.sol";

/**
 * @title   IUniversalGatewayPC
 * @notice  Interface for UniversalGatewayPC contract
 * @dev     Defines all public functions and events for the Push Chain outbound gateway
 */
interface IUniversalGatewayPC {
    // ========= Events =========

    /// @notice                 Single event covering both flows (funds-only and funds+payload).
    /// @param sender           EVM sender on Push Chain (burn initiator) on Push Chain
    /// @param chainId          Origin chain id string, fetched from PRC20 on external chain
    /// @param token            PRC20 token address being withdrawn (represents origin ERC20/native) on external chain
    /// @param target           Raw destination address on origin chain (bytes) on external chain
    /// @param amount           Amount burned on Push Chain
    /// @param gasToken         PRC20 gas coin used to pay cross-chain execution fees on external chain
    /// @param gasFee           Amount of gasToken charged on external chain
    /// @param gasLimit         Gas limit used for fee quote on external chain
    /// @param payload          Optional payload for arbitrary call on origin chain (empty for funds-only) on external chain
    /// @param protocolFee      Flat protocol fee portion (as defined by PRC20), included inside gasFee on external chain
    event UniversalTxOutbound(
        address indexed sender,
        string chainId,
        address indexed token,
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
     * @notice                   Send a universal outbound transaction from Push Chain to origin chain.
     * @dev                      Unified function for all outbound transaction types (FUNDS, FUNDS_AND_PAYLOAD, GAS_AND_PAYLOAD).
     *                           TX_TYPE is automatically inferred based on the presence of payload and amount.
     * @param req                UniversalOutboundTxRequest struct containing all transaction parameters.
     */
    function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req) external;

    // ========= View Functions =========
    function UNIVERSAL_CORE() external view returns (address);
}
