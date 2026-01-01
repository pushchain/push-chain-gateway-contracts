// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { PC20Factory } from "../../src/PC20Factory.sol";
import { PC721Factory } from "../../src/PC721Factory.sol";
import { IPC20 } from "../../src/interfaces/IPC20.sol";
import { IPC721 } from "../../src/interfaces/IPC721.sol";
import { UniversalTxRequest } from "../../src/libraries/Types.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { Errors } from "../../src/libraries/Errors.sol";

/**
 * @title Execute Universal Tx PCAS Test Suite
 * @notice Comprehensive tests for MAGIC_PCAS functionality in executeUniversalTx
 * @dev Tests PC20 and PC721 minting with magic markers for ERC20 token transactions only
 *      PCAS (Push Chain Asset System) only applies to token bridging, not native ETH transactions
 */
contract ExecuteUniversalTxPCASTest is BaseTest {
    // Magic Marker Constants
    bytes4 private constant MAGIC_PCAS = 0x50434153; // "PCAS"
    uint8 private constant META_VERSION = 1;
    uint8 private constant META_KIND_PC20 = 1;
    uint8 private constant META_KIND_PC721 = 2;

    // Test constants
    address private constant ORIGIN_TOKEN_1 = address(0x1111111111111111111111111111111111111111);
    address private constant ORIGIN_TOKEN_2 = address(0x2222222222222222222222222222222222222222);
    address private constant TARGET_CONTRACT = address(0x9876543210987654321098765432109876543210);
    string private constant TOKEN_NAME = "Test PC Token";
    string private constant TOKEN_SYMBOL = "TPC";
    uint8 private constant TOKEN_DECIMALS = 18;
    uint256 private constant MINT_AMOUNT = 1000e18;
    uint256 private constant TOKEN_ID = 42;
    string private constant TOKEN_URI = "https://example.com/token/42";

    PC20Factory public pc20Factory;
    PC721Factory public pc721Factory;

    function setUp() public override {
        super.setUp();
        
        // Deploy and set PC20/PC721 factories
        pc20Factory = new PC20Factory(address(gateway));
        pc721Factory = new PC721Factory(address(gateway));
        
        vm.prank(admin);
        gateway.setPC20Factory(address(pc20Factory));
        
        vm.prank(admin);
        gateway.setPC721Factory(address(pc721Factory));
    }

    // =========================
    // PC20 TESTS - TOKEN TRANSACTIONS (VAULT_ROLE)
    // =========================

    function test_executeUniversalTx_PC20_TokenTx_CreatesAndMints() public {
        // Create PC20 payload with magic marker - using the exact format expected by _handlePCAssetAllocation
        // The function uses both byte extraction and abi.decode, so we need to match the expected format
        bytes memory pc20Payload = abi.encode(
            MAGIC_PCAS,
            META_VERSION,
            META_KIND_PC20,
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );
        
        bytes memory txID = abi.encodePacked("test_pc20_token_tx");
        
        // Create mock token (no minting - PCAS will handle PC20 minting)
        MockERC20 mockToken = new MockERC20("Mock", "MOCK", 18, 0);
        
        // Execute transaction using 6-parameter version (token transactions, VAULT_ROLE)
        // Test contract has VAULT_ROLE from BaseTest setup
        gateway.executeUniversalTx(
            txID,
            user1,
            address(mockToken),
            TARGET_CONTRACT,
            MINT_AMOUNT,
            pc20Payload
        );
        
        // Verify PC20 was created and minted
        address pc20Address = pc20Factory.getPC20(ORIGIN_TOKEN_1);
        assertTrue(pc20Address != address(0), "PC20 should be created");
        
        IPC20 pc20 = IPC20(pc20Address);
        assertEq(pc20.name(), TOKEN_NAME, "PC20 name should match");
        assertEq(pc20.symbol(), TOKEN_SYMBOL, "PC20 symbol should match");
        assertEq(pc20.decimals(), TOKEN_DECIMALS, "PC20 decimals should match");
        
        // PC20 tokens are transferred to VAULT after execution
        address vault = gateway.VAULT();
        assertEq(pc20.balanceOf(vault), MINT_AMOUNT, "PC20 should be transferred to VAULT");
    }

    function test_executeUniversalTx_PC20_TokenTx_ExistingToken() public {
        // First create the PC20 token
        test_executeUniversalTx_PC20_TokenTx_CreatesAndMints();
        
        // Create another payload for the same origin token
        bytes memory pc20Payload = abi.encode(
            MAGIC_PCAS,
            META_VERSION,
            META_KIND_PC20,
            ORIGIN_TOKEN_1, // Same origin token
            "New Name", // Different name (should be ignored)
            "NEW", // Different symbol (should be ignored)
            TOKEN_DECIMALS
        );
        
        bytes memory txID = abi.encodePacked("test_pc20_existing");
        
        // Create mock token (no minting - PCAS will handle PC20 minting)
        MockERC20 mockToken = new MockERC20("Mock", "MOCK", 18, 0);
        
        uint256 additionalAmount = 500e18;
        
        // Execute transaction - should mint to existing PC20
        gateway.executeUniversalTx(
            txID,
            user1,
            address(mockToken),
            TARGET_CONTRACT,
            additionalAmount,
            pc20Payload
        );
        
        // Verify PC20 balance increased in VAULT
        address pc20Address = pc20Factory.getPC20(ORIGIN_TOKEN_1);
        IPC20 pc20 = IPC20(pc20Address);
        address vault = gateway.VAULT();
        assertEq(pc20.balanceOf(vault), MINT_AMOUNT + additionalAmount, "PC20 balance should increase in VAULT");
        
        // Verify original metadata unchanged
        assertEq(pc20.name(), TOKEN_NAME, "PC20 name should remain original");
        assertEq(pc20.symbol(), TOKEN_SYMBOL, "PC20 symbol should remain original");
    }


    // =========================
    // PC721 TESTS - TOKEN TRANSACTIONS (VAULT_ROLE)
    // =========================

    function test_executeUniversalTx_PC721_TokenTx_CreatesAndMints() public {
        // Create PC721 payload with magic marker
        bytes memory pc721Payload = abi.encode(
            MAGIC_PCAS,
            META_VERSION,
            META_KIND_PC721,
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_ID,
            TOKEN_URI
        );
        
        bytes memory txID = abi.encodePacked("test_pc721_token_tx");
        
        // Create mock token (no minting - PCAS will handle PC721 minting)
        MockERC20 mockToken = new MockERC20("Mock", "MOCK", 18, 0);
        
        // Execute transaction using 6-parameter version (VAULT_ROLE)
        gateway.executeUniversalTx(
            txID,
            user1,
            address(mockToken),
            TARGET_CONTRACT,
            MINT_AMOUNT,
            pc721Payload
        );
        
        // Verify PC721 was created and minted
        address pc721Address = pc721Factory.getPC721(ORIGIN_TOKEN_1);
        assertTrue(pc721Address != address(0), "PC721 should be created");
        
        IPC721 pc721 = IPC721(pc721Address);
        assertEq(pc721.name(), TOKEN_NAME, "PC721 name should match");
        assertEq(pc721.symbol(), TOKEN_SYMBOL, "PC721 symbol should match");
        
        // PC721 tokens are transferred to VAULT after execution
        address vault = gateway.VAULT();
        assertEq(pc721.ownerOf(TOKEN_ID), vault, "PC721 should be transferred to VAULT");
    }


    // =========================
    // ERROR CASES
    // =========================

    function test_executeUniversalTx_NoPC20Factory_Revert() public {
        bytes memory pc20Payload = abi.encode(
            MAGIC_PCAS,
            META_VERSION,
            META_KIND_PC20,
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );
        
        bytes memory txID = abi.encodePacked("test_no_factory");
        MockERC20 mockToken = new MockERC20("Mock", "MOCK", 18, 0);
        mockToken.mint(address(gateway), MINT_AMOUNT);
        
        // Should revert with ZeroAddress when trying to set factory to address(0)
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setPC20Factory(address(0));
    }

    function test_executeUniversalTx_NoPC721Factory_Revert() public {
        bytes memory pc721Payload = abi.encode(
            MAGIC_PCAS,
            META_VERSION,
            META_KIND_PC721,
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_ID,
            TOKEN_URI
        );
        
        bytes memory txID = abi.encodePacked("test_no_pc721_factory");
        MockERC20 mockToken = new MockERC20("Mock", "MOCK", 18, 0);
        mockToken.mint(address(gateway), MINT_AMOUNT);
        
        // Should revert with ZeroAddress when trying to set factory to address(0)
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setPC721Factory(address(0));
    }

    function test_executeUniversalTx_InvalidMagicMarker_NoProcessing() public {
        // Create payload with invalid magic marker
        bytes memory invalidPayload = abi.encode(
            bytes4(0x12345678), // Invalid magic
            META_VERSION,
            META_KIND_PC20,
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );
        
        bytes memory txID = abi.encodePacked("test_invalid_magic");
        MockERC20 mockToken = new MockERC20("Mock", "MOCK", 18, 0);
        mockToken.mint(address(gateway), MINT_AMOUNT);
        
        // Execute transaction - should succeed but not create PC20
        gateway.executeUniversalTx(
            txID,
            user1,
            address(mockToken),
            TARGET_CONTRACT,
            MINT_AMOUNT,
            invalidPayload
        );
        
        // Verify no PC20 was created
        address pc20Address = pc20Factory.getPC20(ORIGIN_TOKEN_1);
        assertEq(pc20Address, address(0), "No PC20 should be created with invalid magic");
    }

    function test_executeUniversalTx_InvalidVersion_Revert() public {
        // Create payload with invalid version
        bytes memory invalidPayload = abi.encode(
            MAGIC_PCAS,
            uint8(99), // Invalid version
            META_KIND_PC20,
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );
        
        bytes memory txID = abi.encodePacked("test_invalid_version");
        MockERC20 mockToken = new MockERC20("Mock", "MOCK", 18, 0);
        mockToken.mint(address(gateway), MINT_AMOUNT);
        
        // Should revert with InvalidInput
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.executeUniversalTx(
            txID,
            user1,
            address(mockToken),
            TARGET_CONTRACT,
            MINT_AMOUNT,
            invalidPayload
        );
    }

    function test_executeUniversalTx_InvalidKind_Revert() public {
        // Create payload with invalid kind
        bytes memory invalidPayload = abi.encode(
            MAGIC_PCAS,
            META_VERSION,
            uint8(99), // Invalid kind
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );
        
        bytes memory txID = abi.encodePacked("test_invalid_kind");
        MockERC20 mockToken = new MockERC20("Mock", "MOCK", 18, 0);
        mockToken.mint(address(gateway), MINT_AMOUNT);
        
        // Should revert with InvalidInput
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.executeUniversalTx(
            txID,
            user1,
            address(mockToken),
            TARGET_CONTRACT,
            MINT_AMOUNT,
            invalidPayload
        );
    }

    function test_executeUniversalTx_ShortPayload_NoProcessing() public {
        // Create payload shorter than 4 bytes (no magic marker processing)
        bytes memory shortPayload = abi.encodePacked(uint16(0x1234));
        
        bytes memory txID = abi.encodePacked("test_short_payload");
        MockERC20 mockToken = new MockERC20("Mock", "MOCK", 18, 0);
        mockToken.mint(address(gateway), MINT_AMOUNT);
        
        // Execute transaction - should succeed but not process magic marker
        gateway.executeUniversalTx(
            txID,
            user1,
            address(mockToken),
            TARGET_CONTRACT,
            MINT_AMOUNT,
            shortPayload
        );
        
        // Verify no PC20 was created
        address pc20Address = pc20Factory.getPC20(ORIGIN_TOKEN_1);
        assertEq(pc20Address, address(0), "No PC20 should be created with short payload");
    }

    // =========================
    // INTEGRATION TESTS
    // =========================

    function test_executeUniversalTx_MultiplePC20Tokens() public {
        // Test creating multiple different PC20 tokens
        address[] memory originTokens = new address[](3);
        originTokens[0] = address(0x1111);
        originTokens[1] = address(0x2222);
        originTokens[2] = address(0x3333);
        
        MockERC20 mockToken = new MockERC20("Mock Token", "MOCK", 18, 0);
        address vault = gateway.VAULT();
        
        for (uint i = 0; i < originTokens.length; i++) {
            bytes memory pc20Payload = abi.encode(
                MAGIC_PCAS,
                META_VERSION,
                META_KIND_PC20,
                originTokens[i],
                string(abi.encodePacked(TOKEN_NAME, " ", vm.toString(i))),
                string(abi.encodePacked(TOKEN_SYMBOL, vm.toString(i))),
                TOKEN_DECIMALS
            );
            
            bytes memory txID = abi.encodePacked("test_tx_multi_", vm.toString(i));
            
            gateway.executeUniversalTx(
                txID,
                user1,
                address(mockToken),
                TARGET_CONTRACT,
                MINT_AMOUNT,
                pc20Payload
            );
            
            // Verify each PC20 was created and transferred to VAULT
            address pc20Address = pc20Factory.getPC20(originTokens[i]);
            assertTrue(pc20Address != address(0), string(abi.encodePacked("PC20 ", vm.toString(i), " should be created")));
            
            IPC20 pc20 = IPC20(pc20Address);
            assertEq(pc20.balanceOf(vault), MINT_AMOUNT, string(abi.encodePacked("PC20 ", vm.toString(i), " should be minted to VAULT")));
        }
    }

    function test_executeUniversalTx_PC20WithAdditionalPayload() public {
        // Create PC20 payload with additional data after the magic marker data
        bytes memory pc20Data = abi.encode(
            MAGIC_PCAS,
            META_VERSION,
            META_KIND_PC20,
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );
        
        // Append additional payload data
        bytes memory additionalData = abi.encodePacked("additional_call_data");
        bytes memory combinedPayload = abi.encodePacked(pc20Data, additionalData);
        
        bytes memory txID = abi.encodePacked("test_pc20_with_payload");
        MockERC20 mockToken = new MockERC20("Mock", "MOCK", 18, 0);
        
        // Execute transaction
        gateway.executeUniversalTx(
            txID,
            user1,
            address(mockToken),
            TARGET_CONTRACT,
            MINT_AMOUNT,
            combinedPayload
        );
        
        // Verify PC20 was created and minted to VAULT
        address pc20Address = pc20Factory.getPC20(ORIGIN_TOKEN_1);
        assertTrue(pc20Address != address(0), "PC20 should be created");
        
        IPC20 pc20 = IPC20(pc20Address);
        address vault = gateway.VAULT();
        assertEq(pc20.balanceOf(vault), MINT_AMOUNT, "PC20 should be minted to VAULT");
    }

    // =========================
    // ACCESS CONTROL TESTS
    // =========================

    function test_executeUniversalTx_TokenTx_RequiresVaultRole() public {
        bytes memory pc20Payload = abi.encode(
            MAGIC_PCAS,
            META_VERSION,
            META_KIND_PC20,
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );
        
        bytes memory txID = abi.encodePacked("test_vault_role");
        MockERC20 mockToken = new MockERC20("Mock", "MOCK", 18, 0);
        mockToken.mint(address(gateway), MINT_AMOUNT);
        
        // Should revert when called by non-VAULT_ROLE address
        vm.expectRevert();
        vm.prank(user1);
        gateway.executeUniversalTx(
            txID,
            user1,
            address(mockToken),
            TARGET_CONTRACT,
            MINT_AMOUNT,
            pc20Payload
        );
    }

    function test_executeUniversalTx_NativeTx_RequiresTSSRole() public {
        bytes memory pc20Payload = abi.encode(
            MAGIC_PCAS,
            META_VERSION,
            META_KIND_PC20,
            ORIGIN_TOKEN_1,
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS
        );
        
        bytes memory txID = abi.encodePacked("test_tss_role");
        uint256 ethAmount = 1e18;
        
        // Should revert when called by non-TSS_ROLE address
        vm.deal(user1, ethAmount);
        vm.expectRevert();
        vm.prank(user1);
        gateway.executeUniversalTx{value: ethAmount}(
            txID,
            user1,
            TARGET_CONTRACT,
            ethAmount,
            pc20Payload
        );
    }
}
