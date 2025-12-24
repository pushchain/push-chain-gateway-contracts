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
import { IVaultPC } from "./interfaces/IVaultPC.sol";
import { TX_TYPE, UniversalOutboundTxRequest } from "./libraries/Types.sol";
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

    /// @notice VaultPC on Push Chain (custody vault for fees collected from outbound flows).
    IVaultPC public VAULT_PC;

    /// @notice                 Initializes the contract.
    /// @param admin            address of the admin.
    /// @param pauser           address of the pauser.
    /// @param universalCore    address of the UniversalCore.
    /// @param vaultPC          address of the VaultPC.
    function initialize(address admin, address pauser, address universalCore, address vaultPC) external initializer {
        if (admin == address(0) || pauser == address(0) || universalCore == address(0) || vaultPC == address(0)) revert Errors.ZeroAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);

        UNIVERSAL_CORE = universalCore;
        VAULT_PC = IVaultPC(vaultPC);
    }

    /// @notice                 Sets the VaultPC address.
    /// @param vaultPC    address of the VaultPC.
    function setVaultPC(address vaultPC) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (vaultPC == address(0)) revert Errors.ZeroAddress();
        address oldVaultPC = address(VAULT_PC);
        VAULT_PC = IVaultPC(vaultPC);
        emit VaultPCUpdated(oldVaultPC, vaultPC);
    }

    function pause() external onlyRole(PAUSER_ROLE) whenNotPaused {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) whenPaused {
        _unpause();
    }

    function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        _validateCommon(req.target, req.token, req.amount, req.revertRecipient);

        // Determine TX_TYPE based on user input
        TX_TYPE txType = _fetchTxType(req);

        // Compute fees + collect from caller into the UEM fee sink
        (address gasToken, uint256 gasFee, uint256 gasLimitUsed, uint256 protocolFee) =
            _calculateGasFeesWithLimit(req.token, req.gasLimit);
        _moveFees(msg.sender, gasToken, gasFee);

        _burnPRC20(msg.sender, req.token, req.amount);

        string memory chainId = IPRC20(req.token).SOURCE_CHAIN_ID();
        emit UniversalTxOutbound(
            msg.sender, chainId, req.token, req.target, req.amount, gasToken, gasFee, gasLimitUsed, req.payload, protocolFee, req.revertRecipient, txType
        );
    }

    // ========= Helpers =========

    /**
     * @notice                  Infers the TX_TYPE for an outbound universal request from Push Chain.
     * @dev                     Determines TX_TYPE based on the presence of payload and amount:
     *                          - If NO payload: TX_TYPE.FUNDS (funds-only withdrawal)
     *                          - If payload AND amount > 0: TX_TYPE.FUNDS_AND_PAYLOAD (funds + execution)
     *                          - If payload AND amount == 0: TX_TYPE.GAS_AND_PAYLOAD (execution-only)
     * @param req               UniversalOutboundTxRequest struct
     * @return inferred         The inferred TX_TYPE for routing
     */
    function _fetchTxType(UniversalOutboundTxRequest calldata req)
        private
        pure
        returns (TX_TYPE inferred)
    {
        bool hasPayload = req.payload.length > 0;
        bool hasFunds = req.amount > 0;

        // Case 1: No payload → FUNDS (funds-only withdrawal)
        if (!hasPayload) {
            return TX_TYPE.FUNDS;
        }

        // Case 2: Payload + Funds → FUNDS_AND_PAYLOAD (funds + execution)
        if (hasPayload && hasFunds) {
            return TX_TYPE.FUNDS_AND_PAYLOAD;
        }

        // Case 3: Payload only (no funds) → GAS_AND_PAYLOAD (execution-only)
        if (hasPayload && !hasFunds) {
            return TX_TYPE.GAS_AND_PAYLOAD;
        }

        // Should never reach here due to the logic above, but added for safety
        revert Errors.InvalidInput();
    }

    /// @notice                 Validates the common parameters.
    /// @dev                    Uses UniversalCore to fetch gasToken, gasFee and protocolFee.
    /// @param rawTarget        raw destination address on origin chain.
    /// @param token            PRC20 token address on Push Chain.
    /// @param amount           amount to withdraw (burn on Push, unlock at origin).
    /// @param revertRecipient    address to receive funds in case of revert.
    function _validateCommon(
        bytes calldata rawTarget,
        address token,
        uint256 amount,
        address revertRecipient
    ) internal pure {
        if (rawTarget.length == 0) revert Errors.InvalidInput();
        if (token == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.InvalidAmount();
        if (revertRecipient == address(0)) revert Errors.InvalidRecipient();
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
     * @dev     Pull fee from user into the VaultPC.
     *          Caller must have approved `gasToken` for at least `gasFee`.
     */
    function _moveFees(address from, address gasToken, uint256 gasFee) internal {
        address _vaultPC = address(VAULT_PC);
        if (_vaultPC == address(0)) revert Errors.ZeroAddress();

        bool ok = IPRC20(gasToken).transferFrom(from, _vaultPC, gasFee);
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
