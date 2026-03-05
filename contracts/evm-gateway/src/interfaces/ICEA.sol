// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @dev Interface for CEA (Chain Executor Account)
 * @notice Simplified interface - all execution is via multicall payload
 */
interface ICEA {
    /**
     * @notice Executes a universal transaction using multicall payload.
     * @dev
     *  - Only callable by Vault.
     *  - Payload is ABI-encoded Multicall[] containing execution steps.
     *  - All withdrawals and executions use this single path.
     *
     * @param subTxId           Transaction ID of the UniversalTx to execute.
     * @param universalTxId  Universal transaction identifier from gateway.
     * @param originCaller   UEA address on Push Chain (must match CEA's UEA).
     * @param recipient      Decoded destination address on this chain; address(0) means hold funds in CEA.
     * @param payload        ABI-encoded Multicall[] execution steps.
     */
    function executeUniversalTx(
        bytes32 subTxId,
        bytes32 universalTxId,
        address originCaller,
        address recipient,
        bytes calldata payload
    ) external payable;
}
