// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "../BaseTest.t.sol";
import { IUniversalGateway } from "../../src/interfaces/IUniversalGateway.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { TX_TYPE, RevertInstructions } from "../../src/libraries/Types.sol";
import { UniversalPayload, UniversalTxRequest } from "../../src/libraries/TypesUG.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/**
 * @title CoverageGapsTest
 * @notice Tests for uncovered branches in UniversalGateway.sol
 */
contract CoverageGapsTest is BaseTest {
    // ============================================================
    //  Protocol Fee — TSS Transfer Failure
    // ============================================================

    function testProtocolFee_TSSRejectsETH_Reverts() public {
        // Set INBOUND_FEE > 0
        vm.prank(admin);
        gateway.setProtocolFee(0.001 ether);

        // Set TSS to a contract that rejects ETH
        EthRejectingContract rejecter = new EthRejectingContract();
        vm.prank(admin);
        gateway.setTSS(address(rejecter));

        // Attempt a GAS tx — _collectProtocolFee will try to
        // forward the fee to the rejecting TSS
        vm.prank(user1);
        vm.expectRevert(Errors.DepositFailed.selector);
        gateway.sendUniversalTx{ value: 0.003 ether }(
            _buildGasTxRequest()
        );
    }

    // ============================================================
    //  _handleDeposits — Unsupported ERC20 Token (threshold == 0)
    // ============================================================

    function testHandleDeposits_UnsupportedERC20_Reverts() public {
        // Deploy a new token that is NOT in the supported list
        MockERC20 unsupported = new MockERC20(
            "Unsupported",
            "UNS",
            18,
            0
        );
        unsupported.mint(user1, 1000 ether);
        vm.prank(user1);
        unsupported.approve(address(gateway), type(uint256).max);

        // Build a FUNDS tx request for the unsupported token
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(unsupported),
            amount: 100 ether,
            payload: bytes(""),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.prank(user1);
        vm.expectRevert(Errors.NotSupported.selector);
        gateway.sendUniversalTx(req);
    }

    // ============================================================
    //  _fetchTxType — Native FUNDS with nativeValue == 0
    // ============================================================

    function testFetchTxType_NativeFunds_ZeroNativeValue_Reverts()
        public
    {
        // token=address(0), amount>0, payload empty → FUNDS (native)
        // but nativeValue=0 → fundsIsNative=true, hasNativeValue=false
        // → hits revert at line 923
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 1 ether,
            payload: bytes(""),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTx{ value: 0 }(req);
    }

    // ============================================================
    //  _fetchTxType — Native FUNDS_AND_PAYLOAD with nativeValue == 0
    // ============================================================

    function testFetchTxType_NativeFundsAndPayload_ZeroNativeValue_Reverts()
        public
    {
        UniversalPayload memory payload = buildDefaultPayload();

        // token=address(0), amount>0, payload non-empty
        // but nativeValue=0 → fundsIsNative=true, hasNativeValue=false
        // → hits revert at line 937
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 1 ether,
            payload: abi.encode(payload),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.prank(user1);
        vm.expectRevert(Errors.InvalidInput.selector);
        gateway.sendUniversalTx{ value: 0 }(req);
    }
}

/// @dev Contract that rejects all ETH transfers
contract EthRejectingContract {
    receive() external payable {
        revert("ETH rejected");
    }
}
