// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Vault } from "../../src/Vault.sol";
import { TransparentUpgradeableProxy } from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title DeployVault_BSCTestnet
 * @notice Deploys the Vault on BSC Testnet (Chain ID: 97).
 *
 * USAGE:
 * forge script script/bscTestnet/deployVault.s.sol:DeployVault_BSCTestnet \
 *   --rpc-url $BSC_TESTNET_RPC_URL --private-key $KEY --broadcast --slow -vvv
 */
contract DeployVault_BSCTestnet is Script {
    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // ── BSC Testnet configuration ──────────────────────────────────────────
    address constant DEPLOYER         = 0x6dD2cA20ec82E819541EB43e1925DbE46a441970;
    address constant GATEWAY_ADDRESS  = 0x44aFFC61983F4348DdddB886349eb992C061EaC0;
    address constant CEA_FACTORY_ADDRESS = 0xf882C49A3E3d90640bFbAAf992a04c0712A9Af5C;
    address constant TSS_ADDRESS      = 0x05D7386FB3D7cB00e0CFAc5Af3B2EFF6BF37c5f1;
    // ──────────────────────────────────────────────────────────────────────

    address public vaultImplementation;
    address public vaultProxy;
    address admin;
    address pauser;
    address tss;
    uint256 public deployChainId;

    function run() external {
        deployChainId = block.chainid;
        require(deployChainId == 97, "Wrong chain: expected BSC Testnet (97)");

        console.log("========================================");
        console.log("  DEPLOYING VAULT - BSC TESTNET");
        console.log("========================================");
        console.log("Chain ID:", deployChainId);
        console.log("Deployer:", msg.sender);
        console.log("");

        _validateConfiguration();

        vm.startBroadcast();
        _loadRoles();
        _deployImplementation();
        _deployProxy();
        _verifyDeployment();
        vm.stopBroadcast();

        _printDeploymentSummary();
    }

    function _validateConfiguration() internal view {
        console.log("--- Pre-Deployment Validation ---");

        uint256 ceaCode;
        address cea = CEA_FACTORY_ADDRESS;
        assembly { ceaCode := extcodesize(cea) }
        require(ceaCode > 0, "CEAFactory not found at CEA_FACTORY_ADDRESS");

        uint256 gwCode;
        address gw = GATEWAY_ADDRESS;
        assembly { gwCode := extcodesize(gw) }
        require(gwCode > 0, "Gateway not found at GATEWAY_ADDRESS");

        console.log("OK: CEAFactory found:", CEA_FACTORY_ADDRESS);
        console.log("OK: Gateway found:", GATEWAY_ADDRESS);
        console.log("");
    }

    function _loadRoles() internal {
        admin  = msg.sender;
        pauser = msg.sender;
        tss    = TSS_ADDRESS;
        console.log("Admin/Pauser:", admin);
        console.log("TSS:", tss);
        console.log("");
    }

    function _deployImplementation() internal {
        console.log("--- Deploying Vault Implementation ---");
        Vault impl = new Vault();
        vaultImplementation = address(impl);
        console.log("Implementation:", vaultImplementation);
        console.log("");
    }

    function _deployProxy() internal {
        console.log("--- Deploying Transparent Upgradeable Proxy ---");
        bytes memory initData = abi.encodeWithSelector(
            Vault.initialize.selector,
            admin,
            pauser,
            tss,
            GATEWAY_ADDRESS,
            CEA_FACTORY_ADDRESS
        );
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(vaultImplementation, DEPLOYER, initData);
        vaultProxy = address(proxy);
        console.log("Vault Proxy:", vaultProxy);
        console.log("Proxy Admin:", _getProxyAdmin());
        console.log("");
    }

    function _verifyDeployment() internal view {
        console.log("--- Deployment Verification ---");
        require(vaultImplementation != address(0), "Implementation not deployed");
        require(vaultProxy != address(0), "Proxy not deployed");

        Vault vault = Vault(vaultProxy);
        require(address(vault.gateway()) == GATEWAY_ADDRESS, "Gateway mismatch");
        require(address(vault.CEAFactory()) == CEA_FACTORY_ADDRESS, "CEAFactory mismatch");
        require(vault.TSS_ADDRESS() == tss, "TSS mismatch");
        require(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), "Admin role missing");
        require(vault.hasRole(vault.TSS_ROLE(), tss), "TSS role missing");

        console.log("OK: All parameters verified");
        console.log("OK: All roles assigned correctly");
        console.log("");
    }

    function _printDeploymentSummary() internal view {
        console.log("========================================");
        console.log("     VAULT DEPLOYMENT SUMMARY");
        console.log("========================================");
        console.log("Chain ID:", deployChainId);
        console.log("Vault Implementation:", vaultImplementation);
        console.log("Vault Proxy:         ", vaultProxy);
        console.log("Proxy Admin:         ", _getProxyAdmin());
        console.log("Gateway:             ", GATEWAY_ADDRESS);
        console.log("CEAFactory:          ", CEA_FACTORY_ADDRESS);
        console.log("TSS:                 ", tss);
        console.log("========================================");
        console.log("NEXT STEPS:");
        console.log("1. Run upgradeGatewayV0_upgrade1.s.sol");
        console.log("2. Update docs/addresses/bsc-testnet.md with these addresses");
        console.log("========================================");
    }

    function _getProxyAdmin() internal view returns (address) {
        bytes32 raw = vm.load(vaultProxy, _ADMIN_SLOT);
        return address(uint160(uint256(raw)));
    }
}
