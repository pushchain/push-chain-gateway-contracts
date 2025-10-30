// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title   VaultPC
 * @notice  Custody vault to store fees collected from outbound flows on Push Chain.
 * @dev    - TransparentUpgradeable (OZ Initializable pattern)
 *         - Only supports PRC20 tokens.
 *         - Funds stored are managed by the FUND_MANAGER_ROLE.
 *         - UniversalCore is the single source of truth for supported PRC20 tokens for Push Chain.
 *         - All fees earned via outbound flows are stored and handled in this contract by FUND_MANAGER_ROLE.
 */

import {Errors}                     from "./libraries/Errors.sol";
import {IVaultPC}                   from "./interfaces/IVaultPC.sol";
import {IUniversalCore}             from "./interfaces/IUniversalCore.sol";

import {IERC20}                     from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}                  from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ContextUpgradeable}         from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {PausableUpgradeable}        from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable}              from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable}   from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";


contract VaultPC is
    Initializable,
    ContextUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    IVaultPC
{
    using SafeERC20 for IERC20;

    /// @notice UniversalCore on Push Chain (provides gas coin/prices + UEM address).   
    address public UNIVERSAL_CORE;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant FUND_MANAGER_ROLE = keccak256("FUND_MANAGER_ROLE");

    /**
     * @param admin   DEFAULT_ADMIN_ROLE holder
     * @param pauser  PAUSER_ROLE
     * @param fundManager  FUND_MANAGER_ROLE
     */
    function initialize(address admin, address pauser, address fundManager, address universalCore) external initializer {
        if (admin == address(0) || pauser == address(0) || fundManager == address(0) || universalCore == address(0)) revert Errors.ZeroAddress();

        __Context_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE,          pauser);
        _grantRole(FUND_MANAGER_ROLE,    fundManager);

        UNIVERSAL_CORE = universalCore;
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

    function updateUniversalCore(address universalCore) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (universalCore == address(0)) revert Errors.ZeroAddress();
        UNIVERSAL_CORE = universalCore;
    }

    /// @notice Optional admin sweep for mistakenly sent tokens (never native).
    function sweep(address token, address to, uint256 amount) external onlyRole(FUND_MANAGER_ROLE) {
        if (token == address(0) || to == address(0)) revert Errors.ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    // =========================
    //          WITHDRAW
    // =========================
    /// @inheritdoc IVaultPC
    function withdraw(address token, address to, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyRole(FUND_MANAGER_ROLE)
    {
        _enforceSupportedToken(token);
        if (token == address(0) || to == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.InvalidAmount();
        if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();

        IERC20(token).safeTransfer(to, amount);
    }

    // =========================
    //        INTERNALS
    // =========================
    /**
     * @notice Enforce that a token is supported
     * @param token Token address
     */
    function _enforceSupportedToken(address token) internal view {
        // Single source of truth lives in UniversalCore
        if (!IUniversalCore(UNIVERSAL_CORE).isSupportedToken(token)) revert Errors.NotSupported();
    }
}
