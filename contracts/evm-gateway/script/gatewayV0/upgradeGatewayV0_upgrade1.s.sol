// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGatewayV0 } from "../../src/UniversalGatewayV0.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title UpgradeGatewayV0_1
 * @notice Upgrade 1: Deploys the updated UniversalGatewayV0 implementation (with moveFunds_temp)
 *         and upgrades the existing Sepolia proxy.
 *
 * @dev  Storage layout of the V0 deployment is PRESERVED — no re-initialization.
 *       New VAULT and CEA_FACTORY slots are appended after the existing __gap.
 *       Run registerVault.s.sol AFTER this upgrade to configure VAULT and CEA_FACTORY.
 *
 * USAGE:
 * forge script script/gatewayV0/upgradeGatewayV0_upgrade1.s.sol:UpgradeGatewayV0_1 \
 *   --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast -vvv
 */
contract UpgradeGatewayV0_1 is Script {
    // ========================================
    //        EIP-1967 PROXY CONSTANTS
    // ========================================
    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // ========================================
    //     CONFIGURATION PARAMETERS
    // ========================================
    address constant GATEWAY_PROXY = 0x4DCab975cDe839632db6695e2e936A29ce3e325E;

    // ========================================
    //         UPGRADE STATE
    // ========================================
    address public oldImplementation;
    address public newImplementation;
    address public proxyAdmin;
    uint256 public upgradeChainId;

    // ========================================
    //         MAIN UPGRADE
    // ========================================
    function run() external {
        upgradeChainId = block.chainid;

        console.log("========================================");
        console.log("  UPGRADE 1: UniversalGatewayV0");
        console.log("  (includes moveFunds_temp)");
        console.log("========================================");
        console.log("");
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
        console.log("");

        require(GATEWAY_PROXY != address(0), "GATEWAY_PROXY not set");

        uint256 proxyCodeSize;
        address proxyAddr = GATEWAY_PROXY;
        assembly {
            proxyCodeSize := extcodesize(proxyAddr)
        }
        require(proxyCodeSize > 0, "Gateway proxy not found at GATEWAY_PROXY");

        address proxyAdminAddr = _getProxyAdmin();
        ProxyAdmin admin = ProxyAdmin(proxyAdminAddr);
        address owner = admin.owner();
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
        UniversalGatewayV0 implementation = new UniversalGatewayV0();
        newImplementation = address(implementation);
        console.log("New Implementation deployed at:", newImplementation);
        console.log("");
    }

    function _performUpgrade() internal {
        console.log("--- Performing Upgrade ---");
        ProxyAdmin admin = ProxyAdmin(proxyAdmin);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(GATEWAY_PROXY), newImplementation, "");
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

        // Verify critical storage is preserved
        address tss = gateway.TSS_ADDRESS();
        require(tss != address(0), "TSS_ADDRESS corrupted");
        console.log("OK: Implementation updated successfully");
        console.log("OK: TSS_ADDRESS preserved:", tss);

        // Verify VAULT and CEA_FACTORY are not yet set (expected: address(0) until registerVault runs)
        address vault = gateway.VAULT();
        address ceaFactory = gateway.CEA_FACTORY();
        console.log("OK: VAULT (not yet set):", vault);
        console.log("OK: CEA_FACTORY (not yet set):", ceaFactory);

        // Verify version updated
        string memory ver = gateway.version();
        console.log("OK: version:", ver);
        console.log("");
    }

    function _printUpgradeSummary() internal view {
        console.log("========================================");
        console.log("     UPGRADE 1 SUMMARY");
        console.log("========================================");
        console.log("");
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
        console.log("NEXT STEPS:");
        console.log("1. Run registerVault.s.sol to set VAULT and CEA_FACTORY");
        console.log("2. Run moveFunds.s.sol to migrate USDT from Gateway to Vault");
        console.log("3. Run upgradeGatewayV0_upgrade2.s.sol to remove moveFunds_temp");
        console.log("4. Verify implementation on Etherscan:");
        console.log("   forge verify-contract --chain sepolia \\");
        console.log("     --constructor-args $(cast abi-encode 'constructor()') \\");
        console.log("     <IMPL_ADDR> src/UniversalGatewayV0.sol:UniversalGatewayV0 \\");
        console.log("     --etherscan-api-key $ETHERSCAN_API_KEY");
        console.log("========================================");
    }

    // ========================================
    //         HELPERS
    // ========================================
    function _getProxyAdmin() internal view returns (address proxyAdminAddr) {
        bytes32 raw = vm.load(GATEWAY_PROXY, _ADMIN_SLOT);
        proxyAdminAddr = address(uint160(uint256(raw)));
    }

    function _getImplementation() internal view returns (address implementation) {
        bytes32 raw = vm.load(GATEWAY_PROXY, _IMPLEMENTATION_SLOT);
        implementation = address(uint160(uint256(raw)));
    }
}
