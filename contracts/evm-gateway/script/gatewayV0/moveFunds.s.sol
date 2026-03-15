// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { UniversalGatewayV0 } from "../../src/testnetV0/UniversalGatewayV0.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MoveFunds
 * @notice ALREADY EXECUTED — Migration complete on 2026-02-22.
 *         19067027857453 USDT migrated from Gateway to Vault on Sepolia.
 *         moveFunds_temp() has been removed from the implementation.
 *         This script is retained for historical reference only.
 */
contract MoveFunds is Script {
    function run() external pure {
        revert("Migration already complete. moveFunds_temp removed from implementation.");
    }
}
