// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Vault} from "../../src/Vault.sol";
import {UniversalGateway} from "../../src/UniversalGateway.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockTokenApprovalVariants} from "../mocks/MockTokenApprovalVariants.sol";
import {MockTarget} from "../mocks/MockTarget.sol";
import {MockRevertingTarget} from "../mocks/MockRevertingTarget.sol";
import {MockReentrantContract} from "../mocks/MockReentrantContract.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

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

    address public admin;
    address public pauser;
    address public tss;
    address public user1;
    address public user2;
    address public weth;

    // Events
    event GatewayUpdated(address indexed oldGateway, address indexed newGateway);
    event TSSUpdated(address indexed oldTss, address indexed newTss);
    event VaultWithdraw(address indexed token, address indexed to, uint256 amount);
    event VaultRefund(address indexed token, address indexed to, uint256 amount);

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
            pauser,
            tss,
            1e18,  // minCapUsd
            10e18, // maxCapUsd
            address(0), // factory (not needed for Vault tests)
            address(0), // router (not needed for Vault tests)
            weth
        );
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), gatewayInitData);
        gateway = UniversalGateway(payable(address(gatewayProxy)));

        // Deploy Vault implementation and proxy
        vaultImpl = new Vault();
        bytes memory vaultInitData = abi.encodeWithSelector(
            Vault.initialize.selector,
            admin,
            pauser,
            tss,
            address(gateway)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = Vault(address(vaultProxy));

        // Deploy tokens
        token = new MockERC20("Test Token", "TST", 18, 1_000_000e18);
        token2 = new MockERC20("Test Token 2", "TST2", 6, 1_000_000e6);
        variantToken = new MockTokenApprovalVariants();

        // Deploy helper contracts
        mockRevertingTarget = new MockRevertingTarget();
        reentrantAttacker = new MockReentrantContract(address(0), address(0), address(0));
        reentrantAttacker.setVault(address(vault));
        mockTarget = new MockTarget();

        // Setup: support tokens in gateway
        address[] memory tokens = new address[](3);
        tokens[0] = address(token);
        tokens[1] = address(token2);
        tokens[2] = address(variantToken);
        
        uint256[] memory thresholds = new uint256[](3);
        thresholds[0] = 1_000_000e18;
        thresholds[1] = 1_000_000e6;
        thresholds[2] = 1_000_000e18;
        
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
        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            address(0),
            pauser,
            tss,
            address(gateway)
        );
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialization_RevertsOnZeroPauser() public {
        Vault newImpl = new Vault();
        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            admin,
            address(0),
            tss,
            address(gateway)
        );
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialization_RevertsOnZeroTSS() public {
        Vault newImpl = new Vault();
        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            admin,
            pauser,
            address(0),
            address(gateway)
        );
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialization_RevertsOnZeroGateway() public {
        Vault newImpl = new Vault();
        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            admin,
            pauser,
            tss,
            address(0)
        );
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
            UniversalGateway.initialize.selector,
            admin, pauser, tss, 1e18, 10e18, address(0), address(0), weth
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
            UniversalGateway.initialize.selector,
            admin, pauser, tss, 1e18, 10e18, address(0), address(0), weth
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
        vault.withdraw(address(token), user1, 100e18);
    }

    function test_SetTSS_NewTSSCanCallFunctions() public {
        address newTSS = makeAddr("newTSS");
        
        vm.prank(admin);
        vault.setTSS(newTSS);
        
        vm.prank(newTSS);
        vault.withdraw(address(token), user1, 100e18);
        assertEq(token.balanceOf(user1), 100e18);
    }

    function test_SetTSS_EmitsEvent() public {
        address newTSS = makeAddr("newTSS");
        
        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit TSSUpdated(tss, newTSS);
        vault.setTSS(newTSS);
    }

    function test_SetTSS_RevertsWhenPaused() public {
        address newTSS = makeAddr("newTSS");
        
        vm.prank(pauser);
        vault.pause();
        
        vm.prank(admin);
        vm.expectRevert();
        vault.setTSS(newTSS);
    }

    function test_Withdraw_OnlyTSSCanCall() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(address(token), user1, 100e18);
    }

    function test_RevertWithdraw_OnlyTSSCanCall() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.revertWithdraw(address(token), user1, 100e18);
    }

    // ============================================================================
    // PAUSE GATING TESTS
    // ============================================================================

    function test_Pause_BlocksWithdraw() public {
        vm.prank(pauser);
        vault.pause();
        
        vm.prank(tss);
        vm.expectRevert();
        vault.withdraw(address(token), user1, 100e18);
    }

    function test_Pause_BlocksRevertWithdraw() public {
        vm.prank(pauser);
        vault.pause();
        
        vm.prank(tss);
        vm.expectRevert();
        vault.revertWithdraw(address(token), user1, 100e18);
    }

    function test_Pause_AllowsSetGateway() public {
        vm.prank(pauser);
        vault.pause();
        
        UniversalGateway newGatewayImpl = new UniversalGateway();
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin, pauser, tss, 1e18, 10e18, address(0), address(0), weth
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
        vault.withdraw(address(token), user1, 100e18);
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
        vault.withdraw(address(unsupportedToken), user1, 100e18);
    }

    function test_RevertWithdraw_UnsupportedTokenReverts() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS", 18, 1000e18);
        unsupportedToken.mint(address(vault), 100e18);
        
        vm.prank(tss);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.revertWithdraw(address(unsupportedToken), user1, 100e18);
    }

    function test_TokenSupport_TogglingReflectsImmediately() public {
        // Initially supported
        vm.prank(tss);
        vault.withdraw(address(token), user1, 100e18);
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
        vault.withdraw(address(token), user2, 100e18);
        
        // Re-add support
        thresholds[0] = 1_000_000e18;
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);
        
        vm.prank(tss);
        vault.withdraw(address(token), user2, 100e18);
        assertEq(token.balanceOf(user2), 100e18);
    }

    function test_Withdraw_ZeroTokenAddressReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.withdraw(address(0), user1, 100e18);
    }

    function test_RevertWithdraw_ZeroTokenAddressReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.revertWithdraw(address(0), user1, 100e18);
    }

    // ============================================================================
    // WITHDRAW (SIMPLE TRANSFER) TESTS
    // ============================================================================

    function test_Withdraw_StandardToken_Success() public {
        uint256 amount = 1000e18;
        
        vm.prank(tss);
        vault.withdraw(address(token), user1, amount);
        
        assertEq(token.balanceOf(user1), amount);
    }

    function test_Withdraw_EmitsEvent() public {
        uint256 amount = 1000e18;
        
        vm.prank(tss);
        vm.expectEmit(true, true, false, true);
        emit VaultWithdraw(address(token), user1, amount);
        vault.withdraw(address(token), user1, amount);
    }

    function test_Withdraw_ZeroAmountReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.withdraw(address(token), user1, 0);
    }

    function test_Withdraw_ZeroRecipientReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.withdraw(address(token), address(0), 100e18);
    }

    function test_Withdraw_InsufficientBalanceReverts() public {
        uint256 vaultBalance = token.balanceOf(address(vault));
        
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.withdraw(address(token), user1, vaultBalance + 1);
    }

    function test_Withdraw_MultipleRecipients() public {
        vm.prank(tss);
        vault.withdraw(address(token), user1, 100e18);
        
        vm.prank(tss);
        vault.withdraw(address(token), user2, 200e18);
        
        assertEq(token.balanceOf(user1), 100e18);
        assertEq(token.balanceOf(user2), 200e18);
    }

    function test_Withdraw_DifferentTokens() public {
        vm.prank(tss);
        vault.withdraw(address(token), user1, 100e18);
        
        vm.prank(tss);
        vault.withdraw(address(token2), user1, 50e6);
        
        assertEq(token.balanceOf(user1), 100e18);
        assertEq(token2.balanceOf(user1), 50e6);
    }

    // ============================================================================
    // REVERTWITHDRAW TESTS
    // ============================================================================

    function test_RevertWithdraw_StandardToken_Success() public {
        uint256 amount = 1000e18;
        
        vm.prank(tss);
        vault.revertWithdraw(address(token), user1, amount);
        
        assertEq(token.balanceOf(user1), amount);
    }

    function test_RevertWithdraw_EmitsEvent() public {
        uint256 amount = 1000e18;
        
        vm.prank(tss);
        vm.expectEmit(true, true, false, true);
        emit VaultRefund(address(token), user1, amount);
        vault.revertWithdraw(address(token), user1, amount);
    }

    function test_RevertWithdraw_ZeroAmountReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.revertWithdraw(address(token), user1, 0);
    }

    function test_RevertWithdraw_ZeroRecipientReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.revertWithdraw(address(token), address(0), 100e18);
    }

    function test_RevertWithdraw_InsufficientBalanceReverts() public {
        uint256 vaultBalance = token.balanceOf(address(vault));
        
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.revertWithdraw(address(token), user1, vaultBalance + 1);
    }

    function test_RevertWithdraw_WhenPausedReverts() public {
        vm.prank(pauser);
        vault.pause();
        
        vm.prank(tss);
        vm.expectRevert();
        vault.revertWithdraw(address(token), user1, 100e18);
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
        (bool success,) = address(vault).call{value: 1 ether}("");
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
        (bool success,) = address(vault).call{value: 1 ether}(
            abi.encodeWithSelector(vault.withdraw.selector, address(token), user1, 100e18)
        );
        assertFalse(success);
    }

    // ============================================================================
    // GATEWAY POINTER CHANGES TESTS
    // ============================================================================

    function test_GatewayChange_LiveSupport() public {
        assertTrue(gateway.isSupportedToken(address(token)));
        
        vm.prank(tss);
        vault.withdraw(address(token), user1, 100e18);
        assertEq(token.balanceOf(user1), 100e18);
        
        // Create new gateway that doesn't support token
        UniversalGateway newGatewayImpl = new UniversalGateway();
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin, pauser, tss, 1e18, 10e18, address(0), address(0), weth
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newGatewayImpl), initData);
        UniversalGateway newGateway = UniversalGateway(payable(address(newProxy)));
        
        vm.prank(admin);
        vault.setGateway(address(newGateway));
        
        vm.prank(tss);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.withdraw(address(token), user2, 100e18);
    }

    function test_GatewayChange_ReenableSupport() public {
        // Create new gateway without support
        UniversalGateway newGatewayImpl = new UniversalGateway();
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin, pauser, tss, 1e18, 10e18, address(0), address(0), weth
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newGatewayImpl), initData);
        UniversalGateway newGateway = UniversalGateway(payable(address(newProxy)));
        
        vm.prank(admin);
        vault.setGateway(address(newGateway));
        
        vm.prank(tss);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.withdraw(address(token), user1, 100e18);
        
        // Re-enable support in new gateway
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 1_000_000e18;
        
        vm.prank(admin);
        newGateway.setTokenLimitThresholds(tokens, thresholds);
        
        vm.prank(tss);
        vault.withdraw(address(token), user1, 100e18);
        assertEq(token.balanceOf(user1), 100e18);
    }

    // ============================================================================
    // EVENTS CORRECTNESS TESTS
    // ============================================================================

    function test_Events_GatewayUpdated() public {
        UniversalGateway newGatewayImpl = new UniversalGateway();
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin, pauser, tss, 1e18, 10e18, address(0), address(0), weth
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
        vm.expectEmit(true, true, false, true);
        emit VaultWithdraw(address(token), user1, amount);
        vault.withdraw(address(token), user1, amount);
    }

    function test_Events_VaultRefund() public {
        uint256 amount = 1000e18;
        
        vm.prank(tss);
        vm.expectEmit(true, true, false, true);
        emit VaultRefund(address(token), user1, amount);
        vault.revertWithdraw(address(token), user1, amount);
    }

    function test_Events_InitializationEvents() public {
        Vault newImpl = new Vault();
        
        vm.expectEmit(true, true, false, false);
        emit GatewayUpdated(address(0), address(gateway));
        
        vm.expectEmit(true, true, false, false);
        emit TSSUpdated(address(0), tss);
        
        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            admin,
            pauser,
            tss,
            address(gateway)
        );
        new ERC1967Proxy(address(newImpl), initData);
    }
}
