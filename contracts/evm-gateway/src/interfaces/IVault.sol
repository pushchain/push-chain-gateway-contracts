// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IVault
 * @notice Interface for ERC20 custody vault for outbound flows (withdraw / withdraw+call) managed by TSS.
 */
interface IVault {
    // =========================
    //           EVENTS
    // =========================
    event GatewayUpdated(address indexed oldGateway, address indexed newGateway);
    event TSSUpdated(address indexed oldTss, address indexed newTss);
    event VaultWithdraw(address indexed token, address indexed to, uint256 amount);
    event VaultWithdrawAndCall(address indexed token, address indexed target, uint256 amount, bytes data);
    event VaultRefund(address indexed token, address indexed to, uint256 amount);

    // =========================
    //         INITIALIZER
    // =========================
    /**
     * @notice Initialize the Vault contract
     * @param admin   DEFAULT_ADMIN_ROLE holder
     * @param pauser  PAUSER_ROLE
     * @param tss     TSS_ROLE
     * @param gw      UniversalGateway address (must be non-zero)
     */
    function initialize(address admin, address pauser, address tss, address gw) external;

    // =========================
    //          ADMIN OPS
    // =========================
    /**
     * @notice Pause the vault operations
     */
    function pause() external;

    /**
     * @notice Unpause the vault operations
     */
    function unpause() external;

    /**
     * @notice Update the UniversalGateway pointer
     * @param gw new UniversalGateway address
     */
    function setGateway(address gw) external;

    /**
     * @notice Update the TSS signer address (role transfer)
     * @param newTss new TSS address
     */
    function setTSS(address newTss) external;

    /**
     * @notice Optional admin sweep for mistakenly sent tokens (never native)
     * @param token  ERC20 token address
     * @param to     recipient address
     * @param amount amount to sweep
     */
    function sweep(address token, address to, uint256 amount) external;

    // =========================
    //          WITHDRAW
    // =========================
    /**
     * @notice TSS-only withdraw to an external recipient
     * @param token  ERC20 token to transfer (must be supported by gateway)
     * @param to     destination address
     * @param amount amount to transfer
     */
    function withdraw(address token, address to, uint256 amount) external;

    /**
     * @notice TSS-only withdraw and arbitrary call using the withdrawn ERC20
     * @dev    Pattern: resetApproval(0) -> safeApprove(amount) -> target.call(data) -> resetApproval(0)
     * @param token   ERC20 token to spend (must be supported by gateway)
     * @param target  contract to call
     * @param amount  token amount to allow target to pull/spend
     * @param data    calldata for the target
     */
    function withdrawAndCall(address token, address target, uint256 amount, bytes calldata data) external;

    /**
     * @notice TSS-only refund path (e.g., failed outbound flow) to a designated recipient
     * @param token  ERC20 token to refund (must be supported)
     * @param to     recipient of the refund
     * @param amount amount to refund
     */
    function revertWithdraw(address token, address to, uint256 amount) external;
}

