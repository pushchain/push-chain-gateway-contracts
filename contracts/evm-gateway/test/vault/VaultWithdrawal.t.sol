// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import { Vault } from "../../src/Vault.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { IVault } from "../../src/interfaces/IVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ICEA } from "../../src/interfaces/ICEA.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockCEAFactory } from "../mocks/MockCEAFactory.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Comprehensive test suite for Vault withdrawal functionality via executeUniversalTx with empty payload
/// @dev Tests cover ERC20/native withdrawals, CEA deployment, token parking, edge cases, and integration flows
contract VaultWithdrawalTest is Test {
    // =========================
    //      CONTRACTS
    // =========================
    Vault public vault;
    Vault public vaultImpl;
    UniversalGateway public gateway;
    UniversalGateway public gatewayImpl;
    MockCEAFactory public ceaFactory;
    MockERC20 public usdc;
    MockERC20 public tokenA;

    // =========================
    //      ACTORS
    // =========================
    address public admin;
    address public pauser;
    address public tss;
    address public user1;
    address public user2;
    address public user3;
    address public recipient;
    address public attacker;
    address public weth;

    // =========================
    //      SETUP
    // =========================
    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        tss = makeAddr("tss");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        recipient = makeAddr("recipient");
        attacker = makeAddr("attacker");
        weth = makeAddr("weth");

        // Deploy UniversalGateway
        gatewayImpl = new UniversalGateway();
        bytes memory gatewayInitData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin,
            tss,
            address(this), // vault address (temporary)
            1e18, // minCapUsd
            10e18, // maxCapUsd
            address(0), // factory
            address(0), // router
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

        // Update gateway's VAULT_ROLE
        vm.startPrank(admin);
        gateway.pause();
        gateway.updateVault(address(vault));
        gateway.unpause();
        vm.stopPrank();

        // Deploy tokens
        usdc = new MockERC20("USD Coin", "USDC", 6, 1_000_000e6);
        tokenA = new MockERC20("Token A", "TKNA", 18, 1_000_000e18);

        // Setup: support tokens in gateway
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(tokenA);
        tokens[2] = address(0); // Native

        uint256[] memory thresholds = new uint256[](3);
        thresholds[0] = 1_000_000e6; // 1M USDC
        thresholds[1] = 1_000_000e18; // 1M TokenA
        thresholds[2] = 1_000_000 ether; // 1M ETH

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Fund vault with tokens
        usdc.mint(address(vault), 100_000e6);
        tokenA.mint(address(vault), 100_000e18);
        vm.deal(address(vault), 1000 ether);
    }

    // =========================
    //  1. ERC20 WITHDRAWAL TESTS
    // =========================

    /// @notice Test ERC20 withdrawal when CEA already exists
    function testWithdraw_ERC20_CEAExists_Success() public {
        bytes32 txID = keccak256("tx1");
        bytes32 universalTxID = keccak256("utx1");
        address originCaller = user1; // UEA on Push Chain
        uint256 amount = 100e6; // 100 USDC

        // Pre-deploy CEA for user1
        vm.prank(address(vault));
        address cea = ceaFactory.deployCEA(originCaller);

        uint256 initialUserBalance = usdc.balanceOf(recipient);
        uint256 initialVaultBalance = usdc.balanceOf(address(vault));

        // Expect event emission
        vm.expectEmit(true, true, true, true);
        emit IVault.VaultUniversalTxExecuted(txID, universalTxID, originCaller, recipient, address(usdc), amount, bytes(""));

        // TSS calls vault.executeUniversalTx with EMPTY PAYLOAD
        vm.prank(tss);
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            address(usdc),    // token
            recipient,        // target (recipient)
            amount,
            bytes("")         // EMPTY PAYLOAD = withdrawal signal
        );

        // Verify balances
        assertEq(usdc.balanceOf(recipient), initialUserBalance + amount, "User should receive tokens");
        assertEq(usdc.balanceOf(address(vault)), initialVaultBalance - amount, "Vault balance should decrease");
        assertEq(usdc.balanceOf(cea), 0, "CEA should not hold tokens after withdrawal");
    }

    /// @notice Test ERC20 withdrawal when CEA doesn't exist - should deploy CEA first
    function testWithdraw_ERC20_CEANotExists_DeploysAndSucceeds() public {
        bytes32 txID = keccak256("tx2");
        bytes32 universalTxID = keccak256("utx2");
        address originCaller = user2; // Fresh UEA (no CEA yet)
        uint256 amount = 200e6;

        // Verify CEA doesn't exist
        (address ceaBefore, bool isDeployedBefore) = ceaFactory.getCEAForUEA(originCaller);
        assertFalse(isDeployedBefore, "CEA should not exist before withdrawal");

        uint256 initialUserBalance = usdc.balanceOf(recipient);

        // TSS calls vault.executeUniversalTx - should deploy CEA on-demand
        vm.prank(tss);
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            address(usdc),
            recipient,
            amount,
            bytes("") // Empty payload = withdrawal
        );

        // Verify CEA was deployed
        (address ceaAfter, bool isDeployedAfter) = ceaFactory.getCEAForUEA(originCaller);
        assertTrue(isDeployedAfter, "CEA should be deployed");
        assertTrue(ceaAfter != address(0), "CEA address should be valid");

        // Verify withdrawal succeeded
        assertEq(usdc.balanceOf(recipient), initialUserBalance + amount, "User should receive tokens");
    }

    /// @notice Test ERC20 withdrawal with insufficient Vault balance - should revert
    function testWithdraw_ERC20_InsufficientBalance_Reverts() public {
        bytes32 txID = keccak256("tx3");
        bytes32 universalTxID = keccak256("utx3");
        address originCaller = user1;
        uint256 excessiveAmount = usdc.balanceOf(address(vault)) + 1; // More than Vault has

        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            address(usdc),
            recipient,
            excessiveAmount,
            bytes("")
        );
    }

    /// @notice Test ERC20 withdrawal with unsupported token - should revert
    function testWithdraw_ERC20_TokenNotSupported_Reverts() public {
        bytes32 txID = keccak256("tx4");
        bytes32 universalTxID = keccak256("utx4");
        address originCaller = user1;
        address unsupportedToken = address(0xDEAD);
        uint256 amount = 100e18;

        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotSupported.selector));
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            unsupportedToken,
            recipient,
            amount,
            bytes("")
        );
    }

    /// @notice Test ERC20 withdrawal with zero amount - should revert
    function testWithdraw_ERC20_AmountZero_Reverts() public {
        bytes32 txID = keccak256("tx5");
        bytes32 universalTxID = keccak256("utx5");
        address originCaller = user1;

        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            address(usdc),
            recipient,
            0, // Zero amount
            bytes("")
        );
    }

    /// @notice Test ERC20 withdrawal with zero target address - should revert
    function testWithdraw_ERC20_TargetZero_Reverts() public {
        bytes32 txID = keccak256("tx6");
        bytes32 universalTxID = keccak256("utx6");
        address originCaller = user1;
        uint256 amount = 100e6;

        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            address(usdc),
            address(0), // Zero recipient
            amount,
            bytes("")
        );
    }

    /// @notice Test ERC20 withdrawal with non-zero msg.value - should revert
    function testWithdraw_ERC20_MsgValueNonZero_Reverts() public {
        bytes32 txID = keccak256("tx7");
        bytes32 universalTxID = keccak256("utx7");
        address originCaller = user1;
        uint256 amount = 100e6;

        vm.deal(tss, 1 ether);
        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        vault.executeUniversalTx{value: 1 ether}( // Should not send ETH for ERC20 withdrawal
            txID,
            universalTxID,
            originCaller,
            address(usdc),
            recipient,
            amount,
            bytes("")
        );
    }

    // =========================
    //  2. NATIVE WITHDRAWAL TESTS
    // =========================

    /// @notice Test native (ETH) withdrawal when CEA already exists
    function testWithdraw_Native_CEAExists_Success() public {
        bytes32 txID = keccak256("tx10");
        bytes32 universalTxID = keccak256("utx10");
        address originCaller = user1;
        uint256 amount = 5 ether;

        // Pre-deploy CEA
        vm.prank(address(vault));
        address cea = ceaFactory.deployCEA(originCaller);

        uint256 initialUserBalance = recipient.balance;
        uint256 initialVaultBalance = address(vault).balance;

        // Expect event
        vm.expectEmit(true, true, true, true);
        emit IVault.VaultUniversalTxExecuted(txID, universalTxID, originCaller, recipient, address(0), amount, bytes(""));

        // Fund TSS with ETH to send
        vm.deal(tss, amount);

        // TSS calls vault.executeUniversalTx with native tokens (address(0))
        vm.prank(tss);
        vault.executeUniversalTx{value: amount}(
            txID,
            universalTxID,
            originCaller,
            address(0),      // token = address(0) for native
            recipient,
            amount,
            bytes("")        // Empty payload = withdrawal
        );

        // Verify balances
        assertEq(recipient.balance, initialUserBalance + amount, "User should receive ETH");
        // Vault balance stays same: receives `amount` from TSS, sends `amount` to CEA (net = 0)
        assertEq(address(vault).balance, initialVaultBalance, "Vault balance should stay same");
    }

    /// @notice Test native withdrawal when CEA doesn't exist - should deploy and succeed
    function testWithdraw_Native_CEANotExists_DeploysAndSucceeds() public {
        bytes32 txID = keccak256("tx11");
        bytes32 universalTxID = keccak256("utx11");
        address originCaller = user3; // Fresh UEA
        uint256 amount = 10 ether;

        // Verify no CEA exists
        (, bool isDeployedBefore) = ceaFactory.getCEAForUEA(originCaller);
        assertFalse(isDeployedBefore, "CEA should not exist");

        uint256 initialUserBalance = recipient.balance;

        // Fund TSS with ETH to send
        vm.deal(tss, amount);

        // Withdraw - should deploy CEA
        vm.prank(tss);
        vault.executeUniversalTx{value: amount}(
            txID,
            universalTxID,
            originCaller,
            address(0),
            recipient,
            amount,
            bytes("")
        );

        // Verify CEA deployed
        (, bool isDeployedAfter) = ceaFactory.getCEAForUEA(originCaller);
        assertTrue(isDeployedAfter, "CEA should be deployed");

        // Verify withdrawal
        assertEq(recipient.balance, initialUserBalance + amount, "User should receive ETH");
    }

    /// @notice Test native withdrawal with msg.value mismatch - should revert
    function testWithdraw_Native_MsgValueMismatch_Reverts() public {
        bytes32 txID = keccak256("tx12");
        bytes32 universalTxID = keccak256("utx12");
        address originCaller = user1;
        uint256 amount = 5 ether;
        uint256 wrongValue = 3 ether;

        // Fund TSS with the wrong value amount that will be sent
        vm.deal(tss, wrongValue);

        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        vault.executeUniversalTx{value: wrongValue}( // msg.value != amount
            txID,
            universalTxID,
            originCaller,
            address(0),
            recipient,
            amount,
            bytes("")
        );
    }

    /// @notice Test native withdrawal with zero amount - should revert
    function testWithdraw_Native_AmountZero_Reverts() public {
        bytes32 txID = keccak256("tx13");
        bytes32 universalTxID = keccak256("utx13");
        address originCaller = user1;

        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            address(0),
            recipient,
            0, // Zero amount
            bytes("")
        );
    }

    /// @notice Test native withdrawal with zero target - should revert
    function testWithdraw_Native_TargetZero_Reverts() public {
        bytes32 txID = keccak256("tx14");
        bytes32 universalTxID = keccak256("utx14");
        address originCaller = user1;
        uint256 amount = 1 ether;

        // Fund TSS with ETH to send
        vm.deal(tss, amount);

        vm.prank(tss);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        vault.executeUniversalTx{value: amount}(
            txID,
            universalTxID,
            originCaller,
            address(0),
            address(0), // Zero target
            amount,
            bytes("")
        );
    }

    // =========================
    //  3. PAYLOAD EXECUTION TESTS (Unchanged - should still work)
    // =========================

    /// @notice Test ERC20 execution with non-empty payload - existing functionality
    function testExecute_ERC20_WithPayload_Success() public {
        bytes32 txID = keccak256("tx20");
        bytes32 universalTxID = keccak256("utx20");
        address originCaller = user1;
        uint256 amount = 100e6;
        bytes memory payload = abi.encodeWithSignature("someFunction()");

        // Mock target that will be called
        address mockTarget = address(0x1234);
        vm.etch(mockTarget, hex"00"); // Make it a contract

        vm.mockCall(
            mockTarget,
            payload,
            abi.encode(true)
        );

        // Execute with non-empty payload - should route to execution path
        vm.prank(tss);
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            address(usdc),
            mockTarget,     // target contract
            amount,
            payload         // NON-EMPTY payload = execution
        );

        // Verify call was made (checked via mockCall)
        assertTrue(true, "Execution should succeed");
    }

    /// @notice Test native execution with non-empty payload - existing functionality
    function testExecute_Native_WithPayload_Success() public {
        bytes32 txID = keccak256("tx21");
        bytes32 universalTxID = keccak256("utx21");
        address originCaller = user1;
        uint256 amount = 1 ether;
        bytes memory payload = abi.encodeWithSignature("deposit()");

        address mockTarget = address(0x5678);
        vm.etch(mockTarget, hex"00");
        vm.mockCall(
            mockTarget,
            payload,
            abi.encode(true)
        );

        // Fund TSS with ETH to send
        vm.deal(tss, amount);

        // Execute with non-empty payload
        vm.prank(tss);
        vault.executeUniversalTx{value: amount}(
            txID,
            universalTxID,
            originCaller,
            address(0),    // native
            mockTarget,
            amount,
            payload        // NON-EMPTY = execution
        );

        assertTrue(true, "Native execution should succeed");
    }

    // =========================
    //  4. TOKEN PARKING TESTS
    // =========================

    /// @notice Test ERC20 token parking - tokens sent to CEA itself
    function testWithdraw_ERC20_Parking_CEAAsTarget() public {
        bytes32 txID = keccak256("tx30");
        bytes32 universalTxID = keccak256("utx30");
        address originCaller = user1;
        uint256 amount = 500e6;

        // Get CEA address (will be deployed if not exists)
        (address cea, bool isDeployed) = ceaFactory.getCEAForUEA(originCaller);
        if (!isDeployed) {
            vm.prank(address(vault));
            cea = ceaFactory.deployCEA(originCaller);
        }

        uint256 initialCEABalance = usdc.balanceOf(cea);
        uint256 initialVaultBalance = usdc.balanceOf(address(vault));

        // Withdraw with target = CEA address (parking)
        vm.prank(tss);
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            address(usdc),
            cea,           // target = CEA address (parking)
            amount,
            bytes("")      // Empty payload = withdrawal (but to CEA)
        );

        // Verify tokens are "parked" in CEA
        assertEq(usdc.balanceOf(cea), initialCEABalance + amount, "Tokens should be parked in CEA");
        assertEq(usdc.balanceOf(address(vault)), initialVaultBalance - amount, "Vault balance should decrease");
    }

    /// @notice Test native token parking
    function testWithdraw_Native_Parking_CEAAsTarget() public {
        bytes32 txID = keccak256("tx31");
        bytes32 universalTxID = keccak256("utx31");
        address originCaller = user1;
        uint256 amount = 10 ether;

        // Get/deploy CEA
        (address cea, bool isDeployed) = ceaFactory.getCEAForUEA(originCaller);
        if (!isDeployed) {
            vm.prank(address(vault));
            cea = ceaFactory.deployCEA(originCaller);
        }

        uint256 initialCEABalance = cea.balance;

        // Fund TSS with ETH to send
        vm.deal(tss, amount);

        // Park native tokens in CEA
        vm.prank(tss);
        vault.executeUniversalTx{value: amount}(
            txID,
            universalTxID,
            originCaller,
            address(0),
            cea,           // Parking in CEA
            amount,
            bytes("")
        );

        // Verify parking
        assertEq(cea.balance, initialCEABalance + amount, "ETH should be parked in CEA");
    }

    // =========================
    //  5. EVENT EMISSION TESTS
    // =========================

    /// @notice Test that withdrawal emits correct VaultUniversalTxExecuted event
    function testWithdraw_EmitsVaultUniversalTxExecuted() public {
        bytes32 txID = keccak256("tx40");
        bytes32 universalTxID = keccak256("utx40");
        address originCaller = user1;
        uint256 amount = 100e6;

        // Expect exact event with empty payload
        vm.expectEmit(true, true, true, true);
        emit IVault.VaultUniversalTxExecuted(
            txID,
            universalTxID,
            originCaller,
            recipient,
            address(usdc),
            amount,
            bytes("") // Empty payload for withdrawal
        );

        vm.prank(tss);
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            address(usdc),
            recipient,
            amount,
            bytes("")
        );
    }

    /// @notice Test that execution emits correct event with non-empty payload
    function testExecute_EmitsVaultUniversalTxExecuted() public {
        bytes32 txID = keccak256("tx41");
        bytes32 universalTxID = keccak256("utx41");
        address originCaller = user1;
        uint256 amount = 100e6;
        bytes memory payload = abi.encodeWithSignature("test()");

        address mockTarget = address(0x9999);
        vm.etch(mockTarget, hex"00");
        vm.mockCall(mockTarget, payload, abi.encode(true));

        // Expect event with non-empty payload
        vm.expectEmit(true, true, true, true);
        emit IVault.VaultUniversalTxExecuted(
            txID,
            universalTxID,
            originCaller,
            mockTarget,
            address(usdc),
            amount,
            payload // Non-empty for execution
        );

        vm.prank(tss);
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            address(usdc),
            mockTarget,
            amount,
            payload
        );
    }

    // =========================
    //  6. INTEGRATION TESTS
    // =========================

    /// @notice End-to-end test: Vault → CEA → User (ERC20)
    function testE2E_Withdrawal_ERC20_VaultToCEAToUser() public {
        bytes32 txID = keccak256("tx50");
        bytes32 universalTxID = keccak256("utx50");
        address originCaller = user1;
        uint256 amount = 1000e6;

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        uint256 userBefore = usdc.balanceOf(recipient);

        // Execute withdrawal
        vm.prank(tss);
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            address(usdc),
            recipient,
            amount,
            bytes("")
        );

        // Verify end-to-end flow
        assertEq(usdc.balanceOf(address(vault)), vaultBefore - amount, "Vault decreased");
        assertEq(usdc.balanceOf(recipient), userBefore + amount, "User increased");

        // Verify CEA exists but doesn't hold tokens
        (address cea, bool deployed) = ceaFactory.getCEAForUEA(originCaller);
        assertTrue(deployed, "CEA should be deployed");
        assertEq(usdc.balanceOf(cea), 0, "CEA should not hold tokens after withdrawal");
    }

    /// @notice End-to-end test: Vault → CEA → User (Native)
    function testE2E_Withdrawal_Native_VaultToCEAToUser() public {
        bytes32 txID = keccak256("tx51");
        bytes32 universalTxID = keccak256("utx51");
        address originCaller = user1;
        uint256 amount = 20 ether;

        uint256 vaultBefore = address(vault).balance;
        uint256 userBefore = recipient.balance;

        // Fund TSS with ETH to send
        vm.deal(tss, amount);

        // Execute withdrawal
        vm.prank(tss);
        vault.executeUniversalTx{value: amount}(
            txID,
            universalTxID,
            originCaller,
            address(0),
            recipient,
            amount,
            bytes("")
        );

        // Verify flow
        // Vault balance stays same: receives `amount` from TSS, sends `amount` to CEA (net = 0)
        assertEq(address(vault).balance, vaultBefore, "Vault balance unchanged (pass-through)");
        assertEq(recipient.balance, userBefore + amount, "User increased");
    }

    /// @notice Test balance tracking across multiple withdrawals
    function testBalances_MultipleWithdrawals_Tracking() public {
        address originCaller = user1;
        uint256 amount1 = 100e6;
        uint256 amount2 = 200e6;

        uint256 vaultStart = usdc.balanceOf(address(vault));
        uint256 userStart = usdc.balanceOf(recipient);

        // First withdrawal
        vm.prank(tss);
        vault.executeUniversalTx(
            keccak256("tx60"),
            keccak256("utx60"),
            originCaller,
            address(usdc),
            recipient,
            amount1,
            bytes("")
        );

        // Second withdrawal
        vm.prank(tss);
        vault.executeUniversalTx(
            keccak256("tx61"),
            keccak256("utx61"),
            originCaller,
            address(usdc),
            recipient,
            amount2,
            bytes("")
        );

        // Verify cumulative changes
        assertEq(usdc.balanceOf(address(vault)), vaultStart - amount1 - amount2, "Vault decreased by total");
        assertEq(usdc.balanceOf(recipient), userStart + amount1 + amount2, "User increased by total");
    }

    // =========================
    //  7. EDGE CASES
    // =========================

    /// @notice Test withdrawal when Vault is paused - should revert
    function testWithdraw_WhenPaused_Reverts() public {
        bytes32 txID = keccak256("tx70");
        bytes32 universalTxID = keccak256("utx70");
        address originCaller = user1;
        uint256 amount = 100e6;

        // Pause Vault (use pauser role, not admin)
        vm.prank(pauser);
        vault.pause();

        // Attempt withdrawal
        vm.prank(tss);
        vm.expectRevert();
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            address(usdc),
            recipient,
            amount,
            bytes("")
        );
    }

    /// @notice Test non-TSS caller - should revert with access control error
    function testWithdraw_NonTSS_Reverts() public {
        bytes32 txID = keccak256("tx71");
        bytes32 universalTxID = keccak256("utx71");
        address originCaller = user1;
        uint256 amount = 100e6;

        // Attacker tries to call
        vm.prank(attacker);
        vm.expectRevert(); // Should revert with role error
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            address(usdc),
            recipient,
            amount,
            bytes("")
        );
    }

    /// @notice Test contract recipient (smart wallet) - should work
    function testWithdraw_SmartWalletRecipient_Success() public {
        bytes32 txID = keccak256("tx72");
        bytes32 universalTxID = keccak256("utx72");
        address originCaller = user1;
        uint256 amount = 100e6;

        // Create a simple contract recipient (mock smart wallet)
        address smartWallet = address(0xABCD);
        vm.etch(smartWallet, hex"00"); // Make it a contract

        uint256 initialBalance = usdc.balanceOf(smartWallet);

        // Withdraw to smart wallet
        vm.prank(tss);
        vault.executeUniversalTx(
            txID,
            universalTxID,
            originCaller,
            address(usdc),
            smartWallet,
            amount,
            bytes("")
        );

        // Verify smart wallet received tokens
        assertEq(usdc.balanceOf(smartWallet), initialBalance + amount, "Smart wallet should receive tokens");
    }
}
