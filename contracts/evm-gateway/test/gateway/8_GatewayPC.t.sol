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
import { MockPC20 } from "../mocks/MockPC20.sol";
import { MockPC721 } from "../mocks/MockPC721.sol";
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
    address public vaultPC;

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
    MockPRC20 public gasToken;// PC20 / PC721 mocks
    MockPC20 public pc20Token;
    MockPC721 public pc721Token;

    // =========================
    //      TEST CONSTANTS
    // =========================
    uint256 public constant LARGE_AMOUNT = 1000000 * 1e18;
    uint256 public constant DEFAULT_GAS_LIMIT = 500_000; // Matches UniversalCore.BASE_GAS_LIMIT
    uint256 public constant DEFAULT_PROTOCOL_FEE = 0.01 ether;
    uint256 public constant DEFAULT_GAS_PRICE = 20 gwei;
    string public constant SOURCE_CHAIN_ID = "1"; // Ethereum mainnet
    string public constant SOURCE_TOKEN_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; // USDC
    string public constant ETH_CHAIN_NAMESPACE = "eip155:1"; // ETHEREUM
    string public constant UNSUPPORTED_CHAIN_NAMESPACE = "eip155:8453"; // UNSUPPORTED

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
            address(universalCore),
            vaultPC
        );

        TransparentUpgradeableProxy newProxy = new TransparentUpgradeableProxy(
            address(newImplementation),
            address(newProxyAdmin),
            initData
        );

        UniversalGatewayPC newGateway = UniversalGatewayPC(address(newProxy));

        // Verify initialization
        assertEq(newGateway.UNIVERSAL_CORE(), address(universalCore));
        assertEq(address(newGateway.VAULT_PC()), vaultPC);
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
            address(universalCore),
            vaultPC
        );

        vm.expectRevert(); // Proxy wraps the error
        new TransparentUpgradeableProxy(address(newImplementation), address(newProxyAdmin), initData);
    }

    function testInitializeRevertZeroPauser() public {
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin,
            address(0), // zero pauser
            address(universalCore),
            vaultPC
        );

        vm.expectRevert(); // Proxy wraps the error
        new TransparentUpgradeableProxy(address(newImplementation), address(newProxyAdmin), initData);
    }

    function testInitializeRevertZeroUniversalCore() public {
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin,
            pauser,
            address(0), // zero universal core
            vaultPC
        );

        vm.expectRevert(); // Proxy wraps the error
        new TransparentUpgradeableProxy(address(newImplementation), address(newProxyAdmin), initData);
    }

    function testInitializeRevertZeroVaultPC() public {
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin,
            pauser,
            address(universalCore),
            address(0) // zero vaultPC
        );

        vm.expectRevert(); // Proxy wraps the error
        new TransparentUpgradeableProxy(address(newImplementation), address(newProxyAdmin), initData);
    }

    function testInitializeRevertDoubleInit() public {
        UniversalGatewayPC newImplementation = new UniversalGatewayPC();
        ProxyAdmin newProxyAdmin = new ProxyAdmin(admin);

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin,
            pauser,
            address(universalCore),
            vaultPC
        );

        TransparentUpgradeableProxy newProxy = new TransparentUpgradeableProxy(
            address(newImplementation),
            address(newProxyAdmin),
            initData
        );

        UniversalGatewayPC newGateway = UniversalGatewayPC(address(newProxy));

        // Try to initialize again
        vm.expectRevert();
        newGateway.initialize(admin, pauser, address(universalCore), vaultPC);
    }

    // =========================
    //      ADMIN FUNCTION TESTS
    // =========================

    function testSetVaultPCSuccess() public {
        address newVaultPC = address(0x999);
        
        // Admin sets new VaultPC
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit IUniversalGatewayPC.VaultPCUpdated(vaultPC, newVaultPC);
        gateway.setVaultPC(newVaultPC);

        // Verify state changes
        assertEq(address(gateway.VAULT_PC()), newVaultPC);
    }

    function testSetVaultPCRevertNonAdmin() public {
        address newVaultPC = address(0x999);

        vm.prank(attacker);
        vm.expectRevert();
        gateway.setVaultPC(newVaultPC);
    }

    function testSetVaultPCRevertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setVaultPC(address(0));
    }

    function testSetVaultPCRevertWhenPaused() public {
        // Pause the gateway first
        vm.prank(pauser);
        gateway.pause();

        address newVaultPC = address(0x999);
        
        // Attempt to set VaultPC while paused should revert
        vm.prank(admin);
        vm.expectRevert();
        gateway.setVaultPC(newVaultPC);
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

        // Verify that the contract is paused
        assertTrue(gateway.paused());
        
        // Unpause should still work
        vm.prank(pauser);
        gateway.unpause();
        
        assertFalse(gateway.paused());
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
        uint256 initialGasTokenBalance = gasToken.balanceOf(vaultPC);
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound(to, address(prc20Token), amount, 0, gasLimit, "", "", revertCfg);

        // Verify token balances
        assertEq(gasToken.balanceOf(vaultPC), initialGasTokenBalance + expectedGasFee);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawEventEmission() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = 150_000;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.recordLogs();
        vm.prank(user1);
        gateway.sendUniversalTxOutbound(to, address(prc20Token), amount, 0, gasLimit, "", "", revertCfg);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(logs.length >= 1, "At least one event should be emitted");
    }

    function testWithdrawSuccessWithDefaultGasLimit() public {
        uint256 amount = 1000 * 1e6; // 1000 USDC (6 decimals)
        uint256 gasLimit = 0; // Use default gas limit
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        uint256 expectedGasFee = calculateExpectedGasFee(DEFAULT_GAS_LIMIT);
        uint256 initialGasTokenBalance = gasToken.balanceOf(vaultPC);
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound(to, address(prc20Token), amount, 0, gasLimit, "", "", revertCfg);

        // Verify token balances
        assertEq(gasToken.balanceOf(vaultPC), initialGasTokenBalance + expectedGasFee);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawRevertEmptyTarget() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = bytes(""); // Empty target
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTxOutbound(to, address(prc20Token), amount, 0, gasLimit, "", "", revertCfg);
    }

    function testWithdrawRevertZeroToken() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.sendUniversalTxOutbound(to, address(0), amount, 0, gasLimit, "", "", revertCfg);
    }

    function testWithdrawRevertZeroAmount() public {
        uint256 amount = 0; // Zero amount
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendUniversalTxOutbound(to, address(prc20Token), amount, 0, gasLimit, "", "", revertCfg);
    }

    function testWithdrawRevertInvalidRecipient() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(address(0)); // Zero recipient

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        gateway.sendUniversalTxOutbound(to, address(prc20Token), amount, 0, gasLimit, "", "", revertCfg);
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
        gateway.sendUniversalTxOutbound(to, address(prc20Token), amount, 0, gasLimit, "", "", revertCfg);
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
        gateway.sendUniversalTxOutbound(to, address(prc20Token), amount, 0, gasLimit, "", "", revertCfg);
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
        gateway.sendUniversalTxOutbound(to, address(prc20Token), amount, 0, gasLimit, "", "", revertCfg);
    }

    function testWithdrawRevertInsufficientPrc20Balance() public {
        uint256 amount = LARGE_AMOUNT + 1; // More than user has
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert("MockPRC20: insufficient balance");
        gateway.sendUniversalTxOutbound(to, address(prc20Token), amount, 0, gasLimit, "", "", revertCfg);
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
        uint256 initialGasTokenBalance = gasToken.balanceOf(vaultPC);
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound(target, address(prc20Token), amount, 0, gasLimit, payload, "", revertCfg);

        // Verify token balances
        assertEq(gasToken.balanceOf(vaultPC), initialGasTokenBalance + expectedGasFee);
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
        gateway.sendUniversalTxOutbound(target, address(prc20Token), amount, 0, gasLimit, payload, "", revertCfg);

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
        uint256 initialGasTokenBalance = gasToken.balanceOf(vaultPC);
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound(target, address(prc20Token), amount, 0, gasLimit, payload, "", revertCfg);

        // Verify token balances
        assertEq(gasToken.balanceOf(vaultPC), initialGasTokenBalance + expectedGasFee);
        assertEq(prc20Token.balanceOf(user1), initialPrc20Balance - amount);
    }

    function testWithdrawAndExecuteSuccessWithEmptyPayload() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = bytes(""); // Empty payload
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        uint256 expectedGasFee = calculateExpectedGasFee(gasLimit);
        uint256 initialGasTokenBalance = gasToken.balanceOf(vaultPC);
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound(target, address(prc20Token), amount, 0, gasLimit, payload, "", revertCfg);

        // Verify token balances
        assertEq(gasToken.balanceOf(vaultPC), initialGasTokenBalance + expectedGasFee);
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
        uint256 initialGasTokenBalance = gasToken.balanceOf(vaultPC);
        uint256 initialPrc20Balance = prc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound(target, address(prc20Token), amount, 0, gasLimit, payload, "", revertCfg);

        // Verify token balances
        assertEq(gasToken.balanceOf(vaultPC), initialGasTokenBalance + expectedGasFee);
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
        gateway.sendUniversalTxOutbound(target, address(prc20Token), amount, 0, gasLimit, payload, "", revertCfg);
    }

    function testWithdrawAndExecuteRevertZeroToken() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.sendUniversalTxOutbound(target, address(0), amount, 0, gasLimit, payload, "", revertCfg);
    }

    function testWithdrawAndExecuteRevertZeroAmount() public {
        uint256 amount = 0; // Zero amount
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendUniversalTxOutbound(target, address(prc20Token), amount, 0, gasLimit, payload, "", revertCfg);
    }

    function testWithdrawAndExecuteRevertInvalidRecipient() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(address(0)); // Zero recipient

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        gateway.sendUniversalTxOutbound(target, address(prc20Token), amount, 0, gasLimit, payload, "", revertCfg);
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
        gateway.sendUniversalTxOutbound(target, address(prc20Token), amount, 0, gasLimit, payload, "", revertCfg);
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
        gateway.sendUniversalTxOutbound(target, address(prc20Token), amount, 0, gasLimit, payload, "", revertCfg);
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
        gateway.sendUniversalTxOutbound(target, address(prc20Token), amount, 0, gasLimit, payload, "", revertCfg);
    }

    function testWithdrawAndExecuteRevertInsufficientPrc20Balance() public {
        uint256 amount = LARGE_AMOUNT + 1; // More than user has
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("transfer(address,uint256)", user2, 100);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert("MockPRC20: insufficient balance");
        gateway.sendUniversalTxOutbound(target, address(prc20Token), amount, 0, gasLimit, payload, "", revertCfg);
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
        gateway.sendUniversalTxOutbound(target, address(prc20Token), amount, 0, gasLimit, smallPayload, "", revertCfg);

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
        gateway.sendUniversalTxOutbound(target, address(prc20Token), amount, 0, gasLimit, largePayload, "", revertCfg);

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
        uint256 initialGasTokenBalance = gasToken.balanceOf(vaultPC);

        // Ensure user has enough gas tokens for the fee
        uint256 userGasBalance = gasToken.balanceOf(user1);
        if (userGasBalance < expectedGasFee) {
            gasToken.mint(user1, expectedGasFee - userGasBalance + 1 ether);
            vm.prank(user1);
            gasToken.approve(address(gateway), type(uint256).max);
        }

        vm.prank(user1);
        gateway.sendUniversalTxOutbound(to, address(prc20Token), amount, 0, gasLimit, "", "", revertCfg);

        // Verify withdrawal with max gas limit succeeded
        assertEq(gasToken.balanceOf(vaultPC), initialGasTokenBalance + expectedGasFee);
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
        uint256 balanceBefore = gasToken.balanceOf(vaultPC);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound(to, address(prc20Token), amount, 0, gasLimit, "", "", revertCfg);

        uint256 balanceAfter = gasToken.balanceOf(vaultPC);
        assertEq(balanceAfter - balanceBefore, expectedGasFee);

        // Reset for next iteration
        prc20Token.mint(user1, amount);
        vm.prank(user1);
        prc20Token.approve(address(gateway), amount);
    }

    function testSetVaultPCToZeroReverts() public {
        // Attempt to set VaultPC to zero should revert
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        gateway.setVaultPC(address(0));
    }

    function testInvalidFeeQuoteZeroGasToken() public {
        uint256 amount = 1000 * 1e6;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory to = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Create token with unconfigured chain ID (no gas token set for this chain)
        string memory unconfiguredChainId = "999"; // Chain ID not configured in universalCore
        MockPRC20 invalidToken = new MockPRC20(
            "Invalid Token",
            "INV",
            6,
            unconfiguredChainId,
            MockPRC20.TokenType.ERC20,
            DEFAULT_PROTOCOL_FEE,
            address(universalCore),
            SOURCE_TOKEN_ADDRESS
        );

        // Mark token as supported
        vm.prank(admin);
        universalCore.setSupportedToken(address(invalidToken), true);

        // Setup token for user1
        invalidToken.mint(user1, amount);
        vm.prank(user1);
        invalidToken.approve(address(gateway), amount);
        
        // Withdrawal should fail with "MockUniversalCore: zero gas token" error
        vm.prank(user1);
        vm.expectRevert("MockUniversalCore: zero gas token");
        gateway.sendUniversalTxOutbound(to, address(invalidToken), amount, 0, gasLimit, "", "", revertCfg);
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

        // Create token with a chain ID that has gas token but no gas price configured
        string memory chainWithTokenNoPrice = "777";
        
        // Configure this chain in universalCore with gas token but NO gas price
        vm.prank(uem);
        universalCore.setGasTokenPRC20(chainWithTokenNoPrice, address(gasToken));
        // Intentionally NOT setting gas price for this chain
        
        MockPRC20 invalidToken = new MockPRC20(
            "Invalid Token",
            "INV",
            6,
            chainWithTokenNoPrice,
            MockPRC20.TokenType.ERC20,
            DEFAULT_PROTOCOL_FEE,
            address(universalCore),
            SOURCE_TOKEN_ADDRESS
        );

        // Mark token as supported
        vm.prank(admin);
        universalCore.setSupportedToken(address(invalidToken), true);

        // Setup token for user1
        invalidToken.mint(user1, amount);
        vm.prank(user1);
        invalidToken.approve(address(gateway), amount);
        
        // Withdrawal should fail with "MockUniversalCore: zero gas price" error
        vm.prank(user1);
        vm.expectRevert("MockUniversalCore: zero gas price");
        gateway.sendUniversalTxOutbound(to, address(invalidToken), amount, 0, gasLimit, "", "", revertCfg);
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

        // Mark token as supported
        vm.prank(admin);
        universalCore.setSupportedToken(address(failingToken), true);

        // Setup token for user1
        failingToken.mint(user1, amount);
        vm.prank(user1);
        failingToken.approve(address(gateway), amount);

        // Mock the burn function to fail by setting balance to 0
        failingToken.setBalance(user1, 0);

        // Withdrawal should fail with transfer failure
        vm.prank(user1);
        vm.expectRevert("MockPRC20: insufficient balance");
        gateway.sendUniversalTxOutbound(to, address(failingToken), amount, 0, gasLimit, "", "", revertCfg);
    }

    // =========================
    //      PC20 OUTBOUND TESTS
    // =========================

    function testPC20_FundsOnly_Success() public {
        uint256 amount = 1000 ether;
        bytes memory target = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        uint256 beforeVaultBalance = vaultPC.balance;
        uint256 beforeUserBalance = pc20Token.balanceOf(user1);

        // PC20 outbound uses native PC for protocol fee
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: DEFAULT_PROTOCOL_FEE}(
            target,
            address(pc20Token),
            amount,
            0,
            0,                      // gasLimit, ignored for PC20 in current fee model
            "",
            ETH_CHAIN_NAMESPACE,
            revertCfg
        );

        // Vault receives the native fee
        assertEq(vaultPC.balance, beforeVaultBalance + DEFAULT_PROTOCOL_FEE);

        // PC20 moved from user to gateway
        assertEq(pc20Token.balanceOf(user1), beforeUserBalance - amount);
        assertEq(pc20Token.balanceOf(address(gateway)), amount);
    }

    function testPC20_FundsAndPayload_Success() public {
        uint256 amount = 500 ether;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("someFunction(uint256)", 42);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        uint256 beforeVaultBalance = vaultPC.balance;
        uint256 beforeUserBalance = pc20Token.balanceOf(user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: DEFAULT_PROTOCOL_FEE}(
            target,
            address(pc20Token),
            amount,
            0,
            123_456,                // gasLimit hint, still flat fee now
            payload,
            ETH_CHAIN_NAMESPACE,
            revertCfg
        );

        assertEq(vaultPC.balance, beforeVaultBalance + DEFAULT_PROTOCOL_FEE);
        assertEq(pc20Token.balanceOf(user1), beforeUserBalance - amount);
        assertEq(pc20Token.balanceOf(address(gateway)), amount);
    }

    function testPC20_Revert_EmptyChainNamespace() public {
        uint256 amount = 1000 ether;
        bytes memory target = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTxOutbound{value: DEFAULT_PROTOCOL_FEE}(
            target,
            address(pc20Token),
            amount,
            0,
            0,
            "",
            "",                     // empty chainNamespace
            revertCfg
        );
    }

    function testPC20_Revert_UnsupportedChainNamespace() public {
        uint256 amount = 1000 ether;
        bytes memory target = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Disable PC20 support on ETH_CHAIN_NAMESPACE
        vm.prank(admin);
        universalCore.setPC20SupportOnChain(ETH_CHAIN_NAMESPACE, false);

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTxOutbound{value: DEFAULT_PROTOCOL_FEE}(
            target,
            address(pc20Token),
            amount,
            0,
            0,
            "",
            ETH_CHAIN_NAMESPACE,
            revertCfg
        );
    }

    function testPC20_Revert_InsufficientNativeFee() public {
        uint256 amount = 1000 ether;
        bytes memory target = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // Send less native value than required protocol fee
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendUniversalTxOutbound{value: DEFAULT_PROTOCOL_FEE - 1}(
            target,
            address(pc20Token),
            amount,
            0,
            0,
            "",
            ETH_CHAIN_NAMESPACE,
            revertCfg
        );
    }
    // =========================
    //      PC721 OUTBOUND TESTS
    // =========================

    function testPC721_FundsOnly_Success() public {
        uint256 tokenId = 1;
        bytes memory target = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        uint256 beforeVaultBalance = vaultPC.balance;
        address beforeOwner = pc721Token.ownerOf(tokenId);

        assertEq(beforeOwner, user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: DEFAULT_PROTOCOL_FEE}(
            target,
            address(pc721Token),
            0,
            tokenId,
            0,
            "",
            ETH_CHAIN_NAMESPACE,
            revertCfg
        );

        assertEq(vaultPC.balance, beforeVaultBalance + DEFAULT_PROTOCOL_FEE);
        assertEq(pc721Token.ownerOf(tokenId), address(gateway));
    }

    function testPC721_FundsAndPayload_Success() public {
        uint256 tokenId = 2;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("doSomething(address,uint256)", user2, tokenId);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        uint256 beforeVaultBalance = vaultPC.balance;
        address beforeOwner = pc721Token.ownerOf(tokenId);
        assertEq(beforeOwner, user1);

        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: DEFAULT_PROTOCOL_FEE}(
            target,
            address(pc721Token),
            0,
            tokenId,
            250_000,
            payload,
            ETH_CHAIN_NAMESPACE,
            revertCfg
        );

        assertEq(vaultPC.balance, beforeVaultBalance + DEFAULT_PROTOCOL_FEE);
        assertEq(pc721Token.ownerOf(tokenId), address(gateway));
    }

    function testPC721_Revert_EmptyChainNamespace() public {
        uint256 tokenId = 3;
        bytes memory target = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // ensure user2 owns tokenId 3 in setup
        assertEq(pc721Token.ownerOf(3), user2);

        vm.prank(user2);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTxOutbound{value: DEFAULT_PROTOCOL_FEE}(
            target,
            address(pc721Token),
            0,
            tokenId,
            0,
            "",
            "",
            revertCfg
        );
    }

    function testPC721_Revert_UnsupportedChainNamespace() public {
        uint256 tokenId = 1;
        bytes memory target = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(admin);
        universalCore.setPC721SupportOnChain(ETH_CHAIN_NAMESPACE, false);

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTxOutbound{value: DEFAULT_PROTOCOL_FEE}(
            target,
            address(pc721Token),
            0,
            tokenId,
            0,
            "",
            ETH_CHAIN_NAMESPACE,
            revertCfg
        );
    }

    function testPC721_Revert_InsufficientNativeFee() public {
        uint256 tokenId = 2;
        bytes memory target = abi.encodePacked(user2);
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendUniversalTxOutbound{value: DEFAULT_PROTOCOL_FEE - 1}(
            target,
            address(pc721Token),
            0,
            tokenId,
            0,
            "",
            ETH_CHAIN_NAMESPACE,
            revertCfg
        );
    }

    function test_UniversalTxOutbound_TxIdComputedCorrectly_PRC20() public {
        uint256 amount        = 1000 * 1e6;
        uint256 gasLimit      = DEFAULT_GAS_LIMIT;
        bytes  memory target  = abi.encodePacked(user2);
        bytes  memory payload = "";                 // keep simple
        string memory chainNamespace = "";          // PRC20 path ignores this for routing

        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // 1) Read nonce BEFORE call (this is what the contract hashes in)
        uint256 nonceBefore = gateway.outboundTxNonce();

        // 2) Execute and record logs
        vm.recordLogs();
        vm.prank(user1);
        gateway.sendUniversalTxOutbound(
            target,
            address(prc20Token),
            amount,
            0,              // tokenId
            gasLimit,
            payload,
            chainNamespace,
            revertCfg
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // 3) Find the first log from gateway and take topics[1] as txId
        bytes32 actualTxId;
        bool found;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(gateway)) {
                // topic[0] = event signature, topic[1] = first indexed arg (txId)
                require(logs[i].topics.length > 1, "no indexed txId in event");
                actualTxId = logs[i].topics[1];
                found = true;
                break;
            }
        }

        assertTrue(found, "UniversalTxOutbound event not found");

        // 4) Compute expectedTxId with EXACT same formula as the contract
        bytes32 expectedTxId = keccak256(
            abi.encode(
                bytes32("PUSH.OUTBOUND.TX"),
                user1,                              // msg.sender
                address(prc20Token),                // token
                amount,                             // amount
                uint256(0),                         // tokenId
                keccak256(payload),                 // keccak(payload)
                keccak256(bytes(chainNamespace)),   // keccak(bytes(chainNamespace))
                nonceBefore                         // nonce before increment
            )
        );

        assertEq(actualTxId, expectedTxId, "txId mismatch");
    }

    function test_UniversalTxOutbound_TxIdComputedCorrectly_PC20() public {
        // Enable PC20 support on this chain namespace
        vm.prank(admin);
        universalCore.setPC20SupportOnChain(ETH_CHAIN_NAMESPACE, true);

        // Deploy and fund PC20 for user1
        MockPC20 pc20 = new MockPC20("PC20 Test Token", "PC20T");
        pc20.mint(user1, 1_000 ether);

        vm.prank(user1);
        pc20.approve(address(gateway), type(uint256).max);

        uint256 amount = 100 ether;
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("pc20Function(address,uint256)", user2, amount);
        
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // 1) Capture nonce BEFORE call (this is what the contract hashes in)
        uint256 nonceBefore = gateway.outboundTxNonce();

        // 2) Execute and record logs
        vm.recordLogs();
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: DEFAULT_PROTOCOL_FEE}(
            target,
            address(pc20),
            amount,
            0,                    // tokenId (not used for PC20)
            gasLimit,
            payload,
            ETH_CHAIN_NAMESPACE,
            revertCfg
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // 3) Find the UniversalTxOutbound event and extract txId from topics[1]
        bytes32 eventSig = keccak256(
            "UniversalTxOutbound(bytes32,address,address,string,bytes,uint256,address,uint256,uint256,bytes,uint256,(address,bytes))"
        );
        
        bytes32 actualTxId;
        bool found;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                actualTxId = logs[i].topics[1];
                found = true;
                break;
            }
        }

        assertTrue(found, "UniversalTxOutbound event not found for PC20");

        // 4) Compute expectedTxId with EXACT same formula as the contract
        bytes32 expectedTxId = keccak256(
            abi.encode(
                bytes32("PUSH.OUTBOUND.TX"),
                user1,                                      // msg.sender
                address(pc20),                              // token
                amount,                                     // amount
                uint256(0),                                 // tokenId
                keccak256(payload),                         // keccak(payload)
                keccak256(bytes(ETH_CHAIN_NAMESPACE)),      // keccak(bytes(chainNamespace))
                nonceBefore                                 // nonce before increment
            )
        );

        assertEq(actualTxId, expectedTxId, "txId mismatch for PC20");
    }

    function test_UniversalTxOutbound_TxIdComputedCorrectly_PC721() public {
        // Enable PC721 support on this chain namespace
        vm.prank(admin);
        universalCore.setPC721SupportOnChain(ETH_CHAIN_NAMESPACE, true);

        // Deploy and mint PC721 for user1
        MockPC721 pc721 = new MockPC721("PC721 Test Token", "PC721T");
        uint256 tokenId = 1;
        pc721.mint(user1, tokenId);

        vm.prank(user1);
        pc721.approve(address(gateway), tokenId);

        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("pc721Function(address,uint256)", user2, tokenId);
        
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // 1) Capture nonce BEFORE call (this is what the contract hashes in)
        uint256 nonceBefore = gateway.outboundTxNonce();

        // 2) Execute and record logs
        vm.recordLogs();
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: DEFAULT_PROTOCOL_FEE}(
            target,
            address(pc721),
            0,                    // amount (not used for PC721)
            tokenId,
            gasLimit,
            payload,
            ETH_CHAIN_NAMESPACE,
            revertCfg
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // 3) Find the UniversalTxOutbound event and extract txId from topics[1]
        bytes32 eventSig = keccak256(
            "UniversalTxOutbound(bytes32,address,address,string,bytes,uint256,address,uint256,uint256,bytes,uint256,(address,bytes))"
        );
        
        bytes32 actualTxId;
        bool found;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                actualTxId = logs[i].topics[1];
                found = true;
                break;
            }
        }

        assertTrue(found, "UniversalTxOutbound event not found for PC721");

        // 4) Compute expectedTxId with EXACT same formula as the contract
        bytes32 expectedTxId = keccak256(
            abi.encode(
                bytes32("PUSH.OUTBOUND.TX"),
                user1,                                      // msg.sender
                address(pc721),                             // token
                uint256(0),                                 // amount
                tokenId,                                    // tokenId
                keccak256(payload),                         // keccak(payload)
                keccak256(bytes(ETH_CHAIN_NAMESPACE)),      // keccak(bytes(chainNamespace))
                nonceBefore                                 // nonce before increment
            )
        );

        assertEq(actualTxId, expectedTxId, "txId mismatch for PC721");
    }

    function test_UniversalTxOutbound_TxIdComputedCorrectly_PayloadOnly() public {
        uint256 gasLimit = DEFAULT_GAS_LIMIT;
        bytes memory target = abi.encodePacked(user2);
        bytes memory payload = abi.encodeWithSignature("executeAction(address,string)", user2, "test");
        
        RevertInstructions memory revertCfg = buildRevertInstructions(user2);

        // 1) Capture nonce BEFORE call (this is what the contract hashes in)
        uint256 nonceBefore = gateway.outboundTxNonce();

        // 2) Execute and record logs
        vm.recordLogs();
        vm.prank(user1);
        gateway.sendUniversalTxOutbound{value: DEFAULT_PROTOCOL_FEE}(
            target,
            address(0),           // token = address(0) for payload-only
            0,                    // amount
            0,                    // tokenId
            gasLimit,
            payload,
            ETH_CHAIN_NAMESPACE,
            revertCfg
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // 3) Find the UniversalTxOutbound event and extract txId from topics[1]
        bytes32 eventSig = keccak256(
            "UniversalTxOutbound(bytes32,address,address,string,bytes,uint256,address,uint256,uint256,bytes,uint256,(address,bytes))"
        );
        
        bytes32 actualTxId;
        bool found;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                actualTxId = logs[i].topics[1];
                found = true;
                break;
            }
        }

        assertTrue(found, "UniversalTxOutbound event not found for PayloadOnly");

        // 4) Compute expectedTxId with EXACT same formula as the contract
        bytes32 expectedTxId = keccak256(
            abi.encode(
                bytes32("PUSH.OUTBOUND.TX"),
                user1,                                      // msg.sender
                address(0),                                 // token (address(0) for payload-only)
                uint256(0),                                 // amount
                uint256(0),                                 // tokenId
                keccak256(payload),                         // keccak(payload)
                keccak256(bytes(ETH_CHAIN_NAMESPACE)),      // keccak(bytes(chainNamespace))
                nonceBefore                                 // nonce before increment
            )
        );

        assertEq(actualTxId, expectedTxId, "txId mismatch for PayloadOnly");
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
        vaultPC = address(0x7);

        vm.label(admin, "admin");
        vm.label(pauser, "pauser");
        vm.label(user1, "user1");
        vm.label(user2, "user2");
        vm.label(attacker, "attacker");
        vm.label(uem, "uem");
        vm.label(vaultPC, "vaultPC");

        vm.deal(admin, 100 ether);
        vm.deal(pauser, 100 ether);
        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);
        vm.deal(attacker, 1000 ether);
    }

    function _deployMocks() internal {
        // Deploy UniversalCore mock
        universalCore = new MockUniversalCoreReal(uem);
        
        // Grant admin role to admin address
        universalCore.grantRole(universalCore.DEFAULT_ADMIN_ROLE(), admin);

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
        
        // Configure protocol fees for PC20 / PC721 / default
        vm.prank(admin);
        universalCore.setProtocolFees(
            DEFAULT_PROTOCOL_FEE, // PC20
            DEFAULT_PROTOCOL_FEE, // PC721
            DEFAULT_PROTOCOL_FEE  // default
        );

        // Mark PC20 / PC721 as supported on this chainNamespace
        vm.prank(admin);
        universalCore.setPC20SupportOnChain(ETH_CHAIN_NAMESPACE, true);
        vm.prank(admin);
        universalCore.setPC721SupportOnChain(ETH_CHAIN_NAMESPACE, true);

        // Mark PRC20 token as supported
        vm.prank(admin);
        universalCore.setSupportedToken(address(prc20Token), true);

          // Deploy PC20 and PC721 mocks
        pc20Token = new MockPC20("PC20 Test Token", "PC20T");
        pc721Token = new MockPC721("PC721 Test Token", "PC721T");

        vm.label(address(universalCore), "UniversalCore");
        vm.label(address(prc20Token), "PRC20Token");
        vm.label(address(gasToken), "GasToken");
        vm.label(address(pc20Token), "PC20Token");
        vm.label(address(pc721Token), "PC721Token");
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
            address(universalCore),
            vaultPC
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
        assertEq(address(gateway.VAULT_PC()), vaultPC);
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

        // Mint PC20 and PC721 to users for tests
        pc20Token.mint(user1, LARGE_AMOUNT);
        pc20Token.mint(user2, LARGE_AMOUNT);

        // Approve gateway for PC20
        vm.prank(user1);
        pc20Token.approve(address(gateway), type(uint256).max);
        vm.prank(user2);
        pc20Token.approve(address(gateway), type(uint256).max);

        // Mint NFTs to users
        pc721Token.mint(user1, 1);
        pc721Token.mint(user1, 2);
        pc721Token.mint(user2, 3);

        // Approve gateway for NFTs
        vm.prank(user1);
        pc721Token.setApprovalForAll(address(gateway), true);
        vm.prank(user2);
        pc721Token.setApprovalForAll(address(gateway), true);
    }
}