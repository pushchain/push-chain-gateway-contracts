// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import { UniversalGatewayPC } from "../../src/UniversalGatewayPC.sol";
import { IPRC20 } from "../../src/interfaces/IPRC20.sol";

contract WithdrawScript is Script {
    // Reserved proxy address
    address constant PROXY = 0x00000000000000000000000000000000000000B0;

    address prc20Weth = 0x00cb38A885cf8D0B2dDfd19Bd1c04aAAC44C5a86;
    address prc20Usdt = 0x482AB0cAA8192857C38D1bCD1d37498cBb7a765c;
    address prc20Eth = 0x69c5560bB765a935C345f507D2adD34253FBe41b;
    function run() external {
        vm.startBroadcast();

        // 1. Deploy new implementation with fixed event
        UniversalGatewayPC proxy = UniversalGatewayPC(0x00000000000000000000000000000000000000B0);

        IPRC20(prc20Weth).approve(PROXY, 1e32);
        IPRC20(prc20Usdt).approve(PROXY, 1e32);
        IPRC20(prc20Eth).approve(PROXY, 1e32);

        bytes memory to = new bytes(1);
        uint256 amount = 1e10;

        proxy.withdraw(to, prc20Weth, amount, 21000, PROXY);

        vm.stopBroadcast();
    }
}
