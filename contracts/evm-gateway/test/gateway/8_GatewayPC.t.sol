// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { UniversalGatewayPC } from "../../src/UniversalGatewayPC.sol";
import { IUniversalGatewayPC } from "../../src/interfaces/IUniversalGatewayPC.sol";
import { RevertInstructions } from "../../src/libraries/Types.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { MockPRC20 } from "../mocks/MockPRC20.sol";
import { MockUniversalCoreReal } from "../mocks/MockUniversalCoreReal.sol";
import { MockReentrantContract } from "../mocks/MockReentrantContract.sol";

/**
 * @title   UniversalGatewayPCTest
 * @notice  Comprehensive test suite for UniversalGatewayPC contract
 * @dev     Tests initialization, admin functions, and user withdrawal flows
 */
contract UniversalGatewayPCTest is Test {
    // =========================
    //           ACTORS
    // =========================
    address public admin;
    address public pauser;
    address public user1;
    address public user2;
    address public attacker;
    address public uem;

    // =========================
    //        CONTRACTS
    // =========================
    UniversalGatewayPC public gateway;
    TransparentUpgradeableProxy public gatewayProxy;
    ProxyAdmin public proxyAdmin;

    // =========================
    //          MOCKS
    // =========================
    MockUniversalCoreReal public universalCore;
    MockPRC20 public prc20Token;
    MockPRC20 public gasToken;

    // =========================
    //      TEST CONSTANTS
    // =========================
    uint256 public constant LARGE_AMOUNT = 1000000 * 1e18;
    uint256 public constant DEFAULT_GAS_LIMIT = 500_000; // Matches UniversalCore.BASE_GAS_LIMIT
    uint256 public constant DEFAULT_PROTOCOL_FEE = 0.01 ether;
    uint256 public constant DEFAULT_GAS_PRICE = 20 gwei;
    string public constant SOURCE_CHAIN_ID = "1"; // Ethereum mainnet
    string public constant SOURCE_TOKEN_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; // USDC

    // =========================
    //         SETUP
    // =========================
    function setUp() public {
        _createActors();
        _deployMocks();
        _deployGateway();
        _initializeGateway();
        _setupTokens();
    }

    // =========================
    //      HELPER FUNCTIONS
    // =========================
    function buildRevertInstructions(address fundRecipient) internal pure returns (RevertInstructions memory) {
        return RevertInstructions({ fundRecipient: fundRecipient, revertContext: bytes("") });
    }

    function buildRevertInstructionsWithMsg(address fundRecipient, string memory revertContext) 
        internal 
        pure 
        returns (RevertInstructions memory) 
    {
        return RevertInstructions({ fundRecipient: fundRecipient, revertContext: bytes(revertContext) });
    }

    function calculateExpectedGasFee(uint256 gasLimit) internal view returns (uint256) {
        return DEFAULT_GAS_PRICE * gasLimit + DEFAULT_PROTOCOL_FEE;
    }


    function testInitializeSuccess() public {
        // Deploy new gateway for testing initialization
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin,
            pauser,
            address(universalCore)
        );

        TransparentUpgradeableProxy newProxy = new TransparentUpgradeableProxy(
            address(newImplementation),
            address(newProxyAdmin),
            initData
        );

        UniversalGatewayPC newGateway = UniversalGatewayPC(address(newProxy));

        // Verify initialization
        assertEq(newGateway.UNIVERSAL_CORE(), address(universalCore));
        assertEq(newGateway.UNIVERSAL_EXECUTOR_MODULE(), uem);
        assertTrue(newGateway.hasRole(newGateway.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(newGateway.hasRole(newGateway.PAUSER_ROLE(), pauser));
    }

    function testInitializeRevertZeroAdmin() public {
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            address(0), // zero admin
            pauser,
            address(universalCore)
        );

        vm.expectRevert(Errors.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(newImplementation), address(newProxyAdmin), initData);
    }

    function testInitializeRevertZeroPauser() public {
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin,
            address(0), // zero pauser
            address(universalCore)
        );

        vm.expectRevert(Errors.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(newImplementation), address(newProxyAdmin), initData);
    }

    function testInitializeRevertZeroUniversalCore() public {
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin,
            pauser,
            address(0) // zero universal core
        );

        vm.expectRevert(Errors.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(newImplementation), address(newProxyAdmin), initData);
    }

    function testInitializeRevertDoubleInit() public {
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin,
            pauser,
            address(universalCore)
        );

        TransparentUpgradeableProxy newProxy = new TransparentUpgradeableProxy(
            address(newImplementation),
            address(newProxyAdmin),
            initData
        );

        UniversalGatewayPC newGateway = UniversalGatewayPC(address(newProxy));

        // Try to initialize again
        vm.expectRevert();
        newGateway.initialize(admin, pauser, address(universalCore));
    }

    // =========================
    //      ADMIN FUNCTION TESTS
    // =========================

    function testSetUniversalCoreSuccess() public {
        // Deploy new UniversalCore
        MockUniversalCoreReal newUniversalCore = new MockUniversalCoreReal(address(0x7));
        
        // Configure new core
        vm.prank(address(0x7));
        newUniversalCore.setGasPrice(SOURCE_CHAIN_ID, DEFAULT_GAS_PRICE);
        vm.prank(address(0x7));
        newUniversalCore.setGasTokenPRC20(SOURCE_CHAIN_ID, address(gasToken));

        // Admin sets new universal core
        vm.prank(admin);
        gateway.setUniversalCore(address(newUniversalCore));

        // Verify state changes
        assertEq(gateway.UNIVERSAL_CORE(), address(newUniversalCore));
        assertEq(gateway.UNIVERSAL_EXECUTOR_MODULE(), address(0x7));
    }

    function testSetUniversalCoreRevertNonAdmin() public {
        MockUniversalCoreReal newUniversalCore = new MockUniversalCoreReal(address(0x7));

        vm.prank(attacker);
        vm.expectRevert();
        gateway.setUniversalCore(address(newUniversalCore));
    }

    function testSetUniversalCoreRevertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setUniversalCore(address(0));
    }

    function testRefreshUniversalExecutorSuccess() public {
        // Deploy new UniversalCore with different UEM
        address newUem = address(0x8);
        MockUniversalCoreReal newUniversalCore = new MockUniversalCoreReal(newUem);
        
        // Configure new core
        vm.prank(newUem);
        newUniversalCore.setGasPrice(SOURCE_CHAIN_ID, DEFAULT_GAS_PRICE);
        vm.prank(newUem);
        newUniversalCore.setGasTokenPRC20(SOURCE_CHAIN_ID, address(gasToken));

        // Set new universal core
        vm.prank(admin);
        gateway.setUniversalCore(address(newUniversalCore));

        // Verify UEM was updated
        assertEq(gateway.UNIVERSAL_EXECUTOR_MODULE(), newUem);

        // Update UEM in the core and refresh
        address newerUem = address(0x9);
        MockUniversalCoreReal newerUniversalCore = new MockUniversalCoreReal(newerUem);
        
        vm.prank(newerUem);
        newerUniversalCore.setGasPrice(SOURCE_CHAIN_ID, DEFAULT_GAS_PRICE);
        vm.prank(newerUem);
        newerUniversalCore.setGasTokenPRC20(SOURCE_CHAIN_ID, address(gasToken));

        vm.prank(admin);
        gateway.setUniversalCore(address(newerUniversalCore));

        // Verify UEM was refreshed
        assertEq(gateway.UNIVERSAL_EXECUTOR_MODULE(), newerUem);
    }

    function testRefreshUniversalExecutorRevertNonAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        gateway.refreshUniversalExecutor();
    }

    function testRefreshUniversalExecutorWorksWhenPaused() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();

        // Admin should still be able to refresh executor
        vm.prank(admin);
        gateway.refreshUniversalExecutor();

        // Verify UEM is still correct
        assertEq(gateway.UNIVERSAL_EXECUTOR_MODULE(), uem);
    }

    function testPauseSuccess() public {
        assertFalse(gateway.paused());

        vm.prank(pauser);
        gateway.pause();

        assertTrue(gateway.paused());
    }

    function testPauseRevertNonPauser() public {
        vm.prank(attacker);
        vm.expectRevert();
        gateway.pause();
    }

    function testPauseRevertAlreadyPaused() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();

        // Try to pause again
        vm.prank(pauser);
        vm.expectRevert();
        gateway.pause();
    }

    function testUnpauseSuccess() public {
        // Pause the contract first
        vm.prank(pauser);
        gateway.pause();
        assertTrue(gateway.paused());

        // Pauser unpauses the contract
        vm.prank(pauser);
        gateway.unpause();

        // Verify contract is unpaused
        assertFalse(gateway.paused());
    }

    function testUnpauseRevertNonPauser() public {
        // Pause the contract first
        vm.prank(pauser);
        gateway.pause();

        // Non-pauser tries to unpause
        vm.prank(attacker);
        vm.expectRevert();
        gateway.unpause();
    }

    function testUnpauseRevertNotPaused() public {
        // Contract is not paused initially
        assertFalse(gateway.paused());

        // Try to unpause
        vm.prank(pauser);
        vm.expectRevert();
        gateway.unpause();
    }

    function testAdminFunctionsWorkWhenPaused() public {
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();

        // Admin functions should still work when paused
        MockUniversalCoreReal newUniversalCore = new MockUniversalCoreReal(address(0x8));
        
        vm.prank(address(0x8));
        newUniversalCore.setGasPrice(SOURCE_CHAIN_ID, DEFAULT_GAS_PRICE);
        vm.prank(address(0x8));
        newUniversalCore.setGasTokenPRC20(SOURCE_CHAIN_ID, address(gasToken));

        vm.prank(admin);
        gateway.setUniversalCore(address(newUniversalCore));

        vm.prank(admin);
        gateway.refreshUniversalExecutor();

        // Verify state changes worked
        assertEq(gateway.UNIVERSAL_CORE(), address(newUniversalCore));
        assertEq(gateway.UNIVERSAL_EXECUTOR_MODULE(), address(0x8));
    }

    // =========================
    //      WITHDRAW FUNCTION TESTS
    // =========================

    function testWithdrawSuccessWithCustomGasLimit() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 150_000;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Ensure user has enough balance
        uint256 userBalance = prc20Token.balanceOf(user1);
        if (userBalance < amount) {
            prc20Token.mint(user1, amount);
            vm.prank(user1);
            prc20Token.approve(address(gateway), amount);
        }

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 initialGasTokenBalance = gasToken.balanceOf(uem);
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.withdraw(to, address(prc20Token), amount, gasLimit, revertCfg);

        // Verify token balances
        assertEq(gasToken.balanceOf(uem), initialGasTokenBalance + expectedGasFee);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawEventEmission() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 150_000;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.recordLogs();
        vm.prank(user1);
        gateway.withdraw(to, address(prc20Token), amount, gasLimit, revertCfg);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(logs.length >= 1, "At least one event should be emitted");
    }

    function testWithdrawSuccessWithDefaultGasLimit() public {
        uint256 amount = 1000 * 1e6; // 1000 USDC (6 decimals)
        uint256 gasLimit = 0; // Use default gas limit
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        uint256 expectedGasFee = calculateExpectedGasFee(DEFAULT_GAS_LIMIT);
        uint256 initialGasTokenBalance = gasToken.balanceOf(uem);
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.withdraw(to, address(prc20Token), amount, gasLimit, revertCfg);

        // Verify token balances
        assertEq(gasToken.balanceOf(uem), initialGasTokenBalance + expectedGasFee);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawRevertEmptyTarget() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = bytes(""); // Empty target
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.withdraw(to, address(prc20Token), amount, gasLimit, revertCfg);
    }

    function testWithdrawRevertZeroToken() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.withdraw(to, address(0), amount, gasLimit, revertCfg);
    }

    function testWithdrawRevertZeroAmount() public {
        uint256 amount = 0; // Zero amount
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.withdraw(to, address(prc20Token), amount, gasLimit, revertCfg);
    }

    function testWithdrawRevertInvalidRecipient() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(address(0)); // Zero recipient

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        gateway.withdraw(to, address(prc20Token), amount, gasLimit, revertCfg);
    }

    function testWithdrawRevertWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();

        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert();
        gateway.withdraw(to, address(prc20Token), amount, gasLimit, revertCfg);
    }

    function testWithdrawRevertInsufficientGasTokenBalance() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Calculate required gas fee
        uint256 requiredGasFee = calculateExpectedGasFee(gasLimit);
        
        // Set user1's gas token balance to less than required
        uint256 currentBalance = gasToken.balanceOf(user1);
        vm.prank(user1);
        gasToken.transfer(address(0xdead), currentBalance);
        
        // Give user1 insufficient gas tokens (less than required fee)
        if (requiredGasFee > 1) {
            gasToken.mint(user1, requiredGasFee - 1);
            vm.prank(user1);
            gasToken.approve(address(gateway), type(uint256).max);
        }

        vm.prank(user1);
        vm.expectRevert();
        gateway.withdraw(to, address(prc20Token), amount, gasLimit, revertCfg);
    }

    function testWithdrawRevertInsufficientGasTokenAllowance() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Remove gas token allowance
        vm.prank(user1);
        gasToken.approve(address(gateway), 0);

        vm.prank(user1);
        vm.expectRevert("MockPRC20: insufficient allowance");
        gateway.withdraw(to, address(prc20Token), amount, gasLimit, revertCfg);
    }

    function testWithdrawRevertInsufficientPrc20Balance() public {
        uint256 amount = LARGE_AMOUNT + 1; // More than user has
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert("MockPRC20: insufficient balance");
        gateway.withdraw(to, address(prc20Token), amount, gasLimit, revertCfg);
    }

    // =========================
    //   WITHDRAW AND EXECUTE FUNCTION TESTS
    // =========================

    function testWithdrawAndExecuteSuccessWithCustomGasLimit() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 200_000;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 initialGasTokenBalance = gasToken.balanceOf(uem);
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.withdrawAndExecute(target, address(prc20Token), amount, payload, gasLimit, revertCfg);

        // Verify token balances
        assertEq(gasToken.balanceOf(uem), initialGasTokenBalance + expectedGasFee);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawAndExecuteEventEmission() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 200_000;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.recordLogs();
        vm.prank(user1);
        gateway.withdrawAndExecute(target, address(prc20Token), amount, payload, gasLimit, revertCfg);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(logs.length >= 1, "At least one event should be emitted");
    }

    function testWithdrawAndExecuteSuccessWithDefaultGasLimit() public {
        uint256 amount = 1000 * 1e6; // 1000 USDC (6 decimals)
        uint256 gasLimit = 0; // Use default gas limit
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        uint256 expectedGasFee = calculateExpectedGasFee(DEFAULT_GAS_LIMIT);
        uint256 initialGasTokenBalance = gasToken.balanceOf(uem);
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.withdrawAndExecute(target, address(prc20Token), amount, payload, gasLimit, revertCfg);

        // Verify token balances
        assertEq(gasToken.balanceOf(uem), initialGasTokenBalance + expectedGasFee);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawAndExecuteSuccessWithEmptyPayload() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = bytes(""); // Empty payload
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 initialGasTokenBalance = gasToken.balanceOf(uem);
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.withdrawAndExecute(target, address(prc20Token), amount, payload, gasLimit, revertCfg);

        // Verify token balances
        assertEq(gasToken.balanceOf(uem), initialGasTokenBalance + expectedGasFee);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawAndExecuteSuccessWithComplexPayload() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        
        // Complex payload with multiple parameters
        bytes memory payload = abi.encodeWithSignature(
            "complexFunction(address,uint256,bytes32,string)",
            user2,
            1000,
            keccak256("test"),
            "complex string parameter"
        );
        
        RevertInstructions memory revertCfg = buildRevertInstructionsWithMsg(user2, "Complex operation failed");

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 initialGasTokenBalance = gasToken.balanceOf(uem);
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.withdrawAndExecute(target, address(prc20Token), amount, payload, gasLimit, revertCfg);

        // Verify token balances
        assertEq(gasToken.balanceOf(uem), initialGasTokenBalance + expectedGasFee);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawAndExecuteRevertEmptyTarget() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = bytes(""); // Empty target
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.withdrawAndExecute(target, address(prc20Token), amount, payload, gasLimit, revertCfg);
    }

    function testWithdrawAndExecuteRevertZeroToken() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.withdrawAndExecute(target, address(0), amount, payload, gasLimit, revertCfg);
    }

    function testWithdrawAndExecuteRevertZeroAmount() public {
        uint256 amount = 0; // Zero amount
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.withdrawAndExecute(target, address(prc20Token), amount, payload, gasLimit, revertCfg);
    }

    function testWithdrawAndExecuteRevertInvalidRecipient() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(address(0)); // Zero recipient

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        gateway.withdrawAndExecute(target, address(prc20Token), amount, payload, gasLimit, revertCfg);
    }

    function testWithdrawAndExecuteRevertWhenPaused() public {
        vm.prank(pauser);
        gateway.pause();

        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert();
        gateway.withdrawAndExecute(target, address(prc20Token), amount, payload, gasLimit, revertCfg);
    }

    function testWithdrawAndExecuteRevertInsufficientGasTokenBalance() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Calculate required gas fee
        uint256 requiredGasFee = calculateExpectedGasFee(gasLimit);
        
        // Set user1's gas token balance to less than required
        uint256 currentBalance = gasToken.balanceOf(user1);
        vm.prank(user1);
        gasToken.transfer(address(0xdead), currentBalance);
        
        // Give user1 insufficient gas tokens (less than required fee)
        if (requiredGasFee > 1) {
            gasToken.mint(user1, requiredGasFee - 1);
            vm.prank(user1);
            gasToken.approve(address(gateway), type(uint256).max);
        }

        vm.prank(user1);
        vm.expectRevert();
        gateway.withdrawAndExecute(target, address(prc20Token), amount, payload, gasLimit, revertCfg);
    }

    function testWithdrawAndExecuteRevertInsufficientGasTokenAllowance() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Remove gas token allowance
        vm.prank(user1);
        gasToken.approve(address(gateway), 0);

        vm.prank(user1);
        vm.expectRevert("MockPRC20: insufficient allowance");
        gateway.withdrawAndExecute(target, address(prc20Token), amount, payload, gasLimit, revertCfg);
    }

    function testWithdrawAndExecuteRevertInsufficientPrc20Balance() public {
        uint256 amount = LARGE_AMOUNT + 1; // More than user has
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert("MockPRC20: insufficient balance");
        gateway.withdrawAndExecute(target, address(prc20Token), amount, payload, gasLimit, revertCfg);
    }

    function testWithdrawAndExecuteDifferentPayloadSizes() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        uint256 initialBalance = prc20Token.balanceOf(user1);

        // Test with small payload
        bytes memory smallPayload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        
        vm.prank(user1);
        gateway.withdrawAndExecute(target, address(prc20Token), amount, smallPayload, gasLimit, revertCfg);

        // Reset balances for next test
        prc20Token.mint(user1, amount);
        vm.prank(user1);
        prc20Token.approve(address(gateway), amount);

        // Test with large payload
        bytes memory largePayload = abi.encodeWithSignature(
            "largeFunction(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)",
            user2, 1, 2, 3, 4, 5, 6, 7, 8, 9
        );

        vm.prank(user1);
        gateway.withdrawAndExecute(target, address(prc20Token), amount, largePayload, gasLimit, revertCfg);

        // Both should succeed - verify final balance
        uint256 finalBalance = prc20Token.balanceOf(user1);
        assertEq(finalBalance, initialBalance - amount);
    }

    // =========================
    //      EDGE CASES & ADDITIONAL TESTS
    // =========================

    function testReentrancyProtection() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Create a contract that calls the gateway
        MockReentrantContract reentrantContract = new MockReentrantContract(
            address(gateway), 
            address(prc20Token), 
            address(gasToken)
        );
        
        // Fund the contract
        prc20Token.mint(address(reentrantContract), amount);
        gasToken.mint(address(reentrantContract), LARGE_AMOUNT);
        
        vm.prank(address(reentrantContract));
        prc20Token.approve(address(gateway), amount);
        vm.prank(address(reentrantContract));
        gasToken.approve(address(gateway), type(uint256).max);

        // Call should succeed (reentrancy protection is for preventing recursive calls during execution)
        vm.prank(address(reentrantContract));
        reentrantContract.attemptReentrancy(to, amount, gasLimit, revertCfg);
        
        // Verify the withdrawal succeeded
        assertEq(prc20Token.balanceOf(address(reentrantContract)), 0);
    }

    function testReentrancyProtectionWithExecute() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Create a contract that calls the gateway
        MockReentrantContract reentrantContract = new MockReentrantContract(
            address(gateway), 
            address(prc20Token), 
            address(gasToken)
        );
        
        // Fund the contract
        prc20Token.mint(address(reentrantContract), amount);
        gasToken.mint(address(reentrantContract), LARGE_AMOUNT);
        
        vm.prank(address(reentrantContract));
        prc20Token.approve(address(gateway), amount);
        vm.prank(address(reentrantContract));
        gasToken.approve(address(gateway), type(uint256).max);

        // Call should succeed (reentrancy protection is for preventing recursive calls during execution)
        vm.prank(address(reentrantContract));
        reentrantContract.attemptReentrancyWithExecute(target, amount, payload, gasLimit, revertCfg);
        
        // Verify the withdrawal succeeded
        assertEq(prc20Token.balanceOf(address(reentrantContract)), 0);
    }

    function testMaxGasLimit() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 1_000_000; // Large gas limit
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 initialGasTokenBalance = gasToken.balanceOf(uem);

        // Ensure user has enough gas tokens for the fee
        uint256 userGasBalance = gasToken.balanceOf(user1);
        if (userGasBalance < expectedGasFee) {
            gasToken.mint(user1, expectedGasFee - userGasBalance + 1 ether);
            vm.prank(user1);
            gasToken.approve(address(gateway), type(uint256).max);
        }

        vm.prank(user1);
        gateway.withdraw(to, address(prc20Token), amount, gasLimit, revertCfg);

        // Verify withdrawal with max gas limit succeeded
        assertEq(gasToken.balanceOf(uem), initialGasTokenBalance + expectedGasFee);
    }

    function testGasFeeCalculationAccuracy() public {
        uint256 amount = 1000 * 1e6;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Test specific gas limits individually
        _testGasFeeForLimit(amount, to, revertCfg, 50_000);
        _testGasFeeForLimit(amount, to, revertCfg, 100_000);
        _testGasFeeForLimit(amount, to, revertCfg, 200_000);
        _testGasFeeForLimit(amount, to, revertCfg, 500_000);
        _testGasFeeForLimit(amount, to, revertCfg, 1_000_000);
    }

    function _testGasFeeForLimit(uint256 amount, bytes memory to, RevertInstructions memory revertCfg, uint256 gasLimit) internal {
        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 balanceBefore = gasToken.balanceOf(uem);

        vm.prank(user1);
        gateway.withdraw(to, address(prc20Token), amount, gasLimit, revertCfg);

        uint256 balanceAfter = gasToken.balanceOf(uem);
        assertEq(balanceAfter - balanceBefore, expectedGasFee);

        // Reset for next iteration
        prc20Token.mint(user1, amount);
        vm.prank(user1);
        prc20Token.approve(address(gateway), amount);
    }

    function testZeroUemAddress() public {
        // Deploy UniversalCore with zero UEM
        MockUniversalCoreReal zeroUemCore = new MockUniversalCoreReal(address(0));
        
        vm.prank(address(0));
        zeroUemCore.setGasPrice(SOURCE_CHAIN_ID, DEFAULT_GAS_PRICE);
        vm.prank(address(0));
        zeroUemCore.setGasTokenPRC20(SOURCE_CHAIN_ID, address(gasToken));

        // Set the zero UEM core
        vm.prank(admin);
        gateway.setUniversalCore(address(zeroUemCore));

        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Withdrawal should fail with zero UEM
        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.withdraw(to, address(prc20Token), amount, gasLimit, revertCfg);
    }

    function testInvalidFeeQuoteZeroGasToken() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Create invalid core with zero gas token (don't set it, leave as default zero)
        MockUniversalCoreReal invalidCore = new MockUniversalCoreReal(uem);
        vm.prank(uem);
        invalidCore.setGasPrice(SOURCE_CHAIN_ID, DEFAULT_GAS_PRICE);
        // Intentionally NOT setting gasTokenPRC20, so it remains address(0)

        // Create token with invalid core
        MockPRC20 invalidToken = new MockPRC20(
            "Invalid Token",
            "INV",
            6,
            SOURCE_CHAIN_ID,
            MockPRC20.TokenType.ERC20,
            DEFAULT_PROTOCOL_FEE,
            address(invalidCore),
            SOURCE_TOKEN_ADDRESS
        );

        // Setup token for user1
        invalidToken.mint(user1, amount);
        vm.prank(user1);
        invalidToken.approve(address(gateway), amount);
        
        // Setup gas token for user1
        gasToken.mint(user1, 100 ether);
        vm.prank(user1);
        gasToken.approve(address(gateway), 100 ether);
        
        // Update gateway's UniversalCore to the invalid one
        vm.prank(admin);
        gateway.setUniversalCore(address(invalidCore));
        
        // Refresh the executor module to ensure it's up to date
        vm.prank(admin);
        gateway.refreshUniversalExecutor();

        // Withdrawal should fail with "MockUniversalCore: zero gas token" error
        vm.prank(user1);
        vm.expectRevert("MockUniversalCore: zero gas token");
        gateway.withdraw(to, address(invalidToken), amount, gasLimit, revertCfg);
    }

    function _createInvalidToken() internal returns (MockPRC20) {
        return new MockPRC20(
            "Invalid Token",
            "INV",
            6,
            SOURCE_CHAIN_ID,
            MockPRC20.TokenType.ERC20,
            DEFAULT_PROTOCOL_FEE,
            address(universalCore),
            SOURCE_TOKEN_ADDRESS
        );
    }

    function _createInvalidCoreWithZeroGasToken() internal returns (MockUniversalCoreReal) {
        MockUniversalCoreReal invalidCore = new MockUniversalCoreReal(uem);
        vm.prank(uem);
        invalidCore.setGasPrice(SOURCE_CHAIN_ID, DEFAULT_GAS_PRICE);
        vm.prank(uem);
        invalidCore.setGasTokenPRC20(SOURCE_CHAIN_ID, address(0)); // Zero gas token
        return invalidCore;
    }

    function testInvalidFeeQuoteZeroGasFee() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Create invalid core with zero gas price
        MockUniversalCoreReal invalidCore = new MockUniversalCoreReal(uem);
        vm.prank(uem);
        invalidCore.setGasPrice(SOURCE_CHAIN_ID, 0); // Zero gas price
        vm.prank(uem);
        invalidCore.setGasTokenPRC20(SOURCE_CHAIN_ID, address(gasToken));

        // Create token with invalid core
        MockPRC20 invalidToken = new MockPRC20(
            "Invalid Token",
            "INV",
            6,
            SOURCE_CHAIN_ID,
            MockPRC20.TokenType.ERC20,
            DEFAULT_PROTOCOL_FEE,
            address(invalidCore),
            SOURCE_TOKEN_ADDRESS
        );

        // Setup token for user1
        invalidToken.mint(user1, amount);
        vm.prank(user1);
        invalidToken.approve(address(gateway), amount);
        
        // Setup gas token for user1
        gasToken.mint(user1, 100 ether);
        vm.prank(user1);
        gasToken.approve(address(gateway), 100 ether);
        
        // Update gateway's UniversalCore to the invalid one
        vm.prank(admin);
        gateway.setUniversalCore(address(invalidCore));
        
        // Refresh the executor module to ensure it's up to date
        vm.prank(admin);
        gateway.refreshUniversalExecutor();

        // Withdrawal should fail with "MockUniversalCore: zero gas price" error
        vm.prank(user1);
        vm.expectRevert("MockUniversalCore: zero gas price");
        gateway.withdraw(to, address(invalidToken), amount, gasLimit, revertCfg);
    }

    function _createInvalidCoreWithZeroGasPrice() internal returns (MockUniversalCoreReal) {
        MockUniversalCoreReal invalidCore = new MockUniversalCoreReal(uem);
        vm.prank(uem);
        invalidCore.setGasPrice(SOURCE_CHAIN_ID, 0); // Zero gas price
        vm.prank(uem);
        invalidCore.setGasTokenPRC20(SOURCE_CHAIN_ID, address(gasToken));
        return invalidCore;
    }

    function testTokenBurnFailure() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Create failing token
        MockPRC20 failingToken = _createFailingToken();

        // Setup token for user1
        failingToken.mint(user1, amount);
        vm.prank(user1);
        failingToken.approve(address(gateway), amount);

        // Mock the burn function to fail by setting balance to 0
        failingToken.setBalance(user1, 0);

        // Withdrawal should fail with transfer failure
        vm.prank(user1);
        vm.expectRevert("MockPRC20: insufficient balance");
        gateway.withdraw(to, address(failingToken), amount, gasLimit, revertCfg);
    }

    function _createFailingToken() internal returns (MockPRC20) {
        return new MockPRC20(
            "Failing Token",
            "FAIL",
            6,
            SOURCE_CHAIN_ID,
            MockPRC20.TokenType.ERC20,
            DEFAULT_PROTOCOL_FEE,
            address(universalCore),
            SOURCE_TOKEN_ADDRESS
        );
    }

    // =========================
    //      INTERNAL FUNCTIONS
    // =========================

    function _createActors() internal {
        admin = address(0x1);
        pauser = address(0x2);
        user1 = address(0x3);
        user2 = address(0x4);
        attacker = address(0x5);
        uem = address(0x6);

        vm.label(admin, "admin");
        vm.label(pauser, "pauser");
        vm.label(user1, "user1");
        vm.label(user2, "user2");
        vm.label(attacker, "attacker");
        vm.label(uem, "uem");

        vm.deal(admin, 100 ether);
        vm.deal(pauser, 100 ether);
        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);
        vm.deal(attacker, 1000 ether);
    }

    function _deployMocks() internal {
        // Deploy UniversalCore mock
        universalCore = new MockUniversalCoreReal(uem);

        // Deploy gas token (PC native token)
        gasToken = new MockPRC20(
            "Push Chain Native",
            "PC",
            18,
            SOURCE_CHAIN_ID,
            MockPRC20.TokenType.PC,
            DEFAULT_PROTOCOL_FEE,
            address(universalCore),
            ""
        );

        // Deploy PRC20 token (wrapped USDC)
        prc20Token = new MockPRC20(
            "USDC on Push Chain",
            "USDC",
            6,
            SOURCE_CHAIN_ID,
            MockPRC20.TokenType.ERC20,
            DEFAULT_PROTOCOL_FEE,
            address(universalCore),
            SOURCE_TOKEN_ADDRESS
        );

        // Configure UniversalCore with gas settings
        vm.prank(uem);
        universalCore.setGasPrice(SOURCE_CHAIN_ID, DEFAULT_GAS_PRICE);
        vm.prank(uem);
        universalCore.setGasTokenPRC20(SOURCE_CHAIN_ID, address(gasToken));

        vm.label(address(universalCore), "UniversalCore");
        vm.label(address(prc20Token), "PRC20Token");
        vm.label(address(gasToken), "GasToken");
    }

    function _deployGateway() internal {
        // Deploy implementation
        UniversalGatewayPC implementation = new UniversalGatewayPC();

        // Deploy proxy admin
        proxyAdmin = new ProxyAdmin(admin);

        // Deploy transparent upgradeable proxy
        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin,
            pauser,
            address(universalCore)
        );

        gatewayProxy = new TransparentUpgradeableProxy(address(implementation), address(proxyAdmin), initData);

        // Cast proxy to gateway interface
        gateway = UniversalGatewayPC(address(gatewayProxy));

        vm.label(address(gateway), "UniversalGatewayPC");
        vm.label(address(gatewayProxy), "GatewayProxy");
        vm.label(address(proxyAdmin), "ProxyAdmin");
    }

    function _initializeGateway() internal view {
        // Gateway is already initialized via proxy constructor
        // Verify initialization
        assertEq(gateway.UNIVERSAL_CORE(), address(universalCore));
        assertEq(gateway.UNIVERSAL_EXECUTOR_MODULE(), uem);
        assertTrue(gateway.hasRole(gateway.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(gateway.hasRole(gateway.PAUSER_ROLE(), pauser));
    }

    function _setupTokens() internal {
        // Mint tokens to users
        prc20Token.mint(user1, LARGE_AMOUNT);
        prc20Token.mint(user2, LARGE_AMOUNT);
        gasToken.mint(user1, LARGE_AMOUNT);
        gasToken.mint(user2, LARGE_AMOUNT);

        // Approve gateway to spend tokens
        vm.prank(user1);
        prc20Token.approve(address(gateway), type(uint256).max);
        vm.prank(user1);
        gasToken.approve(address(gateway), type(uint256).max);

        vm.prank(user2);
        prc20Token.approve(address(gateway), type(uint256).max);
        vm.prank(user2);
        gasToken.approve(address(gateway), type(uint256).max);
    }
}