// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {UniversalGatewayPC} from "../../src/UniversalGatewayPC.sol";
import {VaultPC} from "../../src/VaultPC.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title DeployUniversalGatewayPC
 * @notice Deploy UniversalGatewayPC + VaultPC together for Push Chain
 */
contract DeployUniversalGatewayPC is Script {
    using stdJson for string;

    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    string network;
    address deployer;
    address universalCore;

    address admin;
    address pauser;
    address fundManager;

    address public vaultPCImplAddress;
    address public vaultPCProxyAddress;
    address public gatewayPCImplAddress;
    address public gatewayPCProxyAddress;

    function run() external {
        network = vm.envOr("NETWORK", string("push_chain"));
        console.log("=== DEPLOYING GATEWAY PC + VAULT PC TO %s ===", network);

        string memory envKey = string.concat("PRIVATE_KEY_", network);
        uint256 deployerKey = vm.envUint(envKey);
        deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        _loadConfig();
        _deployImplementations();
        _deployProxies();

        vm.stopBroadcast();

        _logSummary();
    }

    function _loadConfig() internal {
        console.log("\n--- Loading Configuration ---");

        string memory configPath = "config/chainConfig.json";
        string memory json = vm.readFile(configPath);
        string memory path = string.concat(".", network);

        universalCore = abi.decode(
            json.parseRaw(string.concat(path, ".universalCore")),
            (address)
        );
        require(
            universalCore != address(0),
            "UniversalCore must be set in chainConfig.json"
        );

        admin = deployer;
        pauser = deployer;
        fundManager = deployer;

        console.log("Network:", network);
        console.log("Deployer:", deployer);
        console.log("UniversalCore:", universalCore);
    }

    function _deployImplementations() internal {
        console.log("\n--- Deploying Implementations ---");

        VaultPC vaultImpl = new VaultPC();
        vaultPCImplAddress = address(vaultImpl);
        console.log("VaultPC Implementation:", vaultPCImplAddress);

        UniversalGatewayPC gatewayImpl = new UniversalGatewayPC();
        gatewayPCImplAddress = address(gatewayImpl);
        console.log("UniversalGatewayPC Implementation:", gatewayPCImplAddress);
    }

    function _deployProxies() internal {
        console.log("\n--- Deploying Proxies ---");

        // Deploy VaultPC first (no dependencies)
        bytes memory vaultInitData = abi.encodeWithSelector(
            VaultPC.initialize.selector,
            admin,
            pauser,
            fundManager,
            universalCore
        );

        TransparentUpgradeableProxy vaultProxy = new TransparentUpgradeableProxy(
                vaultPCImplAddress,
                deployer,
                vaultInitData
            );
        vaultPCProxyAddress = address(vaultProxy);
        console.log("VaultPC Proxy:", vaultPCProxyAddress);

        // Deploy GatewayPC with VaultPC address
        bytes memory gatewayInitData = abi.encodeWithSelector(
            UniversalGatewayPC.initialize.selector,
            admin,
            pauser,
            universalCore,
            vaultPCProxyAddress
        );

        TransparentUpgradeableProxy gatewayProxy = new TransparentUpgradeableProxy(
                gatewayPCImplAddress,
                deployer,
                gatewayInitData
            );
        gatewayPCProxyAddress = address(gatewayProxy);
        console.log("UniversalGatewayPC Proxy:", gatewayPCProxyAddress);
    }

    function _logSummary() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network:", network);
        console.log("VaultPC Implementation:", vaultPCImplAddress);
        console.log("VaultPC Proxy:", vaultPCProxyAddress);
        console.log("VaultPC Proxy Admin:", getProxyAdmin(vaultPCProxyAddress));
        console.log("UniversalGatewayPC Implementation:", gatewayPCImplAddress);
        console.log("UniversalGatewayPC Proxy:", gatewayPCProxyAddress);
        console.log(
            "UniversalGatewayPC Proxy Admin:",
            getProxyAdmin(gatewayPCProxyAddress)
        );
        console.log(
            "\n Addresses saved to: broadcast/DeployUniversalGatewayPC.sol/%s/run-latest.json",
            block.chainid
        );
    }

    /**
     * @notice Get the admin of a TransparentProxy
     * @param proxy The proxy address
     * @return proxyADMIN The address of the proxy admin
     */
    function getProxyAdmin(
        address proxy
    ) public view returns (address proxyADMIN) {
        // Read admin directly from the EIP-1967 admin slot on the proxy
        bytes32 raw = vm.load(proxy, _ADMIN_SLOT);
        proxyADMIN = address(uint160(uint256(raw)));
    }
}
