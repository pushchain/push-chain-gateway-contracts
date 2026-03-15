// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @dev Interface for PRC20 tokens — only the functions used by contracts in this repo.
 */
interface IPRC20 {
    function burn(uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}
