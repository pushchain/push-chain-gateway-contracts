// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGatewayV0 } from "../../src/testnetV0/UniversalGatewayV0.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title UpgradeGatewayV0_Base_BSCTestnet
 * @notice Simple upgrade script: deploys a new UniversalGatewayV0 implementation
 *         and upgrades the existing BSC Testnet proxy. No migration steps.
 *
 * USAGE:
 * forge script script/bscTestnet/upgradeGatewayV0_upgradeBase.s.sol:UpgradeGatewayV0_Base_BSCTestnet \
 *   --rpc-url $BSC_TESTNET_RPC_URL --private-key $KEY --broadcast -vvv
 */
contract UpgradeGatewayV0_Base_BSCTestnet is Script {
    // ========================================
    //        EIP-1967 PROXY CONSTANTS
    // ========================================
    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // ========================================
    //     CONFIGURATION
    // ========================================
    address constant GATEWAY_PROXY = 0x44aFFC61983F4348DdddB886349eb992C061EaC0;

    // ========================================
    //         UPGRADE STATE
    // ========================================
    address public oldImplementation;
    address public newImplementation;
    address public proxyAdmin;
    uint256 public upgradeChainId;

    // ========================================
    //         MAIN
    // ========================================
    function run() external {
        upgradeChainId = block.chainid;
        require(upgradeChainId == 97, "Wrong chain: expected BSC Testnet (97)");

        console.log("========================================");
        console.log("  UPGRADING UniversalGatewayV0");
        console.log("  BSC TESTNET");
        console.log("========================================");
        console.log("Chain ID:", upgradeChainId);
        console.log("Upgrader:", msg.sender);
        console.log("");

        _validateConfiguration();
        _recordOldImplementation();

        vm.startBroadcast();
        _deployNewImplementation();
        _performUpgrade();
        _verifyUpgrade();
        vm.stopBroadcast();

        _printUpgradeSummary();
    }

    // ========================================
    //         VALIDATION
    // ========================================
    function _validateConfiguration() internal view {
        console.log("--- Pre-Upgrade Validation ---");

        uint256 codeSize;
        address proxyAddr = GATEWAY_PROXY;
        assembly { codeSize := extcodesize(proxyAddr) }
        require(codeSize > 0, "Gateway proxy not found at GATEWAY_PROXY");

        address proxyAdminAddr = _getProxyAdmin();
        address owner = ProxyAdmin(proxyAdminAddr).owner();
        require(msg.sender == owner, "Caller is not ProxyAdmin owner");

        console.log("OK: Proxy found at:", GATEWAY_PROXY);
        console.log("OK: ProxyAdmin:", proxyAdminAddr);
        console.log("OK: ProxyAdmin owner:", owner);
        console.log("OK: Caller authorized for upgrade");
        console.log("");
    }

    function _recordOldImplementation() internal {
        console.log("--- Recording Old Implementation ---");
        proxyAdmin = _getProxyAdmin();
        oldImplementation = _getImplementation();
        console.log("Old Implementation:", oldImplementation);
        console.log("");
    }

    // ========================================
    //         UPGRADE STEPS
    // ========================================
    function _deployNewImplementation() internal {
        console.log("--- Deploying New Implementation ---");
        UniversalGatewayV0 impl = new UniversalGatewayV0();
        newImplementation = address(impl);
        console.log("New Implementation deployed at:", newImplementation);
        console.log("");
    }

    function _performUpgrade() internal {
        console.log("--- Performing Upgrade ---");
        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(GATEWAY_PROXY),
            newImplementation,
            ""
        );
        console.log("Upgrade executed");
        console.log("");
    }

    // ========================================
    //         VERIFICATION
    // ========================================
    function _verifyUpgrade() internal view {
        console.log("--- Upgrade Verification ---");

        address currentImpl = _getImplementation();
        require(currentImpl == newImplementation, "Implementation not updated");
        require(currentImpl != oldImplementation, "Implementation unchanged");

        UniversalGatewayV0 gateway = UniversalGatewayV0(payable(GATEWAY_PROXY));
        address tss     = gateway.TSS_ADDRESS();
        address vault   = gateway.VAULT();
        address ceaFact = gateway.CEA_FACTORY();

        require(tss != address(0), "TSS_ADDRESS corrupted");

        console.log("OK: Implementation updated successfully");
        console.log("OK: TSS_ADDRESS intact:", tss);
        console.log("OK: VAULT intact:", vault);
        console.log("OK: CEA_FACTORY intact:", ceaFact);
        console.log("");
    }

    function _printUpgradeSummary() internal view {
        console.log("========================================");
        console.log("     UPGRADE SUMMARY");
        console.log("========================================");
        console.log("Chain ID:", upgradeChainId);
        console.log("Upgrader:", msg.sender);
        console.log("");
        console.log("Gateway Proxy:        ", GATEWAY_PROXY);
        console.log("Proxy Admin:          ", proxyAdmin);
        console.log("");
        console.log("Old Implementation:   ", oldImplementation);
        console.log("New Implementation:   ", newImplementation);
        console.log("");
        console.log("========================================");
        console.log("Upgrade Complete!");
        console.log("========================================");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Verify new implementation on BscScan");
        console.log("2. Update docs/addresses/bsc-testnet.md");
        console.log("3. Call setCEAFactory(0xe2182dae2dc11cBF6AA6c8B1a7f9c8315A6B0719) if needed");
    }

    // ========================================
    //         HELPERS
    // ========================================
    function _getProxyAdmin() internal view returns (address) {
        return address(uint160(uint256(vm.load(GATEWAY_PROXY, _ADMIN_SLOT))));
    }

    function _getImplementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(GATEWAY_PROXY, _IMPLEMENTATION_SLOT))));
    }
}

// ========================================
//      VERIFICATION COMMAND
// ========================================
//
// forge verify-contract --chain bsc-testnet \
//   --constructor-args $(cast abi-encode "constructor()") \
//   <NEW_IMPL_ADDR> src/testnetV0/UniversalGatewayV0.sol:UniversalGatewayV0 \
//   --etherscan-api-key $BSC_SCAN_API_KEY
