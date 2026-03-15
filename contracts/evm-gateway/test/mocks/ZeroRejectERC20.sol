// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { MockERC20 } from "./MockERC20.sol";

/// @dev ERC20 that reverts on zero-amount transfers, simulating early BNB / some non-standard tokens
contract ZeroRejectERC20 is MockERC20 {
    constructor() MockERC20("ZeroReject", "ZRT", 18, 0) { }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(amount > 0, "ZeroRejectERC20: zero transfer");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(amount > 0, "ZeroRejectERC20: zero transfer");
        return super.transferFrom(from, to, amount);
    }
}
