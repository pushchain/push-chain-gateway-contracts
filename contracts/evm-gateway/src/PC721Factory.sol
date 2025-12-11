// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Errors } from "./libraries/Errors.sol";
import { PC721 } from "./PC721.sol";

/// @title  PC721Factory
/// @notice Deploys PC721 tokens at deterministic addresses using CREATE2,
///         keyed only by the origin token address.
///         - One PC721 per origin token.
///         - `gateway` (UniversalGateway) is the sole creator and the minter/burner in PC721.
contract PC721Factory {
    /// @notice Address allowed to create PC721 wrappers (typically UniversalGateway).
    address public immutable gateway;

    /// @notice Mapping from origin token (Push Chain address) to its PC721 wrapper on this chain.
    mapping(address => address) public pc721Mapping;

    /// @dev Emitted when a new PC721 wrapper is deployed.
    event PC721Deployed(
        address indexed originToken,
        address indexed pc721Token,
        string name,
        string symbol
    );

    error OnlyGateway();
    error PC721DeploymentFailed();
    error InvalidMetadata();

    modifier onlyGateway() {
        if (msg.sender != gateway) revert OnlyGateway();
        _;
    }

    constructor(address _gateway) {
        if (_gateway == address(0)) revert Errors.ZeroAddress();
        gateway = _gateway;
    }

    /// @notice Returns the PC721 wrapper for a given origin token, or address(0) if not deployed.
    function getPC721(address originToken) external view returns (address) {
        return pc721Mapping[originToken];
    }

    /// @notice Deploy a PC721 wrapper for a given origin token if not already deployed.
    /// @dev    Deterministic per originToken:
    ///         - salt = keccak256(abi.encodePacked(originToken))
    ///         If already created, returns the existing wrapper.
    function createPC721(
        address originToken,
        string calldata name,
        string calldata symbol
    ) external onlyGateway returns (address pc721Token) {
        if (originToken == address(0)) revert Errors.ZeroAddress();
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert InvalidMetadata();

        pc721Token = pc721Mapping[originToken];
        if (pc721Token != address(0)) {
            // Already deployed for this origin token
            return pc721Token;
        }

        // Deterministic salt per origin token
        bytes32 salt = keccak256(abi.encodePacked(originToken));

        // Constructor args baked into init code
        bytes memory bytecode = abi.encodePacked(
            type(PC721).creationCode,
            abi.encode(name, symbol, gateway, originToken)
        );

        address deployed;
        assembly {
            let encodedData := add(bytecode, 0x20)
            let encodedSize := mload(bytecode)
            deployed := create2(0, encodedData, encodedSize, salt)
        }

        if (deployed == address(0)) revert PC721DeploymentFailed();

        pc721Token = deployed;
        pc721Mapping[originToken] = pc721Token;

        emit PC721Deployed(originToken, pc721Token, name, symbol);
    }
}
