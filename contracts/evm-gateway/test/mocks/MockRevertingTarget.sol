// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title MockRevertingTarget
 * @notice Consolidated mock contract for testing various call failure scenarios
 * @dev Includes payable reverts, non-payable failures, and gas exhaustion
 */
contract MockRevertingTarget {
    /**
     * @notice Standard revert for basic revert testing
     */
    function receiveFunds() external payable {
        revert("Mock revert");
    }
    
    /**
     * @notice Gas-heavy function that causes gas exhaustion
     * @dev Consumes excessive gas to simulate out-of-gas scenarios
     */
    function receiveFundsGasHeavy() external payable {
        // Consume a lot of gas
        for (uint256 i = 0; i < 1000000; i++) {
            keccak256(abi.encode(i));
        }
    }
    
    /**
     * @notice Function that reverts with a custom message
     */
    function receiveFundsWithCustomRevert() external payable {
        revert("Custom revert message");
    }
    
    /**
     * @notice Non-payable function that fails when ETH is sent
     * @dev Replaces MockNonPayableTarget - tests ETH transfer to non-payable function
     */
    function receiveFundsNonPayable() external {
        // Non-payable function - will revert if ETH is sent
    }
}



