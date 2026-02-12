// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { VaultPC } from "../../src/VaultPC.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title DeployVaultPC
 * @notice Deployment script for VaultPC on Push Chain
 * @dev Deploys implementation + proxy + initializes with all required parameters
 *
 * USAGE:
 * forge script script/vaultPC/DeployVaultPC.s.sol:DeployVaultPC \
 *   --rpc-url $PUSH_CHAIN_RPC_URL --private-key $PRIVATE_KEY --broadcast
 */
contract DeployVaultPC is Script {
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
    address pauser;
    address fundManager;

    // ========================================
    //         DEPLOYMENT STATE
    // ========================================
    address public vaultPCImplementation;
    address public vaultPCProxy;
    uint256 public deployChainId;

    // ========================================
    //         MAIN DEPLOYMENT
    // ========================================
    function run() external {
        deployChainId = block.chainid;

        console.log("========================================");
        console.log("  DEPLOYING VAULTPC ON PUSH CHAIN");
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

        // Basic sanity checks
        require(msg.sender != address(0), "Invalid deployer");

        console.log("OK: All validation checks passed");
        console.log("");
    }

    function _loadRoles() internal {
        console.log("--- Loading Role Configuration ---");

        // Default all roles to deployer (can transfer later)
        admin = msg.sender;
        pauser = msg.sender;
        fundManager = msg.sender;

        console.log("Admin:", admin);
        console.log("Pauser:", pauser);
        console.log("Fund Manager:", fundManager);
        console.log("");
    }

    // ========================================
    //         DEPLOYMENT STEPS
    // ========================================
    function _deployImplementation() internal {
        console.log("--- Deploying VaultPC Implementation ---");

        VaultPC implementation = new VaultPC();
        vaultPCImplementation = address(implementation);

        console.log("Implementation deployed at:", vaultPCImplementation);
        console.log("");
    }

    function _deployProxy() internal {
        console.log("--- Deploying Transparent Upgradeable Proxy ---");

        // Encode initialization call
        bytes memory initData = abi.encodeWithSelector(
            VaultPC.initialize.selector,
            admin,          // admin
            pauser,         // pauser
            fundManager     // fundManager
        );

        // Deploy proxy with implementation and initialization
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            vaultPCImplementation,
            DEPLOYER,
            initData
        );

        vaultPCProxy = address(proxy);
        console.log("Proxy deployed at:", vaultPCProxy);
        console.log("Proxy Admin:", _getProxyAdmin());
        console.log("");
    }

    // ========================================
    //         VERIFICATION
    // ========================================
    function _verifyDeployment() internal view {
        console.log("--- Deployment Verification ---");

        require(vaultPCImplementation != address(0), "Implementation not deployed");
        require(vaultPCProxy != address(0), "Proxy not deployed");

        VaultPC vaultPC = VaultPC(payable(vaultPCProxy));

        // Verify roles
        require(vaultPC.hasRole(vaultPC.DEFAULT_ADMIN_ROLE(), admin), "Admin role not set");
        require(vaultPC.hasRole(vaultPC.PAUSER_ROLE(), pauser), "Pauser role not set");
        require(vaultPC.hasRole(vaultPC.FUND_MANAGER_ROLE(), fundManager), "Fund Manager role not set");

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
        console.log("  VaultPC Implementation:", vaultPCImplementation);
        console.log("  VaultPC Proxy:         ", vaultPCProxy);
        console.log("  Proxy Admin:           ", _getProxyAdmin());
        console.log("");
        console.log("Configuration:");
        console.log("  Admin:                 ", admin);
        console.log("  Pauser:                ", pauser);
        console.log("  Fund Manager:          ", fundManager);
        console.log("");
        console.log("========================================");
        console.log("VaultPC Address: %s", vaultPCProxy);
        console.log("========================================");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Deploy UniversalGatewayPC with VAULT_PC=%s", vaultPCProxy);
        console.log("2. Verify contracts on block explorer");
        console.log("3. Transfer roles if needed");
        console.log("4. Test fee collection and withdrawal");
    }

    // ========================================
    //         HELPERS
    // ========================================
    function _getProxyAdmin() internal view returns (address proxyAdmin) {
        bytes32 raw = vm.load(vaultPCProxy, _ADMIN_SLOT);
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
//   <IMPL_ADDR> src/VaultPC.sol:VaultPC \
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
