// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @dev Interface for PC721 (Push-native ERC-721–style NFTs)
 */
interface IPC721 {
    /**
     * @notice ERC-721 metadata
     */
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);

    /// @notice Full metadata URI for a given tokenId (ERC721Metadata-style)
    function tokenURI(uint256 tokenId) external view returns (string memory);

    /**
     * @notice Returns the owner of an NFT
     * @param tokenId The NFT ID
     */
    function ownerOf(uint256 tokenId) external view returns (address);

    /**
     * @notice Returns balance of an address
     * @param owner NFT owner address
     */
    function balanceOf(address owner) external view returns (uint256);

    /**
     * @notice Push-native deposit (mirrors IPC20.deposit)
     *         This "locks" or "mints" the NFT into the Push Chain account.
     */
    function deposit(address to, uint256 tokenId) external returns (bool);

    /**
     * @notice Approve another address to transfer the given tokenId
     */
    function approve(address to, uint256 tokenId) external;

    /**
     * @notice Returns approved account for a token ID
     */
    function getApproved(uint256 tokenId) external view returns (address);

    /**
     * @notice Set/unset operator approvals
     */
    function setApprovalForAll(address operator, bool approved) external;

    /**
     * @notice Check if operator is approved for all tokens of owner
     */
    function isApprovedForAll(address owner, address operator)
        external
        view
        returns (bool);

    /**
     * @notice Transfer token from one account to another
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    /**
     * @notice Safe transfer variant
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    /**
     * @notice Safe transfer with data payload
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata data
    ) external;

    /**
     * @notice special PC-20 functions
     */
    function mint(address to, uint256 tokenId) external;
    function burn(uint256 tokenId) external;
}
