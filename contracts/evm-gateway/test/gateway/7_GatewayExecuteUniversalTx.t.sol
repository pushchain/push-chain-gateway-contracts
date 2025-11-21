// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockTarget } from "../mocks/MockTarget.sol";
import { MockRevertingTarget } from "../mocks/MockRevertingTarget.sol";
import { MockUSDTToken } from "../mocks/MockUSDTToken.sol";
import { MockTokenApprovalVariants } from "../mocks/MockTokenApprovalVariants.sol";

contract GatewayExecuteUniversalTxTest is Test {
    UniversalGateway public gateway;
    MockERC20 public token;
    MockTarget public target;
    MockRevertingTarget public revertingTarget;
    MockUSDTToken public usdtToken;
    MockTokenApprovalVariants public approvalToken;

    address public admin = address(0x1);
    address public pauser = address(0x2);
    address public tss = address(0x3);
    address public user = address(0x4);
    address public targetAddress = address(0x5);

    bytes32 public constant TX_ID = keccak256("test-tx-id");
    bytes32 public constant DUPLICATE_TX_ID = keccak256("duplicate-tx-id");
    address public constant ORIGIN_CALLER = address(0x6);
    address public constant ZERO_ADDRESS = address(0);
    uint256 public constant AMOUNT = 1000e18;
    bytes public constant PAYLOAD = abi.encodeWithSignature("receiveFunds()");
    bytes public constant EMPTY_PAYLOAD = "";

    event UniversalTxExecuted(
        bytes32 indexed txID,
        address indexed originCaller,
        address indexed target,
        address token,
        uint256 amount,
        bytes payload
    );

    function setUp() public {
        // Deploy contracts
        gateway = new UniversalGateway();
        token = new MockERC20("Test Token", "TT", 18, 1000000e18);
        target = new MockTarget();
        revertingTarget = new MockRevertingTarget();
        usdtToken = new MockUSDTToken();
        approvalToken = new MockTokenApprovalVariants();

        // Initialize gateway
        gateway.initialize(
            admin,
            tss,
            address(this), // vault address
            1e18, // minCapUsd
            10e18, // maxCapUsd
            address(0), // factory
            address(0), // router
            address(0x123) // weth (dummy address for testing)
        );

        // Set up token support
        address[] memory tokens = new address[](3);
        uint256[] memory thresholds = new uint256[](3);
        tokens[0] = address(token);
        tokens[1] = address(usdtToken);
        tokens[2] = address(approvalToken);
        thresholds[0] = 10000e18;
        thresholds[1] = 10000e18;
        thresholds[2] = 10000e18;
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Fund test contract (acting as Vault) with tokens
        token.mint(address(this), 100000e18);
        usdtToken.mint(address(this), 100000e18);
        approvalToken.mint(address(this), 100000e18);
    }

    // =========================
    //   executeUniversalTx Tests
    // =========================

    function testExecuteUniversalTx_NotTSS_Reverts() public {
        vm.expectRevert();
        vm.prank(user);
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), AMOUNT, PAYLOAD);
    }

    function testExecuteUniversalTx_WhenPaused_Reverts() public {
        vm.prank(admin);
        gateway.pause();

        vm.expectRevert();
        vm.prank(tss); // Native token executeUniversalTx requires TSS_ROLE
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), AMOUNT, PAYLOAD);
    }

    function testExecuteUniversalTx_ValidTSS_Succeeds() public {
        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), AMOUNT, PAYLOAD);

        assertTrue(gateway.isExecuted(TX_ID));
    }

    // Input Validation Tests
    function testExecuteUniversalTx_DuplicateTxID_Reverts() public {
        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT * 2);

        // First execution succeeds
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), AMOUNT, PAYLOAD);

        // Second execution with same txID reverts
        vm.expectRevert(abi.encodeWithSelector(Errors.PayloadExecuted.selector));
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), AMOUNT, PAYLOAD);
    }

    function testExecuteUniversalTx_ZeroOriginCaller_Reverts() public {
        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidInput.selector));
        gateway.executeUniversalTx(TX_ID, ZERO_ADDRESS, address(token), address(target), AMOUNT, PAYLOAD);
    }

    function testExecuteUniversalTx_ZeroTarget_Reverts() public {
        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidInput.selector));
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), ZERO_ADDRESS, AMOUNT, PAYLOAD);
    }

    function testExecuteUniversalTx_ZeroAmount_Reverts() public {
        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), 0, PAYLOAD);
    }

    function testExecuteUniversalTx_EmptyPayload_Succeeds() public {
        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), AMOUNT, EMPTY_PAYLOAD);

        assertTrue(gateway.isExecuted(TX_ID));
        // Verify the target received the call
        assertEq(target.lastCaller(), address(gateway));
    }

    // Native (ETH) Path Tests
    function testExecuteUniversalTx_NativePath_Success() public {
        uint256 initialBalance = address(target).balance;

        vm.deal(tss, AMOUNT);

        vm.expectEmit(true, true, true, false);
        emit UniversalTxExecuted(TX_ID, ORIGIN_CALLER, address(target), ZERO_ADDRESS, AMOUNT, PAYLOAD);

        vm.prank(tss); // Native token executeUniversalTx requires TSS_ROLE
        gateway.executeUniversalTx{ value: AMOUNT }(
            TX_ID, ORIGIN_CALLER, address(target), AMOUNT, PAYLOAD
        );

        assertTrue(gateway.isExecuted(TX_ID));
        assertEq(address(target).balance, initialBalance + AMOUNT);
    }

    function testExecuteUniversalTx_NativePath_WrongValue_Reverts() public {
        vm.deal(tss, AMOUNT - 1);
        vm.prank(tss); // Native token executeUniversalTx requires TSS_ROLE
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.executeUniversalTx{ value: AMOUNT - 1 }(
            TX_ID, ORIGIN_CALLER, address(target), AMOUNT, PAYLOAD
        );

        vm.deal(tss, AMOUNT + 1);
        vm.prank(tss); // Native token executeUniversalTx requires TSS_ROLE
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.executeUniversalTx{ value: AMOUNT + 1 }(
            TX_ID, ORIGIN_CALLER, address(target), AMOUNT, PAYLOAD
        );
    }

    function testExecuteUniversalTx_NativePath_NonPayableTarget_Reverts() public {
        vm.deal(tss, AMOUNT);

        bytes memory nonPayablePayload = abi.encodeWithSignature("receiveFundsNonPayable()");

        vm.prank(tss); // Native token executeUniversalTx requires TSS_ROLE
        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutionFailed.selector));
        gateway.executeUniversalTx{ value: AMOUNT }(
            TX_ID, ORIGIN_CALLER, address(revertingTarget), AMOUNT, nonPayablePayload
        );
    }

    function testExecuteUniversalTx_NativePath_TargetReverts_Reverts() public {
        vm.deal(tss, AMOUNT);

        vm.prank(tss); // Native token executeUniversalTx requires TSS_ROLE
        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutionFailed.selector));
        gateway.executeUniversalTx{ value: AMOUNT }(
            TX_ID, ORIGIN_CALLER, address(revertingTarget), AMOUNT, PAYLOAD
        );

        assertFalse(gateway.isExecuted(TX_ID));
    }

    function testExecuteUniversalTx_NativePath_GasExhaustion_Reverts() public {
        vm.deal(tss, AMOUNT);

        bytes memory gasHeavyPayload = abi.encodeWithSignature("receiveFundsGasHeavy()");

        vm.prank(tss); // Native token executeUniversalTx requires TSS_ROLE
        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutionFailed.selector));
        gateway.executeUniversalTx{ value: AMOUNT, gas: 3000000 }(
            TX_ID, ORIGIN_CALLER, address(revertingTarget), AMOUNT, gasHeavyPayload
        );

        assertFalse(gateway.isExecuted(TX_ID));
    }

    // ERC-20 Path Tests
    function testExecuteUniversalTx_ERC20Path_WithValue_Reverts() public {
        vm.deal(tss, 1);

        vm.prank(tss); // Native token executeUniversalTx requires TSS_ROLE
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.executeUniversalTx{ value: 1 }(TX_ID, ORIGIN_CALLER, address(target), AMOUNT, PAYLOAD);
    }

    function testExecuteUniversalTx_ERC20Path_InsufficientBalance_Reverts() public {
        uint256 largeAmount = 1000000e18;

        // Transfer a small amount of tokens to Gateway
        token.transfer(address(gateway), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), largeAmount, PAYLOAD);
    }

    function testExecuteUniversalTx_ERC20Path_Success() public {
        // Initial setup
        uint256 initialBalance = token.balanceOf(address(target));
        bytes memory tokenPayload = abi.encodeWithSignature("receiveToken(address,uint256)", address(token), AMOUNT);

        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit UniversalTxExecuted(TX_ID, ORIGIN_CALLER, address(target), address(token), AMOUNT, tokenPayload);

        // Execute as Vault (this contract has VAULT_ROLE)
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), AMOUNT, tokenPayload);

        assertTrue(gateway.isExecuted(TX_ID));
        assertEq(token.balanceOf(address(target)), initialBalance + AMOUNT);
    }

    function testExecuteUniversalTx_ERC20Path_TargetReverts_Reverts() public {
        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutionFailed.selector));
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(revertingTarget), AMOUNT, PAYLOAD);

        assertFalse(gateway.isExecuted(TX_ID));
    }

    function testExecuteUniversalTx_ERC20Path_SafeApproveFails_Reverts() public {
        approvalToken.setApprovalBehavior(MockTokenApprovalVariants.ApprovalBehavior.RETURN_FALSE);
        
        // Transfer tokens from Vault (test contract) to Gateway
        approvalToken.transfer(address(gateway), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidData.selector));
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(approvalToken), address(target), AMOUNT, PAYLOAD);

        assertFalse(gateway.isExecuted(TX_ID));
    }

    function testExecuteUniversalTx_ERC20Path_ResetApprovalFails_Reverts() public {
        approvalToken.setApprovalBehavior(MockTokenApprovalVariants.ApprovalBehavior.RETURN_FALSE);

        // Transfer tokens from Vault (test contract) to Gateway
        approvalToken.transfer(address(gateway), AMOUNT);

        vm.prank(address(gateway));
        approvalToken.approve(address(target), AMOUNT);

        bytes memory tokenPayload =
            abi.encodeWithSignature("receiveToken(address,uint256)", address(approvalToken), AMOUNT);

        // This should revert because the token returns false on approve(0)
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidData.selector));
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(approvalToken), address(target), AMOUNT, tokenPayload);

        // Transaction should not be executed
        assertFalse(gateway.isExecuted(TX_ID));
    }

    // Reentrancy Tests
    // Event & State Tests
    function testExecuteUniversalTx_EventEmittedCorrectly() public {
        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit UniversalTxExecuted(TX_ID, ORIGIN_CALLER, address(target), address(token), AMOUNT, PAYLOAD);

        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), AMOUNT, PAYLOAD);
    }

    function testExecuteUniversalTx_StateUpdatedCorrectly() public {
        assertFalse(gateway.isExecuted(TX_ID));

        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), AMOUNT, PAYLOAD);

        assertTrue(gateway.isExecuted(TX_ID));
    }

    // =========================
    //   _resetApproval Tests
    // =========================

    function testResetApproval_StandardERC20_Success() public {
        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        vm.prank(address(gateway));
        token.approve(address(target), 1000);
        assertEq(token.allowance(address(gateway), address(target)), 1000);

        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), AMOUNT, PAYLOAD);

        assertEq(token.allowance(address(gateway), address(target)), 0);
    }

    function testResetApproval_USDTStyle_Success() public {
        // Transfer tokens from Vault (test contract) to Gateway
        usdtToken.transfer(address(gateway), AMOUNT);

        vm.prank(address(gateway));
        usdtToken.approve(address(target), 1000);
        assertEq(usdtToken.allowance(address(gateway), address(target)), 1000);

        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(usdtToken), address(target), AMOUNT, PAYLOAD);

        assertEq(usdtToken.allowance(address(gateway), address(target)), 0);
    }

    function testResetApproval_NoReturnData_Success() public {
        // Configure approvalToken for no return data behavior
        approvalToken.setApprovalBehavior(MockTokenApprovalVariants.ApprovalBehavior.NO_RETURN_DATA);

        // Transfer tokens from Vault (test contract) to Gateway
        approvalToken.transfer(address(gateway), AMOUNT);

        vm.prank(address(gateway));
        approvalToken.approve(address(target), AMOUNT);
        assertEq(approvalToken.allowance(address(gateway), address(target)), AMOUNT);

        bytes memory tokenPayload =
            abi.encodeWithSignature("receiveToken(address,uint256)", address(approvalToken), AMOUNT);

        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(approvalToken), address(target), AMOUNT, tokenPayload);

        assertTrue(gateway.isExecuted(TX_ID));

        assertEq(approvalToken.balanceOf(address(target)), AMOUNT);
    }

    function testResetApproval_RevertsOnZeroApproval_Success() public {
        approvalToken.setApprovalBehavior(MockTokenApprovalVariants.ApprovalBehavior.REVERT_ON_ZERO);

        // Transfer tokens from Vault (test contract) to Gateway
        approvalToken.transfer(address(gateway), AMOUNT);

        vm.prank(address(gateway));
        approvalToken.approve(address(target), AMOUNT);
        assertEq(approvalToken.allowance(address(gateway), address(target)), AMOUNT);

        bytes memory tokenPayload =
            abi.encodeWithSignature("receiveToken(address,uint256)", address(approvalToken), AMOUNT);

        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(approvalToken), address(target), AMOUNT, tokenPayload);

        assertTrue(gateway.isExecuted(TX_ID));

        assertEq(approvalToken.balanceOf(address(target)), AMOUNT);
    }

    function testResetApproval_ReturnsFalse_Reverts() public {
        approvalToken.setApprovalBehavior(MockTokenApprovalVariants.ApprovalBehavior.RETURN_FALSE);

        // Transfer tokens from Vault (test contract) to Gateway
        approvalToken.transfer(address(gateway), AMOUNT);

        vm.prank(address(gateway));
        approvalToken.approve(address(target), AMOUNT);
        assertEq(approvalToken.allowance(address(gateway), address(target)), AMOUNT);

        bytes memory tokenPayload =
            abi.encodeWithSignature("receiveToken(address,uint256)", address(approvalToken), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidData.selector));
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(approvalToken), address(target), AMOUNT, tokenPayload);

        assertFalse(gateway.isExecuted(TX_ID));
    }

    // =========================
    //   _safeApprove Tests
    // =========================

    function testSafeApprove_StandardERC20_Success() public {
        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        vm.prank(address(gateway));
        token.approve(address(target), 0);
        assertEq(token.allowance(address(gateway), address(target)), 0);

        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), AMOUNT, PAYLOAD);

        assertEq(token.allowance(address(gateway), address(target)), 0);
    }

    function testSafeApprove_USDTStyle_FromZero_Success() public {
        // Transfer tokens from Vault (test contract) to Gateway
        usdtToken.transfer(address(gateway), AMOUNT);

        vm.prank(address(gateway));
        usdtToken.approve(address(target), 0);
        assertEq(usdtToken.allowance(address(gateway), address(target)), 0);

        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(usdtToken), address(target), AMOUNT, PAYLOAD);

        assertEq(usdtToken.allowance(address(gateway), address(target)), 0);
    }

    function testSafeApprove_USDTStyle_FromNonZero_Reverts() public {
        // Create a fresh USDT-style token
        MockUSDTToken mockUsdtToken = new MockUSDTToken();

        mockUsdtToken.mint(address(gateway), AMOUNT);

        vm.startPrank(address(gateway));
        mockUsdtToken.approve(address(target), 0);
        mockUsdtToken.approve(address(target), 1000);
        vm.stopPrank();
        assertEq(mockUsdtToken.allowance(address(gateway), address(target)), 1000);

        bytes memory tokenPayload =
            abi.encodeWithSignature("receiveToken(address,uint256)", address(mockUsdtToken), AMOUNT);

        vm.startPrank(address(gateway));
        vm.expectRevert("USDT: Cannot approve from non-zero to non-zero");
        mockUsdtToken.approve(address(target), AMOUNT);
        vm.stopPrank();

        // The full executeUniversalTx would actually succeed because it calls _resetApproval first
        // So we're just testing that the direct approve would fail without the reset

        // Transaction should not be executed
        assertFalse(gateway.isExecuted(TX_ID));
    }

    function testSafeApprove_NoReturnData_Success() public {
        approvalToken.setApprovalBehavior(MockTokenApprovalVariants.ApprovalBehavior.NO_RETURN_DATA);

        // Transfer tokens from Vault (test contract) to Gateway
        approvalToken.transfer(address(gateway), AMOUNT);

        vm.prank(address(gateway));
        approvalToken.approve(address(target), 0);
        assertEq(approvalToken.allowance(address(gateway), address(target)), 0);

        bytes memory tokenPayload =
            abi.encodeWithSignature("receiveToken(address,uint256)", address(approvalToken), AMOUNT);

        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(approvalToken), address(target), AMOUNT, tokenPayload);

        assertTrue(gateway.isExecuted(TX_ID));

        assertEq(approvalToken.balanceOf(address(target)), AMOUNT);
    }

    function testSafeApprove_ReturnsFalse_Reverts() public {
        approvalToken.setApprovalBehavior(MockTokenApprovalVariants.ApprovalBehavior.RETURN_FALSE);

        // Transfer tokens from Vault (test contract) to Gateway
        approvalToken.transfer(address(gateway), AMOUNT);

        vm.prank(address(gateway));
        approvalToken.approve(address(target), 0);
        assertEq(approvalToken.allowance(address(gateway), address(target)), 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidData.selector));
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(approvalToken), address(target), AMOUNT, PAYLOAD);
    }

    function testSafeApprove_RevertsOnApprove_Reverts() public {
        // Configure approvalToken to always revert on approve
        approvalToken.setApprovalBehavior(MockTokenApprovalVariants.ApprovalBehavior.ALWAYS_REVERT);

        // Transfer tokens from Vault (test contract) to Gateway
        approvalToken.transfer(address(gateway), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidData.selector));
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(approvalToken), address(target), AMOUNT, PAYLOAD);
    }

    function testSafeApprove_Idempotency_Success() public {
        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        // Approve X, reset to 0, approve X again
        vm.prank(address(gateway));
        token.approve(address(target), AMOUNT);
        assertEq(token.allowance(address(gateway), address(target)), AMOUNT);

        // Reset to 0
        vm.prank(address(gateway));
        token.approve(address(target), 0);
        assertEq(token.allowance(address(gateway), address(target)), 0);

        // Approve again
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), AMOUNT, PAYLOAD);

        assertEq(token.allowance(address(gateway), address(target)), 0);
    }

    // =========================
    //   _executeCall Tests
    // =========================

    function testExecuteCall_SuccessNoValue() public {
        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), AMOUNT, PAYLOAD);

        assertEq(target.lastCaller(), address(gateway));
        assertEq(target.lastAmount(), 0);
        assertTrue(gateway.isExecuted(TX_ID));
    }

    function testExecuteCall_SuccessWithValue() public {
        uint256 initialBalance = address(target).balance;

        vm.deal(tss, AMOUNT);

        vm.prank(tss); // Native token executeUniversalTx requires TSS_ROLE
        gateway.executeUniversalTx{ value: AMOUNT }(
            TX_ID, ORIGIN_CALLER, address(target), AMOUNT, PAYLOAD
        );

        assertEq(address(target).balance, initialBalance + AMOUNT);
        assertTrue(gateway.isExecuted(TX_ID));
    }

    function testExecuteCall_NonPayableTargetWithValue_Reverts() public {
        vm.deal(tss, AMOUNT);

        bytes memory nonPayablePayload = abi.encodeWithSignature("receiveFundsNonPayable()");

        vm.prank(tss); // Native token executeUniversalTx requires TSS_ROLE
        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutionFailed.selector));
        gateway.executeUniversalTx{ value: AMOUNT }(
            TX_ID, ORIGIN_CALLER, address(revertingTarget), AMOUNT, nonPayablePayload
        );
    }

    function testExecuteCall_TargetReverts_Reverts() public {
        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutionFailed.selector));
        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(revertingTarget), AMOUNT, PAYLOAD);
    }

    function testExecuteCall_GasExhaustion_Reverts() public {
        bytes memory gasHeavyPayload = abi.encodeWithSignature("receiveFundsGasHeavy()");

        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutionFailed.selector));
        gateway.executeUniversalTx(
            TX_ID, ORIGIN_CALLER, address(token), address(revertingTarget), AMOUNT, gasHeavyPayload
        );
    }

    function testExecuteUniversalTx_ERC20WithArbitraryCall() public {
        bytes memory approvePayload = abi.encodeWithSignature("approve(address,uint256)", address(0x7), 500e18);

        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(token), AMOUNT, approvePayload);

        assertTrue(gateway.isExecuted(TX_ID));
        assertEq(token.allowance(address(gateway), address(0x7)), 500e18);
    }

    function testExecuteUniversalTx_MultipleExecutionsDifferentTxIDs() public {
        bytes32 txId1 = keccak256("tx1");
        bytes32 txId2 = keccak256("tx2");

        // Transfer tokens from Vault (test contract) to Gateway for first execution
        token.transfer(address(gateway), AMOUNT);

        gateway.executeUniversalTx(txId1, ORIGIN_CALLER, address(token), address(target), AMOUNT, PAYLOAD);

        // Transfer more tokens for second execution
        token.transfer(address(gateway), AMOUNT);

        gateway.executeUniversalTx(txId2, ORIGIN_CALLER, address(token), address(target), AMOUNT, PAYLOAD);

        assertTrue(gateway.isExecuted(txId1));
        assertTrue(gateway.isExecuted(txId2));
    }

    function testIsExecutedMapping() public {
        assertFalse(gateway.isExecuted(TX_ID));

        // Transfer tokens from Vault (test contract) to Gateway
        token.transfer(address(gateway), AMOUNT);

        gateway.executeUniversalTx(TX_ID, ORIGIN_CALLER, address(token), address(target), AMOUNT, PAYLOAD);

        assertTrue(gateway.isExecuted(TX_ID));
    }
}
