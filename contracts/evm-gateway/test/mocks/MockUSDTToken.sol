// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { MockERC20 } from "./MockERC20.sol";

/**
 * @title MockUSDTToken
 * @notice A mock token that simulates USDT's zero-first approval requirement
 */
contract MockUSDTToken is MockERC20 {
    constructor() MockERC20("USDT", "USDT", 6, 1000000e6) { }

    function approve(address spender, uint256 amount) public override returns (bool) {
        // USDT-style: requires zero-first approval
        if (amount > 0 && allowance(msg.sender, spender) > 0) {
            revert("USDT: Cannot approve from non-zero to non-zero");
        }

        // Otherwise, approve normally
        _approve(msg.sender, spender, amount);
        return true;
    }
}
