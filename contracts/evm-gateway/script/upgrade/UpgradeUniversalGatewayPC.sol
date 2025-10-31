// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {UniversalGatewayPC} from "../../src/UniversalGatewayPC.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title UpgradeUniversalGatewayPC
 * @notice Upgrade UniversalGatewayPC proxy to new implementation
 */
contract UpgradeUniversalGatewayPC is Script {
    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    string network;
    address deployer;
    address existingProxy;
    address existingProxyAdmin;

    address public newImplementationAddress;

    function run() external {
        network = vm.envOr("NETWORK", string("push_chain"));
        console.log("=== UPGRADING UNIVERSAL GATEWAY PC ON %s ===", network);

        string memory envKey = string.concat("PRIVATE_KEY_", network);
        uint256 deployerKey = vm.envUint(envKey);
        deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        _loadConfig();
        _deployNewImplementation();
        _upgradeProxy();

        vm.stopBroadcast();

        _logSummary();
    }

    function _loadConfig() internal {
        console.log("\n--- Loading Configuration ---");

        existingProxy = vm.envAddress("PROXY_ADDRESS");
        // Read ProxyAdmin directly from EIP-1967 admin slot
        existingProxyAdmin = address(
            uint160(uint256(vm.load(existingProxy, _ADMIN_SLOT)))
        );

        require(existingProxy != address(0), "PROXY_ADDRESS env var required");

        console.log("Network:", network);
        console.log("Deployer:", deployer);
        console.log("Existing Proxy:", existingProxy);
        console.log("Existing ProxyAdmin:", existingProxyAdmin);
    }

    function _deployNewImplementation() internal {
        console.log("\n--- Deploying New Implementation ---");

        UniversalGatewayPC newImpl = new UniversalGatewayPC();
        newImplementationAddress = address(newImpl);

        console.log("New Implementation:", newImplementationAddress);
    }

    function _upgradeProxy() internal {
        console.log("\n--- Upgrading Proxy ---");

        ProxyAdmin proxyAdmin = ProxyAdmin(existingProxyAdmin);
        ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(
            existingProxy
        );

        proxyAdmin.upgradeAndCall(proxy, newImplementationAddress, "");

        console.log("Upgrade successful!");
    }

    function _logSummary() internal view {
        console.log("\n=== UPGRADE SUMMARY ===");
        console.log("Network:", network);
        console.log("Proxy:", existingProxy);
        console.log("ProxyAdmin:", existingProxyAdmin);
        console.log("New Implementation:", newImplementationAddress);
    }
}
