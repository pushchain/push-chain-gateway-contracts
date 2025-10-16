// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IPRC20 {

    function SOURCE_CHAIN_ID() external view returns (string memory);
    function GAS_LIMIT() external view returns (uint256);
    function PC_PROTOCOL_FEE() external view returns (uint256);

    // ERC20 subset
    function decimals() external view returns (uint8);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);

    // PRC20 extensions
    function withdrawGasFee() external view returns (address gasToken, uint256 gasFee);
    function withdrawGasFeeWithGasLimit(uint256 gasLimit) external view returns (address gasToken, uint256 gasFee);
    function burn(uint256 amount) external returns (bool);
}