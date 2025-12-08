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


    /**
     * @notice Protocol fee applied to PC20 withdrawals and flows that use PC20 as the asset.
     * @return fee Protocol fee for PC20 in PC units.
     */
    function PC20_PROTOCOL_FEES() external view returns (uint256 fee);

    /**
     * @notice Protocol fee applied to PC721 withdrawals and flows that use PC721 as the asset.
     * @return fee Protocol fee for PC721 in PC units.
     */
    function PC721_PROTOCOL_FEES() external view returns (uint256 fee);

    /**
     * @notice Default protocol fee used when the asset type does not match PC20, PC721 or PRC20.
     * @return fee Default protocol fee in PC units.
     */
    function DEFAULT_PROTOCOL_FEES() external view returns (uint256 fee);

    /**
     * @notice Check if PC20 assets are supported for a given external chain namespace.
     * @param chainNamespace Chain namespace identifier (for example "eip155:1").
     * @return supported True if PC20 is supported on this chain, false otherwise.
     */
    function isPC20SupportedOnChain(string calldata chainNamespace)
        external
        view
        returns (bool supported);

    /**
     * @notice Check if PC721 assets are supported for a given external chain namespace.
     * @param chainNamespace Chain namespace identifier (for example "eip155:1").
     * @return supported True if PC721 is supported on this chain, false otherwise.
     */
    function isPC721SupportedOnChain(string calldata chainNamespace)
        external
        view
        returns (bool supported);
}