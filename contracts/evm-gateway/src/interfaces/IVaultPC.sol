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
     * @notice          Emitted when the UniversalCore address is updated
    * @param oldVaultPC The previous VaultPC address
    * @param newVaultPC The new VaultPC address
     */
    event VaultPCUpdated(address indexed oldVaultPC, address indexed newVaultPC);

    /**
     * @notice          Emitted when fees are withdrawn from the vault
     * @param caller    The address that initiated the withdrawal (FUND_MANAGER_ROLE)
     * @param token     The PRC20 token address (address(0) for native PC)
     * @param amount    The amount withdrawn
     */
    event FeesWithdrawn(address indexed caller, address indexed token, uint256 amount);

    // =========================
    //          WITHDRAW
    // =========================
    
    /**
     * @notice          Allows FUND_MANAGER_ROLE to withdraw native PC tokens from the vault
     * @dev             Only callable by FUND_MANAGER_ROLE
     * @param to        Recipient address
     * @param amount    Amount of native PC to transfer
     */
    function withdraw(address to, uint256 amount) external;

    /**
     * @notice          Allows FUND_MANAGER_ROLE to withdraw PRC20 tokens from the vault
     * @dev             Only callable by FUND_MANAGER_ROLE
     * @param token     PRC20 token address to transfer
     * @param to        Recipient address
     * @param amount    Amount of token to transfer
     */
    function withdrawToken(address token, address to, uint256 amount) external;
}

