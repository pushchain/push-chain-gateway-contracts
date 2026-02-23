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

import { Errors } from "./libraries/Errors.sol";
import { IVault } from "./interfaces/IVault.sol";
import { RevertInstructions } from "./libraries/Types.sol";
import { IUniversalGateway } from "./interfaces/IUniversalGateway.sol";
import { ICEAFactory } from "./interfaces/ICEAFactory.sol";
import { ICEA } from "./interfaces/ICEA.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

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
    bytes32 public constant TSS_ROLE = keccak256("TSS_ROLE");
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
    function initialize(address admin, address pauser, address tss, address gw, address ceaFactory)
        external
        initializer
    {
        if (
            admin == address(0) || pauser == address(0) || tss == address(0) || gw == address(0)
                || ceaFactory == address(0)
        ) {
            revert Errors.ZeroAddress();
        }

        __Context_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(TSS_ROLE, tss);

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

    /// @notice             Allows the admin to update the CEAFactory address
    /// @dev                Only callable by DEFAULT_ADMIN_ROLE
    /// @param newCEAFactory New CEAFactory address
    function setCEAFactory(address newCEAFactory) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCEAFactory == address(0)) revert Errors.ZeroAddress();
        address old = address(CEAFactory);
        CEAFactory = ICEAFactory(newCEAFactory);
        emit CEAFactoryUpdated(old, newCEAFactory);
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
    /// @dev All execution now routes through CEA.executeUniversalTx with multicall payload
    ///      target parameter kept for backwards compatibility / metadata but not used for routing
    function finalizeUniversalTx(
        bytes32 txId,
        bytes32 universalTxId,
        address pushAccount,
        address token,
        address target,
        uint256 amount,
        bytes calldata data
    ) external payable nonReentrant whenNotPaused onlyRole(TSS_ROLE) {
        // Get or deploy CEA
        (address cea, bool isDeployed) = CEAFactory.getCEAForPushAccount(pushAccount);
        if (!isDeployed) {
            cea = CEAFactory.deployCEA(pushAccount);
        }

        // Single execution path for all operations
        _finalizeUniversalTx(txId, universalTxId, pushAccount, token, target, amount, data, cea);

        // Emit event
        emit VaultUniversalTxFinalized(txId, universalTxId, pushAccount, target, token, amount, data);
    }

    /// @inheritdoc IVault
    function revertUniversalTxToken(
        bytes32 txId,
        bytes32 universalTxId,
        address token,
        uint256 amount,
        RevertInstructions calldata revertInstruction
    ) external nonReentrant whenNotPaused onlyRole(TSS_ROLE) {
        if (token == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.InvalidAmount();
        if (revertInstruction.revertRecipient == address(0)) revert Errors.InvalidRecipient();
        _enforceSupported(token);

        if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();

        IERC20(token).safeTransfer(address(gateway), amount);
        gateway.revertUniversalTxToken(txId, universalTxId, token, amount, revertInstruction);

        emit VaultUniversalTxReverted(txId, universalTxId, token, amount, revertInstruction);
    }

    // =========================
    //        INTERNALS
    // =========================
    function _enforceSupported(address token) internal view {
        // Single source of truth lives in UniversalGateway
        if (!gateway.isSupportedToken(token)) revert Errors.NotSupported();
    }

    function _validateParams(address pushAccount, address token, address target, uint256 amount) internal view {
        if (pushAccount == address(0)) revert Errors.ZeroAddress();
        if (target == address(0)) revert Errors.ZeroAddress();
        _enforceSupported(token);

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
     * @dev Unified execution handler - all operations route through CEA.executeUniversalTx
     * @notice data parameter is now a multicall payload (abi.encode(Multicall[]))
     * @param txId   Gateway transaction ID
     * @param universalTxId Universal transaction ID
     * @param pushAccount   Push Chain account (UEA) this transaction is attributed to
     * @param token         Token address (address(0) for native)
     * @param target        Target contract (kept for backward compatibility, not used for routing)
     * @param amount        Amount of tokens to fund CEA with
     * @param data          Multicall payload (abi.encode(Multicall[]))
     * @param cea           CEA address (already deployed or newly created)
     */
    function _finalizeUniversalTx(
        bytes32 txId,
        bytes32 universalTxId,
        address pushAccount,
        address token,
        address target,
        uint256 amount,
        bytes calldata data,
        address cea
    ) private {
        // Validations
        _validateParams(pushAccount, token, target, amount);

        // Fund CEA and forward multicall payload
        if (token != address(0)) {
            // ERC20: transfer to CEA first, then execute multicall
            if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();
            IERC20(token).safeTransfer(cea, amount);
            ICEA(cea).executeUniversalTx(txId, universalTxId, pushAccount, data);
        } else {
            // Native: forward value to CEA during executeUniversalTx call
            ICEA(cea).executeUniversalTx{ value: amount }(txId, universalTxId, pushAccount, data);
        }
    }
}
