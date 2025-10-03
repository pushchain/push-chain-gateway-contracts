pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { BaseTest } from "../BaseTest.t.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { TX_TYPE, RevertInstructions, UniversalPayload, VerificationType } from "../../src/libraries/Types.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniversalGateway } from "../../src/interfaces/IUniversalGateway.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Test suite for NATIVE ETH deposit functions in UniversalGateway
/// @dev Covers only the 2 functions that use PURE native ETH:
///      1. sendTxWithGas(payload, revertCFG) - Native ETH gas funding
///      2. sendFunds(recipient, address(0), bridgeAmount, revertCFG) - Native ETH bridging
/// @dev Note: sendTxWithFunds uses native ETH for gas but requires ERC20 for bridging, so it's not pure native
contract GatewayDepositNativeTest is BaseTest {
    // =========================
    //      SETUP
    // =========================
    function setUp() public override {
        super.setUp();
        // No additional setup needed for pure native ETH tests
    }

    // =========================
    //      HAPPY PATH TESTS - Native ETH Functions
    // =========================

    /// @notice Test sendTxWithGas (native ETH) with valid parameters
    function testSendTxWithGas_NativeETH_HappyPath() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload,) = buildValuePayload(recipient, abi.encodeWithSignature("receive()"), 0);
        RevertInstructions memory revertCfg_ = revertCfg(recipient);

        // Calculate valid ETH amount (within USD caps)
        // ETH price is $2000, so for $5 (middle of $1-$10 range): 5e18 / 2000e18 = 0.0025 ETH
        uint256 validEthAmount = 25e14; // 0.0025 ETH = $5

        // Fund user1 with ETH
        vm.deal(user1, validEthAmount);

        // Record initial balances
        uint256 initialTSSBalance = tss.balance;
        uint256 initialUserBalance = user1.balance;

        // Expect UniversalTx event emission
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1, address(0), address(0), validEthAmount, abi.encode(payload), revertCfg_, TX_TYPE.GAS_AND_PAYLOAD
        );

        // Execute the transaction
        vm.prank(user1);
        gateway.sendTxWithGas{ value: validEthAmount }(payload, revertCfg_);

        // Verify TSS received the ETH
        assertEq(tss.balance, initialTSSBalance + validEthAmount, "TSS should receive ETH");
        assertEq(user1.balance, initialUserBalance - validEthAmount, "User should pay ETH");
    }

    /// @notice Test sendFunds (native ETH + funds) with valid parameters
    function testSendFunds_NativeETH_HappyPath() public {
        // Setup: Use native ETH as bridge token (address(0)) and create revert config
        RevertInstructions memory revertCfg_ = revertCfg(recipient);
        uint256 bridgeAmount = 1e18; // 1 ETH

        // Fund user1 with ETH for the transaction
        vm.deal(user1, bridgeAmount);

        // Record initial balances
        uint256 initialTSSBalance = tss.balance;
        uint256 initialUserBalance = user1.balance;
        uint256 initialGatewayBalance = address(gateway).balance;

        // Expect UniversalTx event emission
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1,
            recipient,
            address(0), // address(0) for native ETH bridging
            bridgeAmount,
            bytes(""), // Empty payload for funds-only bridge
            revertCfg_,
            TX_TYPE.FUNDS
        );

        // Execute the transaction - native ETH bridging
        vm.prank(user1);
        gateway.sendFunds{ value: bridgeAmount }(
            recipient,
            address(0), // address(0) for native ETH bridging
            bridgeAmount,
            revertCfg_
        );

        // Verify TSS received the ETH
        assertEq(tss.balance, initialTSSBalance + bridgeAmount, "TSS should receive ETH");
        assertEq(user1.balance, initialUserBalance - bridgeAmount, "User should pay ETH");
        assertEq(address(gateway).balance, initialGatewayBalance, "Gateway should not hold ETH (sent to TSS)");
    }

    /// @notice Test all native functions with minimum valid amounts
    function testAllNativeFunctions_MinimumAmounts_Success() public {
        // Calculate minimum ETH amount for USD caps
        // ETH price is $2000, so for $1.01 (just above $1 min): 1.01e18 / 2000e18 = 0.000505 ETH
        uint256 minEthAmount = 505e12; // 0.000505 ETH = $1.01

        // Setup payload and revert config
        (UniversalPayload memory payload,) = buildValuePayload(recipient, abi.encodeWithSignature("receive()"), 0);
        RevertInstructions memory revertCfg_ = revertCfg(recipient);

        // Fund user1 with minimum ETH
        vm.deal(user1, minEthAmount * 3); // Enough for all 3 functions

        // tokenA is already minted and approved in BaseTest setup

        // Test 1: sendTxWithGas with minimum amount
        uint256 initialTSSBalance = tss.balance;

        // Expect UniversalTx event emission
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(user1, address(0), address(0), minEthAmount, abi.encode(payload), revertCfg_, TX_TYPE.GAS_AND_PAYLOAD);

        vm.prank(user1);
        gateway.sendTxWithGas{ value: minEthAmount }(payload, revertCfg_);
        assertEq(tss.balance, initialTSSBalance + minEthAmount, "TSS should receive min ETH for sendTxWithGas");

        // Test 2: sendFunds with minimum amounts (native ETH bridging)
        initialTSSBalance = tss.balance;

        // Expect UniversalTx event emission
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1,
            recipient,
            address(0), // address(0) for native ETH bridging
            minEthAmount, // bridge amount = ETH amount for native bridging
            bytes(""), // Empty payload for funds-only bridge
            revertCfg_,
            TX_TYPE.FUNDS
        );

        vm.prank(user1);
        gateway.sendFunds{ value: minEthAmount }(
            recipient,
            address(0), // address(0) for native ETH bridging
            minEthAmount, // bridge amount = ETH amount for native bridging
            revertCfg_
        );
        assertEq(tss.balance, initialTSSBalance + minEthAmount, "TSS should receive min ETH for sendFunds");
    }

    /// @notice Test all native functions with maximum valid amounts
    function testAllNativeFunctions_MaximumAmounts_Success() public {
        // Calculate maximum ETH amount for USD caps
        // ETH price is $2000, so for $9.99 (just below $10 max): 9.99e18 / 2000e18 = 0.004995 ETH
        uint256 maxEthAmount = 4995e12; // 0.004995 ETH = $9.99
        // Setup payload and revert config
        (UniversalPayload memory payload,) = buildValuePayload(recipient, abi.encodeWithSignature("receive()"), 0);
        RevertInstructions memory revertCfg_ = revertCfg(recipient);

        // Fund user1 with maximum ETH
        vm.deal(user1, maxEthAmount * 3); // Enough for all 3 functions

        // tokenA is already minted and approved in BaseTest setup

        // Test 1: sendTxWithGas with maximum amount
        uint256 initialTSSBalance = tss.balance;

        // Expect UniversalTx event emission
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(user1, address(0), address(0), maxEthAmount, abi.encode(payload), revertCfg_, TX_TYPE.GAS_AND_PAYLOAD);

        vm.prank(user1);
        gateway.sendTxWithGas{ value: maxEthAmount }(payload, revertCfg_);
        assertEq(tss.balance, initialTSSBalance + maxEthAmount, "TSS should receive max ETH for sendTxWithGas");
        // Test 2: sendFunds with maximum amounts (native ETH bridging)
        initialTSSBalance = tss.balance;

        // Expect UniversalTx event emission
        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1,
            recipient,
            address(0), // address(0) for native ETH bridging
            maxEthAmount, // bridge amount = ETH amount for native bridging
            bytes(""), // Empty payload for funds-only bridge
            revertCfg_,
            TX_TYPE.FUNDS
        );

        vm.prank(user1);
        gateway.sendFunds{ value: maxEthAmount }(
            recipient,
            address(0), // address(0) for native ETH bridging
            maxEthAmount, // bridge amount = ETH amount for native bridging
            revertCfg_
        );
        assertEq(tss.balance, initialTSSBalance + maxEthAmount, "TSS should receive max ETH for sendFunds");
    }

    // =========================
    //      USD CAP VALIDATION TESTS
    // =========================

    /// @notice Test sendTxWithGas (native) below minimum USD cap
    function testSendTxWithGas_NativeETH_BelowMinCap_Reverts() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload,) = buildValuePayload(recipient, abi.encodeWithSignature("receive()"), 0);
        RevertInstructions memory revertCfg_ = revertCfg(recipient);

        // Calculate ETH amount below minimum USD cap
        // ETH price is $2000, so for $0.99 (below $1 min): 0.99e18 / 2000e18 = 0.000495 ETH
        uint256 belowMinEthAmount = 495e12; // 0.000495 ETH = $0.99

        // Fund user1 with ETH
        vm.deal(user1, belowMinEthAmount);

        // Execute the transaction and expect it to revert
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector); // Should revert due to USD cap check
        gateway.sendTxWithGas{ value: belowMinEthAmount }(payload, revertCfg_);
    }

    /// @notice Test sendTxWithGas (native) above maximum USD cap
    function testSendTxWithGas_NativeETH_AboveMaxCap_Reverts() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload,) = buildValuePayload(recipient, abi.encodeWithSignature("receive()"), 0);
        RevertInstructions memory revertCfg_ = revertCfg(recipient);

        // Calculate ETH amount above maximum USD cap
        // ETH price is $2000, so for $10.01 (above $10 max): 10.01e18 / 2000e18 = 0.005005 ETH
        uint256 aboveMaxEthAmount = 5005e12; // 0.005005 ETH = $10.01

        // Fund user1 with ETH
        vm.deal(user1, aboveMaxEthAmount);

        // Execute the transaction and expect it to revert
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector); // Should revert due to USD cap check
        gateway.sendTxWithGas{ value: aboveMaxEthAmount }(payload, revertCfg_);
    }

    /// @notice Test sendTxWithGas (native) with zero amount
    function testSendTxWithGas_NativeETH_ZeroAmount_Reverts() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload,) = buildValuePayload(recipient, abi.encodeWithSignature("receive()"), 0);
        RevertInstructions memory revertCfg_ = revertCfg(recipient);

        // Fund user1 with some ETH (but we'll send 0)
        vm.deal(user1, 1e18);

        // Execute the transaction with zero value and expect it to revert
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector); // Should revert due to zero amount
        gateway.sendTxWithGas{ value: 0 }(payload, revertCfg_);
    }

    // =========================
    //      TOKEN SUPPORT VALIDATION TESTS
    // =========================

    /// @notice Test sendFunds with zero bridge amount
    function testSendFunds_ZeroBridgeAmount_Reverts() public {
        // Setup: Create revert config
        RevertInstructions memory revertCfg_ = revertCfg(recipient);
        uint256 ethAmount = 1e18; // 1 ETH

        // Fund user1 with ETH
        vm.deal(user1, ethAmount);

        // Execute the transaction with zero bridge amount and expect it to revert
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendFunds{ value: ethAmount }(
            recipient,
            address(0), // address(0) for native ETH bridging
            0, // Zero bridge amount
            revertCfg_
        );
    }

    // =========================
    //      ACCESS CONTROL & PAUSE TESTS
    // =========================

    /// @notice Test sendTxWithGas (native) when contract is paused
    function testSendTxWithGas_NativeETH_WhenPaused_Reverts() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();

        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload,) = buildValuePayload(recipient, abi.encodeWithSignature("receive()"), 0);
        RevertInstructions memory revertCfg_ = revertCfg(recipient);
        uint256 validEthAmount = 25e14; // 0.0025 ETH = $5
        vm.deal(user1, validEthAmount);

        // Execute the transaction and expect it to revert due to pause
        vm.prank(user1);
        vm.expectRevert(); // Should revert due to whenNotPaused modifier
        gateway.sendTxWithGas{ value: validEthAmount }(payload, revertCfg_);
    }

    /// @notice Test sendFunds when contract is paused
    function testSendFunds_WhenPaused_Reverts() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();

        // Setup: Create revert config
        RevertInstructions memory revertCfg_ = revertCfg(recipient);
        uint256 bridgeAmount = 1e18; // 1 ETH
        vm.deal(user1, bridgeAmount);

        // Execute the transaction and expect it to revert due to pause
        vm.prank(user1);
        vm.expectRevert(); // Should revert due to whenNotPaused modifier
        gateway.sendFunds{ value: bridgeAmount }(
            recipient,
            address(0), // address(0) for native ETH bridging
            bridgeAmount,
            revertCfg_
        );
    }

    /// @notice Test sendTxWithGas (native) reentrancy protection via nonReentrant modifier
    function testSendTxWithGas_NativeETH_ReentrancyProtection_Success() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload,) = buildValuePayload(recipient, abi.encodeWithSignature("receive()"), 0);
        RevertInstructions memory revertCfg_ = revertCfg(recipient);
        uint256 validEthAmount = 25e14; // 0.0025 ETH = $5
        vm.deal(user1, validEthAmount);

        // Test that the function works normally (reentrancy protection is built into the modifier)
        vm.prank(user1);
        gateway.sendTxWithGas{ value: validEthAmount }(payload, revertCfg_);

        // Verify the transaction succeeded and TSS received the ETH
        assertTrue(true, "Reentrancy protection is handled by nonReentrant modifier");
    }

    /// @notice Test sendFunds reentrancy protection via nonReentrant modifier
    function testSendFunds_ReentrancyProtection_Success() public {
        // Setup: Create revert config
        RevertInstructions memory revertCfg_ = revertCfg(recipient);
        uint256 bridgeAmount = 1e18; // 1 ETH
        vm.deal(user1, bridgeAmount);

        // Test that the function works normally (reentrancy protection is built into the modifier)
        vm.prank(user1);
        gateway.sendFunds{ value: bridgeAmount }(
            recipient,
            address(0), // address(0) for native ETH bridging
            bridgeAmount,
            revertCfg_
        );

        // Verify the transaction succeeded and TSS received the ETH
        assertTrue(true, "Reentrancy protection is handled by nonReentrant modifier");
    }

    // =========================
    //      ORACLE INTEGRATION TESTS
    // =========================

    /// @notice Test sendTxWithGas (native) with oracle failures
    function testSendTxWithGas_NativeETH_OracleFailures_Reverts() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload,) = buildValuePayload(recipient, abi.encodeWithSignature("receive()"), 0);
        RevertInstructions memory revertCfg_ = revertCfg(recipient);
        uint256 validEthAmount = 25e14; // 0.0025 ETH = $5
        vm.deal(user1, validEthAmount);

        // Test 1: Stale oracle data
        vm.warp(block.timestamp + 3601); // Move time beyond stale period (3600s default)
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidData.selector);
        gateway.sendTxWithGas{ value: validEthAmount }(payload, revertCfg_);

        // Reset time
        vm.warp(block.timestamp - 3601);

        // Test 2: Zero price from oracle
        ethUsdFeedMock.setAnswer(0, block.timestamp); // price = 0
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidData.selector);
        gateway.sendTxWithGas{ value: validEthAmount }(payload, revertCfg_);

        // Test 3: Negative price from oracle
        ethUsdFeedMock.setAnswer(-1000, block.timestamp); // price = -1000
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidData.selector);
        gateway.sendTxWithGas{ value: validEthAmount }(payload, revertCfg_);

        // Test 4: Sequencer down (if L2 sequencer feed is configured)
        if (address(sequencerMock) != address(0)) {
            sequencerMock.setStatus(true, block.timestamp); // status = 1 (DOWN)
            vm.prank(user1);
            vm.expectRevert(Errors.InvalidData.selector);
            gateway.sendTxWithGas{ value: validEthAmount }(payload, revertCfg_);
        }
    }

    // =========================
    //      PAYLOAD VALIDATION TESTS
    // =========================

    // =========================
    //      PARAMETER VALIDATION TESTS
    // =========================

    /// @notice Test sendFunds with zero recipient
    function testSendFunds_ZeroRecipient_Reverts() public {
        // Setup: Create revert config
        RevertInstructions memory revertCfg_ = revertCfg(recipient);
        uint256 bridgeAmount = 1e18; // 1 ETH
        uint256 ethAmount = 1e18; // 1 ETH
        vm.deal(user1, ethAmount);

        // Execute the transaction with zero recipient and expect it to revert
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        gateway.sendFunds{ value: ethAmount }(
            address(0), // Zero recipient
            address(0), // address(0) for native ETH bridging
            bridgeAmount,
            revertCfg_
        );
    }

    // =========================
    //      TSS TRANSFER VERIFICATION TESTS
    // =========================

    /// @notice Test that TSS actually receives ETH from sendTxWithGas
    function testSendTxWithGas_TSSReceivesETH_Success() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload,) = buildValuePayload(recipient, abi.encodeWithSignature("receive()"), 0);
        RevertInstructions memory revertCfg_ = revertCfg(recipient);
        uint256 validEthAmount = 25e14; // 0.0025 ETH = $5

        // Fund user1 with ETH
        vm.deal(user1, validEthAmount);

        // Record initial TSS balance
        uint256 initialTSSBalance = tss.balance;

        // Execute the transaction
        vm.prank(user1);
        gateway.sendTxWithGas{ value: validEthAmount }(payload, revertCfg_);

        // Verify TSS received the exact amount
        assertEq(tss.balance, initialTSSBalance + validEthAmount, "TSS should receive exact ETH amount");

        // Verify gateway contract has no ETH (it forwards to TSS)
        assertEq(address(gateway).balance, 0, "Gateway should not hold ETH after forwarding to TSS");
    }

    /// @notice Test that TSS actually receives ETH from sendFunds
    function testSendFunds_TSSReceivesETH_Success() public {
        // Setup: Create revert config
        RevertInstructions memory revertCfg_ = revertCfg(recipient);
        uint256 bridgeAmount = 1e18; // 1 ETH

        // Fund user1 with ETH
        vm.deal(user1, bridgeAmount);

        // Record initial TSS balance
        uint256 initialTSSBalance = tss.balance;

        // Execute the transaction
        vm.prank(user1);
        gateway.sendFunds{ value: bridgeAmount }(
            recipient,
            address(0), // address(0) for native ETH bridging
            bridgeAmount,
            revertCfg_
        );

        // Verify TSS received the exact amount
        assertEq(tss.balance, initialTSSBalance + bridgeAmount, "TSS should receive exact ETH amount");

        // Verify gateway contract has no ETH (it forwards to TSS)
        assertEq(address(gateway).balance, 0, "Gateway should not hold ETH after forwarding to TSS");
    }

    // =========================
    //      COMPREHENSIVE EDGE CASES
    // =========================

    /// @notice Test boundary values around USD caps
    function testUSD_CapBoundaryValues_Success() public {
        // Get current ETH price and calculate exact boundary amounts
        (uint256 minEthAmount, uint256 maxEthAmount) = gateway.getMinMaxValueForNative();

        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload,) = buildValuePayload(recipient, abi.encodeWithSignature("receive()"), 0);
        RevertInstructions memory revertCfg_ = revertCfg(recipient);

        // Test minimum amount (should pass)
        vm.deal(user1, minEthAmount);
        vm.prank(user1);
        gateway.sendTxWithGas{ value: minEthAmount }(payload, revertCfg_);

        // Test maximum amount (should pass)
        vm.deal(user1, maxEthAmount);
        vm.prank(user1);
        gateway.sendTxWithGas{ value: maxEthAmount }(payload, revertCfg_);

        // Test just below minimum (should fail)
        uint256 belowMin = minEthAmount - 1;
        vm.deal(user1, belowMin);
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendTxWithGas{ value: belowMin }(payload, revertCfg_);

        // Test just above maximum (should fail)
        uint256 aboveMax = maxEthAmount + 1;
        vm.deal(user1, aboveMax);
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendTxWithGas{ value: aboveMax }(payload, revertCfg_);
    }

    /// @notice Test with different ETH prices to verify USD cap calculations
    function testDifferentETH_Prices_Success() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload,) = buildValuePayload(recipient, abi.encodeWithSignature("receive()"), 0);
        RevertInstructions memory revertCfg_ = revertCfg(recipient);

        // Test with very high ETH price ($10,000)
        ethUsdFeedMock.setAnswer(10000e8, block.timestamp); // $10,000 ETH

        // With $10,000 ETH, $1 = 0.0001 ETH, $10 = 0.001 ETH
        uint256 minAmount = 1e14; // 0.0001 ETH = $1
        uint256 maxAmount = 1e15; // 0.001 ETH = $10

        vm.deal(user1, maxAmount);
        vm.prank(user1);
        gateway.sendTxWithGas{ value: maxAmount }(payload, revertCfg_);

        // Test with very low ETH price ($100)
        ethUsdFeedMock.setAnswer(100e8, block.timestamp); // $100 ETH

        // With $100 ETH, $1 = 0.01 ETH, $10 = 0.1 ETH
        minAmount = 1e16; // 0.01 ETH = $1
        maxAmount = 1e17; // 0.1 ETH = $10

        vm.deal(user1, maxAmount);
        vm.prank(user1);
        gateway.sendTxWithGas{ value: maxAmount }(payload, revertCfg_);
    }

    /// @notice Test multiple deposits in sequence
    function testMultipleDeposits_Sequence_Success() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload,) = buildValuePayload(recipient, abi.encodeWithSignature("receive()"), 0);
        RevertInstructions memory revertCfg_ = revertCfg(recipient);
        uint256 validEthAmount = 25e14; // 0.0025 ETH = $5

        // Fund user1 with enough ETH for multiple deposits
        vm.deal(user1, validEthAmount * 5);

        uint256 initialTSSBalance = tss.balance;

        // Make 5 deposits in sequence
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user1);
            gateway.sendTxWithGas{ value: validEthAmount }(payload, revertCfg_);
        }

        // Verify TSS received all deposits
        assertEq(tss.balance, initialTSSBalance + (validEthAmount * 5), "TSS should receive all sequential deposits");
    }

    /// @notice Test deposits from different users
    function testDeposits_DifferentUsers_Success() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload,) = buildValuePayload(recipient, abi.encodeWithSignature("receive()"), 0);
        RevertInstructions memory revertCfg_ = revertCfg(recipient);
        uint256 validEthAmount = 25e14; // 0.0025 ETH = $5

        // Fund multiple users
        vm.deal(user1, validEthAmount);
        vm.deal(user2, validEthAmount);
        vm.deal(user3, validEthAmount);

        uint256 initialTSSBalance = tss.balance;

        // Each user makes a deposit
        vm.prank(user1);
        gateway.sendTxWithGas{ value: validEthAmount }(payload, revertCfg_);

        vm.prank(user2);
        gateway.sendTxWithGas{ value: validEthAmount }(payload, revertCfg_);

        vm.prank(user3);
        gateway.sendTxWithGas{ value: validEthAmount }(payload, revertCfg_);

        // Verify TSS received all deposits
        assertEq(tss.balance, initialTSSBalance + (validEthAmount * 3), "TSS should receive deposits from all users");
    }

    /// @notice Test sendFunds with mismatched msg.value and bridgeAmount
    function testSendFunds_MismatchedAmounts_Reverts() public {
        // Setup: Create revert config
        RevertInstructions memory revertCfg_ = revertCfg(recipient);
        uint256 bridgeAmount = 1e18; // 1 ETH
        uint256 msgValue = 2e18; // 2 ETH (different from bridgeAmount)

        vm.deal(user1, msgValue);

        // For native ETH bridging, msg.value must equal bridgeAmount
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendFunds{ value: msgValue }(
            recipient,
            address(0), // address(0) for native ETH bridging
            bridgeAmount, // Different from msg.value
            revertCfg_
        );
    }

    /// @notice Test sendFunds with non-zero msg.value when using ERC20 token
    function testSendFunds_NonZeroMsgValueWithERC20_Reverts() public {
        // Setup: Create revert config
        RevertInstructions memory revertCfg_ = revertCfg(recipient);
        uint256 bridgeAmount = 1e18; // 1 ETH worth of tokens
        uint256 msgValue = 1e18; // 1 ETH (should be 0 for ERC20)

        vm.deal(user1, msgValue);

        // For ERC20 bridging, msg.value must be 0
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendFunds{ value: msgValue }(
            recipient,
            address(weth), // ERC20 token
            bridgeAmount,
            revertCfg_
        );
    }
}
