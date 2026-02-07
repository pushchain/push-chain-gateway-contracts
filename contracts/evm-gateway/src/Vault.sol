// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title Vault
 * @notice Token custody vault for outbound flows (withdraw / withdraw+call) managed by TSS.
 * @dev    - TransparentUpgradeable (OZ Initializable pattern)
 *         - Handles both ERC20 and native tokens
 *         - Token support is gated by UniversalGateway.isSupportedToken(token) to keep a single source of truth.
 *         - Routes withdrawals (empty payload) and executions (non-empty payload) through CEA contracts
 *         - Uses CEAFactory for deterministic CEA deployment
 */

import {Errors}                     from "./libraries/Errors.sol";
import {IVault}                     from "./interfaces/IVault.sol";
import {RevertInstructions}         from "./libraries/Types.sol";
import {IUniversalGateway}          from "./interfaces/IUniversalGateway.sol";
import {ICEAFactory}                from "./interfaces/ICEAFactory.sol";
import {ICEA}                       from "./interfaces/ICEA.sol";

import {IERC20}                     from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}                  from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ContextUpgradeable}         from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {PausableUpgradeable}        from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable}   from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";


contract Vault is
    Initializable,
    ContextUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    IVault
{
    using SafeERC20 for IERC20;

    // =========================
    //            ROLES
    // =========================
    bytes32 public constant TSS_ROLE    = keccak256("TSS_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // =========================
    //           STATE
    // =========================
    /// @notice UniversalGateway on the same chain; source of truth for token support.
    IUniversalGateway public gateway;

    /// @notice The current TSS address for Vault
    address public TSS_ADDRESS;

    /// @notice The current CEAFactory address for Vault
    ICEAFactory public CEAFactory;

    // =========================
    //         INITIALIZER
    // =========================
    function initialize(address admin, address pauser, address tss, address gw, address ceaFactory) external initializer {
        if (admin == address(0) || pauser == address(0) || tss == address(0) || gw == address(0) || ceaFactory == address(0)) {
            revert Errors.ZeroAddress();
        }

        __Context_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE,          pauser);
        _grantRole(TSS_ROLE,             tss);

        gateway = IUniversalGateway(gw);
        TSS_ADDRESS = tss;
        CEAFactory = ICEAFactory(ceaFactory);
    }

    // =========================
    //          ADMIN OPS
    // =========================
    /// @notice             Allows the admin to pause the contract
    /// @dev                Only callable by PAUSER_ROLE
    function pause() external whenNotPaused onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice             Allows the admin to unpause the contract
    /// @dev                Only callable by PAUSER_ROLE
    function unpause() external whenPaused onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice             Allows the admin to update the UniversalGateway address
    /// @dev                Only callable by DEFAULT_ADMIN_ROLE
    /// @param gw           New UniversalGateway address
    function setGateway(address gw) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (gw == address(0)) revert Errors.ZeroAddress();
        address old = address(gateway);
        gateway = IUniversalGateway(gw);
        emit GatewayUpdated(old, gw);
    }

    /// @notice             Allows the admin to update the TSS address
    /// @dev                Only callable by DEFAULT_ADMIN_ROLE
    /// @param newTss       New TSS address
    function setTSS(address newTss) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTss == address(0)) revert Errors.ZeroAddress();
        address old = TSS_ADDRESS;

        // transfer role
        if (hasRole(TSS_ROLE, old)) _revokeRole(TSS_ROLE, old);
        _grantRole(TSS_ROLE, newTss);

        TSS_ADDRESS = newTss;
        emit TSSUpdated(old, newTss);
    }

    /// @notice             Allows the admin to sweep tokens from the contract
    /// @dev                Only callable by DEFAULT_ADMIN_ROLE
    /// @param token        Token address
    /// @param to           Recipient address
    /// @param amount       Amount of token to sweep
    function sweep(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || to == address(0)) revert Errors.ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    // =========================
    //   WITHDRAW & EXECUTION
    // =========================
    /// @inheritdoc IVault
    function executeUniversalTx(bytes32 txID, bytes32 universalTxID, address originCaller, address token, address target, uint256 amount, bytes calldata data)
        external
        payable
        nonReentrant
        whenNotPaused
        onlyRole(TSS_ROLE)
    {
        // Get or deploy CEA (required for both withdrawal and execution paths)
        (address cea, bool isDeployed) = CEAFactory.getCEAForUEA(originCaller);
        if (!isDeployed) {
            cea = CEAFactory.deployCEA(originCaller);
        }

        // Route based on payload: empty payload = withdrawal, non-empty = execution
        if (data.length == 0) {
            // Withdrawal path
            _handleTokenWithdrawal(txID, universalTxID, originCaller, token, target, amount, cea);
        } else {
            // Execution path
            _handleUniversalTxExecution(txID, universalTxID, originCaller, token, target, amount, data, cea);
        }

        // Emit event (same for both paths)
        emit VaultUniversalTxExecuted(txID, universalTxID, originCaller, target, token, amount, data);
    }

    /// @inheritdoc IVault
    function revertUniversalTxToken(bytes32 txID, bytes32 universalTxID, address token, uint256 amount, RevertInstructions calldata revertInstruction)
        external
        nonReentrant
        whenNotPaused
        onlyRole(TSS_ROLE)
    {
        if (token == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.InvalidAmount();
        _enforceSupported(token);
        if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();

        IERC20(token).safeTransfer(address(gateway), amount);
        gateway.revertUniversalTxToken(txID, universalTxID, token, amount, revertInstruction);

        emit VaultUniversalTxReverted(txID, universalTxID, token, amount, revertInstruction);
    }

    // =========================
    //        INTERNALS
    // =========================
    function _enforceSupported(address token) internal view {
        // Single source of truth lives in UniversalGateway
        if (!gateway.isSupportedToken(token)) revert Errors.NotSupported();
    }

    function _validateExecutionParams(
        address originCaller,
        address token,
        address target,
        uint256 amount
    ) internal view {
        if (originCaller == address(0)) revert Errors.ZeroAddress();
        if (target == address(0)) revert Errors.ZeroAddress();

        // Invariant on (token, msg.value):
        // - Native flow: token == address(0) → msg.value MUST equal amount
        // - ERC20 flow:  token != address(0) → msg.value MUST be 0
        if (token == address(0)) {
            if (msg.value != amount) revert Errors.InvalidAmount();
        } else {
            if (msg.value != 0) revert Errors.InvalidAmount();
        }
    }

    /**
     * @dev Handles token withdrawal (empty payload case)
     * @param txID Transaction ID
     * @param universalTxID Universal transaction ID
     * @param originCaller UEA address on Push Chain
     * @param token Token address (address(0) for native)
     * @param to Recipient address (user or CEA itself for parking)
     * @param amount Amount to withdraw
     * @param cea CEA address (already deployed or newly created)
     */
    function _handleTokenWithdrawal(
        bytes32 txID,
        bytes32 universalTxID,
        address originCaller,
        address token,
        address to,
        uint256 amount,
        address cea
    ) private {
        // Validations (reuses existing validation functions)
        _validateExecutionParams(originCaller, token, to, amount);
        _enforceSupported(token);

        // Withdrawal-specific validation: amount must be non-zero
        if (amount == 0) revert Errors.InvalidAmount();

        // Transfer tokens to CEA and trigger withdrawTo
        if (token == address(0)) {
            // Native token withdrawal
            ICEA(cea).withdrawTo{value: amount}(
                txID,
                universalTxID,
                originCaller,
                token,
                to,
                amount
            );
        } else {
            // ERC20 token withdrawal
            if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();
            IERC20(token).safeTransfer(cea, amount);

            ICEA(cea).withdrawTo(
                txID,
                universalTxID,
                originCaller,
                token,
                to,
                amount
            );
        }
    }

    /**
     * @dev Handles payload execution (non-empty payload case)
     * @notice Contains the existing execution logic from executeUniversalTx
     * @param txID Transaction ID
     * @param universalTxID Universal transaction ID
     * @param originCaller UEA address on Push Chain
     * @param token Token address (address(0) for native)
     * @param target Target contract address
     * @param amount Amount of tokens
     * @param data Payload to execute
     * @param cea CEA address (already deployed or newly created)
     */
    function _handleUniversalTxExecution(
        bytes32 txID,
        bytes32 universalTxID,
        address originCaller,
        address token,
        address target,
        uint256 amount,
        bytes calldata data,
        address cea
    ) private {
        // Validations (existing logic)
        _validateExecutionParams(originCaller, token, target, amount);
        _enforceSupported(token);

        // Execute based on token type (existing logic)
        if (token != address(0)) {
            // ERC20 execution
            if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();
            IERC20(token).safeTransfer(cea, amount);
            ICEA(cea).executeUniversalTx(txID, universalTxID, originCaller, token, target, amount, data);
        } else {
            // Native execution
            ICEA(cea).executeUniversalTx{value: amount}(txID, universalTxID, originCaller, target, amount, data);
        }
    }
}
