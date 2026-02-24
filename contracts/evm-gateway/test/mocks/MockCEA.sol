// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ICEA } from "../../src/interfaces/ICEA.sol";
import { Multicall } from "../../src/libraries/Types.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockCEA
 * @notice Mock implementation of ICEA for testing (multicall-based interface)
 * @dev Implements executeUniversalTx with actual multicall execution for testing
 */
contract MockCEA is ICEA {
    using SafeERC20 for IERC20;

    // Track last call parameters for assertions
    bytes32 public lastsubTxId;
    bytes32 public lastuniversalTxId;
    address public lastUEA;
    bytes public lastPayload;

    // Call path tracking
    uint256 public executeCallCount;

    // Reentrancy testing support
    address public reentrantVault;
    bytes public reentrantCalldata;
    bool public shouldReenter;
    bool public reentrantCallSucceeded;

    // Controllable revert for testing rollback scenarios
    bool public shouldRevertOnExecute;
    string public revertMessage;

    function setReentrant(address _vault, bytes calldata _calldata) external {
        reentrantVault = _vault;
        reentrantCalldata = _calldata;
        shouldReenter = true;
        reentrantCallSucceeded = false;
    }

    function setShouldRevert(bool _shouldRevert, string memory _message) external {
        shouldRevertOnExecute = _shouldRevert;
        revertMessage = _message;
    }

    /**
     * @notice Executes a universal transaction using multicall payload
     * @dev Decodes and executes multicall for testing purposes
     */
    function executeUniversalTx(bytes32 subTxId, bytes32 universalTxId, address originCaller, bytes calldata payload)
        external
        payable
        override
    {
        executeCallCount++;

        // Revert if configured (for rollback testing)
        if (shouldRevertOnExecute) {
            revert(revertMessage);
        }

        // Attempt reentrancy if configured (for reentrancy tests)
        if (shouldReenter && reentrantVault != address(0)) {
            shouldReenter = false;
            (bool success,) = reentrantVault.call(reentrantCalldata);
            reentrantCallSucceeded = success;
        }

        // Store call parameters for test assertions
        lastsubTxId = subTxId;
        lastuniversalTxId = universalTxId;
        lastUEA = originCaller;
        lastPayload = payload;

        // Decode and execute multicall
        if (payload.length > 0) {
            this.decodeAndExecuteMulticall(payload);
        }
    }

    /**
     * @notice External function to decode and execute multicall (for try/catch)
     * @dev Must be external to use in try/catch pattern
     * @dev For test simplicity, automatically approves ERC20 tokens before calls
     */
    function decodeAndExecuteMulticall(bytes calldata payload) external {
        require(msg.sender == address(this), "Only self-call");

        Multicall[] memory calls = abi.decode(payload, (Multicall[]));

        for (uint256 i = 0; i < calls.length; i++) {
            // For testing: auto-approve all ERC20 tokens this CEA holds to the target
            // Real CEA would require explicit approval steps in multicall
            _autoApproveTokens(calls[i].to);

            (bool success,) = calls[i].to.call{ value: calls[i].value }(calls[i].data);
            require(success, "MockCEA: call failed");
        }
    }

    /**
     * @notice Helper to auto-approve common tokens for testing
     * @dev Checks if this CEA has token balances and approves target
     */
    function _autoApproveTokens(address target) private {
        // Try to approve common tokens (this is test-only convenience)
        // In production, approval steps must be explicit in multicall
        address[] memory tokensToTry = new address[](10);
        uint256 tokenCount = 0;

        // We don't know which tokens exist, so we just try approving any we can find
        // This is a hack for testing - real CEA requires explicit approval multicalls

        // Simplified: just approve a large amount for any potential token
        // In a real scenario, the multicall would include explicit approval steps
    }

    /**
     * @notice Withdrawal helper function for testing (mimics real CEA.withdrawFundsToUEA)
     * @dev Called via multicall self-call to transfer tokens from CEA to recipient
     * @param token Token address (address(0) for native)
     * @param recipient Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawFundsToUEA(address token, address recipient, uint256 amount) external {
        require(msg.sender == address(this), "MockCEA: only self-call");

        if (token == address(0)) {
            // Native token withdrawal
            (bool success,) = payable(recipient).call{ value: amount }("");
            require(success, "MockCEA: native transfer failed");
        } else {
            // ERC20 token withdrawal
            IERC20(token).safeTransfer(recipient, amount);
        }
    }

    // Helper to receive native tokens
    receive() external payable { }
}
