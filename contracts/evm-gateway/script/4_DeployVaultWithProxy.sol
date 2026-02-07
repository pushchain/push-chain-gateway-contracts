// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Vault } from "../src/Vault.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title DeployVaultWithProxy
 * @notice Deployment script for Vault on EVM chains (Sepolia testnet)
 * @dev Deploys Vault implementation, proxy admin, and transparent upgradeable proxy
 *
 * PREREQUISITES:
 * - UniversalGateway must be deployed first
 * - CEAFactory must be deployed first
 *
 * DEPLOYMENT COMMAND:
 * forge script script/4_DeployVaultWithProxy.sol:DeployVaultWithProxy \
 *   --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
 */
contract DeployVaultWithProxy is Script {
    // EIP-1967 admin slot for TransparentUpgradeableProxy
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // DEPLOYER ADDRESS (ProxyAdmin owner)
    address constant DEPLOYER = 0xe520d4A985A2356Fa615935a822Ce4eFAcA24aB6;

    // ========================================
    // CONFIGURATION - UPDATE THESE ADDRESSES
    // ========================================

    // **REQUIRED**: Set these addresses before deployment
    // Gateway address (from 1_DeployGatewayWithProxy.sol output)
    address constant GATEWAY_ADDRESS = address(0); // TODO: UPDATE THIS

    // CEAFactory address (must be deployed separately)
    address constant CEA_FACTORY_ADDRESS = address(0); // TODO: UPDATE THIS

    // Role addresses (defaults to deployer, can be changed after deployment)
    address admin;
    address pauser;
    address tss;

    // Deployed contract addresses
    address public vaultImplementation;
    address public vaultProxy;

    function run() external {
        console.log("=== DEPLOYING VAULT TO SEPOLIA ===");
        console.log("");

        // Pre-deployment validation
        _validateConfiguration();

        // Start broadcasting transactions
        vm.startBroadcast();

        // Load configuration
        _loadDeploymentConfig();

        // Deploy contracts
        _deployVaultImplementation();
        _deployVaultProxy();

        // Verify deployment
        _verifyAllAdmins();
        _verifyDeployment();

        vm.stopBroadcast();

        // Log deployment summary
        _logDeploymentSummary();
    }

    function _validateConfiguration() internal view {
        console.log("--- Pre-Deployment Validation ---");

        require(GATEWAY_ADDRESS != address(0), "GATEWAY_ADDRESS not set - deploy Gateway first");
        require(CEA_FACTORY_ADDRESS != address(0), "CEA_FACTORY_ADDRESS not set - deploy CEAFactory first");

        // Verify Gateway has code deployed
        address gatewayAddr = GATEWAY_ADDRESS;
        uint256 gatewayCodeSize;
        assembly {
            gatewayCodeSize := extcodesize(gatewayAddr)
        }
        require(gatewayCodeSize > 0, "Gateway contract not found at GATEWAY_ADDRESS");

        // Verify CEAFactory has code deployed
        address ceaFactoryAddr = CEA_FACTORY_ADDRESS;
        uint256 ceaFactoryCodeSize;
        assembly {
            ceaFactoryCodeSize := extcodesize(ceaFactoryAddr)
        }
        require(ceaFactoryCodeSize > 0, "CEAFactory contract not found at CEA_FACTORY_ADDRESS");

        console.log("OK: Gateway found at:", GATEWAY_ADDRESS);
        console.log("OK: CEAFactory found at:", CEA_FACTORY_ADDRESS);
        console.log("");
    }

    function _loadDeploymentConfig() internal {
        console.log("--- Loading Deployment Configuration ---");

        // Use deployer as default admin/pauser/tss (can transfer roles later)
        admin = msg.sender;
        pauser = msg.sender;
        tss = msg.sender;

        console.log("Deployer:", msg.sender);
        console.log("Admin address:", admin);
        console.log("Pauser address:", pauser);
        console.log("TSS address:", tss);
        console.log("Gateway address:", GATEWAY_ADDRESS);
        console.log("CEAFactory address:", CEA_FACTORY_ADDRESS);
        console.log("");
    }

    function _deployVaultImplementation() internal {
        console.log("--- Deploying Vault Implementation ---");

        Vault implementation = new Vault();
        vaultImplementation = address(implementation);

        console.log("Vault Implementation deployed at:", vaultImplementation);
        console.log("");
    }

    function _deployVaultProxy() internal {
        console.log("--- Deploying Transparent Upgradeable Proxy ---");

        // Encode initialization call
        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            admin,              // admin
            pauser,             // pauser
            tss,                // tss
            GATEWAY_ADDRESS,    // gateway
            CEA_FACTORY_ADDRESS // ceaFactory
        );

        // Deploy proxy with initialization
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            vaultImplementation,
            DEPLOYER,
            initData
        );

        vaultProxy = address(proxy);
        console.log("Vault Proxy deployed at:", vaultProxy);
        console.log("");
    }

    function _verifyAllAdmins() internal view {
        console.log("--- Admin Verification ---");

        // Get admin of TransparentProxy
        address proxyAdmin = getProxyAdmin();
        console.log("TransparentProxy admin:", proxyAdmin);

        // Get admin (owner) of ProxyAdmin
        address proxyAdminOwner = getProxyAdminOwner();
        console.log("ProxyAdmin owner:", proxyAdminOwner);

        if (proxyAdminOwner == DEPLOYER) {
            console.log("OK: ProxyAdmin owner correctly points to DEPLOYER");
        } else {
            console.log("WARNING: ProxyAdmin owner does not point to DEPLOYER");
        }

        if (proxyAdmin != DEPLOYER) {
            console.log("OK: Proxy admin is auto-deployed and accurate");
        } else {
            console.log("WARNING: Proxy admin is not auto-deployed and points to DEPLOYER ADDRESS");
        }

        console.log("");
    }

    function _verifyDeployment() internal view {
        console.log("--- Deployment Verification ---");

        require(vaultImplementation != address(0), "Vault implementation not deployed");
        require(vaultProxy != address(0), "Vault proxy not deployed");

        Vault vault = Vault(vaultProxy);

        // Verify initialization parameters
        require(address(vault.gateway()) == GATEWAY_ADDRESS, "Gateway address mismatch");
        require(address(vault.CEAFactory()) == CEA_FACTORY_ADDRESS, "CEAFactory address mismatch");
        require(vault.TSS_ADDRESS() == tss, "TSS address mismatch");

        // Verify roles
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "Admin role not granted");
        require(vault.hasRole(vault.PAUSER_ROLE(), pauser), "Pauser role not granted");
        require(vault.hasRole(vault.TSS_ROLE(), tss), "TSS role not granted");

        console.log("OK: All initialization parameters verified");
        console.log("OK: All roles correctly assigned");
        console.log("Deployment verification passed!");
        console.log("");
    }

    function _logDeploymentSummary() internal view {
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("Network: Sepolia Testnet");
        console.log("Deployer:", msg.sender);
        console.log("");
        console.log("Deployed Contracts:");
        console.log("  Vault Implementation:", vaultImplementation);
        console.log("  Vault Proxy:", vaultProxy);
        console.log("  Proxy Admin:", getProxyAdmin());
        console.log("");
        console.log("Configuration:");
        console.log("  Gateway:", GATEWAY_ADDRESS);
        console.log("  CEAFactory:", CEA_FACTORY_ADDRESS);
        console.log("  Admin:", admin);
        console.log("  Pauser:", pauser);
        console.log("  TSS:", tss);
        console.log("");
        console.log("Deployment completed successfully!");
        console.log("");
        console.log("Vault Address (use this): %s", vaultProxy);
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Verify contracts on Etherscan (see verification commands below)");
        console.log("2. Transfer admin roles if needed using vault.grantRole() and revokeRole()");
        console.log("3. Update Gateway to point to this Vault if needed");
        console.log("4. Verify Vault integration with Gateway and CEAFactory");
    }

    // ==========================================
    //              HELPER FUNCTIONS
    // ==========================================

    /**
     * @notice Get the admin of the TransparentProxy
     * @return proxyADMIN The address of the proxy admin
     */
    function getProxyAdmin() public view returns (address proxyADMIN) {
        // Read admin directly from the EIP-1967 admin slot on the proxy
        bytes32 raw = vm.load(vaultProxy, _ADMIN_SLOT);
        proxyADMIN = address(uint160(uint256(raw)));
    }

    /**
     * @notice Get the owner (admin) of the ProxyAdmin contract
     * @return owner The address of the ProxyAdmin owner
     */
    function getProxyAdminOwner() public view returns (address owner) {
        address proxyADMIN = getProxyAdmin();
        ProxyAdmin proxyAdmin = ProxyAdmin(proxyADMIN);
        owner = proxyAdmin.owner();
    }
}

