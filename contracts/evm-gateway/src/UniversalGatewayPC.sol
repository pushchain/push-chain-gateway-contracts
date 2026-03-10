// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title   UniversalGatewayPC
 * @notice  Outbound gateway on Push Chain for bridging funds and payloads to external EVM chains.
 *
 * @dev     Deployed on Push Chain only. Routes three outbound TX_TYPEs: FUNDS, FUNDS_AND_PAYLOAD,
 *          and GAS_AND_PAYLOAD. PRC20 tokens are burned at request time; gas fees paid in native PC
 *          are swapped via UniversalCore — the gas-cost portion is burned (freeing backing tokens
 *          for TSS relayers) and the protocol-fee portion is sent to VaultPC as revenue.
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
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    address public UNIVERSAL_CORE;
    IVaultPC public VAULT_PC;
    uint256 public nonce;

    // =========================
    //  UGPC_1: ADMIN ACTIONS
    // =========================

    /// @param admin            Address of the admin.
    /// @param pauser           Address of the pauser.
    /// @param universalCore    Address of the UniversalCore.
    /// @param vaultPC          Address of the VaultPC.
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

    function pause() external onlyRole(PAUSER_ROLE) whenNotPaused {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) whenPaused {
        _unpause();
    }

    /// @notice Sets the VaultPC address.
    /// @param vaultPC Address of the new VaultPC.
    function setVaultPC(address vaultPC) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (vaultPC == address(0)) revert Errors.ZeroAddress();
        address oldVaultPC = address(VAULT_PC);
        VAULT_PC = IVaultPC(vaultPC);
        emit VaultPCUpdated(oldVaultPC, vaultPC);
    }

    // =========================
    //  UGPC_2: OUTBOUND TX
    // =========================

    /// @notice Sends an outbound universal transaction from Push Chain to an external chain.
    /// @param req The outbound transaction request struct.
    function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        _validateParams(req.token, req.revertRecipient);

        TX_TYPE txType = _fetchTxType(req);

        (address gasToken, uint256 gasFee, uint256 gasLimitUsed, uint256 protocolFee, string memory chainNamespace) =
            _fetchOutboundTxInfo(req.token, req.gasLimit);

        if (req.amount > 0) {
            _burnPRC20(msg.sender, req.token, req.amount);
        }

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

    // =========================
    //  UGPC_3: INTERNAL HELPERS
    // =========================

    /**
     * @notice Infers TX_TYPE from the outbound request.
     * @dev    - amount > 0, no payload  → FUNDS
     *         - amount > 0, payload     → FUNDS_AND_PAYLOAD
     *         - amount = 0, payload     → GAS_AND_PAYLOAD
     *         - amount = 0, no payload  → reverts (empty tx)
     */
    function _fetchTxType(UniversalOutboundTxRequest calldata req) private pure returns (TX_TYPE inferred) {
        bool hasPayload = req.payload.length > 0;
        bool hasFunds = req.amount > 0;

        if (!hasPayload && hasFunds) return TX_TYPE.FUNDS;
        if (hasPayload && hasFunds) return TX_TYPE.FUNDS_AND_PAYLOAD;
        if (hasPayload && !hasFunds) return TX_TYPE.GAS_AND_PAYLOAD;

        revert Errors.InvalidInput();
    }

    /// @dev Validates token and revertRecipient are non-zero.
    function _validateParams(address token, address revertRecipient) internal pure {
        if (token == address(0)) revert Errors.ZeroAddress();
        if (revertRecipient == address(0)) revert Errors.InvalidRecipient();
    }

    /**
     * @dev    Fetch gas fee quote and chain metadata from UniversalCore.
     *         If gasLimit = 0, uses BASE_GAS_LIMIT from UniversalCore.
     * @param token         PRC20 token address (used to resolve chain).
     * @param gasLimit      Caller-requested gas limit (0 = default).
     * @return gasToken     Gas token PRC20 address for the target chain.
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
        gasLimitUsed = gasLimit == 0 ? IUniversalCore(UNIVERSAL_CORE).BASE_GAS_LIMIT() : gasLimit;

        (gasToken, gasFee, protocolFee, chainNamespace) =
            IUniversalCore(UNIVERSAL_CORE).getOutboundTxGasAndFees(token, gasLimitUsed);

        if (gasToken == address(0) || gasFee + protocolFee == 0) {
            revert Errors.InvalidData();
        }
    }

    /**
     * @dev    Swap native PC → gas token PRC20 via UniversalCore.
     *         Burns gasFee, sends protocolFee to VaultPC. Refunds unused PC to caller.
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
        IPRC20(token).transferFrom(from, address(this), amount);
        bool ok = IPRC20(token).burn(amount);
        if (!ok) revert Errors.TokenBurnFailed(token, amount);
    }
}
