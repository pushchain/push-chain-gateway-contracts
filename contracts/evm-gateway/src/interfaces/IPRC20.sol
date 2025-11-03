// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @dev Interface for PRC20 tokens
 */
interface IPRC20 {
    /**
     * @notice ERC-20 metadata
     */
    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function SOURCE_CHAIN_ID() external view returns (string memory);
    function PC_PROTOCOL_FEE() external view returns (uint256);
    function GAS_LIMIT() external view returns (uint256);
    function withdrawGasFeeWithGasLimit(uint256 gasLimit) external view returns (address gasToken, uint256 gasFee);

    /**
     * @notice ERC-20 standard functions
     */
    function burn(uint256 amount) external returns (bool);
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);
    function deposit(address to, uint256 amount) external returns (bool);
    
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

}
