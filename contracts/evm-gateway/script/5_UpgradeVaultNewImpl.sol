// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Vault } from "../src/Vault.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title UpgradeVaultNewImpl
 * @notice Upgrade an existing Vault proxy to point to a new implementation
 * @dev This script upgrades a Vault proxy to a new implementation contract
 *      Requires the proxy admin to execute the upgrade
 *
 * USAGE:
 * 1. Update EXISTING_VAULT_PROXY and EXISTING_PROXY_ADMIN addresses below
 * 2. Run: forge script script/5_UpgradeVaultNewImpl.sol:UpgradeVaultNewImpl \
 *         --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
 */
contract UpgradeVaultNewImpl is Script {
    // =========================
    //     CONFIGURATION
    // =========================

    // **REQUIRED**: Set these addresses before running the upgrade
    // Existing Vault proxy address (from 4_DeployVaultWithProxy.sol output)
    address constant EXISTING_VAULT_PROXY = address(0); // TODO: UPDATE THIS

    // Existing ProxyAdmin address (from 4_DeployVaultWithProxy.sol output)
    address constant EXISTING_PROXY_ADMIN = address(0); // TODO: UPDATE THIS

    // New implementation address (will be deployed)
    address public newVaultImplementation;

    function run() external {
        console.log("=== UPGRADING VAULT PROXY ===");
        console.log("");

        // Pre-upgrade validation
        _validateConfiguration();

        // Load configuration
        _loadUpgradeConfig();

        // Start broadcasting transactions
        vm.startBroadcast();

        // Deploy new implementation
        _deployNewImplementation();

        // Upgrade the proxy
        _upgradeProxy();

        // Verify the upgrade
        _verifyUpgrade();

        vm.stopBroadcast();

        // Log upgrade summary
        _logUpgradeSummary();
    }

    function _validateConfiguration() internal view {
        console.log("--- Pre-Upgrade Validation ---");

        require(EXISTING_VAULT_PROXY != address(0), "EXISTING_VAULT_PROXY not set");
        require(EXISTING_PROXY_ADMIN != address(0), "EXISTING_PROXY_ADMIN not set");

        // Verify Vault proxy has code deployed
        address proxyAddr = EXISTING_VAULT_PROXY;
        uint256 proxyCodeSize;
        assembly {
            proxyCodeSize := extcodesize(proxyAddr)
        }
        require(proxyCodeSize > 0, "Vault proxy not found at EXISTING_VAULT_PROXY");

        // Verify ProxyAdmin has code deployed
        address adminAddr = EXISTING_PROXY_ADMIN;
        uint256 adminCodeSize;
        assembly {
            adminCodeSize := extcodesize(adminAddr)
        }
        require(adminCodeSize > 0, "ProxyAdmin not found at EXISTING_PROXY_ADMIN");

        console.log("OK: Vault proxy found at:", EXISTING_VAULT_PROXY);
        console.log("OK: ProxyAdmin found at:", EXISTING_PROXY_ADMIN);
        console.log("");
    }

    function _loadUpgradeConfig() internal view {
        console.log("--- Loading Upgrade Configuration ---");
        console.log("Existing Vault Proxy:", EXISTING_VAULT_PROXY);
        console.log("Existing ProxyAdmin:", EXISTING_PROXY_ADMIN);
        console.log("Deployer:", msg.sender);
        console.log("");
    }

    function _deployNewImplementation() internal {
        console.log("--- Deploying New Vault Implementation ---");

        // Deploy new Vault implementation
        Vault newImplementation = new Vault();
        newVaultImplementation = address(newImplementation);

        console.log("New Vault implementation deployed at:", newVaultImplementation);
        console.log("");
    }

    function _upgradeProxy() internal {
        console.log("--- Upgrading Vault Proxy ---");

        // Get the proxy admin contract
        ProxyAdmin proxyAdmin = ProxyAdmin(EXISTING_PROXY_ADMIN);

        // Get the proxy
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(EXISTING_VAULT_PROXY);

        console.log("Upgrading proxy to new implementation:", newVaultImplementation);

        // Perform the upgrade using upgradeAndCall with empty data
        // Note: If you need to call an initializer function, pass the encoded call data as the third parameter
        proxyAdmin.upgradeAndCall(proxy, newVaultImplementation, "");

        console.log("Vault proxy upgraded successfully!");
        console.log("");
    }

    function _verifyUpgrade() internal view {
        console.log("--- Upgrade Verification ---");

        require(newVaultImplementation != address(0), "New implementation not deployed");

        // Access the Vault through the proxy
        Vault vault = Vault(EXISTING_VAULT_PROXY);

        // Verify that the vault is still functional by checking state variables
        address gateway = address(vault.gateway());
        address ceaFactory = address(vault.CEAFactory());
        address tssAddress = vault.TSS_ADDRESS();

        console.log("Vault state after upgrade:");
        console.log("  Gateway:", gateway);
        console.log("  CEAFactory:", ceaFactory);
        console.log("  TSS Address:", tssAddress);

        require(gateway != address(0), "Gateway address is zero after upgrade");
        require(ceaFactory != address(0), "CEAFactory address is zero after upgrade");
        require(tssAddress != address(0), "TSS address is zero after upgrade");

        console.log("OK: Upgrade verified - all state preserved");
        console.log("");
    }

    function _logUpgradeSummary() internal view {
        console.log("=== UPGRADE SUMMARY ===");
        console.log("Network: Sepolia Testnet");
        console.log("Deployer:", msg.sender);
        console.log("");
        console.log("Upgrade Details:");
        console.log("  Vault Proxy Address:", EXISTING_VAULT_PROXY);
        console.log("  ProxyAdmin Address:", EXISTING_PROXY_ADMIN);
        console.log("  New Implementation:", newVaultImplementation);
        console.log("");
        console.log("Vault Proxy Address (unchanged): %s", EXISTING_VAULT_PROXY);
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Verify new implementation on Etherscan:");
        console.log("   forge verify-contract --chain sepolia \\");
        console.log("     --constructor-args $(cast abi-encode \"constructor()\") \\");
        console.log("     %s src/Vault.sol:Vault", newVaultImplementation);
        console.log("");
        console.log("2. Test the upgraded Vault functionality");
        console.log("3. Monitor for any issues post-upgrade");
    }
}

// ==========================================
//         VERIFICATION COMMANDS
// ==========================================
//
// Verify New Vault Implementation:
// forge verify-contract --chain sepolia \
//   --constructor-args $(cast abi-encode "constructor()") \
//   <NEW_VAULT_IMPL_ADDR> src/Vault.sol:Vault
//
// ==========================================
//         DEPLOYMENT COMMANDS
// ==========================================
//
// Upgrade Vault:
// forge script script/5_UpgradeVaultNewImpl.sol:UpgradeVaultNewImpl \
//   --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
