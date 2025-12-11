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
import { IPC20 } from "./interfaces/IPC20.sol";
import { IPC721 } from "./interfaces/IPC721.sol";
import { IVaultPC } from "./interfaces/IVaultPC.sol";
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
    /// @notice outboundMode type on Push Chain
    enum OutboundMode {
      FUNDS,
      PAYLOAD,
      FUNDS_AND_PAYLOAD
    }

    /// @notice outboundMode type on Push Chain
    enum AssetType { NONE, PRC20, PC20, PC721 }

    /// @notice Pauser role for pausing the contract.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice UniversalCore on Push Chain (provides gas coin/prices + UEM address).
    address public UNIVERSAL_CORE;

    /// @notice VaultPC on Push Chain (custody vault for fees collected from outbound flows).
    IVaultPC public VAULT_PC;

    // ERC type detection constants
    bytes4 private constant _INTERFACE_ID_ERC165 = 0x01ffc9a7;
    bytes4 private constant _INTERFACE_ID_ERC721 = 0x80ac58cd;

    // Outbound Tx Nonce
    uint256 public outboundTxNonce;

    // Magic Marker
    bytes4 constant MAGIC_PCAS = 0x50434153; // "PCAS"
    uint8  private constant META_VERSION = 1;
    uint8  private constant META_KIND_PC20 = 1;
    uint8  private constant META_KIND_PC721 = 2;

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

    /// TODO: define specs
    function sendUniversalTxOutbound(
      bytes calldata target,          // origin target
      address token,                  // PRC20 / PC20 / PC721, or 0 for payload-only
      uint256 amount,                 // fungible amount (for PRC20 / PC20)
      uint256 tokenId,                // NFT id (for PC721)
      uint256 gasLimit,
      bytes calldata payload,         // optional payload
      string calldata chainNamespace, // chain namespace, e.g. "eip155:1"
      RevertInstructions calldata revertInstruction
  ) external payable whenNotPaused nonReentrant {
      if (target.length == 0) revert Errors.InvalidInput();
      if (revertInstruction.fundRecipient == address(0)) revert Errors.InvalidRecipient();
      if (token == address(0) && (amount != 0 || tokenId != 0)) revert Errors.ZeroAddress();
      if (token == address(0) && payload.length == 0) revert Errors.InvalidTxType();

      // Generate canonical txId
      uint256 nonce = outboundTxNonce;
      outboundTxNonce = nonce + 1;

      bytes32 txId = keccak256(
          abi.encode(
              bytes32("PUSH.OUTBOUND.TX"),
              msg.sender,
              token,
              amount,
              tokenId,
              keccak256(payload),
              keccak256(bytes(chainNamespace)),
              nonce
          )
      );

      OutboundMode oMode;
      AssetType aType;

      bool hasPayload        = payload.length != 0;
      bool hasToken          = token != address(0);
      bool hasFungible       = amount != 0;
      bool hasNFT            = tokenId != 0;
      bool hasChainNamespace = bytes(chainNamespace).length != 0;

      if (!hasToken) {
          // payload only
          if (!hasPayload) revert Errors.InvalidTxType();
          if (hasFungible || hasNFT) revert Errors.InvalidInput();
          if (!hasChainNamespace) revert Errors.InvalidInput();

          oMode = OutboundMode.PAYLOAD;
          aType = AssetType.NONE;
      } else {
          // token present
          if (!hasFungible && !hasNFT) revert Errors.InvalidAmount();
          if (hasFungible && hasNFT) revert Errors.InvalidInput();

          oMode = hasPayload ? OutboundMode.FUNDS_AND_PAYLOAD : OutboundMode.FUNDS;

          IUniversalCore core = IUniversalCore(UNIVERSAL_CORE);

          if (core.isSupportedToken(token)) {
              // PRC20
              if (!hasFungible || hasNFT) revert Errors.InvalidAmount();
              aType = AssetType.PRC20;
          } else if (_isERC20(token)) {
              // PC20
              if (!hasFungible || hasNFT) revert Errors.InvalidAmount();
              if (!core.isPC20SupportedOnChain(chainNamespace)) revert Errors.InvalidInput();
              if (!hasChainNamespace) revert Errors.InvalidInput();
              aType = AssetType.PC20;
              oMode = OutboundMode.FUNDS_AND_PAYLOAD; // carry magic marker in the payload
          } else if (_isERC721(token)) {
              // PC721
              if (!hasNFT || hasFungible) revert Errors.InvalidAmount();
              if (!core.isPC721SupportedOnChain(chainNamespace)) revert Errors.InvalidInput();
              if (!hasChainNamespace) revert Errors.InvalidInput();
              aType = AssetType.PC721;
              oMode = OutboundMode.FUNDS_AND_PAYLOAD; // carry magic marker in the payload
          } else {
              revert Errors.TokenNotSupported();
          }
      }

      (address gasToken, uint256 gasFee, uint256 gasLimitUsed, uint256 protocolFee) =
          _calculateGasFeesWithLimit(token, gasLimit, aType);

      if (aType == AssetType.PRC20) {
          _moveFees(msg.sender, gasToken, gasFee);
          _burnPRC20(msg.sender, token, amount);

          string memory sourceChainId = IPRC20(token).SOURCE_CHAIN_ID();
          emit UniversalTxOutbound(
              txId,
              msg.sender,
              token,
              sourceChainId,
              target,
              amount,
              gasToken,
              gasFee,
              gasLimitUsed,
              payload,
              protocolFee,
              revertInstruction
          );
      } else {
          // NONE, PC20, PC721 use native PC for fees
          _moveFeesNative(gasFee);

          bytes memory finalPayload;
          
          if (aType == AssetType.PC20) {
              _movePC20(msg.sender, token, amount);
              
              // generate and append magic marker in the payload
              IPC20 meta = IPC20(token);

              bytes memory enrichedPayload = abi.encode(
                  MAGIC_PCAS,                 // bytes4
                  META_VERSION,               // uint8
                  META_KIND_PC20,             // uint8
                  token,                      // address
                  meta.name(),                // string
                  meta.symbol(),              // string
                  meta.decimals()             // uint8
              );

              finalPayload = abi.encodePacked(enrichedPayload, payload);

          } else if (aType == AssetType.PC721) {
              _movePC721(msg.sender, token, tokenId);

              // generate and append magic marker in the payload
              IPC721 meta = IPC721(token);

              bytes memory enrichedPayload = abi.encode(
                  MAGIC_PCAS,                 // bytes4
                  META_VERSION,               // uint8
                  META_KIND_PC721,            // uint8
                  token,                      // address
                  meta.name(),                // string
                  meta.symbol(),              // string
                  uint8(0)                    // decimals fixed to 0 for NFTs
              );

              finalPayload = abi.encodePacked(enrichedPayload, payload);
          }

          emit UniversalTxOutbound(
              txId,
              msg.sender,
              token,
              chainNamespace,
              target,
              amount,
              address(0), // native PC as fee currency
              gasFee,
              gasLimitUsed,
              finalPayload,
              protocolFee,
              revertInstruction
          );
      }
  }


    // ========= Helpers =========

    /**
     * @dev                 Use UniversalCore's withdrawGasFeeWithGasLimit to compute fee (gas coin + amount).
     *                          If gasLimit = 0, pull the default BASE_GAS_LIMIT from UniversalCore.
     * @return gasToken     PRC20 address to be used for fee payment.
     * @return gasFee       amount of gasToken to collect from the user (includes protocol fee).
     * @return gasLimitUsed gas limit actually used for the quote.
     * @return protocolFee  the flat protocol fee component (as exposed by PRC20).
     */
    function _calculateGasFeesWithLimit(address token, uint256 gasLimit, AssetType aType)
        internal
        view
        returns (address gasToken, uint256 gasFee, uint256 gasLimitUsed, uint256 protocolFee)
    {
        IUniversalCore core = IUniversalCore(UNIVERSAL_CORE);

        gasLimitUsed = gasLimit == 0
            ? core.BASE_GAS_LIMIT()
            : gasLimit;

        if (aType == AssetType.PRC20) {
            (gasToken, gasFee) = core.withdrawGasFeeWithGasLimit(token, gasLimitUsed);
            if (gasToken == address(0) || gasFee == 0) revert Errors.InvalidData();
            protocolFee = IPRC20(token).PC_PROTOCOL_FEE();
        } else if (aType == AssetType.PC20) {
            protocolFee = core.PC20_PROTOCOL_FEES();
            gasFee = protocolFee; // native PC
        } else if (aType == AssetType.PC721) {
            protocolFee = core.PC721_PROTOCOL_FEES();
            gasFee = protocolFee; // native PC
        } else {
            protocolFee = core.DEFAULT_PROTOCOL_FEES();
            gasFee = protocolFee; // payload only, native PC
        }
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

    /**
     * @dev     Pull native fee from user into the VaultPC.
     */
    function _moveFeesNative(uint256 gasFee) internal {
        address _vaultPC = address(VAULT_PC);
        if (_vaultPC == address(0)) revert Errors.ZeroAddress();
        if (gasFee == 0) return;

        if (msg.value < gasFee) revert Errors.InvalidAmount();

        (bool ok, ) = _vaultPC.call{value: gasFee}("");
        if (!ok) revert Errors.GasFeeTransferFailed(address(0), msg.sender, gasFee);

        uint256 refund = msg.value - gasFee;
        if (refund > 0) {
            (bool refundOk, ) = msg.sender.call{value: refund}("");
            if (!refundOk) revert Errors.RefundFailed(msg.sender, refund);
        }
    }


    function _burnPRC20(address from, address token, uint256 amount) internal {
        // Pull PRC20 into this gateway first
        IPRC20(token).transferFrom(from, address(this), amount);

        // Then burn from this contract's balance
        bool ok = IPRC20(token).burn(amount);
        if (!ok) revert Errors.TokenBurnFailed(token, amount);
    }

    function _movePC20(address from, address token, uint256 amount) internal {
        bool ok = IPC20(token).transferFrom(from, address(this), amount);
       // TODO: @Zaryab
       // if (!ok) revert Errors.TokenTransferFailed(token, amount);
    }

    function _movePC721(address from, address token, uint256 tokenId) internal {
        IPC721(token).transferFrom(from, address(this), tokenId);

       // TODO: @Zaryab
       // if (!ok) revert Errors.NFTTransferFailed(token, tokenId);
    }

    // ----- ERC type detection -----

    function _isERC721(address token) internal view returns (bool) {
        (bool ok, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(_INTERFACE_ID_ERC165, _INTERFACE_ID_ERC721)
        );
        return ok && data.length == 32 && abi.decode(data, (bool));
    }

    function _isERC20(address token) internal view returns (bool) {
        if (_isERC721(token)) return false;

        (bool ok1, bytes memory data1) =
            token.staticcall(abi.encodeWithSelector(bytes4(keccak256("totalSupply()"))));
        if (!ok1 || data1.length != 32) return false;

        (bool ok2, bytes memory data2) =
            token.staticcall(abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), address(this)));
        if (!ok2 || data2.length != 32) return false;

        return true;
    }
}
