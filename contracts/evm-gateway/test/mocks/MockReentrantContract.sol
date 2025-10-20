// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;


import { IUniversalGatewayPC } from "../../src/interfaces/IUniversalGatewayPC.sol";
import { RevertInstructions } from "../../src/libraries/Types.sol";

/**
 * @title MockReentrantContract
 * @notice Mock contract that attempts to reenter the UniversalGatewayPC contract
 * @dev Used for testing reentrancy protection
 */
contract MockReentrantContract {
    address public gateway;
    address public prc20Token;
    address public gasToken;

    constructor(address _gateway, address _prc20Token, address _gasToken) {
        gateway = _gateway;
        prc20Token = _prc20Token;
        gasToken = _gasToken;
    }

    function attemptReentrancy(
        bytes calldata to,
        uint256 amount,
        uint256 gasLimit,
        RevertInstructions calldata revertCfg
    ) external {
        IUniversalGatewayPC(gateway).withdraw(to, prc20Token, amount, gasLimit, revertCfg);
    }

    function attemptReentrancyWithExecute(
        bytes calldata target,
        uint256 amount,
        bytes calldata payload,
        uint256 gasLimit,
        RevertInstructions calldata revertCfg
    ) external {
        IUniversalGatewayPC(gateway).withdrawAndExecute(
            target, 
            prc20Token, 
            amount, 
            payload, 
            gasLimit, 
            revertCfg
        );
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}