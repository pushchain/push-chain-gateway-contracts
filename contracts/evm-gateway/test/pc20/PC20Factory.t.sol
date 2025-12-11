// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PC20Factory } from "../../src/PC20Factory.sol";
import { PC20 } from "../../src/PC20.sol";
import { Errors } from "../../src/libraries/Errors.sol";

/**
 * @title   PC20FactoryTest
 * @notice  Comprehensive test suite for PC20Factory contract
 * @dev     Tests deployment, creation, and access control
 */
contract PC20FactoryTest is Test {
    // =========================
    //           ACTORS
    // =========================
    address public gateway;
    address public user1;
    address public attacker;

    // =========================
    //        CONTRACTS
    // =========================
    PC20Factory public factory;

    // =========================
    //      TEST CONSTANTS
    // =========================
    address public constant ORIGIN_TOKEN_1 = address(0x1111);
    address public constant ORIGIN_TOKEN_2 = address(0x2222);
    string public constant TOKEN_NAME = "Test Token";
    string public constant TOKEN_SYMBOL = "TEST";
    uint8 public constant TOKEN_DECIMALS = 18;

    // =========================
    //         EVENTS
    // =========================
    event PC20Deployed(
        address indexed originToken,
        address indexed pc20Token,
        string name,
        string symbol,
        uint8 decimals
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

        factory = new PC20Factory(gateway);
    }

    // =========================
    //    CONSTRUCTOR TESTS
    // =========================

    function test_Constructor_Success() public {
        PC20Factory newFactory = new PC20Factory(gateway);
        assertEq(newFactory.gateway(), gateway, "Gateway address mismatch");
    }

    function test_Constructor_RevertZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new PC20Factory(address(0));
    }

    // =========================
    //    CREATE PC20 TESTS
    // =========================

    function test_CreatePC20_Success() public {
        vm.prank(gateway);
        vm.expectEmit(false, false, false, true);
        emit PC20Deployed(ORIGIN_TOKEN_1, address(0), TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS);
        
        address pc20Address = factory.createPC20(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );

        assertTrue(pc20Address != address(0), "PC20 address should not be zero");
        assertEq(factory.getPC20(ORIGIN_TOKEN_1), pc20Address, "Mapping should store PC20 address");
        assertEq(factory.pc20Mapping(ORIGIN_TOKEN_1), pc20Address, "Public mapping should match");

        // Verify PC20 properties
        PC20 pc20 = PC20(pc20Address);
        assertEq(pc20.name(), TOKEN_NAME, "Name mismatch");
        assertEq(pc20.symbol(), TOKEN_SYMBOL, "Symbol mismatch");
        assertEq(pc20.decimals(), TOKEN_DECIMALS, "Decimals mismatch");
        assertEq(pc20.gateway(), gateway, "Gateway mismatch");
        assertEq(pc20.originToken(), ORIGIN_TOKEN_1, "Origin token mismatch");
    }

    function test_CreatePC20_Idempotent() public {
        // First creation
        vm.prank(gateway);
        address pc20Address1 = factory.createPC20(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );

        // Second creation should return same address
        vm.prank(gateway);
        address pc20Address2 = factory.createPC20(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );

        assertEq(pc20Address1, pc20Address2, "Should return same address on second call");
    }

    function test_CreatePC20_MultipleDifferentTokens() public {
        // Create first PC20
        vm.prank(gateway);
        address pc20Address1 = factory.createPC20(
            ORIGIN_TOKEN_1,
            "Token 1",
            "TK1",
            18
        );

        // Create second PC20
        vm.prank(gateway);
        address pc20Address2 = factory.createPC20(
            ORIGIN_TOKEN_2,
            "Token 2",
            "TK2",
            6
        );

        assertTrue(pc20Address1 != pc20Address2, "Different origin tokens should have different PC20 addresses");
        assertEq(factory.getPC20(ORIGIN_TOKEN_1), pc20Address1, "First mapping incorrect");
        assertEq(factory.getPC20(ORIGIN_TOKEN_2), pc20Address2, "Second mapping incorrect");
    }

    function test_CreatePC20_DeterministicAddress() public {
        // Create PC20
        vm.prank(gateway);
        address pc20Address1 = factory.createPC20(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );

        // Deploy new factory with same gateway
        PC20Factory newFactory = new PC20Factory(gateway);

        // Create PC20 with same parameters
        vm.prank(gateway);
        address pc20Address2 = newFactory.createPC20(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );

        // Addresses should be different (different factory addresses)
        assertTrue(pc20Address1 != pc20Address2, "Different factories should produce different addresses");
    }

    function test_CreatePC20_RevertOnlyGateway() public {
        vm.prank(attacker);
        vm.expectRevert(PC20Factory.OnlyGateway.selector);
        factory.createPC20(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );
    }

    function test_CreatePC20_RevertZeroOriginToken() public {
        vm.prank(gateway);
        vm.expectRevert(Errors.ZeroAddress.selector);
        factory.createPC20(
            address(0),
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );
    }

    function test_CreatePC20_RevertEmptyName() public {
        vm.prank(gateway);
        vm.expectRevert(PC20Factory.InvalidMetadata.selector);
        factory.createPC20(
            ORIGIN_TOKEN_1,
            "",
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );
    }

    function test_CreatePC20_RevertEmptySymbol() public {
        vm.prank(gateway);
        vm.expectRevert(PC20Factory.InvalidMetadata.selector);
        factory.createPC20(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            "",
            TOKEN_DECIMALS
        );
    }

    function test_CreatePC20_RevertEmptyNameAndSymbol() public {
        vm.prank(gateway);
        vm.expectRevert(PC20Factory.InvalidMetadata.selector);
        factory.createPC20(
            ORIGIN_TOKEN_1,
            "",
            "",
            TOKEN_DECIMALS
        );
    }

    function test_CreatePC20_DifferentDecimals() public {
        vm.prank(gateway);
        address pc20Address6 = factory.createPC20(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            6
        );

        PC20 pc20 = PC20(pc20Address6);
        assertEq(pc20.decimals(), 6, "Should support 6 decimals");
    }

    function test_CreatePC20_ZeroDecimals() public {
        vm.prank(gateway);
        address pc20Address = factory.createPC20(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            0
        );

        PC20 pc20 = PC20(pc20Address);
        assertEq(pc20.decimals(), 0, "Should support 0 decimals");
    }

    // =========================
    //    GET PC20 TESTS
    // =========================

    function test_GetPC20_ReturnsZeroForNonExistent() public {
        address pc20Address = factory.getPC20(ORIGIN_TOKEN_1);
        assertEq(pc20Address, address(0), "Should return zero for non-existent PC20");
    }

    function test_GetPC20_ReturnsAddressAfterCreation() public {
        vm.prank(gateway);
        address createdAddress = factory.createPC20(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );

        address queriedAddress = factory.getPC20(ORIGIN_TOKEN_1);
        assertEq(queriedAddress, createdAddress, "getPC20 should return created address");
    }

    function test_GetPC20_MultipleTokens() public {
        // Create multiple PC20s
        vm.prank(gateway);
        address pc20Address1 = factory.createPC20(ORIGIN_TOKEN_1, "Token 1", "TK1", 18);
        
        vm.prank(gateway);
        address pc20Address2 = factory.createPC20(ORIGIN_TOKEN_2, "Token 2", "TK2", 6);

        // Query each
        assertEq(factory.getPC20(ORIGIN_TOKEN_1), pc20Address1, "First token query incorrect");
        assertEq(factory.getPC20(ORIGIN_TOKEN_2), pc20Address2, "Second token query incorrect");
    }

    // =========================
    //    INTEGRATION TESTS
    // =========================

    function test_Integration_CreateAndMint() public {
        // Create PC20
        vm.prank(gateway);
        address pc20Address = factory.createPC20(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );

        PC20 pc20 = PC20(pc20Address);

        // Gateway should be able to mint
        vm.prank(gateway);
        pc20.mint(user1, 1000 ether);

        assertEq(pc20.balanceOf(user1), 1000 ether, "Mint failed");
    }

    function test_Integration_CreateAndBurn() public {
        // Create PC20
        vm.prank(gateway);
        address pc20Address = factory.createPC20(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );

        PC20 pc20 = PC20(pc20Address);

        // Mint first
        vm.prank(gateway);
        pc20.mint(user1, 1000 ether);

        // Burn
        vm.prank(gateway);
        pc20.burn(user1, 500 ether);

        assertEq(pc20.balanceOf(user1), 500 ether, "Burn failed");
    }

    // =========================
    //    FUZZ TESTS
    // =========================

    function testFuzz_CreatePC20_DifferentOriginTokens(address originToken) public {
        vm.assume(originToken != address(0));

        vm.prank(gateway);
        address pc20Address = factory.createPC20(
            originToken,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );

        assertTrue(pc20Address != address(0), "PC20 should be deployed");
        assertEq(factory.getPC20(originToken), pc20Address, "Mapping should be correct");
    }

    function testFuzz_CreatePC20_DifferentDecimals(uint8 decimals) public {
        vm.prank(gateway);
        address pc20Address = factory.createPC20(
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            decimals
        );

        PC20 pc20 = PC20(pc20Address);
        assertEq(pc20.decimals(), decimals, "Decimals should match");
    }
}
