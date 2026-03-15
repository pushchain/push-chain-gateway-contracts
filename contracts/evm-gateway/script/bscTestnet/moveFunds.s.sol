// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGatewayV0 } from "../../src/testnetV0/UniversalGatewayV0.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MoveFunds_BSCTestnet
 * @notice Calls moveFunds_temp() on the upgraded UniversalGatewayV0 to migrate
 *         USDT from the Gateway to the Vault on BSC Testnet.
 *         Must run AFTER registerVault.s.sol and BEFORE upgradeGatewayV0_upgrade2.s.sol.
 *
 * USAGE:
 * forge script script/bscTestnet/moveFunds.s.sol:MoveFunds_BSCTestnet \
 *   --rpc-url $BSC_TESTNET_RPC_URL --private-key $KEY --broadcast --slow -vvv
 */
contract MoveFunds_BSCTestnet is Script {
    // ── BSC Testnet configuration ──────────────────────────────────────────
    address constant GATEWAY_PROXY = 0x44aFFC61983F4348DdddB886349eb992C061EaC0;
    address constant USDT          = 0xBC14F348BC9667be46b35Edc9B68653d86013DC5;
    // TODO: fill VAULT_ADDRESS after Phase 1 deployment
    address constant VAULT_ADDRESS = 0xE52AC4f8DD3e0263bDF748F3390cdFA1f02be881;
    // ──────────────────────────────────────────────────────────────────────

    function run() external {
        require(block.chainid == 97, "Wrong chain: expected BSC Testnet (97)");
        require(VAULT_ADDRESS != address(0), "VAULT_ADDRESS not set - fill in after Phase 1");

        console.log("========================================");
        console.log("  MIGRATE USDT: Gateway -> Vault - BSC TESTNET");
        console.log("========================================");
        console.log("Chain ID:", block.chainid);
        console.log("Caller:  ", msg.sender);
        console.log("");

        // Validate VAULT is registered
        UniversalGatewayV0 gateway = UniversalGatewayV0(payable(GATEWAY_PROXY));
        require(gateway.VAULT() == VAULT_ADDRESS, "VAULT not registered - run registerVault first");

        // Record balances before
        uint256 gwBefore   = IERC20(USDT).balanceOf(GATEWAY_PROXY);
        uint256 vaultBefore = IERC20(USDT).balanceOf(VAULT_ADDRESS);

        console.log("Gateway USDT before:", gwBefore);
        console.log("Vault USDT before:  ", vaultBefore);
        require(gwBefore > 0, "Gateway has no USDT to migrate");
        console.log("");

        // Call moveFunds_temp() via low-level call because the function is present in the
        // Upgrade 1 implementation on BSC Testnet but has already been removed from the
        // current source tree (it was removed after the Sepolia migration).
        bytes4 selector = bytes4(keccak256("moveFunds_temp()"));
        vm.startBroadcast();
        (bool ok, bytes memory data) = GATEWAY_PROXY.call(abi.encodeWithSelector(selector));
        if (!ok) {
            assembly { revert(add(data, 32), mload(data)) }
        }
        vm.stopBroadcast();

        // Verify balances after
        uint256 gwAfter    = IERC20(USDT).balanceOf(GATEWAY_PROXY);
        uint256 vaultAfter = IERC20(USDT).balanceOf(VAULT_ADDRESS);

        console.log("Gateway USDT after: ", gwAfter);
        console.log("Vault USDT after:   ", vaultAfter);

        require(gwAfter == 0, "Gateway USDT balance is not 0 after migration");
        require(vaultAfter == vaultBefore + gwBefore, "Vault USDT did not increase by migrated amount");

        console.log("========================================");
        console.log("OK: Migration complete -", gwBefore, "USDT moved to Vault");
        console.log("========================================");
        console.log("NEXT STEPS:");
        console.log("1. Remove moveFunds_temp() from src/UniversalGatewayV0.sol");
        console.log("2. forge build && forge test -vv");
        console.log("3. Run upgradeGatewayV0_upgrade2.s.sol");
        console.log("========================================");
    }
}
