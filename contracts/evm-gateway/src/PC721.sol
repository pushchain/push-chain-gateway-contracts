// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Errors } from "./libraries/Errors.sol";

/// @title  PC721
/// @notice Push Chain ERC721 style wrapper for external NFTs
/// @dev
///   - Name and symbol are set at construction.
///   - `gateway` is the ONLY address allowed to mint and burn.
///   - Used together with PC721Factory and UniversalGateway.
contract PC721 is ERC721 {
    /// @notice Address that can mint and burn (typically UniversalGateway).
    address public immutable gateway;

    /// @notice Origin token address on Push Chain that this PC721 represents.
    address public immutable originToken;

    error OnlyGateway();
    error InvalidTokenId();

    modifier onlyGateway() {
        if (msg.sender != gateway) revert OnlyGateway();
        _;
    }

    /// @param name_         ERC721 name
    /// @param symbol_       ERC721 symbol
    /// @param gateway_      minter and burner (UniversalGateway)
    /// @param originToken_  origin token address on Push Chain
    constructor(
        string memory name_,
        string memory symbol_,
        address gateway_,
        address originToken_
    ) ERC721(name_, symbol_) {
        if (gateway_ == address(0)) revert Errors.ZeroAddress();
        if (originToken_ == address(0)) revert Errors.ZeroAddress();
        gateway = gateway_;
        originToken = originToken_;
    }

    /// @notice Mint tokenId to `to`.
    /// @dev Only callable by `gateway`.
    function mint(address to, uint256 tokenId) external onlyGateway {
        if (to == address(0)) revert Errors.ZeroAddress();
        if (tokenId == 0) revert InvalidTokenId(); // optional, but keeps things strict
        _mint(to, tokenId);
    }

    /// @notice Burn `tokenId`.
    /// @dev Only callable by `gateway`. Does not check msg.sender ownership,
    ///      since the gateway is trusted by design.
    function burn(uint256 tokenId) external onlyGateway {
        if (tokenId == 0) revert InvalidTokenId();
        _burn(tokenId);
    }
}
