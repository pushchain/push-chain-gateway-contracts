// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title   UniversalGatewayPC
 * @notice  Outbound gateway on Push Chain for bridging funds and payloads to external EVM chains.
 *
 * @dev
 *         - Strictly to be deployed on Push Chain.
 *         - Allows users to withdraw PRC20 (wrapped) tokens back to the origin chain.
 *         - Allows users to withdraw PRC20 and attach a payload for arbitrary call execution on the origin chain.
 *         - Allows payload-only transactions (no token burn) using existing CEA funds on the origin chain.
 *         - This contract does NOT handle deposits or inbound transfers.
 *         - This contract does NOT custody user assets; PRC20 are burned at request time.
 *         - Gas fees are paid in native PC, swapped to gas token PRC20 via UniversalCore.
 *           The gas cost portion (gasFee) is burned by UniversalCore, freeing backing tokens for TSS relayers.
 *           The protocol fee portion (protocolFee) is sent to VaultPC as revenue.
 *           Unused PC is refunded directly to the caller by UniversalCore.
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

    /// @notice Nonce for outbound transactions.
    uint256 public nonce;

    /// @notice                 Initializes the contract.
    /// @param admin            address of the admin.
    /// @param pauser           address of the pauser.
    /// @param universalCore    address of the UniversalCore.
    /// @param vaultPC          address of the VaultPC.
    function initialize(address admin, address pauser, address universalCore, address vaultPC) external initializer {
        if (admin == address(0) || pauser == address(0) || universalCore == address(0) || vaultPC == address(0)) {
            revert Errors.ZeroAddress();
        }

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

    /// @notice Sends an outbound universal transaction from Push Chain to an external chain.
    /// @dev    Infers TX_TYPE from the request, quotes gas fees, burns PRC20 (if amount > 0),
    ///         swaps native PC to gas token PRC20 via UniversalCore exactOutputSingle (refunding
    ///         unused PC directly to the caller), and emits UniversalTxOutbound.
    /// @param req The outbound transaction request struct.
    function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        _validateCommon(req.token, req.revertRecipient);

        // Determine TX_TYPE based on user input (rejects empty transactions internally)
        TX_TYPE txType = _fetchTxType(req);

        // Quote gas fees and chain metadata from UniversalCore
        (address gasToken, uint256 gasFee, uint256 gasLimitUsed, uint256 protocolFee, string memory chainNamespace) =
            _fetchOutboundTxInfo(req.token, req.gasLimit);

        // Burn PRC20 first (if amount > 0), before swap
        if (req.amount > 0) {
            _burnPRC20(msg.sender, req.token, req.amount);
        }

        // Swap native PC → gas token: burns gasFee and sends protocolFee to VaultPC
        _swapAndCollectFees(gasToken, msg.value, gasFee, protocolFee);

        uint256 _nonce = nonce;
        nonce = _nonce + 1;

        bytes32 subTxId = keccak256(
            abi.encode(msg.sender, req.recipient, req.token, req.amount, keccak256(req.payload), chainNamespace, _nonce)
        );

        emit UniversalTxOutbound(
            subTxId,
            msg.sender,
            req.recipient,
            chainNamespace,
            req.token,
            req.amount,
            gasToken,
            gasFee,
            gasLimitUsed,
            req.payload,
            protocolFee,
            req.revertRecipient,
            txType,
            msg.value
        );
    }

    // ========= Helpers =========

    /**
     * @notice                  Infers the TX_TYPE for an outbound universal request from Push Chain.
     * @dev                     Determines TX_TYPE based on the presence of payload and amount:
     *                          - If NO payload AND funds > 0: TX_TYPE.FUNDS (funds-only withdrawal)
     *                          - If payload AND amount > 0: TX_TYPE.FUNDS_AND_PAYLOAD (funds + execution)
     *                          - If payload AND amount == 0: TX_TYPE.GAS_AND_PAYLOAD (execution-only)
     *                          - If NO payload AND NO funds: Reverts with InvalidInput (empty transaction)
     * @param req               UniversalOutboundTxRequest struct
     * @return inferred         The inferred TX_TYPE for routing
     */
    function _fetchTxType(UniversalOutboundTxRequest calldata req) private pure returns (TX_TYPE inferred) {
        bool hasPayload = req.payload.length > 0;
        bool hasFunds = req.amount > 0;

        // Case 1: No payload + Funds → FUNDS (funds-only withdrawal)
        if (!hasPayload && hasFunds) {
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

        // Case 4: No payload + No funds → Invalid (empty transaction)
        revert Errors.InvalidInput();
    }

    /// @notice                 Validates the common parameters.
    /// @dev                    Validates token and revertRecipient addresses.
    ///                         Amount validation is handled in _fetchTxType() to support payload-only transactions.
    /// @param token            PRC20 token address on Push Chain.
    /// @param revertRecipient  address to receive funds in case of revert.
    function _validateCommon(address token, address revertRecipient) internal pure {
        if (token == address(0)) revert Errors.ZeroAddress();
        if (revertRecipient == address(0)) revert Errors.InvalidRecipient();
    }

    /**
     * @dev    Fetch gas fee quote and chain metadata from UniversalCore.
     *         If gasLimit = 0, uses BASE_GAS_LIMIT from UniversalCore.
     * @param token         PRC20 token address on Push Chain (used by UniversalCore to resolve chain).
     * @param gasLimit      Caller-requested gas limit (0 = default).
     * @return gasToken     PRC20 address of the gas token for the target chain.
     * @return gasFee       Gas cost in gas token units (excludes protocol fee).
     * @return gasLimitUsed Gas limit actually used for the quote.
     * @return protocolFee  Flat protocol fee in gas token units.
     * @return chainNamespace Chain namespace string for the target chain.
     */
    function _fetchOutboundTxInfo(address token, uint256 gasLimit)
        internal
        view
        returns (
            address gasToken,
            uint256 gasFee,
            uint256 gasLimitUsed,
            uint256 protocolFee,
            string memory chainNamespace
        )
    {
        if (gasLimit == 0) {
            gasLimitUsed = IUniversalCore(UNIVERSAL_CORE).BASE_GAS_LIMIT();
        } else {
            gasLimitUsed = gasLimit;
        }

        (gasToken, gasFee, protocolFee, chainNamespace) =
            IUniversalCore(UNIVERSAL_CORE).withdrawGasFeeWithGasLimit(token, gasLimitUsed);

        if (gasToken == address(0) || gasFee + protocolFee == 0) {
            revert Errors.InvalidData();
        }
    }

    /**
     * @dev     Swap native PC → gas token PRC20 via UniversalCore. Burns gasFee, sends protocolFee to VaultPC.
     *          UniversalCore refunds any unused PC directly to the caller.
     * @param gasToken     Gas token PRC20 address (e.g., pETH).
     * @param pcAmount     Native PC amount (msg.value) to swap.
     * @param gasFee       Gas cost portion to burn (in gas token units).
     * @param protocolFee  Protocol fee portion to send to VaultPC (in gas token units).
     */
    function _swapAndCollectFees(address gasToken, uint256 pcAmount, uint256 gasFee, uint256 protocolFee) internal {
        if (pcAmount == 0) revert Errors.ZeroAmount();
        address vault = address(VAULT_PC);
        if (vault == address(0)) revert Errors.ZeroAddress();

        IUniversalCore(UNIVERSAL_CORE).swapAndBurnGas{ value: pcAmount }(
            gasToken, vault, 0, gasFee, protocolFee, 0, msg.sender
        );
    }

    /// @dev Pulls PRC20 from `from` into this contract, then burns them.
    function _burnPRC20(address from, address token, uint256 amount) internal {
        // Pull PRC20 into this gateway first
        IPRC20(token).transferFrom(from, address(this), amount);

        // Then burn from this contract's balance
        bool ok = IPRC20(token).burn(amount);
        if (!ok) revert Errors.TokenBurnFailed(token, amount);
    }
}
