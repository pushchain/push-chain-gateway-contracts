// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IUniversalCore {

    /**
     * @notice Check if a token is supported
     * @param token Token address
     * @return bool True if the token is supported, false otherwise
     */
    function isSupportedToken(address token) external view returns (bool);

    /**
     * @notice Get gas token PRC20 address for a chain
     * @param chainId Chain ID
     * @return gasToken Gas token address
     */
    function gasTokenPRC20ByChainId(string memory chainId) external view returns (address gasToken);

    /**
     * @notice Get gas price for a chain
     * @param chainId Chain ID
     * @return price Gas price
     */
    function gasPriceByChainId(string memory chainId) external view returns (uint256 price);

    /**
     * @notice Get base gas limit for a chain
     * @return baseGasLimit Base gas limit
     */
    function BASE_GAS_LIMIT() external view returns (uint256 baseGasLimit);

    /**
     * @notice Get the Universal Executor Module address
     * @return executorModule Universal Executor Module address
     */
    function UNIVERSAL_EXECUTOR_MODULE() external view returns (address executorModule);

    /**
     * @notice Get gas fee for a PRC20 token.
     * @dev    Uses BASE_GAS_LIMIT for the gas limit used in the fee computation.
     * @param _prc20 PRC20 address
     * @return gasToken Gas token address
     * @return gasFee Gas fee
     */
    function withdrawGasFee(address _prc20) external view returns (address gasToken, uint256 gasFee);

    /**
     * @notice Get gas fee for a PRC20 token with a custom gas limit
     * @dev    Uses the provided gas limit for the fee computation.
     * @param _prc20 PRC20 address
     * @param gasLimit Gas limit
     * @return gasToken Gas token address
     * @return gasFee Gas fee
     */
    function withdrawGasFeeWithGasLimit(address _prc20, uint256 gasLimit) external view returns (address gasToken, uint256 gasFee);
}