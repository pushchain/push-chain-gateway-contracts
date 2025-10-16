// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockTarget {
    address public lastCaller;
    uint256 public lastAmount;
    address public lastToken;
    uint256 public lastTokenAmount;
    
    function receiveFunds() external payable {
        lastCaller = msg.sender;
        lastAmount = msg.value;
    }
    
    // Function to receive tokens via transferFrom
    function receiveToken(address token, uint256 amount) external {
        lastCaller = msg.sender;
        lastToken = token;
        lastTokenAmount = amount;
        
        // Transfer the tokens from sender to this contract
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
    
    // Fallback function to handle any calls
    fallback() external payable {
        lastCaller = msg.sender;
        lastAmount = msg.value;
    }
    
    // Receive function for empty calls
    receive() external payable {
        lastCaller = msg.sender;
        lastAmount = msg.value;
    }
}
