// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title Vault
 * @notice ERC20 custody vault for outbound flows (withdraw / withdraw+call) managed by TSS.
 * @dev    - TransparentUpgradeable (OZ Initializable pattern)
 *         - ERC20-only (no native); native is handled by the gateway directly.
 *         - Token support is gated by UniversalGateway.isSupportedToken(token) to keep a single source of truth.
 *         - Uses safe-approve -> call -> reset-approval pattern (USDT-safe).
 */

import {Errors}                     from "./libraries/Errors.sol";
import {IVault}                     from "./interfaces/IVault.sol";
import {RevertInstructions}         from "./libraries/Types.sol";
import {IUniversalGateway}          from "./interfaces/IUniversalGateway.sol";

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

    // =========================
    //         INITIALIZER
    // =========================
    function initialize(address admin, address pauser, address tss, address gw) external initializer {
        if (admin == address(0) || pauser == address(0) || tss == address(0) || gw == address(0)) {
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
        emit GatewayUpdated(address(0), gw);
        emit TSSUpdated(address(0), tss);
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
    //          WITHDRAW
    // =========================
    /// @inheritdoc IVault
    function withdraw(bytes32 txID, address originCaller, address token, address to, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyRole(TSS_ROLE)
    {
        if (token == address(0) || to == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.InvalidAmount();
        _enforceSupported(token);
        if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();

        IERC20(token).safeTransfer(address(gateway), amount);
        gateway.withdrawTokens(txID, originCaller, token, to, amount);
        emit VaultWithdraw(txID, originCaller, token, to, amount);
    }

    /// @inheritdoc IVault
    function withdrawAndExecute(bytes32 txID, address originCaller, address token, address target, uint256 amount, bytes calldata data)
        external
        nonReentrant
        whenNotPaused
        onlyRole(TSS_ROLE)
    {
        if (token == address(0) || target == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.InvalidAmount();
        _enforceSupported(token);
        if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();

        // Transfer tokens to gateway
        IERC20(token).safeTransfer(address(gateway), amount);

        // Forward execution call to gateway
        gateway.executeUniversalTx(txID, originCaller, token, target, amount, data);
        
        emit VaultWithdrawAndExecute(token, target, amount, data);
    }

    /// @inheritdoc IVault
    function revertWithdraw(bytes32 txID, address token, address to, uint256 amount, RevertInstructions calldata revertInstruction)
        external
        nonReentrant
        whenNotPaused
        onlyRole(TSS_ROLE)
    {
        if (token == address(0) || to == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.InvalidAmount();
        _enforceSupported(token);
        if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();

        IERC20(token).safeTransfer(address(gateway), amount);
        gateway.revertUniversalTxToken(txID, token, amount, revertInstruction);

        emit VaultRevert(token, to, amount, revertInstruction);
    }

    // =========================
    //        INTERNALS
    // =========================
    function _enforceSupported(address token) internal view {
        // Single source of truth lives in UniversalGateway
        if (!gateway.isSupportedToken(token)) revert Errors.NotSupported();
    }
}
