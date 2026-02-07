// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.26;

// import {ICEA} from "../interfaces/ICEA.sol";
// import {CEAErrors} from "../libraries/Errors.sol";
// import {IUniversalGateway,
//             UniversalTxRequest,
//                 RevertInstructions} from "../interfaces/IUniversalGateway.sol";

// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// /**
//  * @title   CEA
//  * @notice  Chain Executor Account implementation (v1).
//  *
//  * @dev
//  *  - Intended to be deployed behind a minimal proxy (Clones) by CEAFactory.
//  *  - Represents a single UEA on Push Chain on a specific external EVM chain.
//  *  - In v1:
//  *      * Only Vault may call state-changing functions.
//  *      * CEA can:
//  *          - execute calls to external protocols using ERC20 balances it holds.
//  *          - withdraw tokens to specified recipients (including token parking in CEA itself).
//  *          - send tokens back to Vault when requested.
//  *      * No direct user / EOA interaction. No signatures. No owner.
//  */
// contract CEA is ICEA, ReentrancyGuard {
//     using SafeERC20 for IERC20;

//     //========================
//     //           State
//     //========================

//     /// @inheritdoc ICEA
//     address public UEA;
//     /// @inheritdoc ICEA
//     address public VAULT;
//     /// @notice Address of the Universal Gateway contract of the respective chain.
//     address public UNIVERSAL_GATEWAY;

//     bool private _initialized;

//     /// @notice Mapping from txID to bool to check if the tx has been executed
//     mapping (bytes32 => bool) public isExecuted;

//     bytes4 private constant WITHDRAW_FUNDS_SELECTOR = bytes4(keccak256("withdrawFundsToUEA(address,uint256)"));

//     //========================
//     //        Modifiers
//     //========================

//     modifier onlyVault() {
//         if (msg.sender != VAULT) revert CEAErrors.NotVault();
//         _;
//     }

//     //========================
//     //        Views
//     //========================

//     /// @inheritdoc ICEA
//     function isInitialized() external view override returns (bool) {
//         return _initialized;
//     }

//     //========================
//     //       Initializer
//     //========================

//     /// @notice         Initializes this CEA with its UEA identity, Vault and Universal Gateway.
//     /// @param _uea     Address of the UEA contract on Push Chain.
//     /// @param _vault   Address of the Vault contract on this chain.
//     /// @param _universalGateway Address of the Universal Gateway contract of the respective chain.
//     function initializeCEA(address _uea, address _vault, address _universalGateway) external {
//             if (_initialized) revert CEAErrors.AlreadyInitialized();
//         if (_uea == address(0) ||
//             _vault == address(0) ||
//                 _universalGateway == address(0)) revert CEAErrors.ZeroAddress();

//         UEA = _uea;
//         VAULT     = _vault;
//         UNIVERSAL_GATEWAY = _universalGateway;

//         _initialized = true;

//     }

//     //========================
//     //      Vault-only ops
//     //========================

//     function executeUniversalTx(
//         bytes32 txID,
//         bytes32 universalTxID,
//         address originCaller,
//         address token,
//         address target,
//         uint256 amount,
//         bytes calldata payload
//         ) external onlyVault nonReentrant {

//         if (target == address(this)) {
//             _handleSelfCalls(txID, universalTxID, originCaller, payload);
//             return;
//         }

//         _validateExecuteUniversalTxParams(txID, originCaller, token, target, amount);

//         isExecuted[txID] = true;

//         _resetApproval(token, target);                // reset approval to zero
//         _safeApprove(token, target, amount);        // approve target to spend amount
//         _executeCall(target, payload, 0);            // execute call with required amount
//         _resetApproval(token, target);               // reset approval back to zero

//         emit UniversalTxExecuted(txID, universalTxID, originCaller, target, token, amount, payload);
//     }

