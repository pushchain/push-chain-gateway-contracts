// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PC721Factory } from "../../src/PC721Factory.sol";
import { PC721 } from "../../src/PC721.sol";
import { Errors } from "../../src/libraries/Errors.sol";

/**
 * @title   PC721FactoryTest
 * @notice  Comprehensive test suite for PC721Factory contract
 * @dev     Tests deployment, creation, and access control for NFT wrappers
 */
contract PC721FactoryTest is Test {
    // =========================
    //           ACTORS
    // =========================
    address public gateway;
    address public user1;
    address public attacker;

    // =========================
    //        CONTRACTS
    // =========================
    PC721Factory public factory;

    // =========================
    //      TEST CONSTANTS
    // =========================
    address public constant ORIGIN_TOKEN_1 = address(0x1111);
    address public constant ORIGIN_TOKEN_2 = address(0x2222);
    string public constant TOKEN_NAME = "Test NFT";
    string public constant TOKEN_SYMBOL = "TNFT";

    // =========================
    //         EVENTS
    // =========================
    event PC721Deployed(
        address indexed originToken,
        address indexed pc721Token,
        string name,
        string symbol
    );

    // =========================
    //         SETUP
    // =========================
    function setUp() public {
        gateway = address(0x100);
        user1 = address(0x200);
        attacker = address(0x300);

        vm.label(gateway, "gateway");
        vm.label(user1, "user1");
        vm.label(attacker, "attacker");

        factory = new PC721Factory(gateway);
    }

    // =========================
    //    CONSTRUCTOR TESTS
    // =========================

    function test_Constructor_Success() public {
        PC721Factory newFactory = new PC721Factory(gateway);
        assertEq(newFactory.gateway(), gateway, "Gateway address mismatch");
    }

    function test_Constructor_RevertZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new PC721Factory(address(0));
    }

    // =========================
    //    CREATE PC721 TESTS
    // =========================

    function test_CreatePC721_Success() public {
        vm.prank(gateway);
        vm.expectEmit(false, false, false, true);
        emit PC721Deployed(ORIGIN_TOKEN_1, address(0), TOKEN_NAME, TOKEN_SYMBOL);
        
        address pc721Address = factory.createPC721(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL
        );

        assertTrue(pc721Address != address(0), "PC721 address should not be zero");
        assertEq(factory.getPC721(ORIGIN_TOKEN_1), pc721Address, "Mapping should store PC721 address");
        assertEq(factory.pc721Mapping(ORIGIN_TOKEN_1), pc721Address, "Public mapping should match");

        // Verify PC721 properties
        PC721 pc721 = PC721(pc721Address);
        assertEq(pc721.name(), TOKEN_NAME, "Name mismatch");
        assertEq(pc721.symbol(), TOKEN_SYMBOL, "Symbol mismatch");
        assertEq(pc721.gateway(), gateway, "Gateway mismatch");
        assertEq(pc721.originToken(), ORIGIN_TOKEN_1, "Origin token mismatch");
    }

    function test_CreatePC721_Idempotent() public {
        // First creation
        vm.prank(gateway);
        address pc721Address1 = factory.createPC721(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL
        );

        // Second creation should return same address
        vm.prank(gateway);
        address pc721Address2 = factory.createPC721(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL
        );

        assertEq(pc721Address1, pc721Address2, "Should return same address on second call");
    }

    function test_CreatePC721_MultipleDifferentTokens() public {
        // Create first PC721
        vm.prank(gateway);
        address pc721Address1 = factory.createPC721(
            ORIGIN_TOKEN_1,
            "NFT 1",
            "NFT1"
        );

        // Create second PC721
        vm.prank(gateway);
        address pc721Address2 = factory.createPC721(
            ORIGIN_TOKEN_2,
            "NFT 2",
            "NFT2"
        );

        assertTrue(pc721Address1 != pc721Address2, "Different origin tokens should have different PC721 addresses");
        assertEq(factory.getPC721(ORIGIN_TOKEN_1), pc721Address1, "First mapping incorrect");
        assertEq(factory.getPC721(ORIGIN_TOKEN_2), pc721Address2, "Second mapping incorrect");
    }

    function test_CreatePC721_DeterministicAddress() public {
        // Create PC721
        vm.prank(gateway);
        address pc721Address1 = factory.createPC721(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL
        );

        // Deploy new factory with same gateway
        PC721Factory newFactory = new PC721Factory(gateway);

        // Create PC721 with same parameters
        vm.prank(gateway);
        address pc721Address2 = newFactory.createPC721(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL
        );

        // Addresses should be different (different factory addresses)
        assertTrue(pc721Address1 != pc721Address2, "Different factories should produce different addresses");
    }

    function test_CreatePC721_RevertOnlyGateway() public {
        vm.prank(attacker);
        vm.expectRevert(PC721Factory.OnlyGateway.selector);
        factory.createPC721(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL
        );
    }

    function test_CreatePC721_RevertZeroOriginToken() public {
        vm.prank(gateway);
        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.createPC721(
            address(0),
            TOKEN_NAME,
            TOKEN_SYMBOL
        );
    }

    function test_CreatePC721_RevertEmptyName() public {
        vm.prank(gateway);
        vm.expectRevert(PC721Factory.InvalidMetadata.selector);
        factory.createPC721(
            ORIGIN_TOKEN_1,
            "",
            TOKEN_SYMBOL
        );
    }

    function test_CreatePC721_RevertEmptySymbol() public {
        vm.prank(gateway);
        vm.expectRevert(PC721Factory.InvalidMetadata.selector);
        factory.createPC721(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            ""
        );
    }

    function test_CreatePC721_RevertEmptyNameAndSymbol() public {
        vm.prank(gateway);
        vm.expectRevert(PC721Factory.InvalidMetadata.selector);
        factory.createPC721(
            ORIGIN_TOKEN_1,
            "",
            ""
        );
    }

    function test_CreatePC721_LongNameAndSymbol() public {
        string memory longName = "Very Long NFT Collection Name That Exceeds Normal Limits";
        string memory longSymbol = "VLNFTTEXNL";

        vm.prank(gateway);
        address pc721Address = factory.createPC721(
            ORIGIN_TOKEN_1,
            longName,
            longSymbol
        );

        PC721 pc721 = PC721(pc721Address);
        assertEq(pc721.name(), longName, "Long name should be supported");
        assertEq(pc721.symbol(), longSymbol, "Long symbol should be supported");
    }

    // =========================
    //    GET PC721 TESTS
    // =========================

    function test_GetPC721_ReturnsZeroForNonExistent() public {
        address pc721Address = factory.getPC721(ORIGIN_TOKEN_1);
        assertEq(pc721Address, address(0), "Should return zero for non-existent PC721");
    }

    function test_GetPC721_ReturnsAddressAfterCreation() public {
        vm.prank(gateway);
        address createdAddress = factory.createPC721(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL
        );

        address queriedAddress = factory.getPC721(ORIGIN_TOKEN_1);
        assertEq(queriedAddress, createdAddress, "getPC721 should return created address");
    }

    function test_GetPC721_MultipleTokens() public {
        // Create multiple PC721s
        vm.prank(gateway);
        address pc721Address1 = factory.createPC721(ORIGIN_TOKEN_1, "NFT 1", "NFT1");
        
        vm.prank(gateway);
        address pc721Address2 = factory.createPC721(ORIGIN_TOKEN_2, "NFT 2", "NFT2");

        // Query each
        assertEq(factory.getPC721(ORIGIN_TOKEN_1), pc721Address1, "First token query incorrect");
        assertEq(factory.getPC721(ORIGIN_TOKEN_2), pc721Address2, "Second token query incorrect");
    }

    // =========================
    //    INTEGRATION TESTS
    // =========================

    function test_Integration_CreateAndMint() public {
        // Create PC721
        vm.prank(gateway);
        address pc721Address = factory.createPC721(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL
        );

        PC721 pc721 = PC721(pc721Address);

        // Gateway should be able to mint
        vm.prank(gateway);
        pc721.mint(user1, 1);

        assertEq(pc721.ownerOf(1), user1, "Mint failed");
        assertEq(pc721.balanceOf(user1), 1, "Balance should be 1");
    }

    function test_Integration_CreateAndBurn() public {
        // Create PC721
        vm.prank(gateway);
        address pc721Address = factory.createPC721(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL
        );

        PC721 pc721 = PC721(pc721Address);

        // Mint first
        vm.prank(gateway);
        pc721.mint(user1, 1);

        // Burn
        vm.prank(gateway);
        pc721.burn(1);

        assertEq(pc721.balanceOf(user1), 0, "Burn failed");
    }

    function test_Integration_CreateMultipleAndMint() public {
        // Create first PC721
        vm.prank(gateway);
        address pc721Address1 = factory.createPC721(ORIGIN_TOKEN_1, "NFT 1", "NFT1");

        // Create second PC721
        vm.prank(gateway);
        address pc721Address2 = factory.createPC721(ORIGIN_TOKEN_2, "NFT 2", "NFT2");

        PC721 pc721_1 = PC721(pc721Address1);
        PC721 pc721_2 = PC721(pc721Address2);

        // Mint from both
        vm.prank(gateway);
        pc721_1.mint(user1, 1);

        vm.prank(gateway);
        pc721_2.mint(user1, 1);

        assertEq(pc721_1.ownerOf(1), user1, "NFT 1 mint failed");
        assertEq(pc721_2.ownerOf(1), user1, "NFT 2 mint failed");
        assertEq(pc721_1.balanceOf(user1), 1, "NFT 1 balance incorrect");
        assertEq(pc721_2.balanceOf(user1), 1, "NFT 2 balance incorrect");
    }

    // =========================
    //       FUZZ TESTS
    // =========================

    function testFuzz_CreatePC721_DifferentOriginTokens(address originToken) public {
        vm.assume(originToken != address(0));

        vm.prank(gateway);
        address pc721Address = factory.createPC721(
            originToken,
            TOKEN_NAME,
            TOKEN_SYMBOL
        );

        assertTrue(pc721Address != address(0), "PC721 should be deployed");
        assertEq(factory.getPC721(originToken), pc721Address, "Mapping should be correct");
    }

    function testFuzz_CreatePC721_DifferentNames(uint256 seed) public {
        // Generate a valid name from seed to avoid vm.assume rejections
        string memory name = string(abi.encodePacked("NFT_", _toString(seed % 10000)));

        vm.prank(gateway);
        address pc721Address = factory.createPC721(
            ORIGIN_TOKEN_1,
            name,
            TOKEN_SYMBOL
        );

        PC721 pc721 = PC721(pc721Address);
        assertEq(pc721.name(), name, "Name should match");
    }

    function testFuzz_CreatePC721_DifferentSymbols(uint256 seed) public {
        // Generate a valid symbol from seed to avoid vm.assume rejections
        string memory symbol = string(abi.encodePacked("SYM", _toString(seed % 1000)));

        vm.prank(gateway);
        address pc721Address = factory.createPC721(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            symbol
        );

        PC721 pc721 = PC721(pc721Address);
        assertEq(pc721.symbol(), symbol, "Symbol should match");
    }

    // Helper function to convert uint to string
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
