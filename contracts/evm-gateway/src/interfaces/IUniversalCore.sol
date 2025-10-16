// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;


interface IUniversalCore {
    function UNIVERSAL_EXECUTOR_MODULE() external view returns (address);
    function gasTokenPRC20ByChainId(string calldata chainId) external view returns (address);
    function gasPriceByChainId(string calldata chainId) external view returns (uint256);
}