// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGatewayV0 } from "../../src/UniversalGatewayV0.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title UpgradeGatewayV0
 * @notice Reusable upgrade script for UniversalGatewayV0.
 *         Deploys a new implementation and upgrades the proxy.
 *
 * USAGE (BSC Testnet):
 *   forge script script/gatewayV0/upgradeGatewayV0.s.sol:UpgradeGatewayV0 \
 *     --rpc-url $BSC_TESTNET_RPC_URL --private-key $KEY --broadcast --slow -vvv
 */
contract UpgradeGatewayV0 is Script {
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // ── Configuration ────────────────────────────────────────────────────
    address constant GATEWAY_PROXY = 0x44aFFC61983F4348DdddB886349eb992C061EaC0; // CHECK BEFORE UPGRADE
    // ─────────────────────────────────────────────────────────────────────

    address public oldImplementation;
    address public newImplementation;
    address public proxyAdmin;
    uint256 public upgradeChainId;

    function run() external {
        upgradeChainId = block.chainid;

        console.log("========================================");
        console.log("  UPGRADE: UniversalGatewayV0");
        console.log("========================================");
        console.log("Chain ID:", upgradeChainId);
        console.log("Gateway Proxy:", GATEWAY_PROXY);
        console.log("Upgrader:", msg.sender);
        console.log("");

        _validate();
        _recordOldState();

        vm.startBroadcast();
        _deployNewImplementation();
        _performUpgrade();
        vm.stopBroadcast();

        _verifyUpgrade();
        _printSummary();
    }

    function _validate() internal view {
        console.log("--- Validation ---");

        uint256 codeSize;
        address proxy = GATEWAY_PROXY;
        assembly { codeSize := extcodesize(proxy) }
        require(codeSize > 0, "Gateway proxy has no code");

        address admin = _getProxyAdmin();
        address owner = ProxyAdmin(admin).owner();
        require(msg.sender == owner, "Caller is not ProxyAdmin owner");

        console.log("OK: Proxy found");
        console.log("OK: ProxyAdmin:", admin);
        console.log("OK: Caller authorized");
        console.log("");
    }

    function _recordOldState() internal {
        proxyAdmin = _getProxyAdmin();
        oldImplementation = _getImplementation();

        UniversalGatewayV0 gw = UniversalGatewayV0(payable(GATEWAY_PROXY));
        console.log("--- Current State ---");
        console.log("Implementation:", oldImplementation);
        console.log("Version:", gw.version());
        console.log("TSS_ADDRESS:", gw.TSS_ADDRESS());
        console.log("VAULT:", gw.VAULT());
        console.log("CEA_FACTORY:", gw.CEA_FACTORY());
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
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(GATEWAY_PROXY), newImplementation, "");
        console.log("Upgrade tx submitted");
        console.log("");
    }

    function _verifyUpgrade() internal view {
        console.log("--- Post-Upgrade Verification ---");
        address currentImpl = _getImplementation();
        require(currentImpl == newImplementation, "Implementation not updated");
        require(currentImpl != oldImplementation, "Implementation unchanged");

        UniversalGatewayV0 gw = UniversalGatewayV0(payable(GATEWAY_PROXY));

        address tss = gw.TSS_ADDRESS();
        require(tss != address(0), "TSS_ADDRESS corrupted");
        console.log("OK: TSS_ADDRESS preserved:", tss);

        address vault = gw.VAULT();
        console.log("OK: VAULT preserved:", vault);

        address ceaFactory = gw.CEA_FACTORY();
        console.log("OK: CEA_FACTORY preserved:", ceaFactory);

        console.log("OK: Version:", gw.version());
        console.log("OK: Implementation updated:", currentImpl);
        console.log("");
    }

    function _printSummary() internal view {
        console.log("========================================");
        console.log("     UPGRADE SUMMARY");
        console.log("========================================");
        console.log("Chain ID:", upgradeChainId);
        console.log("Gateway Proxy:       ", GATEWAY_PROXY);
        console.log("Proxy Admin:         ", proxyAdmin);
        console.log("Old Implementation:  ", oldImplementation);
        console.log("New Implementation:  ", newImplementation);
        console.log("========================================");
        console.log("NEXT STEPS:");
        console.log("1. Verify new impl on block explorer:");
        console.log("   forge verify-contract --chain <id> \\");
        console.log("     --constructor-args $(cast abi-encode 'constructor()') \\");
        console.log("     <NEW_IMPL> src/UniversalGatewayV0.sol:UniversalGatewayV0");
        console.log("2. Update docs/addresses with new impl address");
        console.log("========================================");
    }

    function _getProxyAdmin() internal view returns (address) {
        return address(uint160(uint256(vm.load(GATEWAY_PROXY, _ADMIN_SLOT))));
    }

    function _getImplementation() internal view returns (address) {
        return address(uint160(uint256(vm.load(GATEWAY_PROXY, _IMPLEMENTATION_SLOT))));
    }
}
