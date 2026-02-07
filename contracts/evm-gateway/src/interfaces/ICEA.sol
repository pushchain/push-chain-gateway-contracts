// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @dev Interface for CEA tokens
 */
interface ICEA {
        /**
     * @notice Executes a call against an external target on behalf of the UEA,
     *         using tokens that are already held by this CEA.
     *
     * @dev
     *  - Only callable by Vault.
     *  - Typical usage pattern:
     *      1. Vault transfers `amount` of `token` into this CEA.
     *      2. Vault calls executeUniversalTx(txID, uea, token, target, amount, payload).
     *      3. CEA safe-approves `target` for `amount` and then calls `target` with `data`.
     *  - This ensures the external protocol sees `msg.sender == CEA`, not Vault.
     *
     * @param txID    Transaction ID of the UniversalTx to execute.
     * @param universalTxID universal transaction identifier
     * @param originCaller    UEA address on Push Chain
     * @param token   ERC20 token to be used for the operation (address(0) if purely native / no-ERC20 op).
     * @param target  Target protocol contract to call.
     * @param amount  Amount of `token` to make available to `target` (used for allowance).
     * @param payload Calldata to forward to `target`.
     */
    function executeUniversalTx(
        bytes32 txID,
        bytes32 universalTxID,
        address originCaller,
        address token,
        address target, 
        uint256 amount,
        bytes calldata payload
    ) external;

    /**
     * @notice Executes a call against an external target on behalf of the UEA,
     *         using native tokens that are already held by this CEA.
     *
     * @dev
     *  - Only callable by Vault.
     *  - Typical usage pattern:
     *      1. Vault transfers `amount` of native tokens into this CEA.
     *      2. Vault calls executeUniversalTx(txID, uea, target, amount, payload).
     *      3. CEA calls `target` with `payload` and `amount` of native tokens.
     */
    function executeUniversalTx(
        bytes32 txID,
        bytes32 universalTxID,
        address originCaller,
        address target,
        uint256 amount,
        bytes calldata payload
    ) external payable;

    /**
     * @notice Withdraws tokens to a specified recipient (withdrawal path)
     *
     * @dev
     *  - Only callable by Vault.
     *  - Called when payload is empty (withdrawal signal).
     *  - Supports token parking: if `to == address(this)`, tokens remain in CEA.
     *  - Typical usage pattern:
     *      1. Vault transfers tokens to CEA (native or ERC20).
     *      2. Vault calls withdrawTo(txID, universalTxID, originCaller, token, to, amount).
     *      3. CEA transfers tokens directly to recipient (or parks them if to == address(this)).
     *
     * @param txID           Transaction ID of the UniversalTx to execute.
     * @param universalTxID  Universal transaction identifier from Push Chain.
     * @param originCaller   UEA address on Push Chain (must match CEA's UEA).
     * @param token          Token address (address(0) for native tokens).
     * @param to             Recipient address (can be user, contract, or address(this) for parking).
     * @param amount         Amount to withdraw (must be > 0).
     */
    function withdrawTo(
        bytes32 txID,
        bytes32 universalTxID,
        address originCaller,
        address token,
        address to,
        uint256 amount
    ) external payable;
}