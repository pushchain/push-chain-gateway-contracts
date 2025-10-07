// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../BaseTest.t.sol";
import {IUniversalGateway} from "../../src/interfaces/IUniversalGateway.sol";
import {UniversalGateway} from "../../src/UniversalGateway.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {UniversalPayload, RevertInstructions, TX_TYPE} from "../../src/libraries/Types.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

/**
 * @title   GatewayBlockRateLimitTest
 * @notice  Test suite for the block-based rate limiting feature of UniversalGateway
 */
contract GatewayBlockRateLimitTest is BaseTest {
    uint256 constant BLOCK_USD_CAP_1E18 = 10e18; // $10 block cap
    uint256 constant HALF_BLOCK_CAP_1E18 = 5e18;  // $5
    uint256 constant SMALL_AMOUNT_1E18 = 2e18;    // $2
    uint256 constant LARGE_AMOUNT_1E18 = 12e18;   // $12 (exceeds block cap)

    // Mock ETH price: $4000 per ETH
    uint256 constant ETH_PRICE_USD_1E8 = 400000000000; 
    
    uint256 constant ETH_FOR_10_USD = 2500000000000000; // 0.0025 ETH = $10 at $4000/ETH
    uint256 constant ETH_FOR_5_USD = 1250000000000000;  // 0.00125 ETH = $5
    uint256 constant ETH_FOR_2_USD = 500000000000000;   // 0.0005 ETH = $2
    uint256 constant ETH_FOR_12_USD = 3000000000000000; // 0.003 ETH = $12
    
    address public revertingTSS;
    
    MockAggregatorV3 public mockEthUsdFeed;

    function setUp() public override {
        super.setUp();
        
        // Create reverting TSS contract
        revertingTSS = address(new RevertingReceiver());
        
        tokenA = new MockERC20("Mock Token", "MOCK", 18, 1000 ether);
        tokenA.mint(user1, 1000 ether);
        tokenA.mint(user2, 1000 ether);
        
        // Deploy mock price feed with fixe d ETH price     
        mockEthUsdFeed = new MockAggregatorV3(8);
        mockEthUsdFeed.setAnswer(int256(ETH_PRICE_USD_1E8), block.timestamp);
        
        vm.startPrank(admin);
        gateway.setEthUsdFeed(address(mockEthUsdFeed));
        
        address[] memory tokens = new address[](1);
        bool[] memory supported = new bool[](1);
        tokens[0] = address(tokenA);
        supported[0] = true;
        gateway.modifySupportForToken(tokens, supported);
        
        // Configure gateway with mock WETH and dummy routers
        gateway.setRouters(address(0x1), address(0x2)); 
        vm.stopPrank();
    }

    // ===========================
    // SETUP / ADMIN TESTS
    // ===========================
    
    function testSetBlockUsdCap_HappyPath() public {
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        assertEq(gateway.BLOCK_USD_CAP(), BLOCK_USD_CAP_1E18, "Block USD cap not set correctly");
    }
    
    function testSetBlockUsdCap_OnlyAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
    }
    
    // Note: As of now, disabling BLOCK CAP doesn't REVERT. It returns.
    function testDisableBlockCap() public {
        // First enable the cap
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        // Then disable it
        vm.prank(admin);
        gateway.setBlockUsdCap(0);
        
        assertEq(gateway.BLOCK_USD_CAP(), 0, "Block USD cap not disabled");
        
        // Test that with cap disabled, multiple transactions can go through
        uint256 totalAmount = ETH_FOR_5_USD * 5; // 5x the cap if it was enabled
        
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user1);
            gateway.sendTxWithGas{value: ETH_FOR_5_USD}(
                _buildDefaultPayload(),
                _buildDefaultRevertInstructions(),
                bytes("")
            );
        }
        
        // If we got here without reverting, the test passed
    }
    
    // ===========================
    // INTERPLAY WITH PER-TX USD CAP
    // ===========================
    
    function testPerTxCapFailsFirst() public {
        // Set block cap higher than per-tx max cap
        uint256 perTxMaxCap = gateway.MAX_CAP_UNIVERSAL_TX_USD();
        
        vm.prank(admin);
        gateway.setBlockUsdCap(perTxMaxCap * 2);
        
        // Calculate ETH amount that exceeds per-tx cap but is under block cap
        uint256 ethAmount = _getEthAmountFromUsd(perTxMaxCap + 1e18);
        
        // Send tx that should fail due to per-tx cap, not block cap
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendTxWithGas{value: ethAmount}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
    }
    
    function testSingleCallExceedsBlockCap() public {
        // Set block cap to $10
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        // Set per-tx caps to allow larger amounts
        vm.prank(admin);
        gateway.setCapsUSD(1e18, 20e18); // $1 min, $20 max
        
        // Send tx worth $12 (exceeds block cap)
        vm.prank(user1);
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        gateway.sendTxWithGas{value: ETH_FOR_12_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
    }
    
    function testExactlyEqualToBlockCap() public {
        // Set block cap to $10
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        // Send tx worth exactly $10
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_10_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
    }
    
    // ===========================
    // SAME-BLOCK ACCUMULATION
    // ===========================
    
    function testAccumulateUnderCap() public {
        // Set block cap to $10
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        // Record the current block number to ensure all transactions are in the same block
        uint256 startingBlockNumber = block.number;
        
        // Send first tx: $2
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_2_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Verify we're still in the same block
        assertEq(block.number, startingBlockNumber, "Block number changed unexpectedly");
        
        // Send second tx: $3
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_2_USD + ETH_FOR_2_USD/2}( // $3
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Send third tx: $5
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_5_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Try to send a fourth tx that would exceed the cap - should revert
        vm.prank(user1);
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        gateway.sendTxWithGas{value: ETH_FOR_2_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // If we got here without reverting earlier and the final transaction reverted,
        // it proves that the accumulation worked correctly
    }
    
    function testOverflowOnNthCall() public {
        // Set block cap to $10
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        // Record the current block number
        uint256 startingBlockNumber = block.number;
        
        // Send first tx: $6
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_5_USD + ETH_FOR_2_USD/2}( // $6
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Verify we're still in the same block
        assertEq(block.number, startingBlockNumber, "Block number changed unexpectedly");
        
        // Send second tx: $5 (should revert as total would be $11)
        vm.prank(user1);
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        gateway.sendTxWithGas{value: ETH_FOR_5_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // We should be able to send a smaller tx that fits within the remaining cap
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_2_USD * 2}( // $4
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // But trying to send even $1 more should fail
        vm.prank(user1);
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        gateway.sendTxWithGas{value: ETH_FOR_2_USD/2}( // $1
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
    }
    
    function testCrossSenderGlobalBudget() public {
        // Set block cap to $10
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        // Record the current block number
        uint256 startingBlockNumber = block.number;
        
        // First user sends tx: $6
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_5_USD + ETH_FOR_2_USD/2}( // $6
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Verify we're still in the same block
        assertEq(block.number, startingBlockNumber, "Block number changed unexpectedly");
        
        // Second user sends tx: $5 (should revert as total would be $11)
        vm.prank(user2);
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        gateway.sendTxWithGas{value: ETH_FOR_5_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
    }
    
    // ===========================
    // CROSS-BLOCK RESET
    // ===========================
    
    function testResetOnNextBlock() public {
        // Set block cap to $10
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        // Consume full cap in block N
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_10_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Move to next block
        vm.roll(block.number + 1);
        
        // Should be able to send $10 again in the new block
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_10_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // If we got here without reverting, the test passed
    }
    
    function testPartialUsageThenNextBlock() public {
        // Set block cap to $10
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        // Use $5 in block N
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_5_USD}( // $5
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // We should be able to send another $2 in the same block
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_2_USD}( // $2
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // And another $2
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_2_USD}( // $2
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // But trying to send even $2 more should fail as we've used $9 of $10
        vm.prank(user1);
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        gateway.sendTxWithGas{value: ETH_FOR_2_USD}( // $2
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Move to next block
        vm.roll(block.number + 1);
        
        // Should be able to send $5 in the new block
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_5_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // And another $5
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_5_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // But trying to send even $1 more should fail
        vm.prank(user1);
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        gateway.sendTxWithGas{value: ETH_FOR_2_USD/2}( // $1
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
    }
    
    // ===========================
    // TOKEN GAS ROUTES
    // ===========================
    
    // Note: We're not testing the WETH fast path or ERC20 swap path in these tests
    // as they would require more complex mocking of the Uniswap router and pools.
    // The block cap functionality is tested thoroughly with native ETH transactions,
    // and the same logic applies to post-swap ETH amounts.
    
    // ===========================
    // GAS Route inside Send-Fund Txs
    // ===========================
    
    function testNativeGasLegInSendTxWithFunds() public {
        // Set block cap to $10
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        // Approve token for bridging
        vm.prank(user1);
        tokenA.approve(address(gateway), 1 ether);
        
        // Send tx with native gas worth $5 and token bridge
        vm.prank(user1);
        gateway.sendTxWithFunds{value: ETH_FOR_5_USD}(
            address(tokenA),
            1 ether,
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Send another tx with native gas worth $6 - should fail due to block cap
        vm.prank(user1);
        tokenA.approve(address(gateway), 1 ether);
        
        vm.prank(user1);
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        gateway.sendTxWithFunds{value: ETH_FOR_5_USD + ETH_FOR_2_USD/2}( // $6
            address(tokenA),
            1 ether,
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
    }
    
    // ===========================
    // ROLLBACK SAFETY
    // ===========================
    
    function testRevertAfterCapCheckDoesntLeakUsage() public {
        // Set block cap to $10
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        // Set TSS to reverting contract
        address originalTSS = gateway.tssAddress();
        vm.prank(admin);
        gateway.setTSSAddress(revertingTSS);
        
        // Try to send tx - should revert due to TSS rejecting ETH
        vm.prank(user1);
        vm.expectRevert(Errors.DepositFailed.selector);
        gateway.sendTxWithGas{value: ETH_FOR_5_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Restore normal TSS
        vm.prank(admin);
        gateway.setTSSAddress(originalTSS);
        
        // Send same tx again - should succeed because usage wasn't recorded due to revert
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_5_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Send another tx to test that block cap is working normally
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_5_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Third tx should fail as we've now reached the cap
        vm.prank(user1);
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        gateway.sendTxWithGas{value: ETH_FOR_2_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
    }
    
    // ===========================
    // BOUNDARY & ROUNDING
    // ===========================
    
    function testJustUnderJustOver() public {
        // Set block cap to $10
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        // Calculate amounts that quote to just under and just over the cap
        uint256 justUnder = ETH_FOR_10_USD - 1;
        uint256 justOver = ETH_FOR_10_USD + 1;
        
        // Just under should pass
        vm.prank(user1);
        gateway.sendTxWithGas{value: justUnder}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Reset for next test
        vm.roll(block.number + 1);
        
        // Just over should fail - but with InvalidAmount due to per-tx cap
        // Note: The per-tx cap check happens before the block cap check
        vm.prank(user1);
        vm.expectRevert(Errors.InvalidAmount.selector);
        gateway.sendTxWithGas{value: justOver}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
    }
    
    // Note: sendFunds which is a non-gas route is unaffected by the block cap.
    
    function testFundsOnlyRouteNotThrottled() public {
        // Set block cap to $10
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        // Consume full block cap with gas route
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_10_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Funds-only route should still work
        vm.prank(user1);
        tokenA.approve(address(gateway), 1 ether);
        
        vm.prank(user1);
        gateway.sendFunds(
            user2, // recipient
            address(tokenA),
            1 ether,
            _buildDefaultRevertInstructions()
        );
        
        // If we got here without reverting, the test passed
    }
    
    // ===========================
    // PAUSED STATE & CAP
    // ===========================
    
    function testPausedStateAndCap() public {
        // Set block cap to $10
        vm.prank(admin);
        gateway.setBlockUsdCap(BLOCK_USD_CAP_1E18);
        
        // Use $5 of the cap
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_5_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Pause the contract
        vm.prank(pauser);
        gateway.pause();
        
        // Try to send tx while paused - should revert due to pause
        vm.prank(user1);
        vm.expectRevert("EnforcedPause()");
        gateway.sendTxWithGas{value: ETH_FOR_5_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Unpause
        vm.prank(pauser);
        gateway.unpause();
        
        // Should be able to use remaining $5 of cap
        vm.prank(user1);
        gateway.sendTxWithGas{value: ETH_FOR_5_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
        
        // Additional tx should fail due to cap
        vm.prank(user1);
        vm.expectRevert(Errors.BlockCapLimitExceeded.selector);
        gateway.sendTxWithGas{value: ETH_FOR_2_USD}(
            _buildDefaultPayload(),
            _buildDefaultRevertInstructions(),
            bytes("")
        );
    }
    
    // ===========================
    // HELPER FUNCTIONS
    // ===========================
    
    function _buildDefaultPayload() internal pure returns (UniversalPayload memory) {
        return UniversalPayload({
            to: address(0x123),
            value: 0,
            data: bytes(""),
            gasLimit: 100000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            nonce: 0,
            deadline: 0,
            vType: VerificationType.signedVerification
        });
    }
    
    function _buildDefaultRevertInstructions() internal pure returns (RevertInstructions memory) {
        return RevertInstructions({
            fundRecipient: address(0x456),
            revertMsg: bytes("")
        });
    }
    
    function _getEthAmountFromUsd(uint256 usdAmount1e18) internal view returns (uint256) {
        // USD(1e18) / ETH_price(1e18) * 1e18 = ETH(wei)
        uint256 ethUsdPrice1e18 = uint256(ETH_PRICE_USD_1E8) * 10**10; // Convert from 8 decimals to 18
        return (usdAmount1e18 * 1e18) / ethUsdPrice1e18;
    }
}

/**
 * @title RevertingReceiver
 * @notice Helper contract that reverts when receiving ETH
 * @dev Used to test rollback safety of the block cap feature
 */
contract RevertingReceiver {
    // Always revert when receiving ETH
    receive() external payable {
        revert("RevertingReceiver: ETH transfer rejected");
    }
}
