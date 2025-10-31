// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {UniversalGatewayV0} from "../../src/UniversalGatewayV0.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title DeployUniversalGatewayV0
 * @notice Deploy UniversalGatewayV0 (legacy version with USDT support)
 */
contract DeployUniversalGatewayV0 is Script {
    using stdJson for string;

    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    string network;
    address deployer;
    address weth;
    address uniswapV3Factory;
    address uniswapV3Router;
    address ethUsdFeed;
    address usdt;
    address usdtUsdFeed;

    address admin;
    address pauser;
    address tss;

    uint256 constant MIN_CAP_USD = 1e18;
    uint256 constant MAX_CAP_USD = 10e18;

    address public implementationAddress;
    address public proxyAddress;

    function run() external {
        network = vm.envOr("NETWORK", string("sepolia"));
        console.log("=== DEPLOYING UNIVERSAL GATEWAY V0 TO %s ===", network);

        string memory envKey = string.concat("PRIVATE_KEY_", network);
        uint256 deployerKey = vm.envUint(envKey);
        deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        _loadConfig();
        _deployImplementation();
        _deployProxy();
        _configure();

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
        usdt = abi.decode(
            json.parseRaw(string.concat(path, ".usdt")),
            (address)
        );
        usdtUsdFeed = abi.decode(
            json.parseRaw(string.concat(path, ".usdtUsdFeed")),
            (address)
        );

        admin = deployer;
        pauser = deployer;
        tss = deployer;

        console.log("Network:", network);
        console.log("Deployer:", deployer);
        console.log("WETH:", weth);
        console.log("USDT:", usdt);
    }

    function _deployImplementation() internal {
        console.log("\n--- Deploying Implementation ---");
        UniversalGatewayV0 impl = new UniversalGatewayV0();
        implementationAddress = address(impl);
        console.log("Implementation:", implementationAddress);
    }

    function _deployProxy() internal {
        console.log("\n--- Deploying Proxy ---");

        bytes memory initData = abi.encodeWithSelector(
            UniversalGatewayV0.initialize.selector,
            admin,
            pauser,
            tss,
            MIN_CAP_USD,
            MAX_CAP_USD,
            uniswapV3Factory,
            uniswapV3Router,
            weth,
            usdt,
            usdtUsdFeed,
            ethUsdFeed
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            implementationAddress,
            deployer,
            initData
        );

        proxyAddress = address(proxy);
        console.log("Proxy:", proxyAddress);
    }

    function _configure() internal {
        console.log("\n--- Configuring ---");
        UniversalGatewayV0 gateway = UniversalGatewayV0(payable(proxyAddress));

        gateway.setChainlinkStalePeriod(24 hours);
        gateway.setL2SequencerFeed(address(0));

        console.log("Configuration completed");
    }

    function _logSummary() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Network:", network);
        console.log("Implementation:", implementationAddress);
        console.log("Proxy:", proxyAddress);
        console.log("Proxy Admin:", getProxyAdmin());
        console.log("USDT:", usdt);
        console.log(
            "\n Addresses saved to: broadcast/DeployUniversalGatewayV0.sol/%s/run-latest.json",
            block.chainid
        );
    }

    /**
     * @notice Get the admin of the TransparentProxy
     * @return proxyADMIN The address of the proxy admin
     */
    function getProxyAdmin() public view returns (address proxyADMIN) {
        // Read admin directly from the EIP-1967 admin slot on the proxy
        bytes32 raw = vm.load(proxyAddress, _ADMIN_SLOT);
        proxyADMIN = address(uint160(uint256(raw)));
    }
}
