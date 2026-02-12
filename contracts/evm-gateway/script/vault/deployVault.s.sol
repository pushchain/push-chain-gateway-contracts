// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Vault } from "../../src/Vault.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title DeployVault
 * @notice Deployment script for Vault on external EVM chains
 * @dev Deploys implementation + proxy + initializes with all required parameters
 *
 * PREREQUISITES:
 * - CEAFactory must be deployed first
 * - Gateway can be set to address(0) initially, then updated via setGateway()
 *
 * USAGE:
 * forge script script/vault/DeployVault.s.sol:DeployVault \
 *   --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
 */
contract DeployVault is Script {
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
    address tss;

    // Gateway address (can deploy Vault first, then set gateway later via setGateway())
    // Set to address(0) to deploy Vault before Gateway
    address constant GATEWAY_ADDRESS = address(0); // TODO: Set after deploying Gateway OR leave as 0

    // CEAFactory address (REQUIRED - must be deployed first)
    address constant CEA_FACTORY_ADDRESS = address(0); // TODO: Set CEAFactory address

    // ========================================
    //         DEPLOYMENT STATE
    // ========================================
    address public vaultImplementation;
    address public vaultProxy;
    uint256 public deployChainId;

    // ========================================
    //         MAIN DEPLOYMENT
    // ========================================
    function run() external {
        deployChainId = block.chainid;

        console.log("========================================");
        console.log("  DEPLOYING VAULT");
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

        // Critical validation: CEAFactory must be deployed
        if (CEA_FACTORY_ADDRESS == address(0)) {
            console.log("ERROR: CEA_FACTORY_ADDRESS is not set!");
            console.log("Please deploy CEAFactory first and update CEA_FACTORY_ADDRESS in this script.");
            revert("CEA_FACTORY_ADDRESS not set");
        }

        // Verify CEAFactory has code
        uint256 ceaFactoryCodeSize;
        address ceaFactoryAddr = CEA_FACTORY_ADDRESS;
        assembly {
            ceaFactoryCodeSize := extcodesize(ceaFactoryAddr)
        }
        require(ceaFactoryCodeSize > 0, "CEAFactory contract not found at CEA_FACTORY_ADDRESS");

        // Gateway validation (optional - can be set later)
        if (GATEWAY_ADDRESS != address(0)) {
            uint256 gatewayCodeSize;
            address gatewayAddr = GATEWAY_ADDRESS;
            assembly {
                gatewayCodeSize := extcodesize(gatewayAddr)
            }
            require(gatewayCodeSize > 0, "Gateway contract not found at GATEWAY_ADDRESS");
            console.log("OK: Gateway found at:", GATEWAY_ADDRESS);
        } else {
            console.log("INFO: Gateway not set - will need to call setGateway() after deployment");
        }

        console.log("OK: CEAFactory found at:", CEA_FACTORY_ADDRESS);
        console.log("OK: All validation checks passed");
        console.log("");
    }

    function _loadRoles() internal {
        console.log("--- Loading Role Configuration ---");

        // Default all roles to deployer (can transfer later)
        admin = msg.sender;
        pauser = msg.sender;
        tss = msg.sender;

        console.log("Admin:", admin);
        console.log("Pauser:", pauser);
        console.log("TSS:", tss);
        console.log("");
    }

    // ========================================
    //         DEPLOYMENT STEPS
    // ========================================
    function _deployImplementation() internal {
        console.log("--- Deploying Vault Implementation ---");

        Vault implementation = new Vault();
        vaultImplementation = address(implementation);

        console.log("Implementation deployed at:", vaultImplementation);
        console.log("");
    }

    function _deployProxy() internal {
        console.log("--- Deploying Transparent Upgradeable Proxy ---");

        // Encode initialization call
        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            admin,                  // admin
            pauser,                 // pauser
            tss,                    // tss
            GATEWAY_ADDRESS,        // gateway (can be address(0))
            CEA_FACTORY_ADDRESS     // ceaFactory
        );

        // Deploy proxy with implementation and initialization
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            vaultImplementation,
            DEPLOYER,
            initData
        );

        vaultProxy = address(proxy);
        console.log("Proxy deployed at:", vaultProxy);
        console.log("Proxy Admin:", _getProxyAdmin());
        console.log("");
    }

    // ========================================
    //         VERIFICATION
    // ========================================
    function _verifyDeployment() internal view {
        console.log("--- Deployment Verification ---");

        require(vaultImplementation != address(0), "Implementation not deployed");
        require(vaultProxy != address(0), "Proxy not deployed");

        Vault vault = Vault(vaultProxy);

        // Verify initialization parameters
        require(address(vault.gateway()) == GATEWAY_ADDRESS, "Gateway address mismatch");
        require(address(vault.CEAFactory()) == CEA_FACTORY_ADDRESS, "CEAFactory address mismatch");
        require(vault.TSS_ADDRESS() == tss, "TSS address mismatch");

        // Verify roles
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "Admin role not set");
        require(vault.hasRole(vault.PAUSER_ROLE(), pauser), "Pauser role not set");
        require(vault.hasRole(vault.TSS_ROLE(), tss), "TSS role not set");

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
        console.log("  Vault Implementation:  ", vaultImplementation);
        console.log("  Vault Proxy:           ", vaultProxy);
        console.log("  Proxy Admin:           ", _getProxyAdmin());
        console.log("");
        console.log("Configuration:");
        console.log("  Gateway:               ", GATEWAY_ADDRESS);
        console.log("  CEAFactory:            ", CEA_FACTORY_ADDRESS);
        console.log("  Admin:                 ", admin);
        console.log("  Pauser:                ", pauser);
        console.log("  TSS:                   ", tss);
        console.log("");
        console.log("========================================");
        console.log("Vault Address: %s", vaultProxy);
        console.log("========================================");
        console.log("");
        console.log("NEXT STEPS:");
        if (GATEWAY_ADDRESS == address(0)) {
            console.log("1. Deploy UniversalGateway with VAULT_ADDRESS=%s", vaultProxy);
            console.log("2. Call vault.setGateway(<gateway_proxy_address>)");
        } else {
            console.log("1. Call gateway.updateVault(%s)", vaultProxy);
            console.log("2. Verify integration between Gateway and Vault");
        }
        console.log("3. Verify contracts on block explorer");
        console.log("4. Transfer roles if needed");
        console.log("5. Test CEA deployment functionality");
    }

    // ========================================
    //         HELPERS
    // ========================================
    function _getProxyAdmin() internal view returns (address proxyAdmin) {
        bytes32 raw = vm.load(vaultProxy, _ADMIN_SLOT);
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
//   <IMPL_ADDR> src/Vault.sol:Vault \
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
