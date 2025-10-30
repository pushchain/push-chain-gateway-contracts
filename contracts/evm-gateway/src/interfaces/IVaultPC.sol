// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IVaultPC
 * @notice Interface for VaultPC - Custody vault to store fees collected from outbound flows on Push Chain.
 */
interface IVaultPC {
    // =========================
    //           EVENTS
    // =========================
    
    /**
     * @notice Emitted when the UniversalCore address is updated
    * @param oldVaultPC The previous VaultPC address
    * @param newVaultPC The new VaultPC address
     */
    event VaultPCUpdated(address indexed oldVaultPC, address indexed newVaultPC);

    // =========================
    //          WITHDRAW
    // =========================
    
    /**
     * @notice          Allows owner/manager to withdraw tokens collected via Outbound Flows.
     * @dev             Only callable by FUND_MANAGER_ROLE
     * @dev             Token must be supported by UniversalCore
     * @param token     PRC20 token address to transfer (must be supported)
     * @param to        Recipient address on external chain
     * @param amount    Amount of token to transfer on external chain
     */
    function withdraw(address token, address to, uint256 amount) external;
}

