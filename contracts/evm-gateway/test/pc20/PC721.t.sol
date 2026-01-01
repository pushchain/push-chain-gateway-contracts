// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PC721 } from "../../src/PC721.sol";
import { Errors } from "../../src/libraries/Errors.sol";

/**
 * @title   PC721Test
 * @notice  Comprehensive test suite for PC721 contract
 * @dev     Tests minting, burning, transfers, and access control for NFTs
 */
contract PC721Test is Test {
    // =========================
    //           ACTORS
    // =========================
    address public gateway;
    address public user1;
    address public user2;
    address public attacker;

    // =========================
    //        CONTRACTS
    // =========================
    PC721 public pc721;

    // =========================
    //      TEST CONSTANTS
    // =========================
    address public constant ORIGIN_TOKEN = address(0x1111);
    string public constant TOKEN_NAME = "Test NFT";
    string public constant TOKEN_SYMBOL = "TNFT";
    uint256 public constant TOKEN_ID_1 = 1;
    uint256 public constant TOKEN_ID_2 = 2;
    uint256 public constant TOKEN_ID_3 = 3;

    // =========================
    //         SETUP
    // =========================
    function setUp() public {
        gateway = address(0x100);
        user1 = address(0x200);
        user2 = address(0x300);
        attacker = address(0x400);

        vm.label(gateway, "gateway");
        vm.label(user1, "user1");
        vm.label(user2, "user2");
        vm.label(attacker, "attacker");

        pc721 = new PC721(TOKEN_NAME, TOKEN_SYMBOL, gateway, ORIGIN_TOKEN);
    }

    // =========================
    //    CONSTRUCTOR TESTS
    // =========================

    function test_Constructor_Success() public {
        PC721 newPC721 = new PC721(TOKEN_NAME, TOKEN_SYMBOL, gateway, ORIGIN_TOKEN);
        
        assertEq(newPC721.name(), TOKEN_NAME, "Name mismatch");
        assertEq(newPC721.symbol(), TOKEN_SYMBOL, "Symbol mismatch");
        assertEq(newPC721.gateway(), gateway, "Gateway mismatch");
        assertEq(newPC721.originToken(), ORIGIN_TOKEN, "Origin token mismatch");
    }

    function test_Constructor_RevertZeroGateway() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new PC721(TOKEN_NAME, TOKEN_SYMBOL, address(0), ORIGIN_TOKEN);
    }

    function test_Constructor_RevertZeroOriginToken() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new PC721(TOKEN_NAME, TOKEN_SYMBOL, gateway, address(0));
    }

    // =========================
    //       MINT TESTS
    // =========================

    function test_Mint_Success() public {
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        assertEq(pc721.ownerOf(TOKEN_ID_1), user1, "Owner mismatch");
        assertEq(pc721.balanceOf(user1), 1, "Balance should be 1");
    }

    function test_Mint_MultipleTokens() public {
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_2);

        assertEq(pc721.ownerOf(TOKEN_ID_1), user1, "Token 1 owner mismatch");
        assertEq(pc721.ownerOf(TOKEN_ID_2), user1, "Token 2 owner mismatch");
        assertEq(pc721.balanceOf(user1), 2, "Balance should be 2");
    }

    function test_Mint_DifferentUsers() public {
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        vm.prank(gateway);
        pc721.mint(user2, TOKEN_ID_2);

        assertEq(pc721.ownerOf(TOKEN_ID_1), user1, "User1 token owner mismatch");
        assertEq(pc721.ownerOf(TOKEN_ID_2), user2, "User2 token owner mismatch");
        assertEq(pc721.balanceOf(user1), 1, "User1 balance should be 1");
        assertEq(pc721.balanceOf(user2), 1, "User2 balance should be 1");
    }

    function test_Mint_RevertOnlyGateway() public {
        vm.prank(attacker);
        vm.expectRevert(PC721.OnlyGateway.selector);
        pc721.mint(user1, TOKEN_ID_1);
    }

    function test_Mint_RevertZeroAddress() public {
        vm.prank(gateway);
        vm.expectRevert(Errors.ZeroAddress.selector);
        pc721.mint(address(0), TOKEN_ID_1);
    }

    function test_Mint_RevertZeroTokenId() public {
        vm.prank(gateway);
        vm.expectRevert(PC721.InvalidTokenId.selector);
        pc721.mint(user1, 0);
    }

    function test_Mint_RevertAlreadyMinted() public {
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        vm.prank(gateway);
        vm.expectRevert();
        pc721.mint(user2, TOKEN_ID_1);
    }

    // =========================
    //       BURN TESTS
    // =========================

    function test_Burn_Success() public {
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        vm.prank(gateway);
        pc721.burn(TOKEN_ID_1);

        assertEq(pc721.balanceOf(user1), 0, "Balance should be 0 after burn");
        
        vm.expectRevert();
        pc721.ownerOf(TOKEN_ID_1);
    }

    function test_Burn_MultipleTokens() public {
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_2);

        vm.prank(gateway);
        pc721.burn(TOKEN_ID_1);

        assertEq(pc721.balanceOf(user1), 1, "Balance should be 1 after burning one");
        assertEq(pc721.ownerOf(TOKEN_ID_2), user1, "Token 2 should still exist");
    }

    function test_Burn_RevertOnlyGateway() public {
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        vm.prank(attacker);
        vm.expectRevert(PC721.OnlyGateway.selector);
        pc721.burn(TOKEN_ID_1);
    }

    function test_Burn_RevertZeroTokenId() public {
        vm.prank(gateway);
        vm.expectRevert(PC721.InvalidTokenId.selector);
        pc721.burn(0);
    }

    function test_Burn_RevertNonExistentToken() public {
        vm.prank(gateway);
        vm.expectRevert();
        pc721.burn(TOKEN_ID_1);
    }

    // =========================
    //     TRANSFER TESTS
    // =========================

    function test_Transfer_Success() public {
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        vm.prank(user1);
        pc721.transferFrom(user1, user2, TOKEN_ID_1);

        assertEq(pc721.ownerOf(TOKEN_ID_1), user2, "Owner should be user2");
        assertEq(pc721.balanceOf(user1), 0, "User1 balance should be 0");
        assertEq(pc721.balanceOf(user2), 1, "User2 balance should be 1");
    }

    function test_Transfer_RevertNotOwner() public {
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        vm.prank(user2);
        vm.expectRevert();
        pc721.transferFrom(user1, user2, TOKEN_ID_1);
    }

    function test_Transfer_RevertNonExistentToken() public {
        vm.prank(user1);
        vm.expectRevert();
        pc721.transferFrom(user1, user2, TOKEN_ID_1);
    }

    // =========================
    //     APPROVE TESTS
    // =========================

    function test_Approve_Success() public {
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        vm.prank(user1);
        pc721.approve(user2, TOKEN_ID_1);

        assertEq(pc721.getApproved(TOKEN_ID_1), user2, "Approved address mismatch");
    }

    function test_Approve_TransferFrom() public {
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        vm.prank(user1);
        pc721.approve(user2, TOKEN_ID_1);

        vm.prank(user2);
        pc721.transferFrom(user1, user2, TOKEN_ID_1);

        assertEq(pc721.ownerOf(TOKEN_ID_1), user2, "Owner should be user2");
    }

    function test_SetApprovalForAll_Success() public {
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_2);

        vm.prank(user1);
        pc721.setApprovalForAll(user2, true);

        assertTrue(pc721.isApprovedForAll(user1, user2), "Should be approved for all");

        // User2 can transfer both tokens
        vm.prank(user2);
        pc721.transferFrom(user1, user2, TOKEN_ID_1);

        vm.prank(user2);
        pc721.transferFrom(user1, user2, TOKEN_ID_2);

        assertEq(pc721.ownerOf(TOKEN_ID_1), user2, "Token 1 owner should be user2");
        assertEq(pc721.ownerOf(TOKEN_ID_2), user2, "Token 2 owner should be user2");
    }

    // =========================
    //     VIEW FUNCTION TESTS
    // =========================

    function test_Name() public {
        assertEq(pc721.name(), TOKEN_NAME, "Name should match");
    }

    function test_Symbol() public {
        assertEq(pc721.symbol(), TOKEN_SYMBOL, "Symbol should match");
    }

    function test_Gateway() public {
        assertEq(pc721.gateway(), gateway, "Gateway should match");
    }

    function test_OriginToken() public {
        assertEq(pc721.originToken(), ORIGIN_TOKEN, "Origin token should match");
    }

    function test_BalanceOf_InitiallyZero() public {
        assertEq(pc721.balanceOf(user1), 0, "Initial balance should be zero");
    }

    function test_OwnerOf_RevertNonExistent() public {
        vm.expectRevert();
        pc721.ownerOf(TOKEN_ID_1);
    }

    // =========================
    //     INTEGRATION TESTS
    // =========================

    function test_Integration_MintTransferBurn() public {
        // Mint to user1
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        // User1 transfers to user2
        vm.prank(user1);
        pc721.transferFrom(user1, user2, TOKEN_ID_1);

        assertEq(pc721.ownerOf(TOKEN_ID_1), user2, "Owner should be user2");

        // Gateway burns from user2
        vm.prank(gateway);
        pc721.burn(TOKEN_ID_1);

        assertEq(pc721.balanceOf(user2), 0, "Balance should be 0 after burn");
    }

    function test_Integration_MintApproveTransferBurn() public {
        // Mint to user1
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        // User1 approves user2
        vm.prank(user1);
        pc721.approve(user2, TOKEN_ID_1);

        // User2 transfers to themselves
        vm.prank(user2);
        pc721.transferFrom(user1, user2, TOKEN_ID_1);

        assertEq(pc721.ownerOf(TOKEN_ID_1), user2, "Owner should be user2");

        // Gateway burns
        vm.prank(gateway);
        pc721.burn(TOKEN_ID_1);

        assertEq(pc721.balanceOf(user2), 0, "Balance should be 0");
    }

    function test_Integration_MultipleNFTs() public {
        // Mint multiple NFTs
        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_1);

        vm.prank(gateway);
        pc721.mint(user1, TOKEN_ID_2);

        vm.prank(gateway);
        pc721.mint(user2, TOKEN_ID_3);

        assertEq(pc721.balanceOf(user1), 2, "User1 should have 2 NFTs");
        assertEq(pc721.balanceOf(user2), 1, "User2 should have 1 NFT");

        // Transfer one from user1 to user2
        vm.prank(user1);
        pc721.transferFrom(user1, user2, TOKEN_ID_1);

        assertEq(pc721.balanceOf(user1), 1, "User1 should have 1 NFT");
        assertEq(pc721.balanceOf(user2), 2, "User2 should have 2 NFTs");

        // Burn all
        vm.prank(gateway);
        pc721.burn(TOKEN_ID_1);

        vm.prank(gateway);
        pc721.burn(TOKEN_ID_2);

        vm.prank(gateway);
        pc721.burn(TOKEN_ID_3);

        assertEq(pc721.balanceOf(user1), 0, "User1 balance should be 0");
        assertEq(pc721.balanceOf(user2), 0, "User2 balance should be 0");
    }

    // =========================
    //       FUZZ TESTS
    // =========================

    function testFuzz_Mint(uint256 tokenId) public {
        tokenId = bound(tokenId, 1, type(uint128).max);

        vm.prank(gateway);
        pc721.mint(user1, tokenId);

        assertEq(pc721.ownerOf(tokenId), user1, "Owner should be user1");
        assertEq(pc721.balanceOf(user1), 1, "Balance should be 1");
    }

    function testFuzz_MintAndBurn(uint256 tokenId) public {
        tokenId = bound(tokenId, 1, type(uint128).max);

        vm.prank(gateway);
        pc721.mint(user1, tokenId);

        vm.prank(gateway);
        pc721.burn(tokenId);

        assertEq(pc721.balanceOf(user1), 0, "Balance should be 0 after burn");
    }

    function testFuzz_MintAndTransfer(uint256 tokenId) public {
        tokenId = bound(tokenId, 1, type(uint128).max);

        vm.prank(gateway);
        pc721.mint(user1, tokenId);

        vm.prank(user1);
        pc721.transferFrom(user1, user2, tokenId);

        assertEq(pc721.ownerOf(tokenId), user2, "Owner should be user2");
        assertEq(pc721.balanceOf(user1), 0, "User1 balance should be 0");
        assertEq(pc721.balanceOf(user2), 1, "User2 balance should be 1");
    }
}
