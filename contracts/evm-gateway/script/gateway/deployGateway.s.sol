// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title DeployGateway
 * @notice Deployment script for UniversalGateway on external EVM chains
 * @dev Deploys implementation + proxy + initializes with all required parameters
 *
 * USAGE:
 * forge script script/gateway/DeployGateway.s.sol:DeployGateway \
 *   --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
 */
contract DeployGateway is Script {
    // ========================================
    //        EIP-1967 PROXY CONSTANTS
    // ========================================
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // ========================================
    //     CONFIGURATION PARAMETERS
    // ========================================
    // **TODO: UPDATE THESE BEFORE DEPLOYMENT**

    // Deployer will be ProxyAdmin owner
    address constant DEPLOYER = 0xe520d4A985A2356Fa615935a822Ce4eFAcA24aB6;

    // Role addresses (set to msg.sender by default, transfer later if needed)
    address admin;
    address tss;

    // Vault address (deploy Vault first, then set this)
    address constant VAULT_ADDRESS = address(0); // TODO: Set after deploying Vault

    // Gateway USD caps (18 decimals: 1e18 = $1 USD)
    uint256 constant MIN_CAP_USD = 1e18;      // $1 USD minimum
    uint256 constant MAX_CAP_USD = 100e18;    // $100 USD maximum

    // Uniswap V3 addresses
    address constant UNISWAP_V3_FACTORY = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c; // Sepolia
    address constant UNISWAP_V3_ROUTER = 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E;  // Sepolia

    // Token addresses
    address constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14; // Sepolia WETH

    // Chainlink price feeds
    address constant ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Sepolia ETH/USD

    // ========================================
    //         DEPLOYMENT STATE
    // ========================================
    address public gatewayImplementation;
    address public gatewayProxy;
    uint256 public deployChainId;

    // ========================================
    //         MAIN DEPLOYMENT
    // ========================================
    function run() external {
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
        if (VAULT_ADDRESS == address(0)) {
            console.log("ERROR: VAULT_ADDRESS is not set!");
            console.log("Please deploy Vault first and update VAULT_ADDRESS in this script.");
            revert("VAULT_ADDRESS not set");
        }

        // Verify Vault has code
        uint256 vaultCodeSize;
        address vaultAddr = VAULT_ADDRESS;
        assembly {
            vaultCodeSize := extcodesize(vaultAddr)
        }
        require(vaultCodeSize > 0, "Vault contract not found at VAULT_ADDRESS");

        // Validate USD caps
        require(MIN_CAP_USD > 0, "MIN_CAP_USD must be > 0");
        require(MAX_CAP_USD > MIN_CAP_USD, "MAX_CAP_USD must be > MIN_CAP_USD");

        // Validate addresses
        require(UNISWAP_V3_FACTORY != address(0), "UNISWAP_V3_FACTORY is zero");
        require(UNISWAP_V3_ROUTER != address(0), "UNISWAP_V3_ROUTER is zero");
        require(WETH != address(0), "WETH is zero");
        require(ETH_USD_FEED != address(0), "ETH_USD_FEED is zero");

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
            admin,                  // admin
            tss,                    // tss
            VAULT_ADDRESS,          // vault
            MIN_CAP_USD,            // minCapUsd
            MAX_CAP_USD,            // maxCapUsd
            UNISWAP_V3_FACTORY,     // uniswapFactory
            UNISWAP_V3_ROUTER,      // uniswapRouter
            WETH,                   // weth
            ETH_USD_FEED            // ethUsdFeed
        );

        // Deploy proxy with implementation and initialization
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            gatewayImplementation,
            DEPLOYER,
            initData
        );

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
        require(gateway.VAULT() == VAULT_ADDRESS, "Vault address mismatch");
        require(gateway.TSS_ADDRESS() == tss, "TSS address mismatch");
        require(gateway.MIN_CAP_UNIVERSAL_TX_USD() == MIN_CAP_USD, "Min cap mismatch");
        require(gateway.MAX_CAP_UNIVERSAL_TX_USD() == MAX_CAP_USD, "Max cap mismatch");
        require(gateway.WETH() == WETH, "WETH mismatch");
        require(address(gateway.ethUsdFeed()) == ETH_USD_FEED, "ETH/USD feed mismatch");

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
        console.log("  Vault:          ", VAULT_ADDRESS);
        console.log("  Admin:          ", admin);
        console.log("  TSS:            ", tss);
        console.log("  Min USD Cap:     $", MIN_CAP_USD / 1e18);
        console.log("  Max USD Cap:     $", MAX_CAP_USD / 1e18);
        console.log("  WETH:           ", WETH);
        console.log("  ETH/USD Feed:   ", ETH_USD_FEED);
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
