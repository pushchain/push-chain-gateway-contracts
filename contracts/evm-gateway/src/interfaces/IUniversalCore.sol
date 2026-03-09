// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IUniversalCore {
    /**
     * @notice Get base gas limit for a chain
     * @return baseGasLimit Base gas limit
     */
    function BASE_GAS_LIMIT() external view returns (uint256 baseGasLimit);

    /**
     * @notice Get gas fee and chain metadata for an outbound transaction with a custom gas limit.
     * @param _prc20 PRC20 address (used to resolve chain namespace)
     * @param gasLimit Gas limit
     * @return gasToken Gas token address
     * @return gasFee Gas cost only (gasPrice * gasLimit), excludes protocol fee
     * @return protocolFee Flat protocol fee in gas token units
     * @return chainNamespace Chain namespace string for the target chain
     */
    function getOutboundTxGasAndFees(address _prc20, uint256 gasLimit)
        external
        view
        returns (address gasToken, uint256 gasFee, uint256 protocolFee, string memory chainNamespace);

    function swapAndBurnGas(
        address gasToken,
        address vault,
        uint24 fee,
        uint256 gasFee,
        uint256 protocolFee,
        uint256 deadline,
        address caller
    ) external payable returns (uint256 gasTokenOut, uint256 refund);
}
