// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title   UniversalGatewayPC
 * @notice  Universal Gateway implementation for Push Chain 
 * 
 * @dev 
 *         - Strictly to be deployed on Push Chain.
 *         - Allows users to withdraw PRC20 (wrapped) tokens back to the origin chain.
 *         - Allows users to withdraw PRC20 and attach a payload for arbitrary call execution on the origin chain.
 *         - This contract does NOT handle deposits or inbound transfers. 
 *         - This contract does NOT custody user assets; PRC20 are burned at request time.
 *         - The Gateway includes a withdrawal fees for withdrwal from Push Chain to origin chain.
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
    /// @notice Pauser role for pausing the contract.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice UniversalCore on Push Chain (provides gas coin/prices + UEM address).
    address public UNIVERSAL_CORE;

    /// @notice Cached Universal Executor Module as fee vault; derived from UniversalCore.
    /// @dev    If UniversalCore updates, call {refreshUniversalExecutor} to recache.
    address public UNIVERSAL_EXECUTOR_MODULE;

    /// @notice                 Initializes the contract.
    /// @param admin            address of the admin.
    /// @param pauser           address of the pauser.
    /// @param universalCore    address of the UniversalCore.
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

    /// @notice                 Sets the UniversalCore address.
    /// @param universalCore    address of the UniversalCore.
    function setUniversalCore(address universalCore) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (universalCore == address(0)) revert Errors.ZeroAddress();
        UNIVERSAL_CORE = universalCore;

        UNIVERSAL_EXECUTOR_MODULE = IUniversalCore(universalCore).UNIVERSAL_EXECUTOR_MODULE();
    }

    function pause() external onlyRole(PAUSER_ROLE) whenNotPaused {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) whenPaused {
        _unpause();
    }

    /// @inheritdoc IUniversalGatewayPC
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
        _burnPRC20(msg.sender, token, amount);

        string memory chainId = IPRC20(token).SOURCE_CHAIN_ID();
        emit UniversalTxWithdraw(
            msg.sender, chainId, token, to, amount, gasToken, gasFee, gasLimitUsed, bytes(""), protocolFee, revertInstruction
        );
    }

    /// @inheritdoc IUniversalGatewayPC
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

        _burnPRC20(msg.sender, token, amount);

        string memory chainId = IPRC20(token).SOURCE_CHAIN_ID();
        emit UniversalTxWithdraw(
            msg.sender, chainId, token, target, amount, gasToken, gasFee, gasLimitUsed, payload, protocolFee, revertInstruction
        );
    }

    // ========= Helpers =========

    /// @notice                 Validates the common parameters.
    /// @dev                    Uses UniversalCore to fetch gasToken, gasFee and protocolFee.
    /// @param rawTarget        raw destination address on origin chain.
    /// @param token            PRC20 token address on Push Chain.
    /// @param amount           amount to withdraw (burn on Push, unlock at origin).
    /// @param revertInstruction revert configuration (fundRecipient, revertMsg) for off-chain use.
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
     * @dev                 Use UniversalCore's withdrawGasFeeWithGasLimit to compute fee (gas coin + amount).
     *                          If gasLimit = 0, pull the default BASE_GAS_LIMIT from UniversalCore.
     * @return gasToken     PRC20 address to be used for fee payment.
     * @return gasFee       amount of gasToken to collect from the user (includes protocol fee).
     * @return gasLimitUsed gas limit actually used for the quote.
     * @return protocolFee  the flat protocol fee component (as exposed by PRC20).
     */
    function _calculateGasFeesWithLimit(address token, uint256 gasLimit)
        internal
        view
        returns (address gasToken, uint256 gasFee, uint256 gasLimitUsed, uint256 protocolFee)
    {
        if (gasLimit == 0) {
            gasLimitUsed = IUniversalCore(UNIVERSAL_CORE).BASE_GAS_LIMIT();
        } else {
            gasLimitUsed = gasLimit;
        }

        (gasToken, gasFee) = IUniversalCore(UNIVERSAL_CORE).withdrawGasFeeWithGasLimit(token, gasLimitUsed);
        if (gasToken == address(0) || gasFee == 0) revert Errors.InvalidData();

        protocolFee = IPRC20(token).PC_PROTOCOL_FEE();
    }

    /**
     * @dev     Pull fee from user into the Universal Executor Module.
     *          Caller must have approved `gasToken` for at least `gasFee`.
     */
    function _moveFees(address from, address gasToken, uint256 gasFee) internal {
        address _ueModule = UNIVERSAL_EXECUTOR_MODULE;
        if (_ueModule == address(0)) revert Errors.ZeroAddress();

        bool ok = IPRC20(gasToken).transferFrom(from, _ueModule, gasFee);
        if (!ok) revert Errors.GasFeeTransferFailed(gasToken, from, gasFee);
    }

    function _burnPRC20(address from, address token, uint256 amount) internal {
        // Pull PRC20 into this gateway first
        IPRC20(token).transferFrom(from, address(this), amount);

        // Then burn from this contract's balance
        bool ok = IPRC20(token).burn(amount);
        if (!ok) revert Errors.TokenBurnFailed(token, amount);
    }
}