//     function executeUniversalTx(
//         bytes32 txID,
//         bytes32 universalTxID,
//         address originCaller,
//         address target,
//         uint256 amount,
//         bytes calldata payload
//     ) external payable onlyVault nonReentrant {

//         if (target == address(this)) {
//             _handleSelfCalls(txID, universalTxID, originCaller, payload);
//             return;
//         }

//         _validateExecuteUniversalTxParams(txID, originCaller, address(0), target, amount);

//         isExecuted[txID] = true;

//         _executeCall(target, payload, amount);

//         emit UniversalTxExecuted(txID, universalTxID, originCaller, target, address(0), amount, payload);
//     }

//     /// @notice             Withdraw tokens to a specified recipient (withdrawal path)
//     /// @dev                Called by Vault when payload is empty (withdrawal signal).
//     ///                     Supports token parking: if `to == address(this)`, tokens remain in CEA.
//     ///                     Parked tokens can be retrieved later via withdrawFundsToUEA().
//     /// @param txID         Unique transaction identifier (for replay protection)
//     /// @param universalTxID Universal transaction ID from Push Chain
//     /// @param originCaller  Original caller on Push Chain (must be UEA)
//     /// @param token         Token address (address(0) for native)
//     /// @param to            Recipient address (can be user, contract, or address(this) for parking)
//     /// @param amount        Amount to withdraw (must be > 0)
//     function withdrawTo(
//         bytes32 txID,
//         bytes32 universalTxID,
//         address originCaller,
//         address token,
//         address to,
//         uint256 amount
//     ) external payable onlyVault nonReentrant {
//         // Replay protection
//         if (isExecuted[txID]) revert CEAErrors.PayloadExecuted();
//         if (originCaller != UEA) revert CEAErrors.InvalidUEA();
//         if (to == address(0)) revert CEAErrors.InvalidTarget();
//         if (amount == 0) revert CEAErrors.InvalidAmount();

//         // Mark as executed
//         isExecuted[txID] = true;

//         // SPECIAL CASE: Token parking in CEA
//         // When to == address(this), tokens are "parked" in the CEA for future use
//         // No transfer needed - tokens already sent by Vault to CEA
//         if (to == address(this)) {
//             emit UniversalTxExecuted(txID, universalTxID, originCaller, to, token, amount, bytes(""));
//             return;
//         }

//         // Transfer tokens to recipient
//         if (token == address(0)) {
//             // Native token withdrawal
//             if (msg.value != amount) revert CEAErrors.InvalidAmount();
//             (bool success, ) = payable(to).call{value: amount}("");
//             if (!success) revert CEAErrors.WithdrawFailed();
//         } else {
//             // ERC20 token withdrawal
//             if (msg.value != 0) revert CEAErrors.InvalidAmount();
//             if (IERC20(token).balanceOf(address(this)) < amount) revert CEAErrors.InsufficientBalance();
//             IERC20(token).safeTransfer(to, amount);
//         }

//         emit UniversalTxExecuted(txID, universalTxID, originCaller, to, token, amount, bytes(""));
//     }

//     function withdrawFundsToUEA(address token, uint256 amount) private {
//         UniversalTxRequest memory req = UniversalTxRequest({
//             recipient: UEA,
//             token: token,
//             amount: amount,
//             payload: "",
//             revertInstruction: RevertInstructions({
//                 fundRecipient: UEA,
//                 revertMsg: ""
//             }),
//             signatureData: ""
//         });

//         if (token == address(0)) {
//             if (address(this).balance < amount ) revert CEAErrors.InsufficientBalance();
//             IUniversalGateway(UNIVERSAL_GATEWAY).sendUniversalTx{value: amount}(req);
//         } else {
//             if (IERC20(token).balanceOf(address(this)) < amount) revert CEAErrors.InsufficientBalance();

//             _resetApproval(token, UNIVERSAL_GATEWAY);
//             _safeApprove(token, UNIVERSAL_GATEWAY, amount);
//             IUniversalGateway(UNIVERSAL_GATEWAY).sendUniversalTx(req);
//         }

