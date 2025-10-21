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
    AccessControlUpgradeable
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

    /// @notice gap for future upgrades
    uint256[48] private __gap;

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
     * @param admin   DEFAULT_ADMIN_ROLE holder
     * @param pauser  PAUSER_ROLE
     * @param tss     TSS_ROLE
     * @param gw      UniversalGateway address (must be non-zero)
     */
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
    function pause() external whenNotPaused onlyRole(PAUSER_ROLE) {
        _pause();
    }
    function unpause() external whenPaused onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Update the UniversalGateway pointer.
    function setGateway(address gw) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (gw == address(0)) revert Errors.ZeroAddress();
        address old = address(gateway);
        gateway = IUniversalGateway(gw);
        emit GatewayUpdated(old, gw);
    }

    /// @notice Update the TSS signer address (role transfer).
    function setTSS(address newTss) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (newTss == address(0)) revert Errors.ZeroAddress();
        address old = TSS_ADDRESS;

        // transfer role
        if (hasRole(TSS_ROLE, old)) _revokeRole(TSS_ROLE, old);
        _grantRole(TSS_ROLE, newTss);

        TSS_ADDRESS = newTss;
        emit TSSUpdated(old, newTss);
    }

    /// @notice Optional admin sweep for mistakenly sent tokens (never native).
    function sweep(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || to == address(0)) revert Errors.ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    // =========================
    //          WITHDRAW
    // =========================
    /**
     * @notice TSS-only withdraw to an external recipient.
     * @param token  ERC20 token to transfer (must be supported by gateway)
     * @param to     destination address
     * @param amount amount to transfer
     */
    function withdraw(address token, address to, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyRole(TSS_ROLE)
    {
        if (token == address(0) || to == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.InvalidAmount();
        _enforceSupported(token);
        if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();

        IERC20(token).safeTransfer(to, amount);
        emit VaultWithdraw(token, to, amount);
    }

    /**
     * @notice TSS-only withdraw and arbitrary call using the withdrawn ERC20.
     *         Pattern: resetApproval(0) -> safeApprove(amount) -> target.call(data) -> resetApproval(0)
     * @param token   ERC20 token to spend (must be supported by gateway)
     * @param target  contract to call
     * @param amount  token amount to allow target to pull/spend
     * @param data    calldata for the target
     */
    function withdrawAndCall(address token, address target, uint256 amount, bytes calldata data)
        external
        nonReentrant
        whenNotPaused
        onlyRole(TSS_ROLE)
    {
        if (token == address(0) || target == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.InvalidAmount();
        _enforceSupported(token);
        if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();

        // Approve target to pull `amount`, call, then reset to 0.
        _resetApproval(token, target);
        _safeApprove(token, target, amount);

        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            // Reset approval before bubbling an error.
            _resetApproval(token, target);
            // If target returned a reason, bubble it; else revert with a generic error.
            if (ret.length > 0) {
                assembly {
                    let size := mload(ret)
                    revert(add(ret, 32), size)
                }
            } else {
                revert Errors.ExecutionFailed();
            }
        }

        _resetApproval(token, target);
        emit VaultWithdrawAndCall(token, target, amount, data);
    }

    /**
     * @notice TSS-only refund path (e.g., failed outbound flow) to a designated recipient.
     * @param token  ERC20 token to refund (must be supported)
     * @param to     recipient of the refund
     * @param amount amount to refund
     */
    function revertWithdraw(address token, address to, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyRole(TSS_ROLE)
    {
        if (token == address(0) || to == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.InvalidAmount();
        _enforceSupported(token);
        if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();

        IERC20(token).safeTransfer(to, amount);
        emit VaultRefund(token, to, amount);
    }

    // =========================
    //        INTERNALS
    // =========================
    function _enforceSupported(address token) internal view {
        // Single source of truth lives in UniversalGateway
        if (!gateway.isSupportedToken(token)) revert Errors.NotSupported();
    }

    /// @dev Safely reset approval to zero before granting any new allowance to target contract.
    function _resetApproval(address token, address spender) internal {
        (bool success, bytes memory returnData) =
            token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
        if (!success) {
            // Some non-standard tokens revert on zero-approval; treat as reset-ok to avoid breaking the flow.
            return;
        }
        // If token returns a boolean, ensure it is true; if no return data, assume success (USDT-style).
        if (returnData.length > 0) {
            bool ok = abi.decode(returnData, (bool));
            if (!ok) revert Errors.InvalidData();
        }
    }

    /// @dev Safely approve ERC20 token spending to a target contract.
    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory returnData) =
            token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!success) revert Errors.InvalidData();
        if (returnData.length > 0) {
            bool ok = abi.decode(returnData, (bool));
            if (!ok) revert Errors.InvalidData();
        }
    }
}
