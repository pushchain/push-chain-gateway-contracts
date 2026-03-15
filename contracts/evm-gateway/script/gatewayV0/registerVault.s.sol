// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGatewayV0 } from "../../src/testnetV0/UniversalGatewayV0.sol";

/**
 * @title RegisterVault
 * @notice Registers the Vault and CEAFactory addresses on the upgraded UniversalGatewayV0.
 *
 * @dev  Must be run AFTER upgradeGatewayV0_upgrade1.s.sol and BEFORE moveFunds.s.sol.
 *       Calls gateway.setVault() and gateway.setCEAFactory() from the DEFAULT_ADMIN_ROLE holder.
 *
 * USAGE:
 * forge script script/gatewayV0/registerVault.s.sol:RegisterVault \
 *   --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast -vvv
 */
contract RegisterVault is Script {
    // ========================================
    //     CONFIGURATION PARAMETERS
    // ========================================
    address constant GATEWAY_PROXY    = 0x4DCab975cDe839632db6695e2e936A29ce3e325E;
    address constant VAULT_ADDRESS    = 0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294;
    address constant CEA_FACTORY_ADDR = 0xE86655567d3682c0f141d0F924b9946999DC3381;

    function run() external {
        console.log("========================================");
        console.log("  REGISTERING VAULT & CEAFactory");
        console.log("========================================");
        console.log("");
        console.log("Chain ID:", block.chainid);
        console.log("Caller:  ", msg.sender);
        console.log("");

        _validateConfiguration();

        vm.startBroadcast();
        _registerVault();
        _registerCEAFactory();
        vm.stopBroadcast();

        _verifyRegistration();
        _printSummary();
    }

    function _validateConfiguration() internal view {
        console.log("--- Pre-Registration Validation ---");
        console.log("");

        require(GATEWAY_PROXY != address(0), "GATEWAY_PROXY not set");
        require(VAULT_ADDRESS != address(0), "VAULT_ADDRESS not set");
        require(CEA_FACTORY_ADDR != address(0), "CEA_FACTORY_ADDR not set");

        // Verify vault has code
        uint256 vaultCodeSize;
        address vaultAddr = VAULT_ADDRESS;
        assembly {
            vaultCodeSize := extcodesize(vaultAddr)
        }
        require(vaultCodeSize > 0, "Vault contract not found at VAULT_ADDRESS");

        // Verify CEAFactory has code
        uint256 ceaCodeSize;
        address ceaAddr = CEA_FACTORY_ADDR;
        assembly {
            ceaCodeSize := extcodesize(ceaAddr)
        }
        require(ceaCodeSize > 0, "CEAFactory contract not found at CEA_FACTORY_ADDR");

        console.log("OK: Gateway proxy found:", GATEWAY_PROXY);
        console.log("OK: Vault found:", VAULT_ADDRESS);
        console.log("OK: CEAFactory found:", CEA_FACTORY_ADDR);
        console.log("");
    }

    function _registerVault() internal {
        console.log("--- Registering Vault ---");
        UniversalGatewayV0 gateway = UniversalGatewayV0(payable(GATEWAY_PROXY));
        gateway.setVault(VAULT_ADDRESS);
        console.log("setVault() called with:", VAULT_ADDRESS);
        console.log("");
    }

    function _registerCEAFactory() internal {
        console.log("--- Registering CEAFactory ---");
        UniversalGatewayV0 gateway = UniversalGatewayV0(payable(GATEWAY_PROXY));
        gateway.setCEAFactory(CEA_FACTORY_ADDR);
        console.log("setCEAFactory() called with:", CEA_FACTORY_ADDR);
        console.log("");
    }

    function _verifyRegistration() internal view {
        console.log("--- Registration Verification ---");
        UniversalGatewayV0 gateway = UniversalGatewayV0(payable(GATEWAY_PROXY));

        address vault = gateway.VAULT();
        address ceaFactory = gateway.CEA_FACTORY();

        require(vault == VAULT_ADDRESS, "VAULT not set correctly");
        require(ceaFactory == CEA_FACTORY_ADDR, "CEA_FACTORY not set correctly");

        // Verify VAULT_ROLE was granted to vault
        bytes32 vaultRole = gateway.VAULT_ROLE();
        require(gateway.hasRole(vaultRole, VAULT_ADDRESS), "VAULT_ROLE not granted to Vault");

        console.log("OK: VAULT =", vault);
        console.log("OK: CEA_FACTORY =", ceaFactory);
        console.log("OK: VAULT_ROLE granted to Vault");
        console.log("");
    }

    function _printSummary() internal view {
        console.log("========================================");
        console.log("     REGISTRATION SUMMARY");
        console.log("========================================");
        console.log("");
        console.log("Gateway Proxy:   ", GATEWAY_PROXY);
        console.log("Vault:           ", VAULT_ADDRESS);
        console.log("CEAFactory:      ", CEA_FACTORY_ADDR);
        console.log("");
        console.log("========================================");
        console.log("NEXT STEPS:");
        console.log("1. Run moveFunds.s.sol to migrate USDT to Vault");
        console.log("========================================");
    }
}
