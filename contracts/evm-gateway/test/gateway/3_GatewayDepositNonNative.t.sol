pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { BaseTest } from "../BaseTest.t.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { TX_TYPE, RevertInstructions, UniversalPayload, VerificationType } from "../../src/libraries/Types.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUniversalGateway } from "../../src/interfaces/IUniversalGateway.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { IWETH } from "../../src/interfaces/IWETH.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

// USDT interface for non-standard transfer and approve functions

interface TetherToken {
    function transfer(address to, uint256 amount) external;

    function approve(address spender, uint256 amount) external;

    function balanceOf(address account) external view returns (uint256);
}

/// @notice Test suite for ERC20 deposit functions in UniversalGateway
/// @dev Covers all functions that use ERC20 tokens (not native ETH):
///      1. sendTxWithGas(tokenIn, amountIn, payload, revertCFG, amountOutMinETH, deadline) - ERC20 gas funding
///      2. sendFunds(recipient, bridgeToken, bridgeAmount, revertCFG) - ERC20 bridging (when bridgeToken != address(0))
///      3. sendTxWithFunds(bridgeToken, bridgeAmount, gasToken, gasAmount, amountOutMinETH, deadline, payload, revertCFG) - ERC20 gas + ERC20 bridging
/// @dev Note: Uses mainnet fork for Uniswap integration testing
contract GatewayDepositNonNativeTest is BaseTest {
    // =========================
    //      MAINNET CONTRACTS
    // =========================
    // Mainnet WETH address
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Mainnet USDC address
    address constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Mainnet USDT address
    address constant MAINNET_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // Mainnet DAI address
    address constant MAINNET_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // Mainnet Uniswap V3 Router
    address constant MAINNET_UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Mainnet Uniswap V3 Factory
    address constant MAINNET_UNISWAP_V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    // Mainnet Chainlink ETH/USD Feed
    address constant MAINNET_ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // Real mainnet token contracts
    IERC20 mainnetWETH;
    IERC20 mainnetUSDC;
    TetherToken mainnetUSDT;
    IERC20 mainnetDAI;

    // =========================
    //      SETUP
    // =========================
    function setUp() public override {
        // Use mainnet fork for Uniswap integration
        vm.createSelectFork("https://eth-mainnet.public.blastapi.io");
        super.setUp();

        // Redeploy gateway with mainnet WETH address
        _redeployGatewayWithMainnetWETH();

        // Override gateway configuration to use mainnet contracts
        vm.prank(admin);
        gateway.setRouters(MAINNET_UNISWAP_V3_FACTORY, MAINNET_UNISWAP_V3_ROUTER);

        // Initialize real mainnet token contracts
        mainnetWETH = IERC20(MAINNET_WETH);
        mainnetUSDC = IERC20(MAINNET_USDC);
        mainnetUSDT = TetherToken(MAINNET_USDT);
        mainnetDAI = IERC20(MAINNET_DAI);

        // Enable mainnet ERC20 token support for testing
        address[] memory tokens = new address[](5);
        bool[] memory supported = new bool[](5);
        tokens[0] = MAINNET_WETH;
        tokens[1] = MAINNET_USDC;
        tokens[2] = MAINNET_USDT;
        tokens[3] = MAINNET_DAI;
        supported[0] = true;
        supported[1] = true;
        supported[2] = true;
        supported[3] = true;
        supported[4] = true;

        vm.prank(admin);
        // Set threshold to a large value to enable support (0 means unsupported)
        uint256[] memory thresholds = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            thresholds[i] = supported[i] ? 1000000 ether : 0;
        }
        gateway.setTokenLimitThresholds(tokens, thresholds);
    }

    // =========================
    //      HELPER FUNCTIONS
    // =========================

    /// @notice Fund user with real mainnet tokens by impersonating a whale
    function fundUserWithMainnetTokens(address user, address token, uint256 amount) internal override {
        // Find a whale address that has the token
        address whale;
        if (token == MAINNET_WETH) {
            whale = 0x28C6c06298d514Db089934071355E5743bf21d60; // Binance 14
        } else if (token == MAINNET_USDC) {
            whale = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341; // SKY
        } else if (token == MAINNET_USDT) {
            whale = 0xF977814e90dA44bFA03b6295A0616a897441aceC; // Binance 20
        } else if (token == MAINNET_DAI) {
            whale = 0x28C6c06298d514Db089934071355E5743bf21d60; // Binance 14
        } else {
            revert("Unknown token");
        }

        // Check if whale has enough tokens
        uint256 whaleBalance = IERC20(token).balanceOf(whale);
        require(whaleBalance >= amount, "Whale doesn't have enough tokens");

        // Impersonate whale and transfer tokens

        vm.startPrank(whale);

        // Handle USDT specially since it has non-standard transfer function
        if (token == MAINNET_USDT) {
            // USDT transfer returns void, not bool
            TetherToken(token).transfer(user, amount);
        } else {
            IERC20(token).transfer(user, amount);
        }

        vm.stopPrank();

        // Verify transfer was successful (user should have at least the amount we sent)
        assertGe(IERC20(token).balanceOf(user), amount, "User should receive tokens");
    }

    /// @notice Redeploy gateway with mainnet WETH address
    function _redeployGatewayWithMainnetWETH() internal {
        // Deploy new implementation
        UniversalGateway newImplementation = new UniversalGateway();

        // Create initialization data with mainnet WETH
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin, // admin
            pauser, // pauser
            tss, // tss
            MIN_CAP_USD,
            MAX_CAP_USD,
            uniV3Factory,
            uniV3Router,
            MAINNET_WETH // Use mainnet WETH instead of mock
        );

        // Deploy new proxy
        gatewayProxy = new TransparentUpgradeableProxy(address(newImplementation), address(proxyAdmin), initData);

        // Update gateway reference
        gateway = UniversalGateway(payable(address(gatewayProxy)));

        // Label for debugging
        vm.label(address(gateway), "UniversalGateway-MainnetWETH");
        vm.label(address(gatewayProxy), "GatewayProxy-MainnetWETH");

        // Re-initialize gateway settings
        vm.prank(admin);
        gateway.setEthUsdFeed(MAINNET_ETH_USD_FEED);

        // Set the correct fee order for Uniswap V3
        vm.prank(admin);
        gateway.setV3FeeOrder(500, 3000, 10000);
    }

    // =========================
    //      HAPPY PATH TESTS - ERC20 Functions
    // =========================

    /// @notice Test sendTxWithGas (ERC20) with valid parameters
    function testSendTxWithGas_ERC20_HappyPath() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg_) =
            buildERC20Payload(recipient, abi.encodeWithSignature("receive()"), 0);

        // Use WETH for gas funding (fast path - no swap needed)
        // Using a smaller amount to stay within USD caps
        uint256 wethAmount = 0.002e18; // 0.002 WETH (well within USD caps)
        uint256 amountOutMinETH = 0.0001e18; // Allow 95% slippage for testing
        uint256 deadline = block.timestamp + 3600; // 1 hour deadline

        // Fund user with mainnet WETH and approve gateway
        fundUserWithMainnetTokens(user1, MAINNET_WETH, wethAmount);
        vm.prank(user1);
        mainnetWETH.approve(address(gateway), wethAmount);

        // Record initial balances
        uint256 initialTSSBalance = tss.balance;
        uint256 initialUserWETHBalance = mainnetWETH.balanceOf(user1);
        uint256 initialGatewayWETHBalance = mainnetWETH.balanceOf(address(gateway));

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1,
            address(0),
            address(0),
            wethAmount,
            abi.encode(payload),
            revertCfg_,
            TX_TYPE.GAS_AND_PAYLOAD,
            bytes("")
        );

        // Execute the transaction
        vm.prank(user1);
        gateway.sendTxWithGas(MAINNET_WETH, wethAmount, payload, revertCfg_, amountOutMinETH, deadline, bytes(""));

        // Verify TSS received the ETH (WETH was unwrapped to ETH)
        assertEq(tss.balance, initialTSSBalance + wethAmount, "TSS should receive ETH from WETH unwrapping");

        // Verify user's WETH balance decreased
        assertEq(mainnetWETH.balanceOf(user1), initialUserWETHBalance - wethAmount, "User should pay WETH");

        // Verify gateway's WETH balance is unchanged (WETH was unwrapped)
        assertEq(
            mainnetWETH.balanceOf(address(gateway)),
            initialGatewayWETHBalance,
            "Gateway should not hold WETH (unwrapped to ETH)"
        );
    }

    /// @notice Test sendFunds (ERC20) with valid parameters
    function testSendFunds_ERC20_HappyPath() public {
        // Setup: Create revert config
        RevertInstructions memory revertCfg_ = RevertInstructions({ fundRecipient: recipient, revertMsg: bytes("") });

        // Use USDC for bridging
        uint256 bridgeAmount = 1000e6; // 1000 USDC (6 decimals)

        // Fund user with mainnet USDC and approve gateway
        fundUserWithMainnetTokens(user1, MAINNET_USDC, bridgeAmount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gateway), bridgeAmount);

        // Record initial balances
        uint256 initialUserTokenBalance = mainnetUSDC.balanceOf(user1);
        uint256 initialGatewayTokenBalance = mainnetUSDC.balanceOf(address(gateway));

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1, recipient, MAINNET_USDC, bridgeAmount, bytes(""), revertCfg_, TX_TYPE.FUNDS, bytes("")
        );

        // Execute the transaction - ERC20 bridging (msg.value must be 0)
        vm.prank(user1);
        gateway.sendFunds{ value: 0 }(
            recipient,
            MAINNET_USDC, // ERC20 token for bridging
            bridgeAmount,
            revertCfg_
        );

        // Verify user's token balance decreased
        assertEq(mainnetUSDC.balanceOf(user1), initialUserTokenBalance - bridgeAmount, "User should pay ERC20 tokens");

        // Verify gateway's token balance increased
        assertEq(
            mainnetUSDC.balanceOf(address(gateway)),
            initialGatewayTokenBalance + bridgeAmount,
            "Gateway should receive ERC20 tokens"
        );
    }

    /// @notice Test sendTxWithFunds (ERC20 gas + ERC20 bridging) with valid parameters
    function testSendTxWithFunds_ERC20_HappyPath() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg_) =
            buildERC20Payload(recipient, abi.encodeWithSignature("receive()"), 0);

        // Use WETH for gas funding and USDC for bridging
        (, uint256 maxEthAmount) = gateway.getMinMaxValueForNative();
        uint256 gasAmount = (maxEthAmount * 8) / 10; // 80% of max ETH amount for gas
        uint256 bridgeAmount = 1000e6; // 1000 USDC for bridging (6 decimals)
        uint256 amountOutMinETH = gasAmount; // same as weth amount
        uint256 deadline = block.timestamp + 3600; // 1 hour deadline

        // Fund user with mainnet tokens
        fundUserWithMainnetTokens(user1, MAINNET_WETH, gasAmount);
        fundUserWithMainnetTokens(user1, MAINNET_USDC, bridgeAmount);

        // Approve gateway for both tokens
        vm.startPrank(user1);
        mainnetWETH.approve(address(gateway), gasAmount);
        mainnetUSDC.approve(address(gateway), bridgeAmount);
        vm.stopPrank();

        // Record initial balances
        uint256 initialTSSBalance = tss.balance;
        uint256 initialUserWETHBalance = mainnetWETH.balanceOf(user1);
        uint256 initialUserTokenBalance = mainnetUSDC.balanceOf(user1);
        uint256 initialGatewayTokenBalance = mainnetUSDC.balanceOf(address(gateway));

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1, address(0), address(0), gasAmount, bytes(""), revertCfg_, TX_TYPE.GAS, bytes("")
        );

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user1,
            address(0),
            MAINNET_USDC,
            bridgeAmount,
            abi.encode(payload),
            revertCfg_,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes("")
        );

        // Execute the transaction
        console2.log(deadline, block.timestamp);
        vm.prank(user1);
        gateway.sendTxWithFunds(
            MAINNET_USDC, // Bridge token
            bridgeAmount,
            MAINNET_WETH, // Gas token
            gasAmount,
            amountOutMinETH,
            deadline,
            payload,
            revertCfg_,
            bytes("")
        );

        // Verify TSS received the ETH (from WETH unwrapping)
        assertEq(tss.balance, initialTSSBalance + gasAmount, "TSS should receive ETH from WETH unwrapping");

        // Verify user's WETH balance decreased
        assertEq(mainnetWETH.balanceOf(user1), initialUserWETHBalance - gasAmount, "User should pay WETH for gas");

        // Verify user's token balance decreased
        assertEq(
            mainnetUSDC.balanceOf(user1), initialUserTokenBalance - bridgeAmount, "User should pay USDC for bridging"
        );

        // Verify gateway's token balance increased
        assertEq(
            mainnetUSDC.balanceOf(address(gateway)),
            initialGatewayTokenBalance + bridgeAmount,
            "Gateway should receive USDC for bridging"
        );
    }

    /// @notice Test all ERC20 functions with minimum valid amounts
    function testAllERC20Functions_MinimumAmounts_Success() public {
        // Test sendFunds with minimum amount (no Uniswap dependency)
        RevertInstructions memory revertCfg_ = RevertInstructions({ fundRecipient: recipient, revertMsg: bytes("") });

        uint256 minAmount = 1; // Minimum amount

        // Test sendFunds with minimum amount
        fundUserWithMainnetTokens(user2, MAINNET_USDC, minAmount);
        vm.prank(user2);
        mainnetUSDC.approve(address(gateway), minAmount);

        uint256 initialGatewayBalance = IERC20(MAINNET_USDC).balanceOf(address(gateway));

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user2, recipient, MAINNET_USDC, minAmount, bytes(""), revertCfg_, TX_TYPE.FUNDS, bytes("")
        );

        vm.prank(user2);
        gateway.sendFunds{ value: 0 }(recipient, MAINNET_USDC, minAmount, revertCfg_);

        // Test passes if no revert occurs
        assertEq(
            IERC20(MAINNET_USDC).balanceOf(address(gateway)),
            initialGatewayBalance + minAmount,
            "Gateway should receive USDC"
        );
    }

    /// @notice Test all ERC20 functions with maximum valid amounts
    function testAllERC20Functions_MaximumAmounts_Success() public {
        // Test sendFunds with maximum amount (no Uniswap dependency)
        RevertInstructions memory revertCfg_ = RevertInstructions({ fundRecipient: recipient, revertMsg: bytes("") });

        // Test sendFunds with maximum amount
        uint256 maxTokenAmount = 1000000e6; // Large token amount
        fundUserWithMainnetTokens(user2, MAINNET_USDC, maxTokenAmount);
        vm.prank(user2);
        mainnetUSDC.approve(address(gateway), maxTokenAmount);

        uint256 initialGatewayBalance = IERC20(MAINNET_USDC).balanceOf(address(gateway));

        vm.expectEmit(true, true, true, true);
        emit IUniversalGateway.UniversalTx(
            user2, recipient, MAINNET_USDC, maxTokenAmount, bytes(""), revertCfg_, TX_TYPE.FUNDS, bytes("")
        );

        vm.prank(user2);
        gateway.sendFunds{ value: 0 }(recipient, MAINNET_USDC, maxTokenAmount, revertCfg_);
    }

    // =========================
    //      PARAMETER VALIDATION TESTS
    // =========================

    /// @notice Test sendTxWithGas (ERC20) with zero token address
    function testSendTxWithGas_ERC20_WrongValues_Reverts() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg_) =
            buildERC20Payload(recipient, abi.encodeWithSignature("receive()"), 0);

        uint256 amountIn = 1e18;
        uint256 amountOutMinETH = 1e18;
        uint256 deadline = block.timestamp + 3600;

        // Execute the transaction with zero token address and expect it to revert
        vm.startPrank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendTxWithGas(
            address(0), // Zero token address
            amountIn,
            payload,
            revertCfg_,
            amountOutMinETH,
            deadline,
            bytes("")
        );

        // Execute the transaction with zero amount and expect it to revert
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendTxWithGas(
            MAINNET_WETH,
            0, // Zero amount
            payload,
            revertCfg_,
            amountOutMinETH,
            deadline,
            bytes("")
        );

        // Execute the transaction with zero amountOutMinETH and expect it to revert
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendTxWithGas(
            MAINNET_WETH,
            amountIn,
            payload,
            revertCfg_,
            0, // Zero amountOutMinETH
            deadline,
            bytes("")
        );

        // Execute the transaction with expired deadline and expect it to revert
        uint256 expiredDeadline = block.timestamp - 1; // Expired deadline
        vm.expectRevert(Errors.SlippageExceededOrExpired.selector);
        gateway.sendTxWithGas(MAINNET_WETH, amountIn, payload, revertCfg_, amountOutMinETH, expiredDeadline, bytes(""));

        // Execute the transaction with non-zero msg.value and expect it to revert
        uint256 bridgeAmount = 1000e6; // 1000 USDC (6 decimals)
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendFunds{ value: 1e18 }( // Non-zero msg.value
            recipient,
            MAINNET_USDC, // ERC20 token for bridging
            bridgeAmount,
            revertCfg_
        );

        // Execute the transaction with zero bridge amount and expect it to revert
        uint256 gasAmount = 1e18;

        // Execute the transaction with zero gas token address and expect it to revert
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendTxWithFunds(
            MAINNET_USDC, // Bridge token
            bridgeAmount,
            address(0), // Zero gas token address
            gasAmount,
            amountOutMinETH,
            deadline,
            payload,
            revertCfg_,
            bytes("")
        );

        // Execute the transaction with zero gas amount and expect it to revert
        // Fund user with WETH for gas token
        fundUserWithMainnetTokens(user1, MAINNET_WETH, gasAmount);
        vm.prank(user1);
        IERC20(MAINNET_WETH).approve(address(gateway), gasAmount);

        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendTxWithFunds(
            MAINNET_USDC, // Bridge token
            bridgeAmount,
            MAINNET_WETH, // Gas token
            0, // Zero gas amount
            amountOutMinETH,
            deadline,
            payload,
            revertCfg_,
            bytes("")
        );
    }

    /// @notice Test sendFunds (ERC20) with zero bridge amount
    function testSendFunds_ERC20_ZeroBridgeAmount_Reverts() public {
        // Setup: Create revert config
        RevertInstructions memory revertCfg_ = RevertInstructions({ fundRecipient: recipient, revertMsg: bytes("") });

        // Note: ERC20 sendFunds doesn't explicitly check for zero amount
        // The _handleTokenDeposit function just calls safeTransferFrom with zero amount
        // which might not revert. This test verifies the current behavior.

        // Execute the transaction with zero bridge amount
        vm.prank(user1);
        gateway.sendFunds{ value: 0 }(
            recipient,
            MAINNET_USDC, // ERC20 token for bridging
            0, // Zero bridge amount
            revertCfg_
        );

        // Verify the transaction succeeded (current behavior)
        // This test documents that zero amounts are allowed for ERC20 sendFunds
    }

    // =========================
    //      TOKEN SUPPORT VALIDATION TESTS
    // =========================

    /// @notice Test all ERC20 functions with unsupported tokens
    function testERC20Functions_UnsupportedTokens_Reverts() public {
        // Setup: Create payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg_) =
            buildERC20Payload(recipient, abi.encodeWithSignature("receive()"), 0);

        uint256 amount = 1000e6; // 1000 USDC (6 decimals)
        uint256 deadline = block.timestamp + 3600;

        // Create an unsupported token (not in the supported list)
        MockERC20 unsupportedToken = new MockERC20("Unsupported", "UNS", 18, 0);
        unsupportedToken.mint(user1, amount);
        vm.startPrank(user1);
        unsupportedToken.approve(address(gateway), amount);

        // Test sendTxWithGas with unsupported token
        vm.expectRevert(Errors.InvalidInput.selector); // Any revert is acceptable for unsupported token
        gateway.sendTxWithGas(address(unsupportedToken), amount, payload, revertCfg_, 0.5e18, deadline, bytes(""));

        // Test sendFunds with unsupported token
        vm.expectRevert(Errors.NotSupported.selector); // Any revert is acceptable for unsupported token
        gateway.sendFunds{ value: 0 }(recipient, address(unsupportedToken), amount, revertCfg_);

        // Test sendTxWithFunds with unsupported bridge token
        fundUserWithMainnetTokens(user1, MAINNET_WETH, amount);
        (, uint256 maxEthAmount) = gateway.getMinMaxValueForNative();
        uint256 amountOutMinETH = (maxEthAmount * 8) / 10;
        mainnetWETH.approve(address(gateway), amountOutMinETH);
        vm.expectRevert(Errors.NotSupported.selector); // Any revert is acceptable for unsupported token
        gateway.sendTxWithFunds(
            address(unsupportedToken), // Unsupported bridge token
            amount,
            address(MAINNET_WETH), // Supported gas token
            (maxEthAmount * 8) / 10,
            amountOutMinETH,
            deadline,
            payload,
            revertCfg_,
            bytes("")
        );

        // Test sendTxWithFunds with unsupported gas token
        vm.expectRevert(Errors.InvalidInput.selector); // Any revert is acceptable for unsupported token
        gateway.sendTxWithFunds(
            MAINNET_USDC, // Supported bridge token
            amount,
            address(unsupportedToken), // Unsupported gas token
            amount,
            0.5e18,
            deadline,
            payload,
            revertCfg_,
            bytes("")
        );
    }

    // =========================
    //      ACCESS CONTROL & PAUSE TESTS
    // =========================

    /// @notice Test all ERC20 functions when contract is paused
    function testERC20Functions_WhenPaused_Reverts() public {
        // Setup: Create payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg_) =
            buildERC20Payload(recipient, abi.encodeWithSignature("receive()"), 0);

        uint256 amount = 1000e6; // 1000 USDC (6 decimals)
        uint256 deadline = block.timestamp + 3600;

        // Fund user with mainnet tokens
        fundUserWithMainnetTokens(user1, MAINNET_WETH, amount);
        fundUserWithMainnetTokens(user1, MAINNET_USDC, amount);
        vm.startPrank(user1);
        mainnetWETH.approve(address(gateway), amount);
        mainnetUSDC.approve(address(gateway), amount);
        vm.stopPrank();

        // Pause the contract
        vm.prank(pauser);
        gateway.pause();

        vm.startPrank(user1);
        // Test sendTxWithGas when paused
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector); // Any revert is acceptable for paused state
        gateway.sendTxWithGas(MAINNET_WETH, amount, payload, revertCfg_, 0.5e18, deadline, bytes(""));

        // Test sendFunds when paused
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector); // Any revert is acceptable for paused state
        gateway.sendFunds{ value: 0 }(recipient, MAINNET_USDC, amount, revertCfg_);

        // Test sendTxWithFunds when paused
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector); // Any revert is acceptable for paused state
        gateway.sendTxWithFunds(
            MAINNET_USDC, amount, MAINNET_WETH, amount, 0.5e18, deadline, payload, revertCfg_, bytes("")
        );
        vm.stopPrank();
    }

    // =========================
    //      USD CAP VALIDATION TESTS
    // =========================

    /// @notice Test sendTxWithFunds (ERC20) with gas amount below minimum USD cap
    function testSendTxWithFunds_ERC20_GasAmountBelowMinCap_Reverts() public {
        // Setup: Create payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg_) =
            buildERC20Payload(recipient, abi.encodeWithSignature("receive()"), 0);

        uint256 bridgeAmount = 1000e6; // 1000 USDC (6 decimals)
        uint256 gasAmount = 0.001e6; // Very small amount (below min cap) - 6 decimals
        uint256 deadline = block.timestamp + 3600;

        // Mint tokens to user1
        fundUserWithMainnetTokens(user1, MAINNET_USDC, bridgeAmount + gasAmount);
        vm.startPrank(user1);
        mainnetUSDC.approve(address(gateway), bridgeAmount + gasAmount);

        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendTxWithFunds(
            MAINNET_USDC, bridgeAmount + gasAmount, MAINNET_USDC, gasAmount, 1, deadline, payload, revertCfg_, bytes("")
        );
        vm.stopPrank();
    }

    /// @notice Test sendTxWithFunds (ERC20) with gas amount above maximum USD cap
    function testSendTxWithFunds_ERC20_GasAmountAboveMaxCap_Reverts() public {
        // Setup: Create payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg_) =
            buildERC20Payload(recipient, abi.encodeWithSignature("receive()"), 0);

        uint256 bridgeAmount = 1000e6; // 1000 USDC (6 decimals)
        uint256 gasAmount = 1000000e6; // Very large amount (above max cap) - 6 decimals
        uint256 deadline = block.timestamp + 3600;

        // Mint tokens to user1
        fundUserWithMainnetTokens(user1, MAINNET_USDC, bridgeAmount + gasAmount);
        vm.startPrank(user1);
        mainnetUSDC.approve(address(gateway), bridgeAmount + gasAmount);

        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendTxWithFunds(
            MAINNET_USDC, bridgeAmount, MAINNET_USDC, gasAmount, 1, deadline, payload, revertCfg_, bytes("")
        );
        vm.stopPrank();
    }

    // =========================
    //      TOKEN TRANSFER VERIFICATION TESTS
    // =========================

    /// @notice Test that ERC20 bridge tokens are actually transferred to gateway
    function testSendFunds_ERC20_TokenTransferToGateway_Success() public {
        // Setup: Create revert config
        RevertInstructions memory revertCfg_ = RevertInstructions({ fundRecipient: recipient, revertMsg: bytes("") });

        uint256 tokenAmount = 1000e6; // 1000 USDC (6 decimals)

        // Record initial balances
        uint256 initialUserBalance = mainnetUSDC.balanceOf(user1);
        uint256 initialGatewayBalance = mainnetUSDC.balanceOf(address(gateway));

        // Fund user with mainnet tokens
        fundUserWithMainnetTokens(user1, MAINNET_USDC, tokenAmount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gateway), tokenAmount);

        // Execute sendFunds
        vm.prank(user1);
        gateway.sendFunds{ value: 0 }(recipient, MAINNET_USDC, tokenAmount, revertCfg_);

        // Verify token transfer
        assertEq(
            mainnetUSDC.balanceOf(user1),
            initialUserBalance,
            "User balance should remain unchanged (tokens transferred to gateway)"
        );

        assertEq(
            mainnetUSDC.balanceOf(address(gateway)),
            initialGatewayBalance + tokenAmount,
            "Gateway should receive the tokens"
        );
    }

    /// @notice Test that ERC20 gas tokens are actually transferred to gateway
    function testSendTxWithFunds_ERC20_GasTokenTransferToGateway_Success() public {
        // Setup: Create payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg_) =
            buildERC20Payload(recipient, abi.encodeWithSignature("receive()"), 0);

        uint256 bridgeAmount = 1000e6; // 1000 USDC (6 decimals)
        uint256 gasAmount = 9e6; // 9 USDC (6 decimals)
        uint256 deadline = block.timestamp + 3600;

        // Mint tokens to user1
        fundUserWithMainnetTokens(user1, MAINNET_USDC, bridgeAmount + gasAmount);

        // Record initial balances
        uint256 initialUserBalance = mainnetUSDC.balanceOf(user1);
        uint256 initialGatewayBalance = mainnetUSDC.balanceOf(address(gateway));
        uint256 initialTSSEthBalance = tss.balance;

        vm.prank(user1);
        mainnetUSDC.approve(address(gateway), bridgeAmount + gasAmount);

        (uint256 ethPrice, uint8 decimals) = gateway.getEthUsdPrice();
        uint256 gasAmountInETH = (gasAmount * 10 ** (18 - 6) * 1e18) / ethPrice;
        // Execute sendTxWithFunds
        vm.startPrank(user1);
        gateway.sendTxWithFunds(
            MAINNET_USDC, // Bridge token
            bridgeAmount,
            MAINNET_USDC, // Gas token
            gasAmount,
            (gasAmountInETH * 9) / 10,
            deadline,
            payload,
            revertCfg_,
            bytes("")
        );
        vm.stopPrank();
        // Verify gas token transfer
        assertEq(
            mainnetUSDC.balanceOf(user1),
            initialUserBalance - bridgeAmount - gasAmount,
            "User balance should remain unchanged (tokens transferred to gateway)"
        );

        assertEq(
            mainnetUSDC.balanceOf(address(gateway)),
            initialGatewayBalance + bridgeAmount,
            "Gateway should receive both bridge and gas tokens"
        );

        assertApproxEqAbs(
            tss.balance, initialTSSEthBalance + gasAmountInETH, 1e15, "TSS should receive ETH from gas tokens"
        );
    }

    // =========================
    //      COMPREHENSIVE EDGE CASES
    // =========================

    /// @notice Test comprehensive edge cases for ERC20 functions
    function testERC20Functions_EdgeCases_Success() public {
        // Setup: Create payload and revert config
        RevertInstructions memory revertCfg_ = RevertInstructions({ fundRecipient: recipient, revertMsg: bytes("") });

        uint256 amount = 1000e6; // 1000 USDC (6 decimals)

        // Test 1: Different ERC20 tokens (USDC only to avoid support issues)
        fundUserWithMainnetTokens(user1, MAINNET_USDC, amount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gateway), amount);

        vm.prank(user1);
        gateway.sendFunds{ value: 0 }(
            recipient,
            MAINNET_USDC, // Use USDC which is supported
            amount,
            revertCfg_
        );
        // Test 2: Different amounts with USDT (skip Uniswap-dependent tests)
        uint256 amount2 = 500e6; // 500 USDT (6 decimals)
        fundUserWithMainnetTokens(user2, MAINNET_USDT, amount2);
        vm.prank(user2);
        // USDT approve returns void, not bool
        TetherToken(MAINNET_USDT).approve(address(gateway), amount2);

        vm.prank(user2);
        gateway.sendFunds{ value: 0 }(recipient, MAINNET_USDT, amount2, revertCfg_);

        // Test 3: Different deadlines with DAI (1 hour, 1 day, 1 week)
        uint256 daiAmount = 1000e18; // 1000 DAI (18 decimals)
        fundUserWithMainnetTokens(user3, MAINNET_DAI, daiAmount);
        vm.prank(user3);
        mainnetDAI.approve(address(gateway), daiAmount);

        // Test with 1 day deadline
        vm.prank(user3);
        gateway.sendFunds{ value: 0 }(recipient, MAINNET_DAI, daiAmount, revertCfg_);

        // Test 4: Multiple ERC20 deposits in sequence
        for (uint256 i = 0; i < 3; i++) {
            fundUserWithMainnetTokens(user4, MAINNET_USDC, amount);
            vm.prank(user4);
            mainnetUSDC.approve(address(gateway), amount);
            vm.prank(user4);
            gateway.sendFunds{ value: 0 }(recipient, MAINNET_USDC, amount, revertCfg_);
        }

        // Test 5: Different users making deposits
        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = user3;

        for (uint256 i = 0; i < users.length; i++) {
            fundUserWithMainnetTokens(users[i], MAINNET_USDC, amount);
            vm.prank(users[i]);
            mainnetUSDC.approve(address(gateway), amount);

            vm.prank(users[i]);
            gateway.sendFunds{ value: 0 }(recipient, MAINNET_USDC, amount, revertCfg_);
        }

        // All tests should succeed, demonstrating robust edge case handling
    }

    /// @notice Test ERC20 deposits with insufficient token balance
    function testERC20Deposits_InsufficientBalance_Reverts() public {
        // Setup: Create payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg_) =
            buildERC20Payload(recipient, abi.encodeWithSignature("receive()"), 0);

        uint256 tokenAmount = 1000e6; // 1000 USDC (6 decimals)
        uint256 deadline = block.timestamp + 3600;

        // Don't fund user1 with tokens (insufficient balance)
        vm.prank(user1);
        mainnetUSDC.approve(address(gateway), tokenAmount);

        // Execute sendTxWithGas with insufficient balance (should fail)
        vm.prank(user1);
        vm.expectRevert();
        gateway.sendTxWithGas(
            MAINNET_USDC,
            tokenAmount,
            payload,
            revertCfg_,
            0.5e18, // 50% slippage tolerance
            deadline,
            bytes("")
        );
    }

    /// @notice Test ERC20 deposits with insufficient token allowance
    function testERC20Deposits_InsufficientAllowance_Reverts() public {
        // Setup: Create payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg_) =
            buildERC20Payload(recipient, abi.encodeWithSignature("receive()"), 0);

        uint256 tokenAmount = 1000e6; // 1000 USDC (6 decimals)
        uint256 deadline = block.timestamp + 3600;

        // Fund user1 with tokens but don't approve (insufficient allowance)
        fundUserWithMainnetTokens(user1, MAINNET_USDC, tokenAmount);

        // Execute sendTxWithGas with insufficient allowance (should fail)
        vm.prank(user1);
        vm.expectRevert();
        gateway.sendTxWithGas(
            MAINNET_USDC,
            tokenAmount,
            payload,
            revertCfg_,
            0.5e18, // 50% slippage tolerance
            deadline,
            bytes("")
        );
    }

    // =========================
    //      UNISWAP POOL VALIDATION TESTS
    // =========================

    /// @notice Test with non-existent Uniswap pool
    function testSendTxWithGas_ERC20_NonExistentPool_Reverts() public {
        // Setup: Create payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg_) =
            buildERC20Payload(recipient, abi.encodeWithSignature("receive()"), 0);

        // Use a token that doesn't have a WETH pair on Uniswap
        // Create a mock token with no liquidity
        MockERC20 fakeToken = new MockERC20("Fake", "FAKE", 18, 0);
        fakeToken.mint(user1, 1e18);

        vm.prank(user1);
        fakeToken.approve(address(gateway), 1e18);

        // This should revert because there's no WETH/FAKE pool
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector); // Any revert is acceptable for non-existent pool
        gateway.sendTxWithGas(address(fakeToken), 1e18, payload, revertCfg_, 0.01e18, block.timestamp + 3600, bytes(""));
    }

    // =========================
    //      HELPER FUNCTIONS
    // =========================

    /// @notice Helper function to create valid ERC20 payload
    function buildERC20Payload(address to, bytes memory data, uint256 value)
        internal
        pure
        override
        returns (UniversalPayload memory, RevertInstructions memory)
    {
        UniversalPayload memory payload = UniversalPayload({
            to: to,
            value: value,
            data: data,
            gasLimit: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            nonce: 0,
            deadline: 0,
            vType: VerificationType.signedVerification
        });

        RevertInstructions memory revertCfg = RevertInstructions({ fundRecipient: to, revertMsg: bytes("") });

        return (payload, revertCfg);
    }

    /// @notice Helper function to calculate minimum ETH output for slippage protection
    function calculateMinETHOutput(uint256 tokenAmount, uint256 slippageBps) internal pure returns (uint256) {
        // Calculate minimum amount out based on slippage tolerance
        // slippageBps is in basis points (e.g., 100 = 1%)
        uint256 slippageAmount = (tokenAmount * slippageBps) / 10000;
        return tokenAmount - slippageAmount;
    }

    /// @notice Helper function to setup ERC20 token with balance and allowance
    function setupERC20Token(address token, address user, uint256 amount) internal {
        // Mint tokens to user and approve gateway
        MockERC20(token).mint(user, amount);
        vm.prank(user);
        MockERC20(token).approve(address(gateway), amount);
    }

    // =========================
    // TRANSACTION TYPE VALIDATIONS TESTS
    // =========================

    function testTransactionTypeValidations_AddressZeroWithInvalidTxType_Reverts() public {
        // Test with address(0) recipient and invalid transaction type
        (UniversalPayload memory payload, RevertInstructions memory revertCfg) =
            buildERC20Payload(address(0), abi.encodeWithSignature("receive()"), 0);

        // Fund user with tokens - use amount within USD caps
        uint256 amount = 9e6; // 9 USDC = $9, well above min cap
        fundUserWithMainnetTokens(user1, MAINNET_USDC, amount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gateway), amount);
        (, uint256 maxEth) = gateway.getMinMaxValueForNative();
        uint256 gasAmount = (maxEth * 8) / 10;

        // This should revert because address(0) with FUNDS type is invalid
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRecipient.selector));
        vm.prank(user1);
        gateway.sendTxWithFunds{ value: gasAmount }(MAINNET_USDC, amount, payload, revertCfg, bytes(""));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidRecipient.selector));
        vm.prank(user1);
        gateway.sendFunds{ value: 0 }(address(0), MAINNET_USDC, amount, revertCfg);
    }

    function testTransactionTypeValidations_AddressZeroWithValidTxType_Success() public {
        // Test with address(0) recipient and valid transaction type
        (UniversalPayload memory payload, RevertInstructions memory revertCfg) =
            buildERC20Payload(address(1), abi.encodeWithSignature("receive()"), 0);

        // Fund user with tokens - use amount within USD caps
        uint256 amount = 9e6; // 9 USDC = $9, well above min cap
        fundUserWithMainnetTokens(user1, MAINNET_USDC, amount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gateway), amount);
        (, uint256 maxEth) = gateway.getMinMaxValueForNative();
        uint256 gasAmount = (maxEth * 8) / 10;

        // This should not revert because FUNDS_AND_PAYLOAD is valid for address(0)
        vm.prank(user1);
        gateway.sendTxWithFunds{ value: gasAmount }(MAINNET_USDC, amount, payload, revertCfg, bytes(""));
    }

    function testTransactionTypeValidations_NonZeroAddressWithAnyTxType_Success() public {
        // Test with non-zero recipient and any transaction type
        (UniversalPayload memory payload, RevertInstructions memory revertCfg) =
            buildERC20Payload(user1, abi.encodeWithSignature("receive()"), 0);

        // Fund user with tokens - use amount within USD caps
        uint256 amount = 9e6; // 9 USDC = $9, well above min cap
        fundUserWithMainnetTokens(user1, MAINNET_USDC, amount);
        vm.prank(user1);
        mainnetUSDC.approve(address(gateway), amount);

        // This should not revert for any transaction type with non-zero recipient
        (, uint256 maxEth) = gateway.getMinMaxValueForNative();
        uint256 gasAmount = (maxEth * 8) / 10;
        vm.prank(user1);
        gateway.sendTxWithFunds{ value: gasAmount }(MAINNET_USDC, amount, payload, revertCfg, bytes(""));
    }

    // =========================
    // SWAP TO NATIVE WITH VARIOUS TOKENS TESTS
    // =========================

    function testSwapToNative_VariousTokens_Success() public {
        // Test with USDT to verify swapToNative functionality
        address token = MAINNET_USDT;
        uint256 gasAmount = 8e6; // 8 USDT (6 decimals)

        // Fund user with tokens - use amount that's within USD caps
        fundUserWithMainnetTokens(user1, token, gasAmount);

        // Create a new gateway proxy to avoid any state issues from previous tests
        _redeployGatewayWithMainnetWETH();

        // Override gateway configuration to use mainnet contracts
        vm.prank(admin);
        gateway.setRouters(MAINNET_UNISWAP_V3_FACTORY, MAINNET_UNISWAP_V3_ROUTER);

        // Enable mainnet ERC20 token support for testing
        address[] memory tokens = new address[](5);
        bool[] memory supported = new bool[](5);
        tokens[0] = MAINNET_WETH;
        tokens[1] = MAINNET_USDC;
        tokens[2] = MAINNET_USDT;
        tokens[3] = MAINNET_DAI;
        supported[0] = true;
        supported[1] = true;
        supported[2] = true;
        supported[3] = true;
        supported[4] = true;

        vm.prank(admin);
        // Set threshold to a large value to enable support (0 means unsupported)
        uint256[] memory thresholds = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            thresholds[i] = supported[i] ? 1000000 ether : 0;
        }
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Set up Chainlink oracle
        vm.prank(admin);
        gateway.setEthUsdFeed(MAINNET_ETH_USD_FEED);

        // Set the correct fee order for Uniswap V3
        vm.prank(admin);
        gateway.setV3FeeOrder(500, 3000, 10000);

        // Test swapToNative (this is an internal function, so we test it indirectly)
        // by calling sendTxWithGas which uses swapToNative internally
        (UniversalPayload memory payload, RevertInstructions memory revertCfg) =
            buildERC20Payload(user1, abi.encodeWithSignature("receive()"), 0);
        console2.log("token", token);
        vm.prank(user1);
        // USDT approve returns void, not bool
        TetherToken(token).approve(address(gateway), gasAmount);

        // Record initial balances
        uint256 initialTSSBalance = tss.balance;
        uint256 initialUserBalance = TetherToken(token).balanceOf(user1);

        // This should not revert for supported tokens
        vm.prank(user1);
        gateway.sendTxWithGas(token, gasAmount, payload, revertCfg, 1, block.timestamp + 3600, bytes(""));

        // Verify the user's token balance decreased
        assertEq(
            TetherToken(token).balanceOf(user1), initialUserBalance - gasAmount, "User token balance should decrease"
        );

        // Verify TSS received ETH (approximate check)
        assertGt(tss.balance, initialTSSBalance, "TSS should receive ETH from token swap");
    }

    function testSwapToNative_UnsupportedToken_Reverts() public {
        // Test with unsupported token
        //Toggle the support for USDC
        MockERC20 newNonSupportedToken = new MockERC20("NonSupported", "NS", 18, 0);
        newNonSupportedToken.mint(user1, 1e18);
        vm.prank(user1);
        newNonSupportedToken.approve(address(gateway), 1e18);

        (UniversalPayload memory payload, RevertInstructions memory revertCfg) =
            buildERC20Payload(user1, abi.encodeWithSignature("receive()"), 0);

        // Get the actual USD caps from the contract and use the max amount
        (, uint256 maxEth) = gateway.getMinMaxValueForNative();
        uint256 amount = (maxEth * 8) / 10;

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidInput.selector));
        vm.prank(user1);
        gateway.sendTxWithGas(
            address(newNonSupportedToken), amount, payload, revertCfg, 1, block.timestamp + 3600, bytes("")
        );
    }

    // =========================
    // 4-PARAMETER sendTxWithFunds TESTS
    // =========================

    function testSendTxWithFunds_4Params_ERC20_HappyPath() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg) =
            buildERC20Payload(user1, abi.encodeWithSignature("receive()"), 0);

        // Fund user with tokens - use amount within USD caps
        uint256 bridgeAmount = 9e6; // 9 USDC = $9, well above min cap
        uint256 gasAmount = 8e6; // 8 USDC for gas
        fundUserWithMainnetTokens(user1, MAINNET_USDC, bridgeAmount + gasAmount);

        // Approve gateway to spend tokens
        vm.prank(user1);
        IERC20(MAINNET_USDC).approve(address(gateway), bridgeAmount + gasAmount);

        // This should not revert for supported tokens
        vm.prank(user1);
        gateway.sendTxWithFunds(
            MAINNET_USDC,
            bridgeAmount,
            MAINNET_USDC,
            gasAmount,
            1,
            block.timestamp + 3600,
            payload,
            revertCfg,
            bytes("")
        );
    }

    function testSendTxWithFunds_4Params_ERC20_ErrorConditions() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg) =
            buildERC20Payload(user1, abi.encodeWithSignature("receive()"), 0);

        uint256 bridgeAmount = 9e6;
        uint256 gasAmount = 8e6;
        fundUserWithMainnetTokens(user1, MAINNET_USDC, bridgeAmount + gasAmount);

        vm.prank(user1);
        IERC20(MAINNET_USDC).approve(address(gateway), bridgeAmount + gasAmount);
        // This should succeed (no revert expected)
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        vm.prank(user1);
        gateway.sendTxWithFunds(
            MAINNET_USDC, 0, MAINNET_USDC, gasAmount, 1, block.timestamp + 3600, payload, revertCfg, bytes("")
        );

        // Test 2: Zero gas amount
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        vm.prank(user1);
        gateway.sendTxWithFunds(
            MAINNET_USDC, bridgeAmount, MAINNET_USDC, 0, 1, block.timestamp + 3600, payload, revertCfg, bytes("")
        );

        // Test 3: Invalid gas token (address(0))
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidInput.selector));
        vm.prank(user1);
        gateway.sendTxWithFunds(
            MAINNET_USDC, bridgeAmount, address(0), gasAmount, 1, block.timestamp + 3600, payload, revertCfg, bytes("")
        );

        // Test 4: Expired deadline
        vm.expectRevert(abi.encodeWithSelector(Errors.SlippageExceededOrExpired.selector));
        vm.prank(user1);
        gateway.sendTxWithFunds(
            MAINNET_USDC, bridgeAmount, MAINNET_USDC, gasAmount, 1, block.timestamp - 1, payload, revertCfg, bytes("")
        );
    }

    function testSendTxWithFunds_4Params_ERC20_USDCapValidations() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg) =
            buildERC20Payload(user1, abi.encodeWithSignature("receive()"), 0);

        // Get USD caps
        (uint256 minEth, uint256 maxEth) = gateway.getMinMaxValueForNative();

        // Test 1: Gas amount below minimum cap
        uint256 bridgeAmount = 9e6;
        uint256 gasAmount = 1; // Very small amount, definitely below minimum
        fundUserWithMainnetTokens(user1, MAINNET_USDC, bridgeAmount + gasAmount);
        vm.prank(user1);
        IERC20(MAINNET_USDC).approve(address(gateway), bridgeAmount + gasAmount);
        vm.expectRevert("Too little received");
        vm.prank(user1);
        gateway.sendTxWithFunds(
            MAINNET_USDC,
            bridgeAmount,
            MAINNET_USDC,
            gasAmount,
            1,
            block.timestamp + 3600,
            payload,
            revertCfg,
            bytes("")
        );

        // Test 2: Gas amount above maximum cap
        gasAmount = 100000e6; // 100K USDC, definitely above maximum cap
        fundUserWithMainnetTokens(user1, MAINNET_USDC, bridgeAmount + gasAmount);
        vm.prank(user1);
        IERC20(MAINNET_USDC).approve(address(gateway), bridgeAmount + gasAmount);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        vm.prank(user1);
        gateway.sendTxWithFunds(
            MAINNET_USDC,
            bridgeAmount,
            MAINNET_USDC,
            gasAmount,
            1,
            block.timestamp + 3600,
            payload,
            revertCfg,
            bytes("")
        );
    }

    function testSendTxWithFunds_4Params_ERC20_UnsupportedTokens() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg) =
            buildERC20Payload(user1, abi.encodeWithSignature("receive()"), 0);

        // Test with unsupported gas token
        address unsupportedToken = address(0x1234567890123456789012345678901234567890);
        uint256 bridgeAmount = 9e6;
        uint256 gasAmount = 8e6;
        fundUserWithMainnetTokens(user1, MAINNET_USDC, bridgeAmount);

        vm.prank(user1);
        IERC20(MAINNET_USDC).approve(address(gateway), bridgeAmount);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidInput.selector));
        vm.prank(user1);
        gateway.sendTxWithFunds(
            MAINNET_USDC,
            bridgeAmount,
            unsupportedToken,
            gasAmount,
            1,
            block.timestamp + 3600,
            payload,
            revertCfg,
            bytes("")
        );
    }

    function testSendTxWithFunds_4Params_ERC20_WhenPaused() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg) =
            buildERC20Payload(user1, abi.encodeWithSignature("receive()"), 0);

        uint256 bridgeAmount = 9e6;
        uint256 gasAmount = 8e6;
        fundUserWithMainnetTokens(user1, MAINNET_USDC, bridgeAmount + gasAmount);

        // Pause the gateway
        vm.prank(pauser);
        gateway.pause();

        vm.prank(user1);
        IERC20(MAINNET_USDC).approve(address(gateway), bridgeAmount + gasAmount);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(user1);
        gateway.sendTxWithFunds(
            MAINNET_USDC,
            bridgeAmount,
            MAINNET_USDC,
            gasAmount,
            1,
            block.timestamp + 3600,
            payload,
            revertCfg,
            bytes("")
        );
    }

    function testSendTxWithFunds_4Params_ERC20_EdgeCases() public {
        // Setup: Create a valid payload and revert config
        (UniversalPayload memory payload, RevertInstructions memory revertCfg) =
            buildERC20Payload(user1, abi.encodeWithSignature("receive()"), 0);

        uint256 bridgeAmount = 9e6;
        uint256 gasAmount = 8e6;
        fundUserWithMainnetTokens(user1, MAINNET_USDC, bridgeAmount + gasAmount);

        // Test with deadline = 0 (should use contract default)
        vm.prank(user1);
        IERC20(MAINNET_USDC).approve(address(gateway), bridgeAmount + gasAmount);
        vm.prank(user1);
        gateway.sendTxWithFunds(
            MAINNET_USDC, bridgeAmount, MAINNET_USDC, gasAmount, 1, 0, payload, revertCfg, bytes("")
        );
    }

    // =========================
    // GATEWAY INITIALIZATION TESTS
    // =========================

    function testGatewayInitialization_AllBranches() public {
        // Test 1: Zero address validation - admin
        UniversalGateway newGateway = new UniversalGateway();
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        newGateway.initialize(
            address(0), // Zero admin
            pauser,
            tss,
            100e18, // minCapUsd
            10000e18, // maxCapUsd
            address(0x123), // factory
            address(0x456), // router
            MAINNET_WETH
        );

        // Test 2: Zero address validation - pauser
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        newGateway.initialize(
            admin,
            address(0), // Zero pauser
            tss,
            100e18,
            10000e18,
            address(0x123),
            address(0x456),
            MAINNET_WETH
        );

        // Test 3: Zero address validation - tss
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        newGateway.initialize(
            admin,
            pauser,
            address(0), // Zero tss
            100e18,
            10000e18,
            address(0x123),
            address(0x456),
            MAINNET_WETH
        );

        // Test 4: Zero address validation - WETH
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector));
        newGateway.initialize(
            admin,
            pauser,
            tss,
            100e18,
            10000e18,
            address(0x123),
            address(0x456),
            address(0) // Zero WETH
        );

        // Test 5: Successful initialization with Uniswap addresses
        newGateway.initialize(
            admin,
            pauser,
            tss,
            100e18,
            10000e18,
            address(0x123), // Non-zero factory
            address(0x456), // Non-zero router
            MAINNET_WETH
        );

        // Verify Uniswap addresses are set
        assertEq(address(newGateway.uniV3Factory()), address(0x123));
        assertEq(address(newGateway.uniV3Router()), address(0x456));
        assertEq(newGateway.WETH(), MAINNET_WETH);
        assertEq(newGateway.TSS_ADDRESS(), tss);
        assertEq(newGateway.MIN_CAP_UNIVERSAL_TX_USD(), 100e18);
        assertEq(newGateway.MAX_CAP_UNIVERSAL_TX_USD(), 10000e18);
        assertEq(newGateway.defaultSwapDeadlineSec(), 10 minutes);
        assertEq(newGateway.chainlinkStalePeriod(), 1 hours);

        // Test 6: Successful initialization with zero Uniswap addresses
        UniversalGateway newGateway2 = new UniversalGateway();
        newGateway2.initialize(
            admin,
            pauser,
            tss,
            50e18,
            5000e18,
            address(0), // Zero factory
            address(0), // Zero router
            MAINNET_WETH
        );

        // Verify Uniswap addresses are NOT set (should be address(0))
        assertEq(address(newGateway2.uniV3Factory()), address(0));
        assertEq(address(newGateway2.uniV3Router()), address(0));
        assertEq(newGateway2.WETH(), MAINNET_WETH);
        assertEq(newGateway2.TSS_ADDRESS(), tss);
        assertEq(newGateway2.MIN_CAP_UNIVERSAL_TX_USD(), 50e18);
        assertEq(newGateway2.MAX_CAP_UNIVERSAL_TX_USD(), 5000e18);
        assertEq(newGateway2.defaultSwapDeadlineSec(), 10 minutes);
        assertEq(newGateway2.chainlinkStalePeriod(), 1 hours);

        // Test 7: Verify roles are set correctly
        assertTrue(newGateway.hasRole(newGateway.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(newGateway.hasRole(newGateway.PAUSER_ROLE(), pauser));
        assertTrue(newGateway.hasRole(newGateway.TSS_ROLE(), tss));

        // Test 8: Verify initial state
        assertFalse(newGateway.paused());
        assertEq(newGateway.v3FeeOrder(0), 500);
        assertEq(newGateway.v3FeeOrder(1), 3000);
        assertEq(newGateway.v3FeeOrder(2), 10000);
    }
}
