// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { GatewayConfig } from "../config/GatewayConfig.sol";

/**
 * @title DeployGateway
 * @notice Deployment script for UniversalGateway on external EVM chains
 * @dev Deploys implementation + proxy + initializes with all required parameters
 *
 * USAGE:
 * forge script script/gateway/DeployGateway.s.sol:DeployGateway \
 *   --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
 */
contract DeployGateway is Script, GatewayConfig {
    // ========================================
    //        EIP-1967 PROXY CONSTANTS
    // ========================================
    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // ========================================
    //     CONFIGURATION PARAMETERS
    // ========================================

    // Gateway USD caps (18 decimals: 1e18 = $1 USD)
    uint256 constant MIN_CAP_USD = 1e18; // $1 USD minimum
    uint256 constant MAX_CAP_USD = 100e18; // $100 USD maximum

    // Role addresses (set to msg.sender by default, transfer later)
    address admin;
    address tss;

    // ========================================
    //         DEPLOYMENT STATE
    // ========================================
    Config cfg;
    address public gatewayImplementation;
    address public gatewayProxy;
    uint256 public deployChainId;

    // ========================================
    //         MAIN DEPLOYMENT
    // ========================================
    function run() external {
        cfg = getConfig();
        deployChainId = block.chainid;

        console.log("========================================");
        console.log("  DEPLOYING UNIVERSAL GATEWAY");
        console.log("========================================");
        console.log("");
        console.log("Chain ID:", deployChainId);
        console.log("Deployer:", msg.sender);
        console.log("");

        // Pre-deployment validation
        _validateConfiguration();

        // Start broadcasting
        vm.startBroadcast();

        // Load roles
        _loadRoles();

        // Deploy implementation
        _deployImplementation();

        // Deploy proxy with initialization
        _deployProxy();

        // Configure gateway
        _configureGateway();

        // Verify deployment
        _verifyDeployment();

        vm.stopBroadcast();

        // Print summary
        _printDeploymentSummary();
    }

    // ========================================
    //         VALIDATION
    // ========================================
    function _validateConfiguration() internal view {
        console.log("--- Pre-Deployment Validation ---");
        console.log("");

        // Critical validation: Vault must be deployed first
        if (cfg.vault == address(0)) {
            console.log("ERROR: vault is not set in config!");
            console.log("Please deploy Vault first and update GatewayConfig.");
            revert("vault not set in config");
        }

        // Verify Vault has code
        uint256 vaultCodeSize;
        address vaultAddr = cfg.vault;
        assembly {
            vaultCodeSize := extcodesize(vaultAddr)
        }
        require(vaultCodeSize > 0, "Vault contract not found at config vault address");

        // Validate USD caps
        require(MIN_CAP_USD > 0, "MIN_CAP_USD must be > 0");
        require(MAX_CAP_USD > MIN_CAP_USD, "MAX_CAP_USD must be > MIN_CAP_USD");

        // Validate addresses
        require(cfg.uniswapV3Factory != address(0), "uniswapV3Factory is zero in config");
        require(cfg.uniswapV3Router != address(0), "uniswapV3Router is zero in config");
        require(cfg.weth != address(0), "weth is zero in config");
        require(cfg.ethUsdFeed != address(0), "ethUsdFeed is zero in config");

        console.log("OK: All validation checks passed");
        console.log("");
    }

    function _loadRoles() internal {
        console.log("--- Loading Role Configuration ---");

        // Default all roles to deployer (can transfer later)
        admin = msg.sender;
        tss = msg.sender;

        console.log("Admin:", admin);
        console.log("TSS:", tss);
        console.log("");
    }

    // ========================================
    //         DEPLOYMENT STEPS
    // ========================================
    function _deployImplementation() internal {
        console.log("--- Deploying Gateway Implementation ---");

        UniversalGateway implementation = new UniversalGateway();
        gatewayImplementation = address(implementation);

        console.log("Implementation deployed at:", gatewayImplementation);
        console.log("");
    }

    function _deployProxy() internal {
        console.log("--- Deploying Transparent Upgradeable Proxy ---");

        // Encode initialization call
        bytes memory initData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin,
            tss,
            cfg.vault,
            MIN_CAP_USD,
            MAX_CAP_USD,
            cfg.uniswapV3Factory,
            cfg.uniswapV3Router,
            cfg.weth,
            cfg.ethUsdFeed
        );

        // Deploy proxy with implementation and initialization
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(gatewayImplementation, cfg.deployer, initData);

        gatewayProxy = address(proxy);
        console.log("Proxy deployed at:", gatewayProxy);
        console.log("Proxy Admin:", _getProxyAdmin());
        console.log("");
    }

    function _configureGateway() internal {
        console.log("--- Configuring Gateway ---");

        UniversalGateway gateway = UniversalGateway(payable(gatewayProxy));

        // Set staleness period (24 hours for testnet, adjust for mainnet)
        console.log("Setting Chainlink staleness period to 24 hours...");
        gateway.setChainlinkStalePeriod(24 hours);

        // Disable L2 sequencer feed (for L1 chains like Sepolia/Mainnet)
        // For L2 chains (Arbitrum, Optimism, Base), set appropriate sequencer feed
        console.log("Disabling L2 sequencer feed (L1 chain)...");
        gateway.setL2SequencerFeed(address(0));

        console.log("Configuration complete");
        console.log("");
    }

    // ========================================
    //         VERIFICATION
    // ========================================
    function _verifyDeployment() internal view {
        console.log("--- Deployment Verification ---");

        require(gatewayImplementation != address(0), "Implementation not deployed");
        require(gatewayProxy != address(0), "Proxy not deployed");

        UniversalGateway gateway = UniversalGateway(payable(gatewayProxy));

        // Verify initialization parameters
        require(gateway.VAULT() == cfg.vault, "Vault address mismatch");
        require(gateway.TSS_ADDRESS() == tss, "TSS address mismatch");
        require(gateway.MIN_CAP_UNIVERSAL_TX_USD() == MIN_CAP_USD, "Min cap mismatch");
        require(gateway.MAX_CAP_UNIVERSAL_TX_USD() == MAX_CAP_USD, "Max cap mismatch");
        require(gateway.WETH() == cfg.weth, "WETH mismatch");
        require(address(gateway.ethUsdFeed()) == cfg.ethUsdFeed, "ETH/USD feed mismatch");

        // Verify roles
        require(gateway.hasRole(gateway.DEFAULT_ADMIN_ROLE(), admin), "Admin role not set");
        require(gateway.hasRole(gateway.TSS_ROLE(), tss), "TSS role not set");

        console.log("OK: All parameters verified");
        console.log("OK: All roles assigned correctly");
        console.log("");
    }

    function _printDeploymentSummary() internal view {
        console.log("========================================");
        console.log("     DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("");
        console.log("Chain ID:", deployChainId);
        console.log("Deployer:", msg.sender);
        console.log("");
        console.log("Deployed Contracts:");
        console.log("  Gateway Implementation:", gatewayImplementation);
        console.log("  Gateway Proxy:         ", gatewayProxy);
        console.log("  Proxy Admin:           ", _getProxyAdmin());
        console.log("");
        console.log("Configuration:");
        console.log("  Vault:          ", cfg.vault);
        console.log("  Admin:          ", admin);
        console.log("  TSS:            ", tss);
        console.log("  Min USD Cap:     $", MIN_CAP_USD / 1e18);
        console.log("  Max USD Cap:     $", MAX_CAP_USD / 1e18);
        console.log("  WETH:           ", cfg.weth);
        console.log("  ETH/USD Feed:   ", cfg.ethUsdFeed);
        console.log("");
        console.log("========================================");
        console.log("Gateway Address: %s", gatewayProxy);
        console.log("========================================");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Update Vault.setGateway(%s)", gatewayProxy);
        console.log("2. Verify contracts on block explorer");
        console.log("3. Transfer roles if needed");
        console.log("4. Test integration with Vault");
    }

    // ========================================
    //         HELPERS
    // ========================================
    function _getProxyAdmin() internal view returns (address proxyAdmin) {
        bytes32 raw = vm.load(gatewayProxy, _ADMIN_SLOT);
        proxyAdmin = address(uint160(uint256(raw)));
    }

    function _getProxyAdminOwner() internal view returns (address owner) {
        address proxyAdminAddr = _getProxyAdmin();
        ProxyAdmin proxyAdminContract = ProxyAdmin(proxyAdminAddr);
        owner = proxyAdminContract.owner();
    }
}

// ========================================
//      VERIFICATION COMMANDS
// ========================================
//
// 1. Verify Implementation:
// forge verify-contract --chain <CHAIN> \
//   --constructor-args $(cast abi-encode "constructor()") \
//   <IMPL_ADDR> src/UniversalGateway.sol:UniversalGateway \
//   --etherscan-api-key $ETHERSCAN_API_KEY
//
// 2. Verify Proxy:
// forge verify-contract --chain <CHAIN> \
//   --constructor-args $(cast abi-encode "constructor(address,address,bytes)" <IMPL_ADDR> <ADMIN_ADDR> <INIT_DATA>) \
//   <PROXY_ADDR> lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy \
//   --etherscan-api-key $ETHERSCAN_API_KEY
//
// 3. Verify ProxyAdmin:
// forge verify-contract --chain <CHAIN> \
//   --constructor-args $(cast abi-encode "constructor(address)" <DEPLOYER>) \
//   <ADMIN_ADDR> lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin \
//   --etherscan-api-key $ETHERSCAN_API_KEY
