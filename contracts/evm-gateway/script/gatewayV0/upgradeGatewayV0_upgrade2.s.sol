// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGatewayV0 } from "../../src/UniversalGatewayV0.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { ITransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title UpgradeGatewayV0_2
 * @notice Upgrade 2: Deploys the clean UniversalGatewayV0 implementation (moveFunds_temp REMOVED)
 *         and upgrades the existing Sepolia proxy.
 *
 * @dev  Prerequisites:
 *       1. upgradeGatewayV0_upgrade1.s.sol has been run
 *       2. registerVault.s.sol has been run
 *       3. moveFunds.s.sol has been run (USDT migrated to Vault)
 *       4. moveFunds_temp() has been REMOVED from src/UniversalGatewayV0.sol
 *
 * USAGE:
 * forge script script/gatewayV0/upgradeGatewayV0_upgrade2.s.sol:UpgradeGatewayV0_2 \
 *   --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast -vvv
 */
contract UpgradeGatewayV0_2 is Script {
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
    address constant GATEWAY_PROXY    = 0x4DCab975cDe839632db6695e2e936A29ce3e325E;
    address constant VAULT_ADDRESS    = 0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294;
    address constant CEA_FACTORY_ADDR = 0xE86655567d3682c0f141d0F924b9946999DC3381;
    address constant USDT             = 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06;

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
        console.log("  UPGRADE 2: UniversalGatewayV0");
        console.log("  (clean - no moveFunds_temp)");
        console.log("========================================");
        console.log("");
        console.log("Chain ID:", upgradeChainId);
        console.log("Upgrader:", msg.sender);
        console.log("");

        _validateConfiguration();
        _validatePreConditions();
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
        console.log("OK: Caller authorized");
        console.log("");
    }

    function _validatePreConditions() internal view {
        console.log("--- Pre-Condition Checks ---");
        console.log("");

        UniversalGatewayV0 gateway = UniversalGatewayV0(payable(GATEWAY_PROXY));

        // Verify VAULT is set
        address vault = gateway.VAULT();
        require(vault == VAULT_ADDRESS, "VAULT not registered - run registerVault.s.sol first");
        console.log("OK: VAULT registered:", vault);

        // Verify CEA_FACTORY is set
        address ceaFactory = gateway.CEA_FACTORY();
        require(ceaFactory == CEA_FACTORY_ADDR, "CEA_FACTORY not registered - run registerVault.s.sol first");
        console.log("OK: CEA_FACTORY registered:", ceaFactory);

        // Verify Gateway has no remaining USDT (migration complete)
        uint256 gatewayUsdtBalance = IERC20(USDT).balanceOf(GATEWAY_PROXY);
        require(gatewayUsdtBalance == 0, "Gateway still holds USDT - run moveFunds.s.sol first");
        console.log("OK: Gateway USDT balance is 0 (migration complete)");

        console.log("");
    }

    function _recordOldImplementation() internal {
        console.log("--- Recording Old Implementation ---");
        proxyAdmin = _getProxyAdmin();
        oldImplementation = _getImplementation();
        console.log("Old Implementation (upgrade1):", oldImplementation);
        console.log("");
    }

    // ========================================
    //         UPGRADE STEPS
    // ========================================
    function _deployNewImplementation() internal {
        console.log("--- Deploying New Clean Implementation ---");
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

        // Verify all critical state preserved
        address tss = gateway.TSS_ADDRESS();
        require(tss != address(0), "TSS_ADDRESS corrupted");
        console.log("OK: TSS_ADDRESS preserved:", tss);

        address vault = gateway.VAULT();
        require(vault == VAULT_ADDRESS, "VAULT address corrupted");
        console.log("OK: VAULT preserved:", vault);

        address ceaFactory = gateway.CEA_FACTORY();
        require(ceaFactory == CEA_FACTORY_ADDR, "CEA_FACTORY corrupted");
        console.log("OK: CEA_FACTORY preserved:", ceaFactory);

        console.log("OK: Implementation updated:", currentImpl);
        console.log("");
    }

    function _printUpgradeSummary() internal view {
        console.log("========================================");
        console.log("     UPGRADE 2 SUMMARY");
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
        console.log("1. Verify new implementation on Etherscan:");
        console.log("   forge verify-contract --chain sepolia \\");
        console.log("     --constructor-args $(cast abi-encode 'constructor()') \\");
        console.log("     <IMPL_ADDR> src/UniversalGatewayV0.sol:UniversalGatewayV0 \\");
        console.log("     --etherscan-api-key $ETHERSCAN_API_KEY");
        console.log("2. Confirm moveFunds_temp is no longer callable (should revert)");
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

// Minimal IERC20 for balance check (avoids extra import)
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}
