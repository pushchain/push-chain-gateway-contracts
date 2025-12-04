// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import { Vault } from "../../src/Vault.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { RevertInstructions } from "../../src/libraries/Types.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockCEAFactory } from "../mocks/MockCEAFactory.sol";
import { MockCEA } from "../mocks/MockCEA.sol";
import { MockTokenApprovalVariants } from "../mocks/MockTokenApprovalVariants.sol";
import { MockTarget } from "../mocks/MockTarget.sol";
import { MockRevertingTarget } from "../mocks/MockRevertingTarget.sol";
import { MockReentrantContract } from "../mocks/MockReentrantContract.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VaultTest is Test {
    Vault public vault;
    Vault public vaultImpl;
    UniversalGateway public gateway;
    UniversalGateway public gatewayImpl;
    MockERC20 public token;
    MockERC20 public token2;
    MockTokenApprovalVariants public variantToken;
    MockRevertingTarget public mockRevertingTarget;
    MockReentrantContract public reentrantAttacker;
    MockTarget public mockTarget;
    MockCEAFactory public ceaFactory;

    address public admin;
    address public pauser;
    address public tss;
    address public user1;
    address public user2;
    address public weth;

    // Events
    event GatewayUpdated(address indexed oldGateway, address indexed newGateway);
    event TSSUpdated(address indexed oldTss, address indexed newTss);
    event VaultWithdraw(
        bytes32 indexed txID, address indexed ueaAddress, address indexed token, address to, uint256 amount
    );
    event VaultWithdrawAndExecute(address indexed token, address indexed target, uint256 amount, bytes data);
    event VaultRevert(address indexed token, address indexed to, uint256 amount, RevertInstructions revertInstruction);

    bytes32 txID = bytes32(uint256(1));

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        tss = makeAddr("tss");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        weth = makeAddr("weth");

        // Deploy UniversalGateway
        gatewayImpl = new UniversalGateway();
        bytes memory gatewayInitData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin,
            tss,
            address(this), // vault address (will be set to actual vault after deployment)
            1e18, // minCapUsd
            10e18, // maxCapUsd
            address(0), // factory (not needed for Vault tests)
            address(0), // router (not needed for Vault tests)
            weth
        );
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), gatewayInitData);
        gateway = UniversalGateway(payable(address(gatewayProxy)));

        // Deploy MockCEAFactory
        ceaFactory = new MockCEAFactory();

        // Deploy Vault implementation and proxy
        vaultImpl = new Vault();
        bytes memory vaultInitData =
            abi.encodeWithSelector(Vault.initialize.selector, admin, pauser, tss, address(gateway), address(ceaFactory));
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = Vault(address(vaultProxy));

        // Set VAULT address in MockCEAFactory (required for onlyVault modifier)
        ceaFactory.setVault(address(vault));

        // Update gateway's VAULT_ROLE to point to actual vault
        vm.startPrank(admin);
        gateway.pause();
        vm.stopPrank();

        vm.prank(admin);
        gateway.updateVault(address(vault));

        vm.startPrank(admin);
        gateway.unpause();
        vm.stopPrank();

        // Deploy tokens
        token = new MockERC20("Test Token", "TST", 18, 1_000_000e18);
        token2 = new MockERC20("Test Token 2", "TST2", 6, 1_000_000e6);
        variantToken = new MockTokenApprovalVariants();

        // Deploy helper contracts
        mockRevertingTarget = new MockRevertingTarget();
        reentrantAttacker = new MockReentrantContract(address(0), address(0), address(0));
        reentrantAttacker.setVault(address(vault));
        mockTarget = new MockTarget();

        // Setup: support tokens in gateway (including native token address(0))
        address[] memory tokens = new address[](4);
        tokens[0] = address(token);
        tokens[1] = address(token2);
        tokens[2] = address(variantToken);
        tokens[3] = address(0); // Native token

        uint256[] memory thresholds = new uint256[](4);
        thresholds[0] = 1_000_000e18;
        thresholds[1] = 1_000_000e6;
        thresholds[2] = 1_000_000e18;
        thresholds[3] = 1_000_000e18; // Native token threshold

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Fund vault with tokens
        token.mint(address(vault), 100_000e18);
        token2.mint(address(vault), 100_000e6);
        variantToken.mint(address(vault), 100_000e18);
    }

    // ============================================================================
    // INITIALIZATION TESTS
    // ============================================================================

    function test_Initialization_RolesAssigned() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), pauser));
        assertTrue(vault.hasRole(vault.TSS_ROLE(), tss));
    }

    function test_Initialization_GatewaySet() public view {
        assertEq(address(vault.gateway()), address(gateway));
    }

    function test_Initialization_TSSAddressSet() public view {
        assertEq(vault.TSS_ADDRESS(), tss);
    }

    function test_Initialization_StartsUnpaused() public view {
        assertFalse(vault.paused());
    }

    function test_Initialization_RevertsOnZeroAdmin() public {
        Vault newImpl = new Vault();
        bytes memory initData =
            abi.encodeWithSelector(Vault.initialize.selector, address(0), pauser, tss, address(gateway), address(ceaFactory));
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialization_RevertsOnZeroPauser() public {
        Vault newImpl = new Vault();
        bytes memory initData =
            abi.encodeWithSelector(Vault.initialize.selector, admin, address(0), tss, address(gateway), address(ceaFactory));
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialization_RevertsOnZeroTSS() public {
        Vault newImpl = new Vault();
        bytes memory initData =
            abi.encodeWithSelector(Vault.initialize.selector, admin, pauser, address(0), address(gateway), address(ceaFactory));
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialization_RevertsOnZeroGateway() public {
        Vault newImpl = new Vault();
        bytes memory initData = abi.encodeWithSelector(Vault.initialize.selector, admin, pauser, tss, address(0), address(ceaFactory));
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialization_RevertsOnZeroCEAFactory() public {
        Vault newImpl = new Vault();
        bytes memory initData = abi.encodeWithSelector(Vault.initialize.selector, admin, pauser, tss, address(gateway), address(0));
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ============================================================================
    // ACCESS CONTROL & ROLE ROTATION TESTS
    // ============================================================================

    function test_Pause_OnlyPauserCanPause() public {
        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_Pause_NonPauserReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.pause();
    }

    function test_Unpause_OnlyPauserCanUnpause() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(pauser);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_Unpause_NonPauserReverts() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(user1);
        vm.expectRevert();
        vault.unpause();
    }

    function test_SetGateway_OnlyAdminCanSet() public {
        UniversalGateway newGatewayImpl = new UniversalGateway();
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector, admin, tss, address(this), 1e18, 10e18, address(0), address(0), weth
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newGatewayImpl), initData);
        UniversalGateway newGateway = UniversalGateway(payable(address(newProxy)));

        vm.prank(admin);
        vault.setGateway(address(newGateway));
        assertEq(address(vault.gateway()), address(newGateway));
    }

    function test_SetGateway_NonAdminReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.setGateway(address(gateway));
    }

    function test_SetGateway_ZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.setGateway(address(0));
    }

    function test_SetGateway_EmitsEvent() public {
        UniversalGateway newGatewayImpl = new UniversalGateway();
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector, admin, tss, address(this), 1e18, 10e18, address(0), address(0), weth
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newGatewayImpl), initData);
        UniversalGateway newGateway = UniversalGateway(payable(address(newProxy)));

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit GatewayUpdated(address(gateway), address(newGateway));
        vault.setGateway(address(newGateway));
    }

    function test_SetTSS_OnlyAdminCanSet() public {
        address newTSS = makeAddr("newTSS");

        vm.prank(admin);
        vault.setTSS(newTSS);
        assertEq(vault.TSS_ADDRESS(), newTSS);
        assertTrue(vault.hasRole(vault.TSS_ROLE(), newTSS));
    }

    function test_SetTSS_NonAdminReverts() public {
        address newTSS = makeAddr("newTSS");

        vm.prank(user1);
        vm.expectRevert();
        vault.setTSS(newTSS);
    }

    function test_SetTSS_ZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.setTSS(address(0));
    }

    function test_SetTSS_RevokesOldTSSRole() public {
        address newTSS = makeAddr("newTSS");

        vm.prank(admin);
        vault.setTSS(newTSS);

        assertFalse(vault.hasRole(vault.TSS_ROLE(), tss));
        assertTrue(vault.hasRole(vault.TSS_ROLE(), newTSS));
    }

    function test_SetTSS_OldTSSCannotCallFunctions() public {
        address newTSS = makeAddr("newTSS");

        vm.prank(admin);
        vault.setTSS(newTSS);

        vm.prank(tss);
        vm.expectRevert();
        vault.withdraw(txID, user1, address(token), user1, 100e18);
    }

    function test_SetTSS_NewTSSCanCallFunctions() public {
        address newTSS = makeAddr("newTSS");

        vm.prank(admin);
        vault.setTSS(newTSS);

        vm.prank(newTSS);
        vault.withdraw(txID, user1, address(token), user1, 100e18);
        assertEq(token.balanceOf(user1), 100e18);
    }

    function test_SetTSS_EmitsEvent() public {
        address newTSS = makeAddr("newTSS");

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit TSSUpdated(tss, newTSS);
        vault.setTSS(newTSS);
    }

    function test_SetTSS_AllowedWhenPaused() public {
        address newTSS = makeAddr("newTSS");

        vm.prank(pauser);
        vault.pause();

        vm.prank(admin);
        vault.setTSS(newTSS);
        assertEq(vault.TSS_ADDRESS(), newTSS);
    }

    function test_Withdraw_OnlyTSSCanCall() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(txID, user1, address(token), user1, 100e18);
    }

    function test_RevertWithdraw_OnlyTSSCanCall() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.revertWithdraw(bytes32(uint256(1)), address(token), user1, 100e18, RevertInstructions(user1, ""));
    }

    // ============================================================================
    // PAUSE GATING TESTS
    // ============================================================================

    function test_Pause_BlocksWithdraw() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.withdraw(txID, user1, address(token), user1, 100e18);
    }

    function test_Pause_BlocksRevertWithdraw() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.revertWithdraw(bytes32(uint256(1)), address(token), user1, 100e18, RevertInstructions(user1, ""));
    }

    function test_Pause_AllowsSetGateway() public {
        vm.prank(pauser);
        vault.pause();

        UniversalGateway newGatewayImpl = new UniversalGateway();
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector, admin, tss, address(this), 1e18, 10e18, address(0), address(0), weth
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newGatewayImpl), initData);
        UniversalGateway newGateway = UniversalGateway(payable(address(newProxy)));

        vm.prank(admin);
        vault.setGateway(address(newGateway));
        assertEq(address(vault.gateway()), address(newGateway));
    }

    function test_Pause_DoublePauseReverts() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(pauser);
        vm.expectRevert();
        vault.pause();
    }

    function test_Unpause_DoubleUnpauseReverts() public {
        vm.prank(pauser);
        vm.expectRevert();
        vault.unpause();
    }

    function test_Unpause_RestoresWithdrawFunctionality() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(pauser);
        vault.unpause();

        vm.prank(tss);
        vault.withdraw(txID, user1, address(token), user1, 100e18);
        assertEq(token.balanceOf(user1), 100e18);
    }

    // ============================================================================
    // TOKEN SUPPORT / GATEWAY GATING TESTS
    // ============================================================================

    function test_Withdraw_UnsupportedTokenReverts() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS", 18, 1000e18);
        unsupportedToken.mint(address(vault), 100e18);

        vm.prank(tss);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.withdraw(txID, user1, address(unsupportedToken), user1, 100e18);
    }

    function test_RevertWithdraw_UnsupportedTokenReverts() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS", 18, 1000e18);
        unsupportedToken.mint(address(vault), 100e18);

        vm.prank(tss);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.revertWithdraw(
            bytes32(uint256(2)), address(unsupportedToken), user1, 100e18, RevertInstructions(user1, "")
        );
    }

    function test_TokenSupport_TogglingReflectsImmediately() public {
        // Initially supported
        vm.prank(tss);
        vault.withdraw(bytes32(uint256(1)), user1, address(token), user1, 100e18);
        assertEq(token.balanceOf(user1), 100e18);

        // Remove support
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 0;

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        vm.prank(tss);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.withdraw(bytes32(uint256(2)), user2, address(token), user2, 100e18);

        // Re-add support
        thresholds[0] = 1_000_000e18;
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        vm.prank(tss);
        vault.withdraw(bytes32(uint256(3)), user2, address(token), user2, 100e18);
        assertEq(token.balanceOf(user2), 100e18);
    }

    function test_Withdraw_ZeroTokenAddressReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.withdraw(txID, user1, address(0), user1, 100e18);
    }

    function test_RevertWithdraw_ZeroTokenAddressReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.revertWithdraw(bytes32(uint256(3)), address(0), user1, 100e18, RevertInstructions(user1, ""));
    }

    // ============================================================================
    // WITHDRAW (SIMPLE TRANSFER) TESTS
    // ============================================================================

    function test_Withdraw_StandardToken_Success() public {
        uint256 amount = 1000e18;

        vm.prank(tss);
        vault.withdraw(txID, user1, address(token), user1, amount);

        assertEq(token.balanceOf(user1), amount);
    }

    function test_Withdraw_EmitsEvent() public {
        uint256 amount = 1000e18;

        vm.prank(tss);
        vm.expectEmit(true, true, true, true);
        emit VaultWithdraw(txID, user1, address(token), user1, amount);
        vault.withdraw(txID, user1, address(token), user1, amount);
    }

    function test_Withdraw_ZeroAmountReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.withdraw(txID, user1, address(token), user1, 0);
    }

    function test_Withdraw_ZeroRecipientReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.withdraw(txID, user1, address(token), address(0), 100e18);
    }

    function test_Withdraw_InsufficientBalanceReverts() public {
        uint256 vaultBalance = token.balanceOf(address(vault));

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.withdraw(txID, user1, address(token), user1, vaultBalance + 1);
    }

    function test_Withdraw_MultipleRecipients() public {
        vm.prank(tss);
        vault.withdraw(bytes32(uint256(1)), user1, address(token), user1, 100e18);

        vm.prank(tss);
        vault.withdraw(bytes32(uint256(2)), user2, address(token), user2, 200e18);

        assertEq(token.balanceOf(user1), 100e18);
        assertEq(token.balanceOf(user2), 200e18);
    }

    function test_Withdraw_DifferentTokens() public {
        vm.prank(tss);
        vault.withdraw(bytes32(uint256(1)), user1, address(token), user1, 100e18);

        vm.prank(tss);
        vault.withdraw(bytes32(uint256(2)), user1, address(token2), user1, 50e6);

        assertEq(token.balanceOf(user1), 100e18);
        assertEq(token2.balanceOf(user1), 50e6);
    }

    // ============================================================================
    // REVERTWITHDRAW TESTS
    // ============================================================================

    function test_RevertWithdraw_StandardToken_Success() public {
        uint256 amount = 1000e18;

        vm.prank(tss);
        vault.revertWithdraw(bytes32(uint256(4)), address(token), user1, amount, RevertInstructions(user1, ""));

        assertEq(token.balanceOf(user1), amount);
    }

    function test_RevertWithdraw_EmitsEvent() public {
        uint256 amount = 1000e18;

        RevertInstructions memory revertInstr = RevertInstructions(user1, "");

        vm.prank(tss);
        vm.expectEmit(true, true, false, true);
        emit VaultRevert(address(token), user1, amount, revertInstr);
        vault.revertWithdraw(bytes32(uint256(5)), address(token), user1, amount, revertInstr);
    }

    function test_RevertWithdraw_ZeroAmountReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.revertWithdraw(bytes32(uint256(6)), address(token), user1, 0, RevertInstructions(user1, ""));
    }

    function test_RevertWithdraw_ZeroRecipientReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.revertWithdraw(
            bytes32(uint256(7)), address(token), address(0), 100e18, RevertInstructions(address(0), "")
        );
    }

    function test_RevertWithdraw_InsufficientBalanceReverts() public {
        uint256 vaultBalance = token.balanceOf(address(vault));

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.revertWithdraw(
            bytes32(uint256(8)), address(token), user1, vaultBalance + 1, RevertInstructions(user1, "")
        );
    }

    function test_RevertWithdraw_WhenPausedReverts() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.revertWithdraw(bytes32(uint256(1)), address(token), user1, 100e18, RevertInstructions(user1, ""));
    }

    // ============================================================================
    // WITHDRAWANDEXECUTE TESTS
    // ============================================================================

    function test_WithdrawAndExecute_StandardToken_Success() public {
        uint256 amount = 100e18;
        bytes memory callData = abi.encodeWithSignature("receiveToken(address,uint256)", address(token), amount);

        uint256 initialVaultBalance = token.balanceOf(address(vault));

        vm.prank(tss);
        vault.handleOutboundExecution(bytes32(uint256(200)), user1, address(token), address(mockTarget), amount, callData);

        // Verify tokens were transferred via CEA and call was executed
        (address cea, ) = ceaFactory.getCEAForUEA(user1);
        assertEq(mockTarget.lastCaller(), cea);
        assertEq(token.balanceOf(address(vault)), initialVaultBalance - amount);
    }

    function test_WithdrawAndExecute_EmitsEvent() public {
        uint256 amount = 100e18;
        bytes memory callData = "";

        vm.prank(tss);
        vm.expectEmit(true, true, false, true);
        emit VaultWithdrawAndExecute(address(token), address(mockTarget), amount, callData);
        vault.handleOutboundExecution(bytes32(uint256(201)), user1, address(token), address(mockTarget), amount, callData);
    }

    function test_WithdrawAndExecute_OnlyTSSCanCall() public {
        bytes memory callData = "";

        vm.prank(user1);
        vm.expectRevert();
        vault.handleOutboundExecution(bytes32(uint256(202)), user1, address(token), address(mockTarget), 100e18, callData);
    }

    function test_WithdrawAndExecute_WhenPausedReverts() public {
        vm.prank(pauser);
        vault.pause();

        bytes memory callData = "";

        vm.prank(tss);
        vm.expectRevert();
        vault.handleOutboundExecution(bytes32(uint256(203)), user1, address(token), address(mockTarget), 100e18, callData);
    }

    function test_WithdrawAndExecute_ZeroTokenReverts() public {
        bytes memory callData = "";

        // In new implementation, address(0) is valid for native flows but requires msg.value == amount
        // Since msg.value is 0 and amount is 100e18, it will revert with InvalidAmount
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.handleOutboundExecution(bytes32(uint256(204)), user1, address(0), address(mockTarget), 100e18, callData);
    }

    function test_WithdrawAndExecute_ZeroTargetReverts() public {
        bytes memory callData = "";

        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.handleOutboundExecution(bytes32(uint256(205)), user1, address(token), address(0), 100e18, callData);
    }

    function test_WithdrawAndExecute_ZeroAmount_Succeeds() public {
        bytes memory callData = "";

        // Zero amount is now allowed in validation (amount check is commented out)
        // The call should succeed with CEA deployment
        vm.prank(tss);
        vault.handleOutboundExecution(bytes32(uint256(206)), user1, address(token), address(mockTarget), 0, callData);
        
        // Verify CEA was deployed even with zero amount
        (address cea, bool isDeployed) = ceaFactory.getCEAForUEA(user1);
        assertTrue(isDeployed);
    }

    function test_WithdrawAndExecute_InsufficientBalanceReverts() public {
        uint256 vaultBalance = token.balanceOf(address(vault));
        bytes memory callData = "";

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.handleOutboundExecution(
            bytes32(uint256(207)), user1, address(token), address(mockTarget), vaultBalance + 1, callData
        );
    }

    function test_WithdrawAndExecute_UnsupportedTokenReverts() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS", 18, 1000e18);
        unsupportedToken.mint(address(vault), 100e18);
        bytes memory callData = "";

        vm.prank(tss);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.handleOutboundExecution(
            bytes32(uint256(208)), user1, address(unsupportedToken), address(mockTarget), 100e18, callData
        );
    }

    function test_WithdrawAndExecute_WithPayload_VerifiesExecution() public {
        uint256 amount = 100e18;
        bytes memory callData = abi.encodeWithSignature("receiveToken(address,uint256)", address(token), amount);

        vm.prank(tss);
        vault.handleOutboundExecution(bytes32(uint256(209)), user1, address(token), address(mockTarget), amount, callData);

        // Verify the call was executed via CEA (MockTarget stores lastCaller)
        (address cea, ) = ceaFactory.getCEAForUEA(user1);
        assertEq(mockTarget.lastCaller(), cea);
        assertEq(mockTarget.lastToken(), address(token));
    }

    function test_WithdrawAndExecute_EmptyPayload_Success() public {
        uint256 amount = 100e18;
        bytes memory callData = "";

        // With empty payload, tokens are transferred to CEA but target doesn't consume them
        uint256 initialVaultBalance = token.balanceOf(address(vault));

        vm.prank(tss);
        vault.handleOutboundExecution(bytes32(uint256(210)), user1, address(token), address(mockTarget), amount, callData);

        // Tokens moved from vault
        assertEq(token.balanceOf(address(vault)), initialVaultBalance - amount);
    }

    function test_WithdrawAndExecute_DifferentTokens() public {
        bytes memory callData = abi.encodeWithSignature("receiveToken(address,uint256)", address(token), 50e18);

        vm.prank(tss);
        vault.handleOutboundExecution(bytes32(uint256(211)), user1, address(token), address(mockTarget), 50e18, callData);

        // Token 2 with different decimals
        bytes memory callData2 = abi.encodeWithSignature("receiveToken(address,uint256)", address(token2), 25e6);
        vm.prank(tss);
        vault.handleOutboundExecution(bytes32(uint256(212)), user1, address(token2), address(mockTarget), 25e6, callData2);

        // Verify both calls executed via CEA
        (address cea, ) = ceaFactory.getCEAForUEA(user1);
        assertEq(mockTarget.lastCaller(), cea);
    }

    // ============================================================================
    // SWEEP TESTS
    // ============================================================================

    function test_Sweep_OnlyAdminCanCall() public {
        vm.prank(admin);
        vault.sweep(address(token), user1, 100e18);
        assertEq(token.balanceOf(user1), 100e18);
    }

    function test_Sweep_NonAdminReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.sweep(address(token), user1, 100e18);
    }

    function test_Sweep_ZeroTokenReverts() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.sweep(address(0), user1, 100e18);
    }

    function test_Sweep_ZeroRecipientReverts() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.sweep(address(token), address(0), 100e18);
    }

    function test_Sweep_StandardToken_Success() public {
        uint256 amount = 500e18;

        vm.prank(admin);
        vault.sweep(address(token), user1, amount);

        assertEq(token.balanceOf(user1), amount);
    }

    function test_Sweep_NoReturnToken_Success() public {
        variantToken.setApprovalBehavior(MockTokenApprovalVariants.ApprovalBehavior.NO_RETURN_DATA);

        uint256 amount = 500e18;

        vm.prank(admin);
        vault.sweep(address(variantToken), user1, amount);
        assertEq(variantToken.balanceOf(user1), amount);
    }

    // ============================================================================
    // NO NATIVE INVARIANT TESTS
    // ============================================================================

    function test_NoNative_DirectETHSendReverts() public {
        vm.deal(user1, 1 ether);

        vm.prank(user1);
        (bool success,) = address(vault).call{ value: 1 ether }("");
        assertFalse(success);
    }

    function test_NoNative_NoReceiveFunction() public {
        vm.deal(user1, 1 ether);

        vm.prank(user1);
        vm.expectRevert();
        payable(address(vault)).transfer(1 ether);
    }

    function test_NoNative_FunctionsDoNotAcceptValue() public {
        vm.deal(tss, 1 ether);

        vm.prank(tss);
        (bool success,) = address(vault).call{ value: 1 ether }(
            abi.encodeWithSelector(vault.withdraw.selector, txID, user1, address(token), user1, 100e18)
        );
        assertFalse(success);
    }

    // ============================================================================
    // GATEWAY POINTER CHANGES TESTS
    // ============================================================================

    function test_GatewayChange_LiveSupport() public {
        assertTrue(gateway.isSupportedToken(address(token)));

        vm.prank(tss);
        vault.withdraw(txID, user1, address(token), user1, 100e18);
        assertEq(token.balanceOf(user1), 100e18);

        // Create new gateway that doesn't support token
        UniversalGateway newGatewayImpl = new UniversalGateway();
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector, admin, tss, address(this), 1e18, 10e18, address(0), address(0), weth
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newGatewayImpl), initData);
        UniversalGateway newGateway = UniversalGateway(payable(address(newProxy)));

        vm.prank(admin);
        vault.setGateway(address(newGateway));

        vm.prank(tss);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.withdraw(txID, user1, address(token), user2, 100e18);
    }

    function test_GatewayChange_ReenableSupport() public {
        // Create new gateway without support
        UniversalGateway newGatewayImpl = new UniversalGateway();
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector, admin, tss, address(vault), 1e18, 10e18, address(0), address(0), weth
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newGatewayImpl), initData);
        UniversalGateway newGateway = UniversalGateway(payable(address(newProxy)));

        vm.prank(admin);
        vault.setGateway(address(newGateway));

        vm.prank(tss);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.withdraw(bytes32(uint256(100)), user1, address(token), user1, 100e18);

        // Re-enable support in new gateway
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 1_000_000e18;

        vm.prank(admin);
        newGateway.setTokenLimitThresholds(tokens, thresholds);

        vm.prank(tss);
        vault.withdraw(bytes32(uint256(101)), user1, address(token), user1, 100e18);
        assertEq(token.balanceOf(user1), 100e18);
    }

    // ============================================================================
    // EVENTS CORRECTNESS TESTS
    // ============================================================================

    function test_Events_GatewayUpdated() public {
        UniversalGateway newGatewayImpl = new UniversalGateway();
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector, admin, tss, address(this), 1e18, 10e18, address(0), address(0), weth
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newGatewayImpl), initData);
        UniversalGateway newGateway = UniversalGateway(payable(address(newProxy)));

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit GatewayUpdated(address(gateway), address(newGateway));
        vault.setGateway(address(newGateway));
    }

    function test_Events_TSSUpdated() public {
        address newTSS = makeAddr("newTSS");

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit TSSUpdated(tss, newTSS);
        vault.setTSS(newTSS);
    }

    function test_Events_VaultWithdraw() public {
        uint256 amount = 1000e18;

        vm.prank(tss);
        vm.expectEmit(true, true, true, true);
        emit VaultWithdraw(txID, user1, address(token), user1, amount);
        vault.withdraw(txID, user1, address(token), user1, amount);
    }

    function test_Events_VaultRefund() public {
        uint256 amount = 1000e18;

        RevertInstructions memory revertInstr = RevertInstructions(user1, "");

        vm.prank(tss);
        vm.expectEmit(true, true, false, true);
        emit VaultRevert(address(token), user1, amount, revertInstr);
        vault.revertWithdraw(bytes32(uint256(5)), address(token), user1, amount, revertInstr);
    }

    function test_Events_InitializationEvents() public {
        Vault newImpl = new Vault();

        // Note: Vault.initialize does not emit GatewayUpdated or TSSUpdated events
        // These events are only emitted when setGateway() or setTSS() are called by admin
        // Initialization just sets the values directly without emitting events
        bytes memory initData = abi.encodeWithSelector(Vault.initialize.selector, admin, pauser, tss, address(gateway), address(ceaFactory));
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newImpl), initData);
        Vault newVault = Vault(address(newProxy));
        
        // Verify initialization succeeded by checking state
        assertEq(address(newVault.gateway()), address(gateway));
        assertEq(newVault.TSS_ADDRESS(), tss);
    }

    // ============================================================================
    // NEW OUTBOUND EXECUTION TESTS (CEA-ONLY PATHS)
    // ============================================================================

    function test_HandleOutboundExecution_Native_Success() public {
        uint256 amount = 1 ether;
        bytes memory callData = abi.encodeWithSignature("receiveFunds()");
        bytes32 testTxID = bytes32(uint256(300));
        address ueaAddr = user1;

        uint256 initialTargetBalance = address(mockTarget).balance;

        // TSS calls handleOutboundExecution with native tokens (CEA is only path)
        vm.deal(tss, amount);
        vm.prank(tss);
        vault.handleOutboundExecution{value: amount}(
            testTxID,
            ueaAddr,
            address(0), // native token
            address(mockTarget),
            amount,
            callData
        );

        // Verify CEA was deployed and target received ETH from CEA
        (address cea, bool isDeployed) = ceaFactory.getCEAForUEA(ueaAddr);
        assertTrue(isDeployed);
        assertEq(address(mockTarget).balance, initialTargetBalance + amount);
        assertEq(mockTarget.lastCaller(), cea);
        assertEq(mockTarget.lastAmount(), amount);
    }

    function test_HandleOutboundExecution_Native_EmitsEvent() public {
        uint256 amount = 1 ether;
        bytes memory callData = abi.encodeWithSignature("receiveFunds()");
        bytes32 testTxID = bytes32(uint256(301));
        address ueaAddr = user1;

        vm.deal(tss, amount);
        vm.prank(tss);
        vm.expectEmit(true, true, false, true);
        emit VaultWithdrawAndExecute(address(0), address(mockTarget), amount, callData);
        vault.handleOutboundExecution{value: amount}(
            testTxID,
            ueaAddr,
            address(0),
            address(mockTarget),
            amount,
            callData
        );
    }

    function test_HandleOutboundExecution_Native_InvalidValueReverts() public {
        uint256 amount = 1 ether;
        bytes memory callData = "";
        bytes32 testTxID = bytes32(uint256(302));
        address ueaAddr = user1;

        // Send wrong amount of ETH
        vm.deal(tss, amount);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.handleOutboundExecution{value: amount / 2}(
            testTxID,
            ueaAddr,
            address(0),
            address(mockTarget),
            amount,
            callData
        );
    }

    function test_HandleOutboundExecution_NativeViaCEA_Success() public {
        uint256 amount = 1 ether;
        bytes memory callData = abi.encodeWithSignature("receiveFunds()");
        bytes32 testTxID = bytes32(uint256(303));
        address ueaAddr = user1;

        uint256 initialTargetBalance = address(mockTarget).balance;

        // TSS calls handleOutboundExecution with native tokens (CEA is only path)
        vm.deal(tss, amount);
        vm.prank(tss);
        vault.handleOutboundExecution{value: amount}(
            testTxID,
            ueaAddr,
            address(0), // native token
            address(mockTarget),
            amount,
            callData
        );

        // Verify CEA was deployed
        (address cea, bool isDeployed) = ceaFactory.getCEAForUEA(ueaAddr);
        assertTrue(isDeployed);
        assertTrue(cea != address(0));

        // Verify target received ETH from CEA
        assertEq(address(mockTarget).balance, initialTargetBalance + amount);
        assertEq(mockTarget.lastCaller(), cea);
        assertEq(mockTarget.lastAmount(), amount);

        // Verify MockCEA tracked the call
        MockCEA mockCEA = ceaFactory.getMockCEA(cea);
        assertEq(mockCEA.lastTxID(), testTxID);
        assertEq(mockCEA.lastUEA(), ueaAddr);
        assertEq(mockCEA.lastTarget(), address(mockTarget));
        assertEq(mockCEA.lastAmount(), amount);
    }

    function test_HandleOutboundExecution_NativeViaCEA_DeploysCEA() public {
        uint256 amount = 1 ether;
        bytes memory callData = "";
        bytes32 testTxID = bytes32(uint256(304));
        address ueaAddr = user2;

        // Verify CEA doesn't exist yet
        (, bool deployedBefore) = ceaFactory.getCEAForUEA(ueaAddr);
        assertFalse(deployedBefore);

        vm.deal(tss, amount);
        vm.prank(tss);
        vault.handleOutboundExecution{value: amount}(
            testTxID,
            ueaAddr,
            address(0),
            address(mockTarget),
            amount,
            callData
        );

        // Verify CEA was deployed
        (address ceaAfter, bool deployedAfter) = ceaFactory.getCEAForUEA(ueaAddr);
        assertTrue(deployedAfter);
        assertTrue(ceaAfter != address(0));
        assertEq(ceaFactory.UEA_to_CEA(ueaAddr), ceaAfter);
        assertEq(ceaFactory.CEA_to_UEA(ceaAfter), ueaAddr);
    }

    function test_HandleOutboundExecution_NativeViaCEA_ReusesExistingCEA() public {
        uint256 amount = 1 ether;
        bytes memory callData = "";
        bytes32 testTxID1 = bytes32(uint256(305));
        bytes32 testTxID2 = bytes32(uint256(306));
        address ueaAddr = user1;

        // First call - deploys CEA
        vm.deal(tss, amount * 2);
        vm.prank(tss);
        vault.handleOutboundExecution{value: amount}(
            testTxID1,
            ueaAddr,
            address(0),
            address(mockTarget),
            amount,
            callData
        );

        (address cea1, bool deployed1) = ceaFactory.getCEAForUEA(ueaAddr);
        assertTrue(deployed1);

        // Second call - reuses existing CEA
        vm.prank(tss);
        vault.handleOutboundExecution{value: amount}(
            testTxID2,
            ueaAddr,
            address(0),
            address(mockTarget),
            amount,
            callData
        );

        (address cea2, bool deployed2) = ceaFactory.getCEAForUEA(ueaAddr);
        assertTrue(deployed2);
        assertEq(cea1, cea2); // Same CEA address
    }

    function test_HandleOutboundExecution_ERC20ViaCEA_Success() public {
        uint256 amount = 100e18;
        bytes memory callData = abi.encodeWithSignature("receiveToken(address,uint256)", address(token), amount);
        bytes32 testTxID = bytes32(uint256(307));
        address ueaAddr = user1;

        uint256 initialVaultBalance = token.balanceOf(address(vault));
        uint256 initialTargetBalance = token.balanceOf(address(mockTarget));

        // TSS calls handleOutboundExecution with ERC20 tokens (CEA is only path)
        vm.prank(tss);
        vault.handleOutboundExecution(
            testTxID,
            ueaAddr,
            address(token),
            address(mockTarget),
            amount,
            callData
        );

        // Verify CEA was deployed
        (address cea, bool isDeployed) = ceaFactory.getCEAForUEA(ueaAddr);
        assertTrue(isDeployed);

        // Verify tokens were transferred from Vault to CEA
        assertEq(token.balanceOf(address(vault)), initialVaultBalance - amount);
        assertEq(token.balanceOf(cea), 0); // CEA should have transferred tokens to target

        // Verify target received tokens
        assertEq(token.balanceOf(address(mockTarget)), initialTargetBalance + amount);
        assertEq(mockTarget.lastCaller(), cea);
        assertEq(mockTarget.lastToken(), address(token));
        assertEq(mockTarget.lastTokenAmount(), amount);

        // Verify MockCEA tracked the call
        MockCEA mockCEA = ceaFactory.getMockCEA(cea);
        assertEq(mockCEA.lastTxID(), testTxID);
        assertEq(mockCEA.lastUEA(), ueaAddr);
        assertEq(mockCEA.lastToken(), address(token));
        assertEq(mockCEA.lastTarget(), address(mockTarget));
        assertEq(mockCEA.lastAmount(), amount);
    }

    function test_HandleOutboundExecution_ERC20ViaCEA_EmitsEvent() public {
        uint256 amount = 100e18;
        bytes memory callData = abi.encodeWithSignature("receiveToken(address,uint256)", address(token), amount);
        bytes32 testTxID = bytes32(uint256(308));
        address ueaAddr = user1;

        vm.prank(tss);
        vm.expectEmit(true, true, false, true);
        emit VaultWithdrawAndExecute(address(token), address(mockTarget), amount, callData);
        vault.handleOutboundExecution(
            testTxID,
            ueaAddr,
            address(token),
            address(mockTarget),
            amount,
            callData
        );
    }

    function test_HandleOutboundExecution_ERC20ViaCEA_WithValueReverts() public {
        uint256 amount = 100e18;
        bytes memory callData = "";
        bytes32 testTxID = bytes32(uint256(309));
        address ueaAddr = user1;

        // ERC20 path should not accept msg.value
        vm.deal(tss, 1 ether);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.handleOutboundExecution{value: 1 ether}(
            testTxID,
            ueaAddr,
            address(token),
            address(mockTarget),
            amount,
            callData
        );
    }

    function test_HandleOutboundExecution_ERC20ViaCEA_InsufficientBalanceReverts() public {
        uint256 vaultBalance = token.balanceOf(address(vault));
        uint256 amount = vaultBalance + 1;
        bytes memory callData = "";
        bytes32 testTxID = bytes32(uint256(310));
        address ueaAddr = user1;

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.handleOutboundExecution(
            testTxID,
            ueaAddr,
            address(token),
            address(mockTarget),
            amount,
            callData
        );
    }

    function test_HandleOutboundExecution_ERC20ViaCEA_DifferentTokens() public {
        uint256 amount1 = 50e18;
        uint256 amount2 = 25e6;
        bytes memory callData1 = abi.encodeWithSignature("receiveToken(address,uint256)", address(token), amount1);
        bytes memory callData2 = abi.encodeWithSignature("receiveToken(address,uint256)", address(token2), amount2);
        bytes32 testTxID1 = bytes32(uint256(311));
        bytes32 testTxID2 = bytes32(uint256(312));
        address ueaAddr = user1;

        // First call with token
        vm.prank(tss);
        vault.handleOutboundExecution(
            testTxID1,
            ueaAddr,
            address(token),
            address(mockTarget),
            amount1,
            callData1
        );

        // Second call with token2
        vm.prank(tss);
        vault.handleOutboundExecution(
            testTxID2,
            ueaAddr,
            address(token2),
            address(mockTarget),
            amount2,
            callData2
        );

        // Verify both calls used the same CEA
        (address cea1, ) = ceaFactory.getCEAForUEA(ueaAddr);
        (address cea2, ) = ceaFactory.getCEAForUEA(ueaAddr);
        assertEq(cea1, cea2);

        // Verify both tokens were received
        assertEq(token.balanceOf(address(mockTarget)), amount1);
        assertEq(token2.balanceOf(address(mockTarget)), amount2);
    }
}
