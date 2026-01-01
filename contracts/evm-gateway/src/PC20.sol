// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Errors } from "./libraries/Errors.sol";

/// @title  PC20
/// @notice Push Chain ERC20-style wrapper for external assets
/// @dev
///   - Name / symbol / decimals are set at construction.
///   - `gateway` is the ONLY address allowed to mint / burn.
///   - Used together with PC20Factory + UniversalGateway.
contract PC20 is ERC20 {
    /// @notice Address that can mint / burn (typically UniversalGateway).
    address public immutable gateway;

    /// @notice Origin token address on Push Chain that this PC20 represents.
    address public immutable originToken;

    /// @notice Decimals for this token (immutable).
    uint8 private immutable _decimals;

    error OnlyGateway();
    error InvalidAmount();

    modifier onlyGateway() {
        if (msg.sender != gateway) revert OnlyGateway();
        _;
    }

    /// @param name_         ERC20 name
    /// @param symbol_       ERC20 symbol
    /// @param decimals_     token decimals
    /// @param gateway_      minter / burner (UniversalGateway)
    /// @param originToken_  origin token address on Push Chain
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address gateway_,
        address originToken_
    ) ERC20(name_, symbol_) {
        if (gateway_ == address(0)) revert Errors.ZeroAddress();
        if (originToken_ == address(0)) revert Errors.ZeroAddress();
        gateway = gateway_;
        originToken = originToken_;
        _decimals = decimals_;
    }

    /// @notice Returns decimals for this PC20 token.
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint tokens to `to`.
    /// @dev Only callable by `gateway`.
    function mint(address to, uint256 amount) external onlyGateway {
        if (to == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        _mint(to, amount);
    }

    /// @notice Burn tokens from `from`.
    /// @dev Only callable by `gateway`.
    function burn(address from, uint256 amount) external onlyGateway {
        if (from == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        _burn(from, amount);
    }
}
