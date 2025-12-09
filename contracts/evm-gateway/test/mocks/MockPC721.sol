// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title MockPC721
 * @notice A comprehensive mock ERC721 token for testing purposes
 * @dev Extends OpenZeppelin's ERC721 with additional testing utilities
 */
contract MockPC721 is ERC721 {
    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}