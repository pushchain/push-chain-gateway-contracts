// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGatewayV0 } from "../../src/UniversalGatewayV0.sol";

/**
 * @title RegisterVault_BSCTestnet
 * @notice Registers Vault and CEAFactory on the upgraded UniversalGatewayV0 on BSC Testnet.
 *         Must run AFTER upgradeGatewayV0_upgrade1.s.sol and BEFORE moveFunds.s.sol.
 *
 * USAGE:
 * forge script script/bscTestnet/registerVault.s.sol:RegisterVault_BSCTestnet \
 *   --rpc-url $BSC_TESTNET_RPC_URL --private-key $KEY --broadcast --slow -vvv
 */
contract RegisterVault_BSCTestnet is Script {
    // ── BSC Testnet configuration ──────────────────────────────────────────
    address constant GATEWAY_PROXY    = 0x44aFFC61983F4348DdddB886349eb992C061EaC0;
    // TODO: fill VAULT_ADDRESS after Phase 1 deployment
    address constant VAULT_ADDRESS    = 0xE52AC4f8DD3e0263bDF748F3390cdFA1f02be881;
    address constant CEA_FACTORY_ADDR = 0xf882C49A3E3d90640bFbAAf992a04c0712A9Af5C;
    // ──────────────────────────────────────────────────────────────────────

    function run() external {
        require(block.chainid == 97, "Wrong chain: expected BSC Testnet (97)");
        require(VAULT_ADDRESS != address(0), "VAULT_ADDRESS not set - fill in after Phase 1");

        console.log("========================================");
        console.log("  REGISTERING VAULT & CEAFactory - BSC TESTNET");
        console.log("========================================");
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

        uint256 vaultCode;
        address v = VAULT_ADDRESS;
        assembly { vaultCode := extcodesize(v) }
        require(vaultCode > 0, "Vault contract not found");

        uint256 ceaCode;
        address c = CEA_FACTORY_ADDR;
        assembly { ceaCode := extcodesize(c) }
        require(ceaCode > 0, "CEAFactory contract not found");

        console.log("OK: Vault found:", VAULT_ADDRESS);
        console.log("OK: CEAFactory found:", CEA_FACTORY_ADDR);
        console.log("");
    }

    function _registerVault() internal {
        console.log("--- Registering Vault ---");
        UniversalGatewayV0(payable(GATEWAY_PROXY)).setVault(VAULT_ADDRESS);
        console.log("setVault() called with:", VAULT_ADDRESS);
        console.log("");
    }

    function _registerCEAFactory() internal {
        console.log("--- Registering CEAFactory ---");
        UniversalGatewayV0(payable(GATEWAY_PROXY)).setCEAFactory(CEA_FACTORY_ADDR);
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
        require(
            gateway.hasRole(gateway.VAULT_ROLE(), VAULT_ADDRESS),
            "VAULT_ROLE not granted to Vault"
        );

        console.log("OK: VAULT =", vault);
        console.log("OK: CEA_FACTORY =", ceaFactory);
        console.log("OK: VAULT_ROLE granted to Vault");
        console.log("");
    }

    function _printSummary() internal view {
        console.log("========================================");
        console.log("     REGISTRATION SUMMARY - BSC TESTNET");
        console.log("========================================");
        console.log("Gateway Proxy:", GATEWAY_PROXY);
        console.log("Vault:        ", VAULT_ADDRESS);
        console.log("CEAFactory:   ", CEA_FACTORY_ADDR);
        console.log("========================================");
        console.log("NEXT STEPS: Run moveFunds.s.sol");
        console.log("========================================");
    }
}
