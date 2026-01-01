// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    /**
     * @notice Pull tokens and revert with reason
     */
    function pullTokensRevertWithReason(address, address, uint256) external pure {
        revert("Pull failed with reason");
    }

    /**
     * @notice Pull tokens and revert without reason
     */
    function pullTokensRevertNoReason(address, address, uint256) external pure {
        revert();
    }

    /**
     * @notice Successfully pull tokens from sender
     */
    function pullTokens(address token, address from, uint256 amount) external {
        IERC20(token).transferFrom(from, address(this), amount);
    }
}
