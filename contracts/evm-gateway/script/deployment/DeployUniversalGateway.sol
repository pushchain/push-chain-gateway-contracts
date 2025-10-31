// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {UniversalGateway} from "../../src/UniversalGateway.sol";
import {Vault} from "../../src/Vault.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title DeployUniversalGateway
 * @notice Deploy UniversalGateway + Vault together (handles circular dependency)
 */
contract DeployUniversalGateway is Script {
    using stdJson for string;

    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    string network;
    address deployer;
    address weth;
    address uniswapV3Factory;
    address uniswapV3Router;
    address ethUsdFeed;

    address admin;
    address pauser;
    address tss;

    uint256 constant MIN_CAP_USD = 1e18;
    uint256 constant MAX_CAP_USD = 10e18;

    address public vaultImplAddress;
    address public vaultProxyAddress;
    address public gatewayImplAddress;
    address public gatewayProxyAddress;

    function run() external {
        network = vm.envOr("NETWORK", string("sepolia"));
        console.log(
            "=== DEPLOYING UNIVERSAL GATEWAY + VAULT TO %s ===",
            network
        );

        string memory envKey = string.concat("PRIVATE_KEY_", network);
        uint256 deployerKey = vm.envUint(envKey);
        deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        _loadConfig();
        _deployImplementations();
        _deployProxies();
        _linkContracts();

        vm.stopBroadcast();

        _logSummary();
    }

    function _loadConfig() internal {
        console.log("\n--- Loading Configuration ---");

        string memory configPath = "config/chainConfig.json";
        string memory json = vm.readFile(configPath);
        string memory path = string.concat(".", network);

        weth = abi.decode(
            json.parseRaw(string.concat(path, ".weth")),
            (address)
        );
        uniswapV3Factory = abi.decode(
            json.parseRaw(string.concat(path, ".uniswapV3Factory")),
            (address)
        );
        uniswapV3Router = abi.decode(
            json.parseRaw(string.concat(path, ".uniswapV3Router")),
            (address)
        );
        ethUsdFeed = abi.decode(
            json.parseRaw(string.concat(path, ".ethUsdFeed")),
            (address)
        );

        admin = deployer;
        pauser = deployer;
        tss = deployer;

        console.log("Network:", network);
        console.log("Deployer:", deployer);
    }

    function _deployImplementations() internal {
        console.log("\n--- Deploying Implementations ---");

        Vault vaultImpl = new Vault();
        vaultImplAddress = address(vaultImpl);
        console.log("Vault Implementation:", vaultImplAddress);

        UniversalGateway gatewayImpl = new UniversalGateway();
        gatewayImplAddress = address(gatewayImpl);
        console.log("Gateway Implementation:", gatewayImplAddress);
    }

    function _deployProxies() internal {
        console.log("\n--- Deploying Proxies ---");

        // Deploy Gateway with placeholder vault (use impl address)
        bytes memory gatewayInitData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin,
            tss,
            vaultImplAddress, // Placeholder - will update
            MIN_CAP_USD,
            MAX_CAP_USD,
            uniswapV3Factory,
            uniswapV3Router,
            weth
        );

        TransparentUpgradeableProxy gatewayProxy = new TransparentUpgradeableProxy(
                gatewayImplAddress,
                deployer,
                gatewayInitData
            );
        gatewayProxyAddress = address(gatewayProxy);
        console.log("Gateway Proxy:", gatewayProxyAddress);

        // Deploy Vault with Gateway address
        bytes memory vaultInitData = abi.encodeWithSelector(
            Vault.initialize.selector,
            admin,
            pauser,
            tss,
            gatewayProxyAddress
        );

        TransparentUpgradeableProxy vaultProxy = new TransparentUpgradeableProxy(
                vaultImplAddress,
                deployer,
                vaultInitData
            );
        vaultProxyAddress = address(vaultProxy);
        console.log("Vault Proxy:", vaultProxyAddress);
    }

    function _linkContracts() internal {
        console.log("\n--- Linking Gateway to Vault ---");

        UniversalGateway gateway = UniversalGateway(
            payable(gatewayProxyAddress)
        );
        gateway.pause();
        gateway.updateVault(vaultProxyAddress);
        gateway.unpause();

        console.log("Linked!");
    }

    function _logSummary() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network:", network);
        console.log("Vault Implementation:", vaultImplAddress);
        console.log("Vault Proxy:", vaultProxyAddress);
        console.log("Vault Proxy Admin:", getProxyAdmin(vaultProxyAddress));
        console.log("Gateway Implementation:", gatewayImplAddress);
        console.log("Gateway Proxy:", gatewayProxyAddress);
        console.log("Gateway Proxy Admin:", getProxyAdmin(gatewayProxyAddress));

        console.log("\n*** IMPORTANT:");
        console.log(
            "  1. Addresses saved to: broadcast/DeployUniversalGateway.sol/%s/run-latest.json",
            block.chainid
        );
        console.log("  2. Configure Gateway after deployment:");
        console.log("     - setEthUsdFeed(%s)", ethUsdFeed);
        console.log("     - setChainlinkStalePeriod(24 hours)");
        console.log("     - setL2SequencerFeed(address) if on L2");
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
