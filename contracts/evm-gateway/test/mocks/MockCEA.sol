// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ICEA } from "../../src/interfaces/ICEA.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockCEA
 * @notice Mock implementation of ICEA for testing
 * @dev Implements both ERC20 and native executeUniversalTx overloads
 */
contract MockCEA is ICEA {
    using SafeERC20 for IERC20;

    // Track last call parameters for assertions
    bytes32 public lastTxID;
    bytes32 public lastUniversalTxID;
    address public lastUEA;
    address public lastToken;
    address public lastTarget;
    uint256 public lastAmount;
    bytes public lastPayload;

    /**
     * @notice ERC20 overload: Executes a call against an external target using ERC20 tokens
     * @dev Transfers tokens to target and calls it with payload
     */
    function executeUniversalTx(
        bytes32 txID,
        bytes32 universalTxID,
        address originCaller,
        address token,
        address target,
        uint256 amount,
        bytes calldata payload
    ) external payable override {
        // Store call parameters
        lastTxID = txID;
        lastUniversalTxID = universalTxID;
        lastUEA = originCaller;  
        lastToken = token;
        lastTarget = target;
        lastAmount = amount;
        lastPayload = payload;


        if (token == address(0)) {
            // Native token execution
            (bool success, ) = target.call{value: amount}(payload);
            require(success, "MockCEA: target call failed");
        } else {
            // Get token instance for SafeERC20
            IERC20 tokenInstance = IERC20(token);
            
            // Approve target to spend tokens (using forceApprove for newer OpenZeppelin)
            tokenInstance.forceApprove(target, amount);

            // Call target with payload
            (bool success, ) = target.call(payload);
            require(success, "MockCEA: target call failed");

            // Reset approval for safety (set to 0)
            tokenInstance.forceApprove(target, 0);
        }
    }

    /**
     * @notice Withdrawal function: Transfers tokens to recipient or parks them in CEA
     * @dev Implements the withdrawal path (empty payload signal)
     */
    function withdrawTo(
        bytes32 txID,
        bytes32 universalTxID,
        address originCaller,
        address token,
        address to,
        uint256 amount
    ) external payable override {
        // Store call parameters
        lastTxID = txID;
        lastUniversalTxID = universalTxID;
        lastUEA = originCaller;
        lastToken = token;
        lastTarget = to;
        lastAmount = amount;
        lastPayload = bytes("");

        // Token parking: if to == address(this), keep tokens
        if (to == address(this)) {
            return;
        }

        // Transfer tokens to recipient
        if (token == address(0)) {
            // Native token withdrawal
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "MockCEA: native transfer failed");
        } else {
            // ERC20 token withdrawal
            IERC20(token).safeTransfer(to, amount);
        }
    }

    // Helper to receive native tokens
    receive() external payable {}
}
