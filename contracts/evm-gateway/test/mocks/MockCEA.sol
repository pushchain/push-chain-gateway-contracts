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
        address uea,
        address token,
        address target,
        uint256 amount,
        bytes calldata payload
    ) external override {
        // Store call parameters
        lastTxID = txID;
        lastUEA = uea;
        lastToken = token;
        lastTarget = target;
        lastAmount = amount;
        lastPayload = payload;

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

    /**
     * @notice Native overload: Executes a call against an external target using native tokens
     * @dev Forwards native value to target with payload
     */
    function executeUniversalTx(
        bytes32 txID,
        address uea,
        address target,
        uint256 amount,
        bytes calldata payload
    ) external payable override {
        // Store call parameters
        lastTxID = txID;
        lastUEA = uea;
        lastToken = address(0);
        lastTarget = target;
        lastAmount = amount;
        lastPayload = payload;

        // Forward native value to target with payload
        (bool success, ) = target.call{value: amount}(payload);
        require(success, "MockCEA: target call failed");
    }

    // Helper to receive native tokens
    receive() external payable {}
}

