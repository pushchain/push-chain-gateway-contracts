// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Errors } from "./libraries/Errors.sol";
import { PC20 } from "./PC20.sol";

/// @title  PC20Factory
/// @notice Deploys PC20 tokens at deterministic addresses using CREATE2,
///         keyed only by the origin token address.
///         - One PC20 per origin token.
///         - `gateway` (UniversalGateway) is the sole creator and the minter/burner in PC20.
contract PC20Factory {
    /// @notice Address allowed to create PC20 wrappers (typically UniversalGateway).
    address public immutable gateway;

    /// @notice Mapping from origin token (Push Chain address) to its PC20 wrapper on this chain.
    mapping(address => address) public pc20Mapping;

    /// @dev Emitted when a new PC20 wrapper is deployed.
    event PC20Deployed(
        address indexed originToken,
        address indexed pc20Token,
        string name,
        string symbol,
        uint8 decimals
    );

    error OnlyGateway();
    error PC20DeploymentFailed();
    error InvalidMetadata();

    modifier onlyGateway() {
        if (msg.sender != gateway) revert OnlyGateway();
        _;
    }

    constructor(address _gateway) {
        if (_gateway == address(0)) revert Errors.ZeroAddress();
        gateway = _gateway;
    }

    /// @notice Returns the PC20 wrapper for a given origin token, or address(0) if not deployed.
    function getPC20(address originToken) external view returns (address) {
        return pc20Mapping[originToken];
    }

    /// @notice Deploy a PC20 wrapper for a given origin token if not already deployed.
    /// @dev    Deterministic per originToken:
    ///         - salt = keccak256(abi.encodePacked(originToken))
    ///         If already created, returns the existing wrapper.
    function createPC20(
        address originToken,
        string calldata name,
        string calldata symbol,
        uint8 decimals
    ) external onlyGateway returns (address pc20Token) {
        if (originToken == address(0)) revert Errors.ZeroAddress();
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert InvalidMetadata();

        pc20Token = pc20Mapping[originToken];
        if (pc20Token != address(0)) {
            // Already deployed for this origin token
            return pc20Token;
        }

        // Deterministic salt per origin token
        bytes32 salt = keccak256(abi.encodePacked(originToken));

        // Constructor args baked into init code
        bytes memory bytecode = abi.encodePacked(
            type(PC20).creationCode,
            abi.encode(name, symbol, decimals, gateway, originToken)
        );

        address deployed;
        assembly {
            let encodedData := add(bytecode, 0x20)
            let encodedSize := mload(bytecode)
            deployed := create2(0, encodedData, encodedSize, salt)
        }

        if (deployed == address(0)) revert PC20DeploymentFailed();

        pc20Token = deployed;
        pc20Mapping[originToken] = pc20Token;

        emit PC20Deployed(originToken, pc20Token, name, symbol, decimals);
    }
}