// ==========================================
//         VERIFICATION COMMANDS
// ==========================================
//
// 1. Verify Vault Implementation:
// forge verify-contract --chain sepolia \
//   --constructor-args $(cast abi-encode "constructor()") \
//   <VAULT_IMPL_ADDR> src/Vault.sol:Vault
//
// 2. Verify TransparentUpgradeableProxy:
// forge verify-contract --chain sepolia \
//   --constructor-args $(cast abi-encode "constructor(address,address,bytes)" <VAULT_IMPL_ADDR> <PROXY_ADMIN_ADDR> 0x) \
//   <VAULT_PROXY_ADDR> lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy
//
// 3. Verify ProxyAdmin:
// forge verify-contract --chain sepolia \
//   --constructor-args $(cast abi-encode "constructor(address)" <DEPLOYER_ADDR>) \
//   <PROXY_ADMIN_ADDR> lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin
//
// ==========================================
//         DEPLOYMENT COMMANDS
// ==========================================
//
// Deploy Vault with Proxy:
// forge script script/4_DeployVaultWithProxy.sol:DeployVaultWithProxy \
//   --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
//
// Upgrade Vault (create separate upgrade script based on 3_UpgradeGatewayNewImpl.sol):
// forge script script/5_UpgradeVaultNewImpl.sol:UpgradeVaultNewImpl \
//   --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
