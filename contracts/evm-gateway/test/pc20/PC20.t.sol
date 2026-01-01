// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PC20 } from "../../src/PC20.sol";
import { Errors } from "../../src/libraries/Errors.sol";

/**
 * @title   PC20Test
 * @notice  Comprehensive test suite for PC20 contract
 * @dev     Tests minting, burning, transfers, and access control
 */
contract PC20Test is Test {
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
    PC20 public pc20;

    // =========================
    //      TEST CONSTANTS
    // =========================
    address public constant ORIGIN_TOKEN = address(0x1111);
    string public constant TOKEN_NAME = "Test Token";
    string public constant TOKEN_SYMBOL = "TEST";
    uint8 public constant TOKEN_DECIMALS = 18;

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

        pc20 = new PC20(TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS, gateway, ORIGIN_TOKEN);
    }

    // =========================
    //    CONSTRUCTOR TESTS
    // =========================

    function test_Constructor_Success() public {
        PC20 newPC20 = new PC20(TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS, gateway, ORIGIN_TOKEN);
        
        assertEq(newPC20.name(), TOKEN_NAME, "Name mismatch");
        assertEq(newPC20.symbol(), TOKEN_SYMBOL, "Symbol mismatch");
        assertEq(newPC20.decimals(), TOKEN_DECIMALS, "Decimals mismatch");
        assertEq(newPC20.gateway(), gateway, "Gateway mismatch");
        assertEq(newPC20.originToken(), ORIGIN_TOKEN, "Origin token mismatch");
        assertEq(newPC20.totalSupply(), 0, "Initial supply should be zero");
    }

    function test_Constructor_RevertZeroGateway() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new PC20(TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS, address(0), ORIGIN_TOKEN);
    }

    function test_Constructor_RevertZeroOriginToken() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new PC20(TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS, gateway, address(0));
    }

    function test_Constructor_DifferentDecimals() public {
        PC20 pc20_6 = new PC20(TOKEN_NAME, TOKEN_SYMBOL, 6, gateway, ORIGIN_TOKEN);
        assertEq(pc20_6.decimals(), 6, "Should support 6 decimals");

        PC20 pc20_0 = new PC20(TOKEN_NAME, TOKEN_SYMBOL, 0, gateway, ORIGIN_TOKEN);
        assertEq(pc20_0.decimals(), 0, "Should support 0 decimals");
    }

    // =========================
    //       MINT TESTS
    // =========================

    function test_Mint_Success() public {
        uint256 amount = 1000 ether;

        vm.prank(gateway);
        pc20.mint(user1, amount);

        assertEq(pc20.balanceOf(user1), amount, "Balance mismatch");
        assertEq(pc20.totalSupply(), amount, "Total supply mismatch");
    }

    function test_Mint_MultipleUsers() public {
        uint256 amount1 = 1000 ether;
        uint256 amount2 = 500 ether;

        vm.prank(gateway);
        pc20.mint(user1, amount1);

        vm.prank(gateway);
        pc20.mint(user2, amount2);

        assertEq(pc20.balanceOf(user1), amount1, "User1 balance mismatch");
        assertEq(pc20.balanceOf(user2), amount2, "User2 balance mismatch");
        assertEq(pc20.totalSupply(), amount1 + amount2, "Total supply mismatch");
    }

    function test_Mint_MultipleTimes() public {
        uint256 amount1 = 1000 ether;
        uint256 amount2 = 500 ether;

        vm.prank(gateway);
        pc20.mint(user1, amount1);

        vm.prank(gateway);
        pc20.mint(user1, amount2);

        assertEq(pc20.balanceOf(user1), amount1 + amount2, "Balance should accumulate");
        assertEq(pc20.totalSupply(), amount1 + amount2, "Total supply mismatch");
    }

    function test_Mint_RevertOnlyGateway() public {
        vm.prank(attacker);
        vm.expectRevert(PC20.OnlyGateway.selector);
        pc20.mint(user1, 1000 ether);
    }

    function test_Mint_RevertZeroAddress() public {
        vm.prank(gateway);
        vm.expectRevert(Errors.ZeroAddress.selector);
        pc20.mint(address(0), 1000 ether);
    }

    function test_Mint_RevertZeroAmount() public {
        vm.prank(gateway);
        vm.expectRevert(PC20.InvalidAmount.selector);
        pc20.mint(user1, 0);
    }

    // =========================
    //       BURN TESTS
    // =========================

    function test_Burn_Success() public {
        uint256 mintAmount = 1000 ether;
        uint256 burnAmount = 400 ether;

        // Mint first
        vm.prank(gateway);
        pc20.mint(user1, mintAmount);

        // Burn
        vm.prank(gateway);
        pc20.burn(user1, burnAmount);

        assertEq(pc20.balanceOf(user1), mintAmount - burnAmount, "Balance mismatch after burn");
        assertEq(pc20.totalSupply(), mintAmount - burnAmount, "Total supply mismatch after burn");
    }

    function test_Burn_EntireBalance() public {
        uint256 amount = 1000 ether;

        vm.prank(gateway);
        pc20.mint(user1, amount);

        vm.prank(gateway);
        pc20.burn(user1, amount);

        assertEq(pc20.balanceOf(user1), 0, "Balance should be zero");
        assertEq(pc20.totalSupply(), 0, "Total supply should be zero");
    }

    function test_Burn_MultipleTimes() public {
        uint256 mintAmount = 1000 ether;

        vm.prank(gateway);
        pc20.mint(user1, mintAmount);

        vm.prank(gateway);
        pc20.burn(user1, 300 ether);

        vm.prank(gateway);
        pc20.burn(user1, 200 ether);

        assertEq(pc20.balanceOf(user1), 500 ether, "Balance mismatch");
        assertEq(pc20.totalSupply(), 500 ether, "Total supply mismatch");
    }

    function test_Burn_RevertOnlyGateway() public {
        vm.prank(gateway);
        pc20.mint(user1, 1000 ether);

        vm.prank(attacker);
        vm.expectRevert(PC20.OnlyGateway.selector);
        pc20.burn(user1, 500 ether);
    }

    function test_Burn_RevertZeroAddress() public {
        vm.prank(gateway);
        vm.expectRevert(Errors.ZeroAddress.selector);
        pc20.burn(address(0), 1000 ether);
    }

    function test_Burn_RevertZeroAmount() public {
        vm.prank(gateway);
        pc20.mint(user1, 1000 ether);

        vm.prank(gateway);
        vm.expectRevert(PC20.InvalidAmount.selector);
        pc20.burn(user1, 0);
    }

    function test_Burn_RevertInsufficientBalance() public {
        vm.prank(gateway);
        pc20.mint(user1, 500 ether);

        vm.prank(gateway);
        vm.expectRevert();
        pc20.burn(user1, 1000 ether);
    }

    // =========================
    //     TRANSFER TESTS
    // =========================

    function test_Transfer_Success() public {
        uint256 amount = 1000 ether;
        uint256 transferAmount = 400 ether;

        vm.prank(gateway);
        pc20.mint(user1, amount);

        vm.prank(user1);
        pc20.transfer(user2, transferAmount);

        assertEq(pc20.balanceOf(user1), amount - transferAmount, "User1 balance mismatch");
        assertEq(pc20.balanceOf(user2), transferAmount, "User2 balance mismatch");
        assertEq(pc20.totalSupply(), amount, "Total supply should not change");
    }

    function test_Transfer_EntireBalance() public {
        uint256 amount = 1000 ether;

        vm.prank(gateway);
        pc20.mint(user1, amount);

        vm.prank(user1);
        pc20.transfer(user2, amount);

        assertEq(pc20.balanceOf(user1), 0, "User1 should have zero balance");
        assertEq(pc20.balanceOf(user2), amount, "User2 should have full amount");
    }

    function test_Transfer_RevertInsufficientBalance() public {
        vm.prank(gateway);
        pc20.mint(user1, 500 ether);

        vm.prank(user1);
        vm.expectRevert();
        pc20.transfer(user2, 1000 ether);
    }

    // =========================
    //     APPROVE/TRANSFERFROM TESTS
    // =========================

    function test_Approve_Success() public {
        uint256 amount = 1000 ether;

        vm.prank(user1);
        pc20.approve(user2, amount);

        assertEq(pc20.allowance(user1, user2), amount, "Allowance mismatch");
    }

    function test_TransferFrom_Success() public {
        uint256 mintAmount = 1000 ether;
        uint256 transferAmount = 400 ether;

        vm.prank(gateway);
        pc20.mint(user1, mintAmount);

        vm.prank(user1);
        pc20.approve(user2, transferAmount);

        vm.prank(user2);
        pc20.transferFrom(user1, user2, transferAmount);

        assertEq(pc20.balanceOf(user1), mintAmount - transferAmount, "User1 balance mismatch");
        assertEq(pc20.balanceOf(user2), transferAmount, "User2 balance mismatch");
        assertEq(pc20.allowance(user1, user2), 0, "Allowance should be consumed");
    }

    function test_TransferFrom_RevertInsufficientAllowance() public {
        vm.prank(gateway);
        pc20.mint(user1, 1000 ether);

        vm.prank(user1);
        pc20.approve(user2, 400 ether);

        vm.prank(user2);
        vm.expectRevert();
        pc20.transferFrom(user1, user2, 500 ether);
    }

    // =========================
    //     VIEW FUNCTION TESTS
    // =========================

    function test_Name() public {
        assertEq(pc20.name(), TOKEN_NAME, "Name should match");
    }

    function test_Symbol() public {
        assertEq(pc20.symbol(), TOKEN_SYMBOL, "Symbol should match");
    }

    function test_Decimals() public {
        assertEq(pc20.decimals(), TOKEN_DECIMALS, "Decimals should match");
    }

    function test_Gateway() public {
        assertEq(pc20.gateway(), gateway, "Gateway should match");
    }

    function test_OriginToken() public {
        assertEq(pc20.originToken(), ORIGIN_TOKEN, "Origin token should match");
    }

    function test_TotalSupply_InitiallyZero() public {
        assertEq(pc20.totalSupply(), 0, "Initial total supply should be zero");
    }

    function test_BalanceOf_InitiallyZero() public {
        assertEq(pc20.balanceOf(user1), 0, "Initial balance should be zero");
    }

    // =========================
    //     INTEGRATION TESTS
    // =========================

    function test_Integration_MintTransferBurn() public {
        uint256 initialAmount = 1000 ether;

        // Mint to user1
        vm.prank(gateway);
        pc20.mint(user1, initialAmount);

        // User1 transfers to user2
        vm.prank(user1);
        pc20.transfer(user2, 400 ether);

        // Burn from user1
        vm.prank(gateway);
        pc20.burn(user1, 300 ether);

        // Burn from user2
        vm.prank(gateway);
        pc20.burn(user2, 200 ether);

        assertEq(pc20.balanceOf(user1), 300 ether, "User1 final balance mismatch");
        assertEq(pc20.balanceOf(user2), 200 ether, "User2 final balance mismatch");
        assertEq(pc20.totalSupply(), 500 ether, "Final total supply mismatch");
    }

    function test_Integration_ApproveTransferFromBurn() public {
        uint256 amount = 1000 ether;

        // Mint to user1
        vm.prank(gateway);
        pc20.mint(user1, amount);

        // User1 approves user2
        vm.prank(user1);
        pc20.approve(user2, 600 ether);

        // User2 transfers from user1 to themselves
        vm.prank(user2);
        pc20.transferFrom(user1, user2, 400 ether);

        // Gateway burns from both
        vm.prank(gateway);
        pc20.burn(user1, 300 ether);

        vm.prank(gateway);
        pc20.burn(user2, 200 ether);

        assertEq(pc20.balanceOf(user1), 300 ether, "User1 final balance mismatch");
        assertEq(pc20.balanceOf(user2), 200 ether, "User2 final balance mismatch");
        assertEq(pc20.totalSupply(), 500 ether, "Final total supply mismatch");
    }

    // =========================
    //       FUZZ TESTS
    // =========================

    function testFuzz_Mint(uint256 amount) public {
        // Bound to reasonable range to avoid vm.assume rejections
        amount = bound(amount, 1, type(uint128).max);

        vm.prank(gateway);
        pc20.mint(user1, amount);

        assertEq(pc20.balanceOf(user1), amount, "Balance should match minted amount");
        assertEq(pc20.totalSupply(), amount, "Total supply should match minted amount");
    }

    function testFuzz_MintAndBurn(uint256 mintAmount, uint256 burnAmount) public {
        // Bound to reasonable ranges
        mintAmount = bound(mintAmount, 1, type(uint128).max);
        burnAmount = bound(burnAmount, 1, mintAmount);

        vm.prank(gateway);
        pc20.mint(user1, mintAmount);

        vm.prank(gateway);
        pc20.burn(user1, burnAmount);

        assertEq(pc20.balanceOf(user1), mintAmount - burnAmount, "Balance mismatch");
        assertEq(pc20.totalSupply(), mintAmount - burnAmount, "Total supply mismatch");
    }

    function testFuzz_Transfer(uint256 mintAmount, uint256 transferAmount) public {
        // Bound to reasonable ranges
        mintAmount = bound(mintAmount, 1, type(uint128).max);
        transferAmount = bound(transferAmount, 1, mintAmount);

        vm.prank(gateway);
        pc20.mint(user1, mintAmount);

        vm.prank(user1);
        pc20.transfer(user2, transferAmount);

        assertEq(pc20.balanceOf(user1), mintAmount - transferAmount, "User1 balance mismatch");
        assertEq(pc20.balanceOf(user2), transferAmount, "User2 balance mismatch");
        assertEq(pc20.totalSupply(), mintAmount, "Total supply should not change");
    }

    function testFuzz_Decimals(uint8 decimals) public {
        PC20 newPC20 = new PC20(TOKEN_NAME, TOKEN_SYMBOL, decimals, gateway, ORIGIN_TOKEN);
        assertEq(newPC20.decimals(), decimals, "Decimals should match");
    }
}
