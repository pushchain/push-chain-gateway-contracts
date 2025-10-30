// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {VaultPC} from "../../src/VaultPC.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MockPRC20} from "../mocks/MockPRC20.sol";
import {MockUniversalCoreReal} from "../mocks/MockUniversalCoreReal.sol";
import {MockReentrantContract} from "../mocks/MockReentrantContract.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VaultPCTest is Test {
    VaultPC public vault;
    VaultPC public vaultImpl;
    MockUniversalCoreReal public universalCore;
    MockPRC20 public prc20Token;
    MockPRC20 public prc20Token2;
    MockReentrantContract public reentrantAttacker;

    address public admin;
    address public pauser;
    address public fundManager;
    address public uem;
    address public user1;
    address public user2;

    // Events
    event GatewayPCUpdated(address indexed oldGatewayPC, address indexed newGatewayPC);

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        fundManager = makeAddr("fundManager");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        uem = makeAddr("uem");

        // Deploy UniversalCore mock
        universalCore = new MockUniversalCoreReal(uem);

        // Deploy VaultPC implementation and proxy
        vaultImpl = new VaultPC();
        bytes memory vaultInitData = abi.encodeWithSelector(
            VaultPC.initialize.selector,
            admin,
            pauser,
            fundManager,
            address(universalCore)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = VaultPC(address(vaultProxy));

        // Deploy PRC20 tokens
        prc20Token = new MockPRC20(
            "Push Ethereum",
            "pETH",
            18,
            "1",
            MockPRC20.TokenType.NATIVE,
            100e18, // protocol fee
            address(universalCore),
            "0x0000000000000000000000000000000000000000"
        );
        
        prc20Token2 = new MockPRC20(
            "Push BNB",
            "pBNB",
            18,
            "56",
            MockPRC20.TokenType.NATIVE,
            50e18, // protocol fee
            address(universalCore),
            "0x0000000000000000000000000000000000000000"
        );

        // Setup token support in UniversalCore
        universalCore.setSupportedToken(address(prc20Token), true);
        universalCore.setSupportedToken(address(prc20Token2), true);

        // Deploy reentrant attacker
        reentrantAttacker = new MockReentrantContract(address(0), address(0), address(0));
        reentrantAttacker.setVaultPC(address(vault));

        // Fund vault with tokens
        prc20Token.mint(address(vault), 100_000e18);
        prc20Token2.mint(address(vault), 100_000e18);
    }

    // ============================================================================
    // INITIALIZATION TESTS
    // ============================================================================

    function test_Initialization_RolesAssigned() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), pauser));
        assertTrue(vault.hasRole(vault.FUND_MANAGER_ROLE(), fundManager));
    }

    function test_Initialization_UniversalCoreSet() public view {
        assertEq(vault.UNIVERSAL_CORE(), address(universalCore));
    }

    function test_Initialization_StartsUnpaused() public view {
        assertFalse(vault.paused());
    }

    function test_Initialization_RevertsOnZeroAdmin() public {
        VaultPC newImpl = new VaultPC();
        bytes memory initData = abi.encodeWithSelector(
            VaultPC.initialize.selector,
            address(0),
            pauser,
            fundManager,
            address(universalCore)
        );
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialization_RevertsOnZeroPauser() public {
        VaultPC newImpl = new VaultPC();
        bytes memory initData = abi.encodeWithSelector(
            VaultPC.initialize.selector,
            admin,
            address(0),
            fundManager,
            address(universalCore)
        );
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialization_RevertsOnZeroFundManager() public {
        VaultPC newImpl = new VaultPC();
        bytes memory initData = abi.encodeWithSelector(
            VaultPC.initialize.selector,
            admin,
            pauser,
            address(0),
            address(universalCore)
        );
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialization_RevertsOnZeroUniversalCore() public {
        VaultPC newImpl = new VaultPC();
        bytes memory initData = abi.encodeWithSelector(
            VaultPC.initialize.selector,
            admin,
            pauser,
            fundManager,
            address(0)
        );
        vm.expectRevert(Errors.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ============================================================================
    // ACCESS CONTROL TESTS
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

    function test_UpdateUniversalCore_OnlyAdminCanUpdate() public {
        MockUniversalCoreReal newCore = new MockUniversalCoreReal(uem);
        
        vm.prank(admin);
        vault.updateUniversalCore(address(newCore));
        assertEq(vault.UNIVERSAL_CORE(), address(newCore));
    }

    function test_UpdateUniversalCore_NonAdminReverts() public {
        MockUniversalCoreReal newCore = new MockUniversalCoreReal(uem);
        
        vm.prank(user1);
        vm.expectRevert();
        vault.updateUniversalCore(address(newCore));
    }

    function test_UpdateUniversalCore_ZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.updateUniversalCore(address(0));
    }

    function test_Withdraw_OnlyFundManagerCanCall() public {
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token), user1, 100e18);
        assertEq(prc20Token.balanceOf(user1), 100e18);
    }

    function test_Withdraw_NonFundManagerReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.withdraw(address(prc20Token), user1, 100e18);
    }

    function test_Sweep_OnlyFundManagerCanCall() public {
        vm.prank(fundManager);
        vault.sweep(address(prc20Token), user1, 100e18);
        assertEq(prc20Token.balanceOf(user1), 100e18);
    }

    function test_Sweep_NonFundManagerReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.sweep(address(prc20Token), user1, 100e18);
    }

    // ============================================================================
    // PAUSE GATING TESTS
    // ============================================================================

    function test_Pause_BlocksWithdraw() public {
        vm.prank(pauser);
        vault.pause();
        
        vm.prank(fundManager);
        vm.expectRevert();
        vault.withdraw(address(prc20Token), user1, 100e18);
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
        
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token), user1, 100e18);
        assertEq(prc20Token.balanceOf(user1), 100e18);
    }

    function test_UpdateUniversalCore_WorksWhenPaused() public {
        MockUniversalCoreReal newCore = new MockUniversalCoreReal(uem);
        
        vm.prank(pauser);
        vault.pause();
        
        vm.prank(admin);
        vault.updateUniversalCore(address(newCore));
        assertEq(vault.UNIVERSAL_CORE(), address(newCore));
    }

    // ============================================================================
    // TOKEN SUPPORT / UNIVERSALCORE GATING TESTS
    // ============================================================================

    function test_Withdraw_UnsupportedTokenReverts() public {
        MockPRC20 unsupportedToken = new MockPRC20(
            "Unsupported",
            "UNS",
            18,
            "999",
            MockPRC20.TokenType.NATIVE,
            10e18,
            address(universalCore),
            "0x0000000000000000000000000000000000000000"
        );
        unsupportedToken.mint(address(vault), 100e18);
        
        vm.prank(fundManager);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.withdraw(address(unsupportedToken), user1, 100e18);
    }

    function test_TokenSupport_TogglingReflectsImmediately() public {
        // Initially supported
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token), user1, 100e18);
        assertEq(prc20Token.balanceOf(user1), 100e18);
        
        // Remove support in UniversalCore
        universalCore.setSupportedToken(address(prc20Token), false);
        
        vm.prank(fundManager);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.withdraw(address(prc20Token), user2, 100e18);
        
        // Re-add support
        universalCore.setSupportedToken(address(prc20Token), true);
        
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token), user2, 100e18);
        assertEq(prc20Token.balanceOf(user2), 100e18);
    }

    function test_UniversalCoreChange_LiveSupport() public {
        // Create new UniversalCore without token support
        MockUniversalCoreReal newCore = new MockUniversalCoreReal(uem);
        
        vm.prank(admin);
        vault.updateUniversalCore(address(newCore));
        
        vm.prank(fundManager);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.withdraw(address(prc20Token), user1, 100e18);
        
        // Add support in new core
        newCore.setSupportedToken(address(prc20Token), true);
        
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token), user1, 100e18);
        assertEq(prc20Token.balanceOf(user1), 100e18);
    }

    // ============================================================================
    // WITHDRAW TESTS
    // ============================================================================

    function test_Withdraw_StandardToken_Success() public {
        uint256 amount = 1000e18;
        
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token), user1, amount);
        
        assertEq(prc20Token.balanceOf(user1), amount);
    }

    function test_Withdraw_ZeroAmountReverts() public {
        vm.prank(fundManager);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.withdraw(address(prc20Token), user1, 0);
    }

    function test_Withdraw_ZeroRecipientReverts() public {
        vm.prank(fundManager);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.withdraw(address(prc20Token), address(0), 100e18);
    }

    function test_Withdraw_ZeroTokenAddressReverts() public {
        // Token support is checked first, so we expect NotSupported for address(0)
        vm.prank(fundManager);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.withdraw(address(0), user1, 100e18);
    }

    function test_Withdraw_InsufficientBalanceReverts() public {
        uint256 vaultBalance = prc20Token.balanceOf(address(vault));
        
        vm.prank(fundManager);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.withdraw(address(prc20Token), user1, vaultBalance + 1);
    }

    function test_Withdraw_MultipleRecipients() public {
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token), user1, 100e18);
        
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token), user2, 200e18);
        
        assertEq(prc20Token.balanceOf(user1), 100e18);
        assertEq(prc20Token.balanceOf(user2), 200e18);
    }

    function test_Withdraw_DifferentTokens() public {
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token), user1, 100e18);
        
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token2), user1, 50e18);
        
        assertEq(prc20Token.balanceOf(user1), 100e18);
        assertEq(prc20Token2.balanceOf(user1), 50e18);
    }

    function test_Withdraw_SequentialCalls_Success() public {
        // Multiple sequential withdrawals should work fine
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token), user1, 100e18);
        
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token), user1, 200e18);
        
        assertEq(prc20Token.balanceOf(user1), 300e18);
    }

    // ============================================================================
    // SWEEP TESTS
    // ============================================================================

    function test_Sweep_StandardToken_Success() public {
        uint256 amount = 500e18;
        
        vm.prank(fundManager);
        vault.sweep(address(prc20Token), user1, amount);
        
        assertEq(prc20Token.balanceOf(user1), amount);
    }

    function test_Sweep_ZeroTokenReverts() public {
        vm.prank(fundManager);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.sweep(address(0), user1, 100e18);
    }

    function test_Sweep_ZeroRecipientReverts() public {
        vm.prank(fundManager);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.sweep(address(prc20Token), address(0), 100e18);
    }

    function test_Sweep_UnsupportedToken_NoRevert() public {
        // Sweep should work even for unsupported tokens (emergency recovery)
        MockPRC20 unsupportedToken = new MockPRC20(
            "Unsupported",
            "UNS",
            18,
            "999",
            MockPRC20.TokenType.NATIVE,
            10e18,
            address(universalCore),
            "0x0000000000000000000000000000000000000000"
        );
        unsupportedToken.mint(address(vault), 100e18);
        
        vm.prank(fundManager);
        vault.sweep(address(unsupportedToken), user1, 100e18);
        assertEq(unsupportedToken.balanceOf(user1), 100e18);
    }

    function test_Sweep_WorksWhenPaused() public {
        vm.prank(pauser);
        vault.pause();
        
        // Sweep should work even when paused (emergency recovery)
        vm.prank(fundManager);
        vault.sweep(address(prc20Token), user1, 100e18);
        assertEq(prc20Token.balanceOf(user1), 100e18);
    }

    // ============================================================================
    // EDGE CASES AND INTEGRATION TESTS
    // ============================================================================

    function test_MultipleWithdrawals_ReducesBalance() public {
        uint256 initialBalance = prc20Token.balanceOf(address(vault));
        
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token), user1, 100e18);
        
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token), user2, 200e18);
        
        uint256 finalBalance = prc20Token.balanceOf(address(vault));
        assertEq(finalBalance, initialBalance - 300e18);
    }

    function test_Withdraw_ExactBalance_Success() public {
        uint256 vaultBalance = prc20Token.balanceOf(address(vault));
        
        vm.prank(fundManager);
        vault.withdraw(address(prc20Token), user1, vaultBalance);
        
        assertEq(prc20Token.balanceOf(user1), vaultBalance);
        assertEq(prc20Token.balanceOf(address(vault)), 0);
    }

    function test_UpdateUniversalCore_AffectsTokenSupport() public {
        MockUniversalCoreReal newCore = new MockUniversalCoreReal(uem);
        // Don't configure any token support in new core
        
        vm.prank(admin);
        vault.updateUniversalCore(address(newCore));
        
        // Should now fail because new core doesn't support the token
        vm.prank(fundManager);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.withdraw(address(prc20Token), user1, 100e18);
    }

    function test_Pause_DoesNotAffectUpdateUniversalCore() public {
        MockUniversalCoreReal newCore = new MockUniversalCoreReal(uem);
        
        vm.prank(pauser);
        vault.pause();
        
        vm.prank(admin);
        vault.updateUniversalCore(address(newCore));
        assertEq(vault.UNIVERSAL_CORE(), address(newCore));
    }

    function test_Pause_DoesNotAffectSweep() public {
        vm.prank(pauser);
        vault.pause();
        
        vm.prank(fundManager);
        vault.sweep(address(prc20Token), user1, 100e18);
        assertEq(prc20Token.balanceOf(user1), 100e18);
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

    function test_NoNative_FunctionsDoNotAcceptValue() public {
        vm.deal(fundManager, 1 ether);
        
        vm.prank(fundManager);
        (bool success,) = address(vault).call{value: 1 ether}(
            abi.encodeWithSelector(vault.withdraw.selector, address(prc20Token), user1, 100e18)
        );
        assertFalse(success);
    }
}

