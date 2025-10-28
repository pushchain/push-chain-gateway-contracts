// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title   VaultPC
 * @notice  Custody vault to store fees collected from outbound flows on Push Chain.
 * @dev    - TransparentUpgradeable (OZ Initializable pattern)
 *         - Only supports PRC20 tokens.
 *         - Funds stored are managed by the FUND_MANAGER_ROLE.
 */

// TODO: 
//      1. Add enforcedSupportedToken via a isSupportedToken function icnluded in universalcore.
//      2. Include functionality to allow ADMIN BURN of tokens. 
//      3. Include interfaces 
//      4. Include additional checks for VaultPC if need be.
import {Errors}                     from "./libraries/Errors.sol";

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
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;


    // =========================
    //           STATE
    // =========================

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant FUND_MANAGER_ROLE = keccak256("FUND_MANAGER_ROLE");

    // =========================
    //           EVENTS
    // =========================
    event GatewayPCUpdated(address indexed oldGatewayPC, address indexed newGatewayPC);

    // =========================
    //         INITIALIZER
    // =========================
    /**
     * @param admin   DEFAULT_ADMIN_ROLE holder
     * @param pauser  PAUSER_ROLE
     * @param fundManager  FUND_MANAGER_ROLE
     */
    function initialize(address admin, address pauser, address fundManager) external initializer {
        if (admin == address(0) || pauser == address(0) || fundManager == address(0)) revert Errors.ZeroAddress();

        __Context_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE,          pauser);
        _grantRole(FUND_MANAGER_ROLE,    fundManager);
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

    /// @notice Optional admin sweep for mistakenly sent tokens (never native).
    function sweep(address token, address to, uint256 amount) external onlyRole(FUND_MANAGER_ROLE) {
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
        onlyRole(FUND_MANAGER_ROLE)
    {
        if (token == address(0) || to == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.InvalidAmount();
        if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();

        IERC20(token).safeTransfer(to, amount);
    }


}
