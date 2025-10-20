// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title UniversalGatewayPC
 * @notice Push Chain–side outbound gateway.
 *         - Allows users to withdraw PRC20 (wrapped) tokens back to the origin chain.
 *         - Allows users to withdraw PRC20 and attach a payload for arbitrary call execution on the origin chain.
 *         - This contract does NOT handle deposits or inbound transfers.
 *         - This contract does NOT custody user assets; PRC20 are burned at request time.
 *
 * @dev Upgradeable via TransparentUpgradeableProxy.
 *      Integrates with UniversalCore to discover the Universal Executor Module (fee sink)
 *      and with PRC20 tokens to compute gas fees and burn on withdraw.
 */
import { Errors } from "./libraries/Errors.sol";
import { IPRC20 } from "./interfaces/IPRC20.sol";
import { RevertInstructions } from "./libraries/Types.sol";
import { IUniversalCore } from "./interfaces/IUniversalCore.sol";
import { IUniversalGatewayPC } from "./interfaces/IUniversalGatewayPC.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract UniversalGatewayPC is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IUniversalGatewayPC
{
    // ========= Roles =========
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ========= State =========
    /// @notice UniversalCore on Push Chain (provides gas coin/prices + UEM address).
    address public UNIVERSAL_CORE;

    /// @notice Cached Universal Executor Module as fee vault; derived from UniversalCore.
    /// @dev    If UniversalCore updates, call {refreshUniversalExecutor} to recache.
    address public UNIVERSAL_EXECUTOR_MODULE;

    // ========= Storage gap for upgradeability =========
    uint256[47] private __gap;

    // ========= Initializer =========
    function initialize(address admin, address pauser, address universalCore) external initializer {
        if (admin == address(0) || pauser == address(0) || universalCore == address(0)) revert Errors.ZeroAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);

        UNIVERSAL_CORE = universalCore;
        UNIVERSAL_EXECUTOR_MODULE = IUniversalCore(universalCore).UNIVERSAL_EXECUTOR_MODULE();
    }

    // ========= Admin =========
    function setUniversalCore(address universalCore) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (universalCore == address(0)) revert Errors.ZeroAddress();
        UNIVERSAL_CORE = universalCore;
        // Refresh UEM from the new core
        UNIVERSAL_EXECUTOR_MODULE = IUniversalCore(universalCore).UNIVERSAL_EXECUTOR_MODULE();
    }

    function refreshUniversalExecutor() external onlyRole(DEFAULT_ADMIN_ROLE) {
        UNIVERSAL_EXECUTOR_MODULE = IUniversalCore(UNIVERSAL_CORE).UNIVERSAL_EXECUTOR_MODULE();
    }

    function pause() external onlyRole(PAUSER_ROLE) whenNotPaused {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) whenPaused {
        _unpause();
    }

    // ========= User Flows =========

    /**
     * @notice Withdraw PRC20 back to origin chain (funds only).
     * @param to                 Raw destination address on origin chain.
     * @param token              PRC20 token address on Push Chain.
     * @param amount             Amount to withdraw (burn on Push, unlock at origin).
     * @param gasLimit           Gas limit to use for fee quote; if 0, uses token's default GAS_LIMIT().
     * @param revertInstruction  Revert configuration (fundRecipient, revertMsg) for off-chain use.
     */
    function withdraw(
        bytes calldata to,
        address token,
        uint256 amount,
        uint256 gasLimit,
        RevertInstructions calldata revertInstruction
    ) external whenNotPaused nonReentrant {
        _validateCommon(to, token, amount, revertInstruction);

        // Compute fees + collect from caller into the UEM fee sink
        (address gasToken, uint256 gasFee, uint256 gasLimitUsed, uint256 protocolFee) =
            _calculateGasFeesWithLimit(token, gasLimit);
        _moveFees(msg.sender, gasToken, gasFee);

        // Burn PRC20 on Push Chain
        bool ok = IPRC20(token).burn(amount);
        if (!ok) revert Errors.TokenBurnFailed(token, amount);

        // Emit
        string memory chainId = IPRC20(token).SOURCE_CHAIN_ID();
        emit UniversalTxWithdraw(
            msg.sender, chainId, token, to, amount, gasToken, gasFee, gasLimitUsed, bytes(""), protocolFee
        );
    }

    /**
     * @notice Withdraw PRC20 and attach an arbitrary payload to be executed on the origin chain.
     * @param target             Raw destination (contract) address on origin chain.
     * @param token              PRC20 token address on Push Chain.
     * @param amount             Amount to withdraw (burn on Push, unlock at origin).
     * @param payload            ABI-encoded calldata to execute on the origin chain.
     * @param gasLimit           Gas limit to use for fee quote; if 0, uses token's default GAS_LIMIT().
     * @param revertInstruction  Revert configuration (fundRecipient, revertMsg) for off-chain use.
     */
    function withdrawAndExecute(
        bytes calldata target,
        address token,
        uint256 amount,
        bytes calldata payload,
        uint256 gasLimit,
        RevertInstructions calldata revertInstruction
    ) external whenNotPaused nonReentrant {
        _validateCommon(target, token, amount, revertInstruction);

        // Compute fees + collect from caller into the UEM fee sink
        (address gasToken, uint256 gasFee, uint256 gasLimitUsed, uint256 protocolFee) =
            _calculateGasFeesWithLimit(token, gasLimit);
        _moveFees(msg.sender, gasToken, gasFee);

        // Burn PRC20 on Push Chain
        bool ok = IPRC20(token).burn(amount);
        if (!ok) revert Errors.TokenBurnFailed(token, amount);

        // Emit
        string memory chainId = IPRC20(token).SOURCE_CHAIN_ID();
        emit UniversalTxWithdraw(
            msg.sender, chainId, token, target, amount, gasToken, gasFee, gasLimitUsed, payload, protocolFee
        );
    }

    // ========= Helpers =========

    function _validateCommon(
        bytes calldata rawTarget,
        address token,
        uint256 amount,
        RevertInstructions calldata revertInstruction
    ) internal pure {
        if (rawTarget.length == 0) revert Errors.InvalidInput();
        if (token == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.InvalidAmount();
        if (revertInstruction.fundRecipient == address(0)) revert Errors.InvalidRecipient();
    }

    /**
     * @dev Use the PRC20's withdrawGasFeeWithGasLimit to compute fee (gas coin + amount).
     *      If gasLimit = 0, pull the default token.GAS_LIMIT().
     * @return gasToken     PRC20 address to be used for fee payment.
     * @return gasFee       Amount of gasToken to collect from the user (includes protocol fee).
     * @return gasLimitUsed Gas limit actually used for the quote.
     * @return protocolFee  The flat protocol fee component (as exposed by PRC20).
     */
    function _calculateGasFeesWithLimit(address token, uint256 gasLimit)
        internal
        view
        returns (address gasToken, uint256 gasFee, uint256 gasLimitUsed, uint256 protocolFee)
    {
        if (gasLimit == 0) {
            gasLimitUsed = IPRC20(token).GAS_LIMIT();
        } else {
            gasLimitUsed = gasLimit;
        }

        (gasToken, gasFee) = IPRC20(token).withdrawGasFeeWithGasLimit(gasLimitUsed);
        if (gasToken == address(0) || gasFee == 0) revert Errors.InvalidData();

        protocolFee = IPRC20(token).PC_PROTOCOL_FEE();
    }

    /**
     * @dev Pull fee from user into the Universal Executor Module.
     *      Caller must have approved `gasToken` for at least `gasFee`.
     */
    function _moveFees(address from, address gasToken, uint256 gasFee) internal {
        address _ueModule = UNIVERSAL_EXECUTOR_MODULE;
        if (_ueModule == address(0)) revert Errors.ZeroAddress();

        bool ok = IPRC20(gasToken).transferFrom(from, _ueModule, gasFee);
        if (!ok) revert Errors.GasFeeTransferFailed(gasToken, from, gasFee);
    }
}
