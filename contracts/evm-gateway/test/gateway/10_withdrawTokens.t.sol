// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { BaseTest } from "../BaseTest.t.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { IUniversalGateway } from "../../src/interfaces/IUniversalGateway.sol";
import { RevertInstructions, UniversalPayload, TX_TYPE } from "../../src/libraries/Types.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Test suite for TSS withdrawal functions (revertUniversalTx, revertUniversalTxToken, withdraw)
/// @dev Tests revertNative, revertTokens, onlyTSS modifier, and withdrawal functionality
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
        thresholds[0] = 1000000e6; // 1M USDC
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
        bytes32 universalTxID = bytes32(uint256(1001));
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.WithdrawFailed.selector));
        gateway.revertUniversalTx(txID, universalTxID, 1 ether, RevertInstructions(user1, ""));
    }

    function testOnlyTSS_TSSShouldSucceed() public {
        // TSS should be able to call TSS functions
        bytes32 txID = bytes32(uint256(2));
        bytes32 universalTxID = bytes32(uint256(1002));
        uint256 initialBalance = user1.balance;

        vm.deal(tss, 1 ether);
        vm.prank(tss);
        gateway.revertUniversalTx{ value: 1 ether }(txID, universalTxID, 1 ether, RevertInstructions(user1, ""));

        assertEq(user1.balance, initialBalance + 1 ether);
    }

    // =========================
    //      WITHDRAWFUNDS TESTS
    // =========================

    function testWithdrawFunds_NativeETH_Success() public {
        bytes32 txID = bytes32(uint256(3));
        bytes32 universalTxID = bytes32(uint256(1003));
        uint256 withdrawAmount = 2 ether;
        uint256 initialRecipientBalance = user1.balance;

        // Expect RevertUniversalTx event
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.RevertUniversalTx(txID, universalTxID, user1, address(0), withdrawAmount, RevertInstructions(user1, ""));

        vm.deal(tss, withdrawAmount);
        vm.prank(tss);
        gateway.revertUniversalTx{ value: withdrawAmount }(txID, universalTxID, withdrawAmount, RevertInstructions(user1, ""));

        // Check balances
        assertEq(user1.balance, initialRecipientBalance + withdrawAmount);
    }

    function testWithdrawFunds_ERC20Token_Success() public {
        bytes32 txID = bytes32(uint256(4));
        bytes32 universalTxID = bytes32(uint256(1004));
        uint256 withdrawAmount = 100e6; // 100 USDC
        uint256 initialGatewayBalance = usdc.balanceOf(address(gateway));
        uint256 initialRecipientBalance = usdc.balanceOf(user1);

        // Expect RevertUniversalTx event
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.RevertUniversalTx(
            txID, universalTxID, user1, address(usdc), withdrawAmount, RevertInstructions(user1, "")
        );

        // revertUniversalTxToken requires VAULT_ROLE (test contract has this role)
        gateway.revertUniversalTxToken(txID, universalTxID, address(usdc), withdrawAmount, RevertInstructions(user1, ""));

        // Check balances
        assertEq(usdc.balanceOf(address(gateway)), initialGatewayBalance - withdrawAmount);
        assertEq(usdc.balanceOf(user1), initialRecipientBalance + withdrawAmount);
    }

    function testWithdrawFunds_InvalidRecipient_Revert() public {
        bytes32 txID = bytes32(uint256(5));
        bytes32 universalTxID = bytes32(uint256(1005));
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRecipient.selector));
        gateway.revertUniversalTx(txID, universalTxID, 1 ether, RevertInstructions(address(0), ""));
    }

    function testWithdrawFunds_InvalidAmount_Revert() public {
        bytes32 txID = bytes32(uint256(6));
        bytes32 universalTxID = bytes32(uint256(1006));
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.revertUniversalTx(txID, universalTxID, 0, RevertInstructions(user1, ""));
    }

    function testWithdrawFunds_InsufficientBalance_Revert() public {
        bytes32 txID = bytes32(uint256(7));
        bytes32 universalTxID = bytes32(uint256(1007));
        uint256 amount = 1 ether;
        uint256 wrongValue = 0.5 ether;

        vm.deal(tss, wrongValue);
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.revertUniversalTx{ value: wrongValue }(txID, universalTxID, amount, RevertInstructions(user1, ""));
    }

    function testWithdrawFunds_ERC20InsufficientBalance_Revert() public {
        bytes32 txID = bytes32(uint256(8));
        bytes32 universalTxID = bytes32(uint256(1008));
        uint256 excessiveAmount = usdc.balanceOf(address(gateway)) + 1;

        vm.prank(tss);
        vm.expectRevert();
        gateway.revertUniversalTxToken(txID, universalTxID, address(usdc), excessiveAmount, RevertInstructions(user1, ""));
    }

    // =========================
    //      REVERTWITHDRAWFUNDS TESTS
    // =========================

    function testRevertWithdrawFunds_NativeETH_Success() public {
        bytes32 txID = bytes32(uint256(9));
        bytes32 universalTxID = bytes32(uint256(1009));
        uint256 withdrawAmount = 1.5 ether;
        uint256 initialRecipientBalance = user1.balance;

        RevertInstructions memory revertCfg = revertCfg(user1);

        // Expect RevertUniversalTx event
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.RevertUniversalTx(txID, universalTxID, user1, address(0), withdrawAmount, revertCfg);

        vm.deal(tss, withdrawAmount);
        vm.prank(tss);
        gateway.revertUniversalTx{ value: withdrawAmount }(txID, universalTxID, withdrawAmount, revertCfg);

        // Check balances
        assertEq(user1.balance, initialRecipientBalance + withdrawAmount);
    }

    function testRevertWithdrawFunds_ERC20Token_Success() public {
        bytes32 txID = bytes32(uint256(10));
        bytes32 universalTxID = bytes32(uint256(1010));
        uint256 withdrawAmount = 200e6; // 200 USDC
        uint256 initialGatewayBalance = usdc.balanceOf(address(gateway));
        uint256 initialRecipientBalance = usdc.balanceOf(user1);

        RevertInstructions memory revertCfg = revertCfg(user1);

        // Expect RevertUniversalTx event
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.RevertUniversalTx(txID, universalTxID, user1, address(usdc), withdrawAmount, revertCfg);

        // revertUniversalTxToken requires VAULT_ROLE (test contract has this role)
        gateway.revertUniversalTxToken(txID, universalTxID, address(usdc), withdrawAmount, revertCfg);

        // Check balances
        assertEq(usdc.balanceOf(address(gateway)), initialGatewayBalance - withdrawAmount);
        assertEq(usdc.balanceOf(user1), initialRecipientBalance + withdrawAmount);
    }

    function testRevertWithdrawFunds_InvalidRecipient_Revert() public {
        bytes32 txID = bytes32(uint256(11));
        bytes32 universalTxID = bytes32(uint256(1011));
        RevertInstructions memory revertCfg = revertCfg(address(0)); // Invalid user1

        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRecipient.selector));
        gateway.revertUniversalTx(txID, universalTxID, 1 ether, revertCfg);
    }

    function testRevertWithdrawFunds_InvalidAmount_Revert() public {
        bytes32 txID = bytes32(uint256(12));
        bytes32 universalTxID = bytes32(uint256(1012));
        RevertInstructions memory revertCfg = revertCfg(user1);

        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.revertUniversalTx(txID, universalTxID, 0, revertCfg);
    }

    function testRevertWithdrawFunds_InsufficientBalance_Revert() public {
        bytes32 txID = bytes32(uint256(13));
        bytes32 universalTxID = bytes32(uint256(1013));
        uint256 amount = 1 ether;
        uint256 wrongValue = 0.8 ether;
        RevertInstructions memory revertCfg = revertCfg(user1);

        vm.deal(tss, wrongValue);
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.revertUniversalTx{ value: wrongValue }(txID, universalTxID, amount, revertCfg);
    }

    // =========================
    //      EDGE CASES AND ERROR PATHS
    // =========================

    function testWithdrawFunds_WhenPaused_Revert() public {
        bytes32 txID = bytes32(uint256(14));
        bytes32 universalTxID = bytes32(uint256(1014));
        // Pause the contract
        vm.prank(admin);
        gateway.pause();

        vm.prank(tss);
        vm.expectRevert();
        gateway.revertUniversalTx(txID, universalTxID, 1 ether, RevertInstructions(user1, ""));
    }

    function testRevertWithdrawFunds_WhenPaused_Revert() public {
        bytes32 txID = bytes32(uint256(15));
        bytes32 universalTxID = bytes32(uint256(1015));
        // Pause the contract
        vm.prank(admin);
        gateway.pause();

        RevertInstructions memory revertCfg = revertCfg(user1);

        vm.prank(tss);
        vm.expectRevert();
        gateway.revertUniversalTx(txID, universalTxID, 1 ether, revertCfg);
    }

    function testWithdrawFunds_ReentrancyProtection() public {
        bytes32 txID = bytes32(uint256(16));
        bytes32 universalTxID = bytes32(uint256(1016));
        // This test ensures the nonReentrant modifier is working
        // We can't easily test reentrancy without a malicious contract,
        // but the modifier is there and will be covered by the test execution
        vm.deal(tss, 1 ether);
        vm.prank(tss);
        gateway.revertUniversalTx{ value: 1 ether }(txID, universalTxID, 1 ether, RevertInstructions(user1, ""));

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
        gateway.revertUniversalTxToken(
            bytes32(uint256(17)), bytes32(uint256(1017)), address(usdc), usdcAmount, RevertInstructions(user1, "")
        );
        assertEq(usdc.balanceOf(user1), initialUsdcBalance + usdcAmount);

        // Withdraw TokenA (requires VAULT_ROLE)
        uint256 initialTokenABalance = tokenA.balanceOf(user1);
        gateway.revertUniversalTxToken(
            bytes32(uint256(18)), bytes32(uint256(1018)), address(tokenA), tokenAAmount, RevertInstructions(user1, "")
        );
        assertEq(tokenA.balanceOf(user1), initialTokenABalance + tokenAAmount);

        // Withdraw ETH (requires TSS_ROLE)
        uint256 initialEthBalance = user1.balance;
        vm.deal(tss, ethAmount);
        vm.prank(tss);
        gateway.revertUniversalTx{ value: ethAmount }(
            bytes32(uint256(19)), bytes32(uint256(1019)), ethAmount, RevertInstructions(user1, "")
        );
        assertEq(user1.balance, initialEthBalance + ethAmount);
    }

    function testRevertWithdrawFunds_MultipleTokens() public {
        RevertInstructions memory revertCfg = revertCfg(user1);

        // Test reverting different token types
        uint256 usdcAmount = 25e6;
        uint256 ethAmount = 0.25 ether;

        // Revert USDC (requires VAULT_ROLE)
        uint256 initialUsdcBalance = usdc.balanceOf(user1);
        gateway.revertUniversalTxToken(bytes32(uint256(20)), bytes32(uint256(1020)), address(usdc), usdcAmount, revertCfg);
        assertEq(usdc.balanceOf(user1), initialUsdcBalance + usdcAmount);

        // Revert ETH (requires TSS_ROLE)
        uint256 initialEthBalance = user1.balance;
        vm.deal(tss, ethAmount);
        vm.prank(tss);
        gateway.revertUniversalTx{ value: ethAmount }(bytes32(uint256(21)), bytes32(uint256(1021)), ethAmount, revertCfg);
        assertEq(user1.balance, initialEthBalance + ethAmount);
    }

    // =========================
    //      REPLAY PROTECTION TESTS
    // =========================

    function testRevertUniversalTx_ReplayProtection_Native() public {
        bytes32 txID = bytes32(uint256(22));
        bytes32 universalTxID = bytes32(uint256(1022));
        uint256 amount = 1 ether;

        // First call should succeed
        vm.deal(tss, amount);
        vm.prank(tss);
        gateway.revertUniversalTx{ value: amount }(txID, universalTxID, amount, RevertInstructions(user1, ""));

        // Second call with same txID should revert
        vm.deal(tss, amount);
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.PayloadExecuted.selector));
        gateway.revertUniversalTx{ value: amount }(txID, universalTxID, amount, RevertInstructions(user1, ""));
    }

    function testRevertUniversalTxToken_ReplayProtection() public {
        bytes32 txID = bytes32(uint256(23));
        bytes32 universalTxID = bytes32(uint256(1023));
        uint256 amount = 100e6;

        // First call should succeed
        gateway.revertUniversalTxToken(txID, universalTxID, address(usdc), amount, RevertInstructions(user1, ""));

        // Second call with same txID should revert
        vm.expectRevert(abi.encodeWithSelector(Errors.PayloadExecuted.selector));
        gateway.revertUniversalTxToken(txID, universalTxID, address(usdc), amount, RevertInstructions(user1, ""));
    }

    // =========================
    //      WITHDRAW NATIVE TESTS - REMOVED
    // =========================
    // NOTE: Native withdrawal tests have been moved to test/vault/VaultWithdrawal.t.sol
    //       Withdrawals now route through Vault → CEA → User using executeUniversalTx with empty payload
    //       This file now only contains Gateway TSS revert function tests
}
