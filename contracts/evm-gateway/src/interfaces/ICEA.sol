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
     * @param uea     UEA on Push Chain that this CEA represents.
     * @param token   ERC20 token to be used for the operation (address(0) if purely native / no-ERC20 op).
     * @param target  Target protocol contract to call.
     * @param amount  Amount of `token` to make available to `target` (used for allowance).
     * @param payload Calldata to forward to `target`.
     */
    function executeUniversalTx(
        bytes32 txID,
        address uea,
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
        address uea,
        address target,
        uint256 amount,
        bytes calldata payload
    ) external payable;
}