//         emit WithdrawalToUEA(address(this), UEA, token, amount);
//     }




//     //========================
//     //      Internal Helpers
//     //========================

//     function _validateExecuteUniversalTxParams(
//         bytes32 txID,
//         address originCaller,
//         address token,
//         address target,
//         uint256 amount
//     ) internal view {
//         if (isExecuted[txID]) revert CEAErrors.PayloadExecuted();
//         if (originCaller != UEA) revert CEAErrors.InvalidUEA();
//         if (target == address(0)) revert CEAErrors.InvalidTarget();

//         if (token != address(0)) {
//             if (msg.value != 0) revert CEAErrors.InvalidAmount();
//             if (IERC20(token).balanceOf(address(this)) < amount) revert CEAErrors.InsufficientBalance();
//         } else {
//             if (msg.value != amount ) revert CEAErrors.InvalidAmount();
//         }

//     }

//     /// @dev Safely reset approval to zero before granting any new allowance to target contract.
//     function _resetApproval(address token, address spender) internal {
//         (bool success, bytes memory returnData) =
//             token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
//         if (!success) {
//             // Some non-standard tokens revert on zero-approval; treat as reset-ok to avoid breaking the flow.
//             return;
//         }
//         // If token returns a boolean, ensure it is true; if no return data, assume success (USDT-style).
//         if (returnData.length > 0) {
//             bool approved = abi.decode(returnData, (bool));
//             if (!approved) revert CEAErrors.InvalidInput();
//         }
//     }

//     /// @dev Safely approve ERC20 token spending to a target contract.
//     ///      Low-level call must succeed AND (if returns data) decode to true; otherwise revert.
//     function _safeApprove(address token, address spender, uint256 amount) internal {
//         (bool success, bytes memory returnData) =
//             token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
//         if (!success) {
//             revert CEAErrors.InvalidInput(); // approval failed
//         }
//         if (returnData.length > 0) {
//             bool approved = abi.decode(returnData, (bool));
//             if (!approved) {
//                 revert CEAErrors.InvalidInput(); // approval failed
//             }
//         }
//     }

//     /// @dev Unified helper to execute a low-level call to target
//     ///      Call can be executed with native value or ERC20 token. 
//     ///      Reverts with Errors.ExecutionFailed() if the call fails (no bubbling).
//     function _executeCall(address target, bytes calldata payload, uint256 value) internal returns (bytes memory result) {
//         (bool success, bytes memory ret) = target.call{value: value}(payload);
//         if (!success) revert CEAErrors.ExecutionFailed();
//         return ret;
//     }

//     function _handleSelfCalls(bytes32 txID, bytes32 universalTxID, address originCaller, bytes calldata payload) internal {
//         if (isExecuted[txID]) revert CEAErrors.PayloadExecuted();
//         if (originCaller != UEA) revert CEAErrors.InvalidUEA();
//         // Need at least 4 bytes for selector
//         if (payload.length < 4) revert CEAErrors.InvalidInput();

//         // Extract function selector from the first 4 bytes of payload
//         bytes4 selector = bytes4(payload);

//         // the ONLY allowed self-call is withdrawFundsToUEA(address,uint256)
//         if (selector != WITHDRAW_FUNDS_SELECTOR) {
//             revert CEAErrors.InvalidTarget();
//         }

//         (address token, uint256 amount) = abi.decode(payload[4:], (address, uint256));


//         isExecuted[txID] = true;
//         withdrawFundsToUEA(token, amount);
//         emit UniversalTxExecuted(txID, universalTxID, originCaller, address(this), token, amount, payload);
// }

//     //========================
//     //         Receive
//     //========================

//     /**
//      * @notice Allow this CEA to receive native tokens if needed for protocol interactions.
//      */
//     receive() external payable {}
// }