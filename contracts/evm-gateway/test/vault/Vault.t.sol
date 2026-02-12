// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import { Vault } from "../../src/Vault.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { RevertInstructions } from "../../src/libraries/Types.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockTokenApprovalVariants } from "../mocks/MockTokenApprovalVariants.sol";
import { MockTarget } from "../mocks/MockTarget.sol";
import { MockRevertingTarget } from "../mocks/MockRevertingTarget.sol";
import { MockReentrantContract } from "../mocks/MockReentrantContract.sol";
import { MockCEAFactory } from "../mocks/MockCEAFactory.sol";
import { MockCEA } from "../mocks/MockCEA.sol";
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
    event VaultUniversalTxExecuted(bytes32 indexed txID, bytes32 indexed universalTxID, address indexed originCaller, address target, address token, uint256 amount, bytes data);
    event VaultUniversalTxReverted(bytes32 indexed txID, bytes32 indexed universalTxID, address indexed token, uint256 amount, RevertInstructions revertInstruction);

    bytes32 txID = bytes32(uint256(1));

    function _tx(uint256 id) internal pure returns (bytes32) {
        return bytes32(id);
    }

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

        // Deploy CEAFactory
        ceaFactory = new MockCEAFactory();

        // Deploy Vault implementation and proxy
        vaultImpl = new Vault();
        bytes memory vaultInitData =
            abi.encodeWithSelector(Vault.initialize.selector, admin, pauser, tss, address(gateway), address(ceaFactory));
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInitData);
        vault = Vault(address(vaultProxy));

        // Set vault in CEAFactory
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

        // Setup: support tokens in gateway (including native)
        address[] memory tokens = new address[](4);
        tokens[0] = address(token);
        tokens[1] = address(token2);
        tokens[2] = address(variantToken);
        tokens[3] = address(0); // Native token support

        uint256[] memory thresholds = new uint256[](4);
        thresholds[0] = 1_000_000e18;
        thresholds[1] = 1_000_000e6;
        thresholds[2] = 1_000_000e18;
        thresholds[3] = 1_000_000 ether; // Native threshold

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Fund vault with tokens
        token.mint(address(vault), 100_000e18);
        token2.mint(address(vault), 100_000e6);
        variantToken.mint(address(vault), 100_000e18);
    }

    // ============================================================================
    // TEST HELPERS
    // ============================================================================

    function _getCEA(address uea) internal view returns (address, bool) {
        return ceaFactory.getCEAForUEA(uea);
    }

    function _getMockCEA(address ceaAddress) internal view returns (MockCEA) {
        return ceaFactory.getMockCEA(ceaAddress);
    }

    function _assertCEAParams(
        address ceaAddr,
        bytes32 expectedTxID,
        bytes32 expectedUniversalTxID,
        address expectedUEA,
        address expectedToken,
        address expectedTarget,
        uint256 expectedAmount,
        bytes memory expectedPayload
    ) internal view {
        MockCEA cea = _getMockCEA(ceaAddr);
        assertEq(cea.lastTxID(), expectedTxID);
        assertEq(cea.lastUniversalTxID(), expectedUniversalTxID);
        assertEq(cea.lastUEA(), expectedUEA);
        assertEq(cea.lastToken(), expectedToken);
        assertEq(cea.lastTarget(), expectedTarget);
        assertEq(cea.lastAmount(), expectedAmount);
        assertEq(cea.lastPayload(), expectedPayload);
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
        vault.executeUniversalTx(txID, bytes32(uint256(3000 + uint256(txID))), user1, address(token), user1, 100e18, bytes(""));
    }

    function test_SetTSS_NewTSSCanCallFunctions() public {
        address newTSS = makeAddr("newTSS");

        vm.prank(admin);
        vault.setTSS(newTSS);

        vm.prank(newTSS);
        vault.executeUniversalTx(txID, bytes32(uint256(3000 + uint256(txID))), user1, address(token), user1, 100e18, bytes(""));
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
        vault.executeUniversalTx(txID, bytes32(uint256(3000 + uint256(txID))), user1, address(token), user1, 100e18, bytes(""));
    }

    function test_RevertWithdraw_OnlyTSSCanCall() public {
        vm.prank(user1);
        vm.expectRevert();
        vault.revertUniversalTxToken(_tx(1), bytes32(uint256(3000 + 1)), address(token), 100e18, RevertInstructions(user1, ""));
    }

    // ============================================================================
    // PAUSE GATING TESTS
    // ============================================================================

    function test_Pause_BlocksWithdraw() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.executeUniversalTx(txID, bytes32(uint256(3000 + uint256(txID))), user1, address(token), user1, 100e18, bytes(""));
    }

    function test_Pause_BlocksRevertWithdraw() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.revertUniversalTxToken(_tx(1), bytes32(uint256(3000 + 1)), address(token), 100e18, RevertInstructions(user1, ""));
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
        vault.executeUniversalTx(txID, bytes32(uint256(3000 + uint256(txID))), user1, address(token), user1, 100e18, bytes(""));
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
        vault.executeUniversalTx(txID, bytes32(uint256(3000 + uint256(txID))), user1, address(unsupportedToken), user1, 100e18, bytes(""));
    }

    function test_RevertWithdraw_UnsupportedTokenReverts() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS", 18, 1000e18);
        unsupportedToken.mint(address(vault), 100e18);

        vm.prank(tss);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.revertUniversalTxToken(_tx(2), bytes32(uint256(3000 + 2)), address(unsupportedToken), 100e18, RevertInstructions(user1, ""));
    }

    function test_TokenSupport_TogglingReflectsImmediately() public {
        // Initially supported
        vm.prank(tss);
        vault.executeUniversalTx(_tx(1), bytes32(uint256(3000 + uint256(_tx(1)))), user1, address(token), user1, 100e18, bytes(""));
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
        vault.executeUniversalTx(_tx(2), bytes32(uint256(3000 + uint256(_tx(2)))), user2, address(token), user2, 100e18, bytes(""));

        // Re-add support
        thresholds[0] = 1_000_000e18;
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        vm.prank(tss);
        vault.executeUniversalTx(_tx(3), bytes32(uint256(3000 + uint256(_tx(3)))), user2, address(token), user2, 100e18, bytes(""));
        assertEq(token.balanceOf(user2), 100e18);
    }

    // NOTE: Removed test_Withdraw_ZeroTokenAddressReverts - address(0) is now valid (native token)
    // Unsupported token testing is already covered by test_Withdraw_UnsupportedTokenReverts at line 454

    function test_RevertWithdraw_ZeroTokenAddressReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.revertUniversalTxToken(_tx(3), bytes32(uint256(3000 + 3)), address(0), 100e18, RevertInstructions(user1, ""));
    }

    // ============================================================================
    // WITHDRAW (SIMPLE TRANSFER) TESTS
    // ============================================================================

    function test_Withdraw_StandardToken_Success() public {
        uint256 amount = 1000e18;

        vm.prank(tss);
        vault.executeUniversalTx(txID, bytes32(uint256(3000 + uint256(txID))), user1, address(token), user1, amount, bytes(""));

        assertEq(token.balanceOf(user1), amount);
    }

    function test_Withdraw_EmitsEvent() public {
        uint256 amount = 1000e18;

        vm.prank(tss);
        // Event VaultWithdraw was removed - test now verifies withdraw executes successfully
        vault.executeUniversalTx(txID, bytes32(uint256(3000 + uint256(txID))), user1, address(token), user1, amount, bytes(""));
        assertEq(token.balanceOf(user1), amount);
    }

    function test_Withdraw_ZeroAmountReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.executeUniversalTx(txID, bytes32(uint256(3000 + uint256(txID))), user1, address(token), user1, 0, bytes(""));
    }

    function test_Withdraw_ZeroRecipientReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.executeUniversalTx(txID, bytes32(uint256(3000 + uint256(txID))), user1, address(token), address(0), 100e18, bytes(""));
    }

    function test_Withdraw_InsufficientBalanceReverts() public {
        uint256 vaultBalance = token.balanceOf(address(vault));

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.executeUniversalTx(txID, bytes32(uint256(3000 + uint256(txID))), user1, address(token), user1, vaultBalance + 1, bytes(""));
    }

    function test_Withdraw_MultipleRecipients() public {
        vm.prank(tss);
        vault.executeUniversalTx(_tx(1), bytes32(uint256(3000 + uint256(_tx(1)))), user1, address(token), user1, 100e18, bytes(""));

        vm.prank(tss);
        vault.executeUniversalTx(_tx(2), bytes32(uint256(3000 + uint256(_tx(2)))), user2, address(token), user2, 200e18, bytes(""));

        assertEq(token.balanceOf(user1), 100e18);
        assertEq(token.balanceOf(user2), 200e18);
    }

    function test_Withdraw_DifferentTokens() public {
        vm.prank(tss);
        vault.executeUniversalTx(_tx(1), bytes32(uint256(3000 + uint256(_tx(1)))), user1, address(token), user1, 100e18, bytes(""));

        vm.prank(tss);
        vault.executeUniversalTx(_tx(2), bytes32(uint256(3000 + uint256(_tx(2)))), user1, address(token2), user1, 50e6, bytes(""));

        assertEq(token.balanceOf(user1), 100e18);
        assertEq(token2.balanceOf(user1), 50e6);
    }

    // ============================================================================
    // REVERTWITHDRAW TESTS
    // ============================================================================

    function test_RevertWithdraw_StandardToken_Success() public {
        uint256 amount = 1000e18;

        vm.prank(tss);
        vault.revertUniversalTxToken(_tx(4), bytes32(uint256(3000 + 4)), address(token), amount, RevertInstructions(user1, ""));

        assertEq(token.balanceOf(user1), amount);
    }

    function test_RevertWithdraw_EmitsEvent() public {
        uint256 amount = 1000e18;

        RevertInstructions memory revertInstr = RevertInstructions(user1, "test revert message");

        vm.expectEmit(true, true, true, true);
        emit VaultUniversalTxReverted(_tx(5), bytes32(uint256(3000 + 5)), address(token), amount, revertInstr);

        vm.prank(tss);
        vault.revertUniversalTxToken(_tx(5), bytes32(uint256(3000 + 5)), address(token), amount, revertInstr);

        assertEq(token.balanceOf(user1), amount);
    }

    function test_RevertWithdraw_ZeroAmountReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.revertUniversalTxToken(_tx(6), bytes32(uint256(3000 + 6)), address(token), 0, RevertInstructions(user1, ""));
    }

    function test_RevertWithdraw_ZeroRecipientReverts() public {
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vault.revertUniversalTxToken(_tx(7), bytes32(uint256(3000 + 7)), address(token), 100e18, RevertInstructions(address(0), ""));
    }

    function test_RevertWithdraw_InsufficientBalanceReverts() public {
        uint256 vaultBalance = token.balanceOf(address(vault));

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.revertUniversalTxToken(_tx(8), bytes32(uint256(3000 + 8)), address(token), vaultBalance + 1, RevertInstructions(user1, ""));
    }

    function test_RevertWithdraw_WhenPausedReverts() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.revertUniversalTxToken(_tx(1), bytes32(uint256(3000 + 1)), address(token), 100e18, RevertInstructions(user1, ""));
    }

    // ============================================================================
    // EXECUTEUNIVERSALTX TESTS (CEA Pattern)
    // ============================================================================

    // A. Setup & Infrastructure (2 tests)
    function test_ExecuteUniversalTx_Setup_CEAFactoryConfigured() public view {
        assertEq(address(vault.CEAFactory()), address(ceaFactory));
    }

    function test_ExecuteUniversalTx_Setup_MockCEAFactoryVaultSet() public view {
        assertEq(ceaFactory.VAULT(), address(vault));
    }

    // B. Access Control (3 tests)
    function test_ExecuteUniversalTx_OnlyTSSCanCall() public {
        bytes memory data = "";

        vm.prank(user1);
        vm.expectRevert();
        vault.executeUniversalTx(_tx(300), bytes32(uint256(3300)), user1, address(token), address(mockTarget), 100e18, data);
    }

    function test_ExecuteUniversalTx_ERC20_RevertsWhenPaused() public {
        vm.prank(pauser);
        vault.pause();

        bytes memory data = "";

        vm.prank(tss);
        vm.expectRevert();
        vault.executeUniversalTx(_tx(301), bytes32(uint256(3301)), user1, address(token), address(mockTarget), 100e18, data);
    }

    function test_ExecuteUniversalTx_Native_RevertsWhenPaused() public {
        vm.prank(pauser);
        vault.pause();

        bytes memory data = "";
        vm.deal(tss, 1 ether);

        vm.prank(tss);
        vm.expectRevert();
        vault.executeUniversalTx{value: 1 ether}(_tx(302), bytes32(uint256(3302)), user1, address(0), address(mockTarget), 1 ether, data);
    }

    // C. Parameter Validation (5 tests)
    function test_ExecuteUniversalTx_ZeroOriginCallerReverts() public {
        bytes memory data = "";

        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.executeUniversalTx(_tx(303), bytes32(uint256(3303)), address(0), address(token), address(mockTarget), 100e18, data);
    }

    function test_ExecuteUniversalTx_ZeroTargetReverts() public {
        bytes memory data = "";

        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.executeUniversalTx(_tx(304), bytes32(uint256(3304)), user1, address(token), address(0), 100e18, data);
    }

    function test_ExecuteUniversalTx_Native_InvalidMsgValue_TooLow() public {
        bytes memory data = "";
        vm.deal(tss, 1 ether);

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.executeUniversalTx{value: 0.5 ether}(_tx(305), bytes32(uint256(3305)), user1, address(0), address(mockTarget), 1 ether, data);
    }

    function test_ExecuteUniversalTx_Native_InvalidMsgValue_TooHigh() public {
        bytes memory data = "";
        vm.deal(tss, 2 ether);

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.executeUniversalTx{value: 2 ether}(_tx(306), bytes32(uint256(3306)), user1, address(0), address(mockTarget), 1 ether, data);
    }

    function test_ExecuteUniversalTx_ERC20_NonZeroMsgValueReverts() public {
        bytes memory data = "";
        vm.deal(tss, 1 ether);

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.executeUniversalTx{value: 1 ether}(_tx(307), bytes32(uint256(3307)), user1, address(token), address(mockTarget), 100e18, data);
    }

    // D. CEA Lifecycle (4 tests)
    function test_ExecuteUniversalTx_DeploysNewCEA_WhenNotExists() public {
        address uea = makeAddr("newUea");
        bytes memory data = "";

        // Verify CEA doesn't exist yet
        (, bool deployed) = _getCEA(uea);
        assertFalse(deployed);

        vm.prank(tss);
        vault.executeUniversalTx(_tx(308), bytes32(uint256(3308)), uea, address(token), address(mockTarget), 100e18, data);

        // Verify CEA was deployed
        (address cea, bool nowDeployed) = _getCEA(uea);
        assertTrue(nowDeployed);
        assertTrue(cea != address(0));
    }

    function test_ExecuteUniversalTx_ReusesExistingCEA() public {
        address uea = makeAddr("reusableUea");
        bytes memory data = "";

        // First call - deploys CEA
        vm.prank(tss);
        vault.executeUniversalTx(_tx(309), bytes32(uint256(3309)), uea, address(token), address(mockTarget), 100e18, data);

        (address cea1, bool deployed1) = _getCEA(uea);
        assertTrue(deployed1);

        // Second call - reuses CEA
        vm.prank(tss);
        vault.executeUniversalTx(_tx(310), bytes32(uint256(3310)), uea, address(token), address(mockTarget), 50e18, data);

        (address cea2, bool deployed2) = _getCEA(uea);
        assertTrue(deployed2);
        assertEq(cea1, cea2); // Same CEA address
    }

    function test_ExecuteUniversalTx_CEAReceivesCorrectParameters_ERC20() public {
        address uea = makeAddr("paramTestUea");
        uint256 amount = 100e18;
        bytes memory data = abi.encodeWithSignature("receiveToken(address,uint256)", address(token), amount);

        vm.prank(tss);
        vault.executeUniversalTx(_tx(311), bytes32(uint256(3311)), uea, address(token), address(mockTarget), amount, data);

        (address cea,) = _getCEA(uea);
        _assertCEAParams(
            cea,
            _tx(311),
            bytes32(uint256(3311)),
            uea,
            address(token),
            address(mockTarget),
            amount,
            data
        );
    }

    function test_ExecuteUniversalTx_CEAReceivesCorrectParameters_Native() public {
        address uea = makeAddr("nativeParamTestUea");
        uint256 amount = 1 ether;
        bytes memory data = "";

        vm.deal(tss, amount);

        vm.prank(tss);
        vault.executeUniversalTx{value: amount}(_tx(312), bytes32(uint256(3312)), uea, address(0), address(mockTarget), amount, data);

        (address cea,) = _getCEA(uea);
        _assertCEAParams(
            cea,
            _tx(312),
            bytes32(uint256(3312)),
            uea,
            address(0), // Native
            address(mockTarget),
            amount,
            data
        );
    }

    // E. ERC20 Path (3 tests)
    function test_ExecuteUniversalTx_ERC20_TransfersTokensToCEA() public {
        address uea = makeAddr("erc20TransferUea");
        uint256 amount = 100e18;
        bytes memory data = "";

        uint256 vaultBalanceBefore = token.balanceOf(address(vault));

        vm.prank(tss);
        vault.executeUniversalTx(_tx(313), bytes32(uint256(3313)), uea, address(token), address(mockTarget), amount, data);

        (address cea,) = _getCEA(uea);

        // CEA should have received tokens from vault (transferred before execution)
        // Vault balance should decrease
        assertEq(token.balanceOf(address(vault)), vaultBalanceBefore - amount);
        // MockCEA resets approval to 0 after execution, so we verify via balance change
    }

    function test_ExecuteUniversalTx_ERC20_ReducesVaultBalance() public {
        address uea = makeAddr("vaultBalanceUea");
        uint256 amount = 100e18;
        bytes memory data = "";

        uint256 vaultBalanceBefore = token.balanceOf(address(vault));

        vm.prank(tss);
        vault.executeUniversalTx(_tx(314), bytes32(uint256(3314)), uea, address(token), address(mockTarget), amount, data);

        uint256 vaultBalanceAfter = token.balanceOf(address(vault));
        assertEq(vaultBalanceBefore - amount, vaultBalanceAfter);
    }

    function test_ExecuteUniversalTx_ERC20_CEAExecutesCall() public {
        address uea = makeAddr("ceaExecuteUea");
        uint256 amount = 100e18;
        bytes memory data = abi.encodeWithSignature("receiveToken(address,uint256)", address(token), amount);

        vm.prank(tss);
        vault.executeUniversalTx(_tx(315), bytes32(uint256(3315)), uea, address(token), address(mockTarget), amount, data);

        // Verify the CEA called the target (MockTarget records lastCaller)
        (address cea,) = _getCEA(uea);
        assertEq(mockTarget.lastCaller(), cea);
        assertEq(mockTarget.lastToken(), address(token));
    }

    // HIGH PRIORITY TESTS

    // C. Parameter Validation (continued - 3 tests)
    function test_ExecuteUniversalTx_ERC20_UnsupportedTokenReverts() public {
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS", 18, 1000e18);
        unsupportedToken.mint(address(vault), 100e18);
        bytes memory data = "";

        vm.prank(tss);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.executeUniversalTx(_tx(316), bytes32(uint256(3316)), user1, address(unsupportedToken), address(mockTarget), 100e18, data);
    }
    
    function test_ExecuteUniversalTx_ERC20_InsufficientVaultBalanceReverts() public {
        uint256 vaultBalance = token.balanceOf(address(vault));
        bytes memory data = "";

        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.executeUniversalTx(_tx(318), bytes32(uint256(3318)), user1, address(token), address(mockTarget), vaultBalance + 1, data);
    }

    // D. CEA Lifecycle (continued - 1 test)
    function test_ExecuteUniversalTx_DifferentUEAs_GetDifferentCEAs() public {
        address uea1 = makeAddr("uea1");
        address uea2 = makeAddr("uea2");
        bytes memory data = "";

        vm.prank(tss);
        vault.executeUniversalTx(_tx(320), bytes32(uint256(3320)), uea1, address(token), address(mockTarget), 50e18, data);

        vm.prank(tss);
        vault.executeUniversalTx(_tx(321), bytes32(uint256(3321)), uea2, address(token), address(mockTarget), 50e18, data);

        (address cea1,) = _getCEA(uea1);
        (address cea2,) = _getCEA(uea2);

        assertTrue(cea1 != cea2);
    }

    // E. ERC20 Path (continued - 1 test)
    function test_ExecuteUniversalTx_ERC20_DifferentTokenTypes() public {
        address uea = makeAddr("multiTokenUea");
        bytes memory data = "";

        // Test with 18-decimal token
        vm.prank(tss);
        vault.executeUniversalTx(_tx(322), bytes32(uint256(3322)), uea, address(token), address(mockTarget), 100e18, data);

        // Test with 6-decimal token
        vm.prank(tss);
        vault.executeUniversalTx(_tx(323), bytes32(uint256(3323)), uea, address(token2), address(mockTarget), 50e6, data);

        (address cea,) = _getCEA(uea);
        MockCEA mockCea = _getMockCEA(cea);

        // Last call should be for token2
        assertEq(mockCea.lastToken(), address(token2));
        assertEq(mockCea.lastAmount(), 50e6);
    }

    // F. Native Path (4 tests)
    function test_ExecuteUniversalTx_Native_ForwardsETHToCEA() public {
        address uea = makeAddr("nativeEthUea");
        uint256 amount = 1 ether;
        bytes memory data = "";

        vm.deal(tss, amount);

        uint256 ceaBalanceBefore;
        (address cea, bool deployed) = _getCEA(uea);
        if (deployed) {
            ceaBalanceBefore = cea.balance;
        }

        vm.prank(tss);
        vault.executeUniversalTx{value: amount}(_tx(324), bytes32(uint256(3324)), uea, address(0), address(mockTarget), amount, data);

        (address ceaAfter,) = _getCEA(uea);

        // After execution, CEA should have forwarded ETH to target
        // MockCEA forwards ETH in its executeUniversalTx call
        assertGt(address(mockTarget).balance, ceaBalanceBefore);
    }

    function test_ExecuteUniversalTx_Native_CEAExecutesCall() public {
        address uea = makeAddr("nativeCallUea");
        uint256 amount = 1 ether;
        bytes memory data = "";

        vm.deal(tss, amount);

        vm.prank(tss);
        vault.executeUniversalTx{value: amount}(_tx(325), bytes32(uint256(3325)), uea, address(0), address(mockTarget), amount, data);

        (address cea,) = _getCEA(uea);
        MockCEA mockCea = _getMockCEA(cea);

        assertEq(mockCea.lastToken(), address(0));
        assertEq(mockCea.lastTarget(), address(mockTarget));
        assertEq(mockCea.lastAmount(), amount);
    }

    function test_ExecuteUniversalTx_Native_DeploysNewCEA() public {
        address uea = makeAddr("nativeNewCeaUea");
        uint256 amount = 1 ether;
        bytes memory data = "";

        (, bool deployedBefore) = _getCEA(uea);
        assertFalse(deployedBefore);

        vm.deal(tss, amount);

        vm.prank(tss);
        vault.executeUniversalTx{value: amount}(_tx(326), bytes32(uint256(3326)), uea, address(0), address(mockTarget), amount, data);

        (address cea, bool deployedAfter) = _getCEA(uea);
        assertTrue(deployedAfter);
        assertTrue(cea != address(0));
    }

    function test_ExecuteUniversalTx_Native_ReusesExistingCEA() public {
        address uea = makeAddr("nativeReuseCeaUea");
        uint256 amount = 1 ether;
        bytes memory data = "";

        vm.deal(tss, 2 ether);

        // First call
        vm.prank(tss);
        vault.executeUniversalTx{value: amount}(_tx(327), bytes32(uint256(3327)), uea, address(0), address(mockTarget), amount, data);

        (address cea1,) = _getCEA(uea);

        // Second call
        vm.prank(tss);
        vault.executeUniversalTx{value: amount}(_tx(328), bytes32(uint256(3328)), uea, address(0), address(mockTarget), amount, data);

        (address cea2,) = _getCEA(uea);

        assertEq(cea1, cea2);
    }

    // G. Integration (3 tests)
    function test_ExecuteUniversalTx_MixedFlows_ERC20ThenNative() public {
        address uea = makeAddr("mixedFlowUea");
        bytes memory data = "";

        // First ERC20
        vm.prank(tss);
        vault.executeUniversalTx(_tx(329), bytes32(uint256(3329)), uea, address(token), address(mockTarget), 100e18, data);

        (address ceaAfterErc20,) = _getCEA(uea);

        // Then Native
        vm.deal(tss, 1 ether);
        vm.prank(tss);
        vault.executeUniversalTx{value: 1 ether}(_tx(330), bytes32(uint256(3330)), uea, address(0), address(mockTarget), 1 ether, data);

        (address ceaAfterNative,) = _getCEA(uea);

        // Should use same CEA
        assertEq(ceaAfterErc20, ceaAfterNative);
    }

    function test_ExecuteUniversalTx_FullWorkflow_ERC20() public {
        address uea = makeAddr("fullWorkflowErc20Uea");
        uint256 amount = 200e18;
        bytes memory data = abi.encodeWithSignature("receiveToken(address,uint256)", address(token), amount);

        uint256 vaultBalanceBefore = token.balanceOf(address(vault));

        vm.prank(tss);
        vault.executeUniversalTx(_tx(331), bytes32(uint256(3331)), uea, address(token), address(mockTarget), amount, data);

        // Verify all expected outcomes
        (address cea, bool deployed) = _getCEA(uea);
        assertTrue(deployed);

        // Vault balance reduced
        assertEq(token.balanceOf(address(vault)), vaultBalanceBefore - amount);

        // CEA received correct params
        MockCEA mockCea = _getMockCEA(cea);
        assertEq(mockCea.lastTxID(), _tx(331));
        assertEq(mockCea.lastUEA(), uea);
        assertEq(mockCea.lastToken(), address(token));
        assertEq(mockCea.lastAmount(), amount);

        // Target was called by CEA
        assertEq(mockTarget.lastCaller(), cea);
    }

    function test_ExecuteUniversalTx_FullWorkflow_Native() public {
        address uea = makeAddr("fullWorkflowNativeUea");
        uint256 amount = 2 ether;
        bytes memory data = "";

        vm.deal(tss, amount);

        vm.prank(tss);
        vault.executeUniversalTx{value: amount}(_tx(332), bytes32(uint256(3332)), uea, address(0), address(mockTarget), amount, data);

        // Verify all expected outcomes
        (address cea, bool deployed) = _getCEA(uea);
        assertTrue(deployed);

        // CEA received correct params
        MockCEA mockCea = _getMockCEA(cea);
        assertEq(mockCea.lastTxID(), _tx(332));
        assertEq(mockCea.lastUEA(), uea);
        assertEq(mockCea.lastToken(), address(0));
        assertEq(mockCea.lastAmount(), amount);
        assertEq(mockCea.lastTarget(), address(mockTarget));
    }

    // H. Edge Cases (2 tests)
    function test_ExecuteUniversalTx_TargetReverts_ERC20() public {
        address uea = makeAddr("targetRevertUea");
        uint256 amount = 100e18;
        // Use the MockRevertingTarget for proper revert testing
        bytes memory data = abi.encodeWithSignature("someFunction()");  // Non-empty payload triggers execution

        vm.prank(tss);
        vm.expectRevert();
        vault.executeUniversalTx(_tx(333), bytes32(uint256(3333)), uea, address(token), address(mockRevertingTarget), amount, data);
    }

    function test_ExecuteUniversalTx_TargetReverts_Native() public {
        address uea = makeAddr("targetRevertNativeUea");
        uint256 amount = 1 ether;
        // Use the MockRevertingTarget for proper revert testing
        bytes memory data = "";

        vm.deal(tss, amount);

        vm.prank(tss);
        vm.expectRevert();
        vault.executeUniversalTx{value: amount}(_tx(334), bytes32(uint256(3334)), uea, address(0), address(mockRevertingTarget), amount, data);
    }

    // I. Event Emissions (4 tests)
    function test_ExecuteUniversalTx_ERC20_EmitsEvent() public {
        address uea = makeAddr("eventERC20Uea");
        uint256 amount = 100e18;
        bytes memory data = abi.encodeWithSignature("someFunction()");

        vm.expectEmit(true, true, true, true);
        emit VaultUniversalTxExecuted(_tx(335), bytes32(uint256(3335)), uea, address(mockTarget), address(token), amount, data);

        vm.prank(tss);
        vault.executeUniversalTx(_tx(335), bytes32(uint256(3335)), uea, address(token), address(mockTarget), amount, data);
    }

    function test_ExecuteUniversalTx_Native_EmitsEvent() public {
        address uea = makeAddr("eventNativeUea");
        uint256 amount = 1 ether;
        bytes memory data = abi.encodeWithSignature("receiveETH()");

        vm.deal(tss, amount);

        vm.expectEmit(true, true, true, true);
        emit VaultUniversalTxExecuted(_tx(336), bytes32(uint256(3336)), uea, address(mockTarget), address(0), amount, data);

        vm.prank(tss);
        vault.executeUniversalTx{value: amount}(_tx(336), bytes32(uint256(3336)), uea, address(0), address(mockTarget), amount, data);
    }

    function test_ExecuteUniversalTx_EmitsEvent_WithEmptyPayload() public {
        address uea = makeAddr("eventEmptyPayloadUea");
        uint256 amount = 50e18;
        bytes memory data = "";

        vm.expectEmit(true, true, true, true);
        emit VaultUniversalTxExecuted(_tx(337), bytes32(uint256(3337)), uea, address(mockTarget), address(token), amount, data);

        vm.prank(tss);
        vault.executeUniversalTx(_tx(337), bytes32(uint256(3337)), uea, address(token), address(mockTarget), amount, data);
    }

    function test_ExecuteUniversalTx_EmitsEvent_WithComplexPayload() public {
        address uea = makeAddr("eventComplexPayloadUea");
        uint256 amount = 100e18;
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", user1, 50e18);

        vm.expectEmit(true, true, true, true);
        emit VaultUniversalTxExecuted(_tx(338), bytes32(uint256(3338)), uea, address(mockTarget), address(token), amount, data);

        vm.prank(tss);
        vault.executeUniversalTx(_tx(338), bytes32(uint256(3338)), uea, address(token), address(mockTarget), amount, data);
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
            abi.encodeWithSelector(vault.executeUniversalTx.selector, txID, bytes32(uint256(3000 + uint256(txID))), user1, address(token), user1, 100e18, bytes(""))
        );
        assertFalse(success);
    }

    // ============================================================================
    // WITHDRAW PATH: msg.value VALIDATION TESTS
    // ============================================================================

    function test_Withdraw_Native_MsgValueMismatch_TooLow() public {
        vm.deal(tss, 2 ether);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.executeUniversalTx{value: 0.5 ether}(_tx(500), bytes32(uint256(3500)), user1, address(0), user1, 1 ether, bytes(""));
    }

    function test_Withdraw_Native_MsgValueMismatch_TooHigh() public {
        vm.deal(tss, 3 ether);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.executeUniversalTx{value: 2 ether}(_tx(501), bytes32(uint256(3501)), user1, address(0), user1, 1 ether, bytes(""));
    }

    function test_Withdraw_ERC20_NonZeroMsgValueReverts() public {
        vm.deal(tss, 1 ether);
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.executeUniversalTx{value: 1 ether}(_tx(502), bytes32(uint256(3502)), user1, address(token), user1, 100e18, bytes(""));
    }

    function test_Withdraw_NativeUnsupportedReverts() public {
        // Remove native support from gateway
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 0;
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        vm.deal(tss, 1 ether);
        vm.prank(tss);
        vm.expectRevert(Errors.NotSupported.selector);
        vault.executeUniversalTx{value: 1 ether}(_tx(503), bytes32(uint256(3503)), user1, address(0), user1, 1 ether, bytes(""));
    }

    // ============================================================================
    // REVERT FLOW: ADDITIONAL TESTS
    // ============================================================================

    function test_RevertWithdraw_VariantToken_InsufficientBalance() public {
        uint256 vaultBalance = variantToken.balanceOf(address(vault));
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.revertUniversalTxToken(_tx(504), bytes32(uint256(3504)), address(variantToken), vaultBalance + 1, RevertInstructions(user1, ""));
    }

    function test_RevertWithdraw_BalanceDeltaCheck() public {
        uint256 amount = 1000e18;
        uint256 vaultBalanceBefore = token.balanceOf(address(vault));

        vm.prank(tss);
        vault.revertUniversalTxToken(_tx(505), bytes32(uint256(3505)), address(token), amount, RevertInstructions(user1, ""));

        // Vault sent tokens to gateway, gateway forwarded to recipient
        assertEq(token.balanceOf(address(vault)), vaultBalanceBefore - amount);
        assertEq(token.balanceOf(user1), amount);
    }

    // ============================================================================
    // CEA LIFECYCLE: DEPLOYMENT FAILURE & REUSE
    // ============================================================================

    function test_CEADeploymentFailure_Propagates() public {
        address uea = makeAddr("failDeployUea");

        // Make CEAFactory deployCEA always revert
        ceaFactory.setShouldFailDeploy(true);

        vm.prank(tss);
        vm.expectRevert();
        vault.executeUniversalTx(_tx(506), bytes32(uint256(3506)), uea, address(token), user1, 100e18, bytes(""));
    }

    function test_CEA_WithdrawThenExecute_ReusesSameCEA() public {
        address uea = makeAddr("withdrawThenExecUea");

        // Step 1: Withdraw (empty data) — deploys CEA
        vm.prank(tss);
        vault.executeUniversalTx(_tx(507), bytes32(uint256(3507)), uea, address(token), user1, 100e18, bytes(""));
        (address ceaAfterWithdraw,) = _getCEA(uea);

        // Step 2: Execute (non-empty data) — must reuse same CEA
        bytes memory data = abi.encodeWithSignature("receiveToken(address,uint256)", address(token), 50e18);
        vm.prank(tss);
        vault.executeUniversalTx(_tx(508), bytes32(uint256(3508)), uea, address(token), address(mockTarget), 50e18, data);
        (address ceaAfterExecute,) = _getCEA(uea);

        assertEq(ceaAfterWithdraw, ceaAfterExecute);
    }

    // ============================================================================
    // WITHDRAW PATH: CEA FUNCTION ROUTING VERIFICATION
    // ============================================================================

    function test_Withdraw_CallsCEAWithdrawTo_NotExecute() public {
        address uea = makeAddr("withdrawRoutingUea");

        vm.prank(tss);
        vault.executeUniversalTx(_tx(509), bytes32(uint256(3509)), uea, address(token), user1, 100e18, bytes(""));

        (address cea,) = _getCEA(uea);
        MockCEA mockCea = _getMockCEA(cea);

        // withdrawTo should have been called once, executeUniversalTx zero times
        assertEq(mockCea.withdrawToCallCount(), 1);
        assertEq(mockCea.executeCallCount(), 0);
    }

    function test_Execute_CallsCEAExecute_NotWithdrawTo() public {
        address uea = makeAddr("executeRoutingUea");
        bytes memory data = abi.encodeWithSignature("receiveToken(address,uint256)", address(token), 100e18);

        vm.prank(tss);
        vault.executeUniversalTx(_tx(510), bytes32(uint256(3510)), uea, address(token), address(mockTarget), 100e18, data);

        (address cea,) = _getCEA(uea);
        MockCEA mockCea = _getMockCEA(cea);

        // executeUniversalTx should have been called once, withdrawTo zero times
        assertEq(mockCea.executeCallCount(), 1);
        assertEq(mockCea.withdrawToCallCount(), 0);
    }

    function test_Withdraw_Native_ForwardsMsgValueToCEA() public {
        address uea = makeAddr("nativeWithdrawFwdUea");
        uint256 amount = 1 ether;

        vm.deal(tss, amount);
        uint256 userBalanceBefore = user1.balance;

        vm.prank(tss);
        vault.executeUniversalTx{value: amount}(_tx(511), bytes32(uint256(3511)), uea, address(0), user1, amount, bytes(""));

        (address cea,) = _getCEA(uea);
        MockCEA mockCea = _getMockCEA(cea);

        // Confirm withdrawTo was called (not execute)
        assertEq(mockCea.withdrawToCallCount(), 1);
        assertEq(mockCea.executeCallCount(), 0);
        // User received the native tokens via CEA.withdrawTo
        assertEq(user1.balance, userBalanceBefore + amount);
    }

    // ============================================================================
    // SPEC DOCUMENTATION: ZERO AMOUNT WITH DATA
    // ============================================================================

    function test_Execute_ZeroAmount_WithData_Succeeds() public {
        // Documents current spec: amount=0 + non-empty data is allowed (payload-only execute)
        address uea = makeAddr("zeroAmountWithDataUea");
        bytes memory data = abi.encodeWithSignature("receiveToken(address,uint256)", address(token), 0);

        vm.prank(tss);
        // Should succeed — amount=0 with data is a valid execute path
        vault.executeUniversalTx(_tx(512), bytes32(uint256(3512)), uea, address(token), address(mockTarget), 0, data);

        (address cea,) = _getCEA(uea);
        MockCEA mockCea = _getMockCEA(cea);
        assertEq(mockCea.executeCallCount(), 1);
    }

    // ============================================================================
    // REENTRANCY PROTECTION TESTS
    // ============================================================================

    function test_Reentrancy_WithdrawPath_Blocked() public {
        address uea = makeAddr("reentrantWithdrawUea");

        // Pre-deploy CEA via initial withdraw
        vm.prank(tss);
        vault.executeUniversalTx(_tx(513), bytes32(uint256(3513)), uea, address(token), user1, 100e18, bytes(""));

        (address cea,) = _getCEA(uea);
        MockCEA mockCea = _getMockCEA(cea);

        // Configure CEA to attempt reentrancy during withdrawTo
        bytes memory reentrantCall = abi.encodeWithSelector(
            vault.executeUniversalTx.selector,
            _tx(514), bytes32(uint256(3514)), uea, address(token), user1, 50e18, bytes("")
        );
        mockCea.setReentrant(address(vault), reentrantCall);

        // Outer call: CEA will attempt to reenter vault during withdrawTo
        vm.prank(tss);
        vault.executeUniversalTx(_tx(515), bytes32(uint256(3515)), uea, address(token), user1, 50e18, bytes(""));

        // Reentrancy was blocked by nonReentrant guard
        assertFalse(mockCea.reentrantCallSucceeded());
    }

    function test_Reentrancy_ExecutePath_Blocked() public {
        address uea = makeAddr("reentrantExecUea");

        // Pre-deploy CEA via initial withdraw
        vm.prank(tss);
        vault.executeUniversalTx(_tx(516), bytes32(uint256(3516)), uea, address(token), user1, 100e18, bytes(""));

        (address cea,) = _getCEA(uea);
        MockCEA mockCea = _getMockCEA(cea);

        // Configure CEA to attempt reentrancy during executeUniversalTx
        bytes memory reentrantCall = abi.encodeWithSelector(
            vault.executeUniversalTx.selector,
            _tx(517), bytes32(uint256(3517)), uea, address(token), user1, 50e18, bytes("")
        );
        mockCea.setReentrant(address(vault), reentrantCall);

        // Outer call (execute path): CEA will attempt to reenter vault
        bytes memory data = abi.encodeWithSignature("receiveToken(address,uint256)", address(token), 50e18);
        vm.prank(tss);
        vault.executeUniversalTx(_tx(518), bytes32(uint256(3518)), uea, address(token), address(mockTarget), 50e18, data);

        // Reentrancy was blocked by nonReentrant guard
        assertFalse(mockCea.reentrantCallSucceeded());
    }

    // ============================================================================
    // PAUSE GATING: SWEEP BEHAVIOR
    // ============================================================================

    function test_Sweep_AllowedWhenPaused() public {
        vm.prank(pauser);
        vault.pause();

        // Sweep should still work when paused (admin emergency function)
        vm.prank(admin);
        vault.sweep(address(token), user1, 100e18);
        assertEq(token.balanceOf(user1), 100e18);
    }

    // ============================================================================
    // GATEWAY POINTER CHANGES TESTS
    // ============================================================================

    function test_GatewayChange_LiveSupport() public {
        assertTrue(gateway.isSupportedToken(address(token)));

        vm.prank(tss);
        vault.executeUniversalTx(txID, bytes32(uint256(3000 + uint256(txID))), user1, address(token), user1, 100e18, bytes(""));
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
        vault.executeUniversalTx(txID, bytes32(uint256(3000 + uint256(txID))), user1, address(token), user2, 100e18, bytes(""));
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
        vault.executeUniversalTx(_tx(100), bytes32(uint256(3000 + uint256(_tx(100)))), user1, address(token), user1, 100e18, bytes(""));

        // Re-enable support in new gateway
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 1_000_000e18;

        vm.prank(admin);
        newGateway.setTokenLimitThresholds(tokens, thresholds);

        vm.prank(tss);
        vault.executeUniversalTx(_tx(101), bytes32(uint256(3000 + uint256(_tx(101)))), user1, address(token), user1, 100e18, bytes(""));
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
        // Event VaultWithdraw was removed - test now verifies withdraw functionality
        vault.executeUniversalTx(txID, bytes32(uint256(3000 + uint256(txID))), user1, address(token), user1, amount, bytes(""));
        assertEq(token.balanceOf(user1), amount);
    }

    function test_Events_VaultRefund() public {
        uint256 amount = 1000e18;

        RevertInstructions memory revertInstr = RevertInstructions(user1, "");

        vm.prank(tss);
        // Event VaultRevert was removed - test now verifies revertWithdraw functionality
        vault.revertUniversalTxToken(_tx(5), bytes32(uint256(3000 + 5)), address(token), amount, revertInstr);
        assertEq(token.balanceOf(user1), amount);
    }

    function test_Events_InitializationNoEvents() public {
        // NOTE: Vault.initialize() does NOT emit GatewayUpdated or TSSUpdated events
        // Events are only emitted by setGateway() and setTSS() functions
        // This test verifies that initialization works without events
        Vault newImpl = new Vault();
        MockCEAFactory newCeaFactory = new MockCEAFactory();

        bytes memory initData = abi.encodeWithSelector(Vault.initialize.selector, admin, pauser, tss, address(gateway), address(newCeaFactory));

        ERC1967Proxy proxy = new ERC1967Proxy(address(newImpl), initData);

        // Verify the proxy was created and initialized correctly
        Vault newVault = Vault(address(proxy));
        assertEq(address(newVault.gateway()), address(gateway));
        assertEq(newVault.TSS_ADDRESS(), tss);
        assertEq(address(newVault.CEAFactory()), address(newCeaFactory));
        assertTrue(newVault.hasRole(newVault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(newVault.hasRole(newVault.PAUSER_ROLE(), pauser));
        assertTrue(newVault.hasRole(newVault.TSS_ROLE(), tss));
    }
}
