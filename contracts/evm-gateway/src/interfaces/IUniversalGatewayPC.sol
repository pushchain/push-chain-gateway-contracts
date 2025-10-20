// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RevertInstructions} from "../libraries/Types.sol";

/**
 * @title IUniversalGatewayPC
 * @notice Interface for UniversalGatewayPC contract
 * @dev Defines all public functions and events for the Push Chain outbound gateway
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

    // ========= Admin Functions =========
    function setUniversalCore(address universalCore) external;
    function refreshUniversalExecutor() external;
    function pause() external;
    function unpause() external;

    // ========= User Functions =========
    function withdraw(
        bytes calldata to,
        address token,
        uint256 amount,
        uint256 gasLimit,
        RevertInstructions calldata revertInstruction
    ) external;

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
    function UNIVERSAL_EXECUTOR_MODULE() external view returns (address);
    function PAUSER_ROLE() external view returns (bytes32);
}
