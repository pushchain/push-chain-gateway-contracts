// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGatewayV0 } from "../../src/UniversalGatewayV0.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title UpgradeGatewayV0_1_BSCTestnet
 * @notice Upgrade 1: Deploy new UniversalGatewayV0 implementation (includes moveFunds_temp)
 *         and upgrade the existing BSC Testnet proxy.
 *
 * USAGE:
 * forge script script/bscTestnet/upgradeGatewayV0_upgrade1.s.sol:UpgradeGatewayV0_1_BSCTestnet \
 *   --rpc-url $BSC_TESTNET_RPC_URL --private-key $KEY --broadcast --slow -vvv
 */
contract UpgradeGatewayV0_1_BSCTestnet is Script {
    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // ── BSC Testnet configuration ──────────────────────────────────────────
    // Updated after Phase 1 (Vault deployment)
    address constant GATEWAY_PROXY = 0x44aFFC61983F4348DdddB886349eb992C061EaC0;
    // ──────────────────────────────────────────────────────────────────────

    address public oldImplementation;
    address public newImplementation;
    address public proxyAdmin;
    uint256 public upgradeChainId;

    function run() external {
        upgradeChainId = block.chainid;
        require(upgradeChainId == 97, "Wrong chain: expected BSC Testnet (97)");

        console.log("========================================");
        console.log("  UPGRADE 1: UniversalGatewayV0");
        console.log("  (includes moveFunds_temp) - BSC TESTNET");
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

    function _validateConfiguration() internal view {
        console.log("--- Pre-Upgrade Validation ---");
        require(GATEWAY_PROXY != address(0), "GATEWAY_PROXY not set");

        uint256 proxyCodeSize;
        address proxyAddr = GATEWAY_PROXY;
        assembly { proxyCodeSize := extcodesize(proxyAddr) }
        require(proxyCodeSize > 0, "Gateway proxy not found");

        address proxyAdminAddr = _getProxyAdmin();
        address owner = ProxyAdmin(proxyAdminAddr).owner();
        require(msg.sender == owner, "Caller is not ProxyAdmin owner");

        console.log("OK: Proxy found:", GATEWAY_PROXY);
        console.log("OK: ProxyAdmin:", proxyAdminAddr);
        console.log("OK: Owner:", owner);
        console.log("");
    }

    function _recordOldImplementation() internal {
        console.log("--- Recording Old Implementation ---");
        proxyAdmin = _getProxyAdmin();
        oldImplementation = _getImplementation();
        console.log("Old Implementation:", oldImplementation);
        console.log("");
    }

    function _deployNewImplementation() internal {
        console.log("--- Deploying New Implementation ---");
        UniversalGatewayV0 impl = new UniversalGatewayV0();
        newImplementation = address(impl);
        console.log("New Implementation:", newImplementation);
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

    function _verifyUpgrade() internal view {
        console.log("--- Upgrade Verification ---");
        address currentImpl = _getImplementation();
        require(currentImpl == newImplementation, "Implementation not updated");
        require(currentImpl != oldImplementation, "Implementation unchanged");

        UniversalGatewayV0 gateway = UniversalGatewayV0(payable(GATEWAY_PROXY));
        address tss = gateway.TSS_ADDRESS();
        require(tss != address(0), "TSS_ADDRESS corrupted");

        console.log("OK: Implementation updated:", currentImpl);
        console.log("OK: TSS_ADDRESS preserved:", tss);
        console.log("OK: VAULT (not yet set):", gateway.VAULT());
        console.log("OK: CEA_FACTORY (not yet set):", gateway.CEA_FACTORY());
        console.log("OK: version:", gateway.version());
        console.log("");
    }

    function _printUpgradeSummary() internal view {
        console.log("========================================");
        console.log("     UPGRADE 1 SUMMARY - BSC TESTNET");
        console.log("========================================");
        console.log("Chain ID:", upgradeChainId);
        console.log("Gateway Proxy:       ", GATEWAY_PROXY);
        console.log("Proxy Admin:         ", proxyAdmin);
        console.log("Old Implementation:  ", oldImplementation);
        console.log("New Implementation:  ", newImplementation);
        console.log("========================================");
        console.log("NEXT STEPS:");
        console.log("1. Run registerVault.s.sol to set VAULT and CEA_FACTORY");
        console.log("2. Run moveFunds.s.sol to migrate USDT from Gateway to Vault");
        console.log("3. Remove moveFunds_temp() from source, then run upgradeGatewayV0_upgrade2.s.sol");
        console.log("========================================");
    }

    function _getProxyAdmin() internal view returns (address) {
        return address(uint160(uint256(vm.load(GATEWAY_PROXY, _ADMIN_SLOT))));
    }

    function _getImplementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(GATEWAY_PROXY, _IMPLEMENTATION_SLOT))));
    }
}
