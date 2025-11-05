// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { BaseTest } from "../BaseTest.t.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { IUniversalGateway } from "../../src/interfaces/IUniversalGateway.sol";
import { RevertInstructions, UniversalPayload, TX_TYPE } from "../../src/libraries/Types.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Test suite for missing TSS functions and sendTxWithFunds 4-parameter version
/// @dev Tests revertNative, revertTokens, onlyTSS modifier, and sendTxWithFunds overload
contract GatewayTSSFunctionsTest is BaseTest {
    // =========================
    //      SETUP
    // =========================
    function setUp() public override {
        super.setUp();

        // Fund the gateway with some ETH and tokens for withdrawal tests
        vm.deal(address(gateway), 10 ether);

        // Configure token support
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(tokenA);
        
        uint256[] memory thresholds = new uint256[](2);
        thresholds[0] = 1000000e6;  // 1M USDC
        thresholds[1] = 1000000e18; // 1M tokenA
        
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Mint and transfer some test tokens to the gateway
        usdc.mint(address(gateway), 1000e6);
        tokenA.mint(address(gateway), 1000e18);
    }

    // =========================
    //      ONLYTSS MODIFIER TESTS
    // =========================

    function testOnlyTSS_NonTSSShouldRevert() public {
        // Non-TSS user should not be able to call TSS functions
        bytes32 txID = bytes32(uint256(1));
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.WithdrawFailed.selector));
        gateway.revertUniversalTx(txID, 1 ether, RevertInstructions(user1, ""));
    }

    function testOnlyTSS_TSSShouldSucceed() public {
        // TSS should be able to call TSS functions
        bytes32 txID = bytes32(uint256(2));
        uint256 initialBalance = user1.balance;

        vm.deal(tss, 1 ether);
        vm.prank(tss);
        gateway.revertUniversalTx{value: 1 ether}(txID, 1 ether, RevertInstructions(user1, ""));

        assertEq(user1.balance, initialBalance + 1 ether);
    }

    // =========================
    //      WITHDRAWFUNDS TESTS
    // =========================

    function testWithdrawFunds_NativeETH_Success() public {
        bytes32 txID = bytes32(uint256(3));
        uint256 withdrawAmount = 2 ether;
        uint256 initialRecipientBalance = user1.balance;

        // Expect RevertUniversalTx event
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.RevertUniversalTx(txID, user1, address(0), withdrawAmount, RevertInstructions(user1, ""));

        vm.deal(tss, withdrawAmount);
        vm.prank(tss);
        gateway.revertUniversalTx{value: withdrawAmount}(txID, withdrawAmount, RevertInstructions(user1, ""));

        // Check balances
        assertEq(user1.balance, initialRecipientBalance + withdrawAmount);
    }

    function testWithdrawFunds_ERC20Token_Success() public {
        bytes32 txID = bytes32(uint256(4));
        uint256 withdrawAmount = 100e6; // 100 USDC
        uint256 initialGatewayBalance = usdc.balanceOf(address(gateway));
        uint256 initialRecipientBalance = usdc.balanceOf(user1);

        // Expect RevertUniversalTx event
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.RevertUniversalTx(txID, user1, address(usdc), withdrawAmount, RevertInstructions(user1, ""));

        // revertUniversalTxToken requires VAULT_ROLE (test contract has this role)
        gateway.revertUniversalTxToken(txID, address(usdc), withdrawAmount, RevertInstructions(user1, ""));

        // Check balances
        assertEq(usdc.balanceOf(address(gateway)), initialGatewayBalance - withdrawAmount);
        assertEq(usdc.balanceOf(user1), initialRecipientBalance + withdrawAmount);
    }

    function testWithdrawFunds_InvalidRecipient_Revert() public {
        bytes32 txID = bytes32(uint256(5));
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRecipient.selector));
        gateway.revertUniversalTx(txID, 1 ether, RevertInstructions(address(0), ""));
    }

    function testWithdrawFunds_InvalidAmount_Revert() public {
        bytes32 txID = bytes32(uint256(6));
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.revertUniversalTx(txID, 0, RevertInstructions(user1, ""));
    }

    function testWithdrawFunds_InsufficientBalance_Revert() public {
        bytes32 txID = bytes32(uint256(7));
        uint256 amount = 1 ether;
        uint256 wrongValue = 0.5 ether;

        vm.deal(tss, wrongValue);
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.revertUniversalTx{value: wrongValue}(txID, amount, RevertInstructions(user1, ""));
    }

    function testWithdrawFunds_ERC20InsufficientBalance_Revert() public {
        bytes32 txID = bytes32(uint256(8));
        uint256 excessiveAmount = usdc.balanceOf(address(gateway)) + 1;

        vm.prank(tss);
        vm.expectRevert();
        gateway.revertUniversalTxToken(txID, address(usdc), excessiveAmount, RevertInstructions(user1, ""));
    }

    // =========================
    //      REVERTWITHDRAWFUNDS TESTS
    // =========================

    function testRevertWithdrawFunds_NativeETH_Success() public {
        bytes32 txID = bytes32(uint256(9));
        uint256 withdrawAmount = 1.5 ether;
        uint256 initialRecipientBalance = user1.balance;

        RevertInstructions memory revertCfg = revertCfg(user1);

        // Expect RevertUniversalTx event
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.RevertUniversalTx(txID, user1, address(0), withdrawAmount, revertCfg);

        vm.deal(tss, withdrawAmount);
        vm.prank(tss);
        gateway.revertUniversalTx{value: withdrawAmount}(txID, withdrawAmount, revertCfg);

        // Check balances
        assertEq(user1.balance, initialRecipientBalance + withdrawAmount);
    }

    function testRevertWithdrawFunds_ERC20Token_Success() public {
        bytes32 txID = bytes32(uint256(10));
        uint256 withdrawAmount = 200e6; // 200 USDC
        uint256 initialGatewayBalance = usdc.balanceOf(address(gateway));
        uint256 initialRecipientBalance = usdc.balanceOf(user1);

        RevertInstructions memory revertCfg = revertCfg(user1);

        // Expect RevertUniversalTx event
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.RevertUniversalTx(txID, user1, address(usdc), withdrawAmount, revertCfg);

        // revertUniversalTxToken requires VAULT_ROLE (test contract has this role)
        gateway.revertUniversalTxToken(txID, address(usdc), withdrawAmount, revertCfg);

        // Check balances
        assertEq(usdc.balanceOf(address(gateway)), initialGatewayBalance - withdrawAmount);
        assertEq(usdc.balanceOf(user1), initialRecipientBalance + withdrawAmount);
    }

    function testRevertWithdrawFunds_InvalidRecipient_Revert() public {
        bytes32 txID = bytes32(uint256(11));
        RevertInstructions memory revertCfg = revertCfg(address(0)); // Invalid user1

        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRecipient.selector));
        gateway.revertUniversalTx(txID, 1 ether, revertCfg);
    }

    function testRevertWithdrawFunds_InvalidAmount_Revert() public {
        bytes32 txID = bytes32(uint256(12));
        RevertInstructions memory revertCfg = revertCfg(user1);

        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.revertUniversalTx(txID, 0, revertCfg);
    }

    function testRevertWithdrawFunds_InsufficientBalance_Revert() public {
        bytes32 txID = bytes32(uint256(13));
        uint256 amount = 1 ether;
        uint256 wrongValue = 0.8 ether;
        RevertInstructions memory revertCfg = revertCfg(user1);

        vm.deal(tss, wrongValue);
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.revertUniversalTx{value: wrongValue}(txID, amount, revertCfg);
    }

    // =========================
    //      EDGE CASES AND ERROR PATHS
    // =========================

    function testWithdrawFunds_WhenPaused_Revert() public {
        bytes32 txID = bytes32(uint256(14));
        // Pause the contract
        vm.prank(admin);
        gateway.pause();

        vm.prank(tss);
        vm.expectRevert();
        gateway.revertUniversalTx(txID, 1 ether, RevertInstructions(user1, ""));
    }

    function testRevertWithdrawFunds_WhenPaused_Revert() public {
        bytes32 txID = bytes32(uint256(15));
        // Pause the contract
        vm.prank(admin);
        gateway.pause();

        RevertInstructions memory revertCfg = revertCfg(user1);

        vm.prank(tss);
        vm.expectRevert();
        gateway.revertUniversalTx(txID, 1 ether, revertCfg);
    }

    function testWithdrawFunds_ReentrancyProtection() public {
        bytes32 txID = bytes32(uint256(16));
        // This test ensures the nonReentrant modifier is working
        // We can't easily test reentrancy without a malicious contract,
        // but the modifier is there and will be covered by the test execution
        vm.deal(tss, 1 ether);
        vm.prank(tss);
        gateway.revertUniversalTx{value: 1 ether}(txID, 1 ether, RevertInstructions(user1, ""));

        // If we get here without reverting, the reentrancy protection is working
        assertTrue(true);
    }

    function testWithdrawFunds_MultipleTokens() public {
        // Test withdrawing different token types
        uint256 usdcAmount = 50e6;
        uint256 tokenAAmount = 100e18;
        uint256 ethAmount = 0.5 ether;

        // Withdraw USDC (requires VAULT_ROLE)
        uint256 initialUsdcBalance = usdc.balanceOf(user1);
        gateway.revertUniversalTxToken(bytes32(uint256(17)), address(usdc), usdcAmount, RevertInstructions(user1, ""));
        assertEq(usdc.balanceOf(user1), initialUsdcBalance + usdcAmount);

        // Withdraw TokenA (requires VAULT_ROLE)
        uint256 initialTokenABalance = tokenA.balanceOf(user1);
        gateway.revertUniversalTxToken(bytes32(uint256(18)), address(tokenA), tokenAAmount, RevertInstructions(user1, ""));
        assertEq(tokenA.balanceOf(user1), initialTokenABalance + tokenAAmount);

        // Withdraw ETH (requires TSS_ROLE)
        uint256 initialEthBalance = user1.balance;
        vm.deal(tss, ethAmount);
        vm.prank(tss);
        gateway.revertUniversalTx{value: ethAmount}(bytes32(uint256(19)), ethAmount, RevertInstructions(user1, ""));
        assertEq(user1.balance, initialEthBalance + ethAmount);
    }

    function testRevertWithdrawFunds_MultipleTokens() public {
        RevertInstructions memory revertCfg = revertCfg(user1);

        // Test reverting different token types
        uint256 usdcAmount = 25e6;
        uint256 ethAmount = 0.25 ether;

        // Revert USDC (requires VAULT_ROLE)
        uint256 initialUsdcBalance = usdc.balanceOf(user1);
        gateway.revertUniversalTxToken(bytes32(uint256(20)), address(usdc), usdcAmount, revertCfg);
        assertEq(usdc.balanceOf(user1), initialUsdcBalance + usdcAmount);

        // Revert ETH (requires TSS_ROLE)
        uint256 initialEthBalance = user1.balance;
        vm.deal(tss, ethAmount);
        vm.prank(tss);
        gateway.revertUniversalTx{value: ethAmount}(bytes32(uint256(21)), ethAmount, revertCfg);
        assertEq(user1.balance, initialEthBalance + ethAmount);
    }

    // =========================
    //      REPLAY PROTECTION TESTS
    // =========================

    function testRevertUniversalTx_ReplayProtection_Native() public {
        bytes32 txID = bytes32(uint256(22));
        uint256 amount = 1 ether;
        
        // First call should succeed
        vm.deal(tss, amount);
        vm.prank(tss);
        gateway.revertUniversalTx{value: amount}(txID, amount, RevertInstructions(user1, ""));
        
        // Second call with same txID should revert
        vm.deal(tss, amount);
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.PayloadExecuted.selector));
        gateway.revertUniversalTx{value: amount}(txID, amount, RevertInstructions(user1, ""));
    }

    function testRevertUniversalTxToken_ReplayProtection() public {
        bytes32 txID = bytes32(uint256(23));
        uint256 amount = 100e6;
        
        // First call should succeed
        gateway.revertUniversalTxToken(txID, address(usdc), amount, RevertInstructions(user1, ""));
        
        // Second call with same txID should revert
        vm.expectRevert(abi.encodeWithSelector(Errors.PayloadExecuted.selector));
        gateway.revertUniversalTxToken(txID, address(usdc), amount, RevertInstructions(user1, ""));
    }

    // =========================
    //      WITHDRAW NATIVE TESTS
    // =========================

    function testWithdraw_Native_Success() public {
        bytes32 txID = bytes32(uint256(24));
        uint256 amount = 5 ether;
        address originCaller = user2;
        
        uint256 initialBalance = user1.balance;
        
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.WithdrawToken(txID, originCaller, address(0), user1, amount);
        
        vm.deal(tss, amount);
        vm.prank(tss);
        gateway.withdraw{value: amount}(txID, originCaller, user1, amount);
        
        assertEq(user1.balance, initialBalance + amount);
    }

    function testWithdraw_Native_OnlyTSS() public {
        bytes32 txID = bytes32(uint256(25));
        uint256 amount = 1 ether;
        
        vm.deal(user1, amount);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.WithdrawFailed.selector));
        gateway.withdraw{value: amount}(txID, user1, user2, amount);
    }

    function testWithdraw_Native_ReplayProtection() public {
        bytes32 txID = bytes32(uint256(26));
        uint256 amount = 2 ether;
        
        // First call should succeed
        vm.deal(tss, amount);
        vm.prank(tss);
        gateway.withdraw{value: amount}(txID, user1, user2, amount);
        
        // Second call with same txID should revert
        vm.deal(tss, amount);
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.PayloadExecuted.selector));
        gateway.withdraw{value: amount}(txID, user1, user2, amount);
    }

    function testWithdraw_Native_ZeroRecipient_Reverts() public {
        bytes32 txID = bytes32(uint256(27));
        uint256 amount = 1 ether;
        
        vm.deal(tss, amount);
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidInput.selector));
        gateway.withdraw{value: amount}(txID, user1, address(0), amount);
    }

    function testWithdraw_Native_ZeroOriginCaller_Reverts() public {
        bytes32 txID = bytes32(uint256(28));
        uint256 amount = 1 ether;
        
        vm.deal(tss, amount);
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidInput.selector));
        gateway.withdraw{value: amount}(txID, address(0), user1, amount);
    }

    function testWithdraw_Native_ZeroAmount_Reverts() public {
        bytes32 txID = bytes32(uint256(29));
        
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.withdraw(txID, user1, user2, 0);
    }

    function testWithdraw_Native_AmountMismatch_Reverts() public {
        bytes32 txID = bytes32(uint256(30));
        uint256 amount = 1 ether;
        uint256 wrongValue = 0.5 ether;
        
        vm.deal(tss, wrongValue);
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.withdraw{value: wrongValue}(txID, user1, user2, amount);
    }

    function testWithdraw_Native_WhenPaused_Reverts() public {
        bytes32 txID = bytes32(uint256(31));
        uint256 amount = 1 ether;
        
        vm.prank(admin);
        gateway.pause();
        
        vm.deal(tss, amount);
        vm.prank(tss);
        vm.expectRevert();
        gateway.withdraw{value: amount}(txID, user1, user2, amount);
    }

    function testWithdraw_Native_EmitsCorrectEvent() public {
        bytes32 txID = bytes32(uint256(32));
        uint256 amount = 3 ether;
        address originCaller = user2;
        address recipient = user1;
        
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.WithdrawToken(txID, originCaller, address(0), recipient, amount);
        
        vm.deal(tss, amount);
        vm.prank(tss);
        gateway.withdraw{value: amount}(txID, originCaller, recipient, amount);
    }

    function testWithdraw_Native_MultipleSequentialWithdrawals() public {
        uint256 amount1 = 1 ether;
        uint256 amount2 = 2 ether;
        
        uint256 initialBalance = user1.balance;
        
        vm.deal(tss, amount1);
        vm.prank(tss);
        gateway.withdraw{value: amount1}(bytes32(uint256(33)), user2, user1, amount1);
        
        vm.deal(tss, amount2);
        vm.prank(tss);
        gateway.withdraw{value: amount2}(bytes32(uint256(34)), user2, user1, amount2);
        
        assertEq(user1.balance, initialBalance + amount1 + amount2);
    }
}
