// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseTest } from "../BaseTest.t.sol";
import { Vm } from "forge-std/Vm.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import {
    TX_TYPE,
    RevertInstructions,
    UniversalPayload,
    UniversalTxRequest
} from "../../src/libraries/Types.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockCEAFactory } from "../mocks/MockCEAFactory.sol";
import { MockCEA } from "../mocks/MockCEA.sol";

/**
 * @title SendUniversalTxViaCEA Test Suite
 * @notice Tests for sendUniversalTxViaCEA() on UniversalGateway
 * @dev Covers: access control, CEA identity validation, recipient correctness,
 *      TX_TYPE routing, deposit mechanics, caps enforcement, event semantics,
 *      spoof resistance, and E2E scenarios.
 */
contract SendUniversalTxViaCEATest is BaseTest {
    // =========================
    //           EVENTS
    // =========================
    event UniversalTx(
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        bytes payload,
        address revertRecipient,
        TX_TYPE txType,
        bytes signatureData,
        bool viaCEA
    );

    // =========================
    //        TEST STATE
    // =========================
    MockCEAFactory public ceaFactory;
    MockCEA public cea;
    address public mappedUEA;

    // =========================
    //          SETUP
    // =========================
    function setUp() public override {
        super.setUp();

        // Deploy CEAFactory mock and wire to gateway
        ceaFactory = new MockCEAFactory();
        ceaFactory.setVault(address(this));
        vm.label(address(ceaFactory), "CEAFactory");

        vm.prank(admin);
        gateway.setCEAFactory(address(ceaFactory));

        // Deploy a CEA via factory (requires vault as caller)
        mappedUEA = address(0xBEEF);
        address ceaAddr = ceaFactory.deployCEA(mappedUEA);
        cea = MockCEA(payable(ceaAddr));
        vm.label(ceaAddr, "CEA");

        // Support tokenA for epoch rate limits
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = 1_000_000 ether;
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        // Fund CEA with tokens and native
        vm.deal(address(cea), 100 ether);
        tokenA.mint(address(cea), 1_000_000 ether);

        // CEA approves gateway for ERC20
        vm.prank(address(cea));
        tokenA.approve(address(gateway), type(uint256).max);
    }

    // =========================
    //      HELPERS
    // =========================
    function _defaultPayload() internal view returns (bytes memory) {
        return abi.encode(buildDefaultPayload());
    }

    function _buildViaCEARequest(
        address token,
        uint256 amount,
        bytes memory payload
    ) internal view returns (UniversalTxRequest memory) {
        return UniversalTxRequest({
            recipient: mappedUEA,
            token: token,
            amount: amount,
            payload: payload,
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });
    }

    // =====================================================
    //  1. ACCESS CONTROL: Only valid CEAs can call
    // =====================================================

    function test_RevertWhen_CEAFactoryNotSet() public {
        // Zero out CEA_FACTORY via vm.store (slot 20 per storage layout)
        vm.store(address(gateway), bytes32(uint256(20)), bytes32(0));
        assertEq(gateway.CEA_FACTORY(), address(0));

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), 100 ether, _defaultPayload()
        );

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

    function test_RevertWhen_CallerIsNotACEA() public {
        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), 100 ether, _defaultPayload()
        );

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(attacker);
        gateway.sendUniversalTxViaCEA(req);
    }

    function test_RevertWhen_CallerIsEOA() public {
        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), 100 ether, _defaultPayload()
        );

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(user1);
        gateway.sendUniversalTxViaCEA(req);
    }

    // =====================================================
    //  2. CEA IDENTITY VALIDATION (anti-spoof)
    // =====================================================

    function test_RevertWhen_MappedUEAIsZero() public {
        // Deploy a second factory that returns address(0) for getUEAForCEA
        MockCEAFactory badFactory = new MockCEAFactory();
        badFactory.setVault(address(this));
        // Deploy a CEA but then manipulate — use a fresh address not in mapping
        address fakeCEA = address(0xDEAD);

        vm.prank(admin);
        gateway.setCEAFactory(address(badFactory));

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), 100 ether, _defaultPayload()
        );

        // fakeCEA is not in the factory mapping → isCEA returns false
        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(fakeCEA);
        gateway.sendUniversalTxViaCEA(req);
    }

    // =====================================================
    //  3. RECIPIENT CORRECTNESS
    // =====================================================

    function test_RevertWhen_RecipientDoesNotMatchMappedUEA() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0xBAD), // Wrong — not the mapped UEA
            token: address(tokenA),
            amount: 100 ether,
            payload: _defaultPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

    function test_RevertWhen_RecipientIsZero() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(tokenA),
            amount: 100 ether,
            payload: _defaultPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

    function test_RecipientSpoofAttempt_EmitsMappedUEA() public {
        // Even if req.recipient is attacker, validation enforces mapped UEA
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: attacker,
            token: address(tokenA),
            amount: 100 ether,
            payload: _defaultPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        // Reverts because attacker != mappedUEA
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

    // =====================================================
    //  4. TX_TYPE INFERENCE AND ROUTING
    // =====================================================

    function test_RevertWhen_AmountIsZero() public {
        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), 0, _defaultPayload()
        );

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

    function test_RevertWhen_PayloadIsEmpty() public {
        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), 100 ether, bytes("")
        );

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

    function test_RevertWhen_PayloadEmptyAndAmountPositive_FUNDSOnly() public {
        // FUNDS route (no payload) is NOT allowed via CEA
        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), 100 ether, bytes("")
        );

        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

    // =====================================================
    //  5. DEPOSIT MECHANICS: ERC20 FUNDS_AND_PAYLOAD
    // =====================================================

    function test_ERC20_FundsAndPayload_HappyPath() public {
        uint256 amount = 100 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), amount, payload
        );

        uint256 vaultBefore = tokenA.balanceOf(address(this)); // VAULT = address(this) in BaseTest

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(tokenA),
            amount,
            payload,
            req.revertRecipient,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);

        // Vault received tokens
        assertEq(
            tokenA.balanceOf(address(this)),
            vaultBefore + amount,
            "Vault should receive ERC20"
        );
    }

    function test_ERC20_RevertWhen_TokenNotSupported() public {
        // Remove tokenA support
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = 0; // unsupported

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), 100 ether, _defaultPayload()
        );

        vm.expectRevert(Errors.NotSupported.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

    function test_ERC20_RevertWhen_InsufficientAllowance() public {
        // Revoke approval
        vm.prank(address(cea));
        tokenA.approve(address(gateway), 0);

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), 100 ether, _defaultPayload()
        );

        vm.expectRevert();
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

    // =====================================================
    //  6. DEPOSIT MECHANICS: NATIVE FUNDS_AND_PAYLOAD
    // =====================================================

    function test_Native_FundsAndPayload_ExactAmount() public {
        uint256 amount = 1 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(0), amount, payload
        );

        uint256 tssBefore = tss.balance;

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(0),
            amount,
            payload,
            req.revertRecipient,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA{ value: amount }(req);

        assertEq(tss.balance, tssBefore + amount, "TSS should receive native");
    }

    function test_Native_RevertWhen_MsgValueExceedsAmount_NoBatching() public {
        // Gas batching is disallowed — msg.value must equal req.amount exactly
        uint256 fundsAmount = 1 ether;
        uint256 gasTopUp = 0.002 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(0), fundsAmount, payload
        );

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA{ value: fundsAmount + gasTopUp }(req);
    }

    function test_Native_RevertWhen_MsgValueLessThanAmount() public {
        uint256 amount = 2 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(0), amount, payload
        );

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA{ value: 1 ether }(req);
    }

    // =====================================================
    //  7. USD CAPS & PER-BLOCK CAP ENFORCEMENT
    // =====================================================

    function test_ERC20_RevertWhen_MsgValueNonZero_NoBatching() public {
        // ERC-20 path forbids native gas piggybacking
        uint256 amount = 100 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), amount, payload
        );

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA{ value: 0.001 ether }(req);
    }

    function test_NoBatching_NativeExactAmount_Succeeds() public {
        // Exact msg.value == req.amount is the only valid native path
        uint256 amount = 1 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(0), amount, payload
        );

        uint256 tssBefore = tss.balance;

        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA{ value: amount }(req);

        assertEq(tss.balance, tssBefore + amount, "TSS receives exact amount");
    }

    // =====================================================
    //  8. EPOCH RATE LIMITING
    // =====================================================

    function test_ERC20_EpochRateLimitEnforced() public {
        // Set a small threshold
        address[] memory tokens = new address[](1);
        uint256[] memory thresholds = new uint256[](1);
        tokens[0] = address(tokenA);
        thresholds[0] = 50 ether; // Only 50 tokens per epoch

        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), 100 ether, _defaultPayload()
        );

        vm.expectRevert(Errors.RateLimitExceeded.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

    // =====================================================
    //  9. REVERT RECIPIENT SANITY
    // =====================================================

    function test_RevertWhen_RevertRecipientIsZero() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: mappedUEA,
            token: address(tokenA),
            amount: 100 ether,
            payload: _defaultPayload(),
            revertRecipient: address(0),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

    // =====================================================
    //  10. EVENT SEMANTICS
    // =====================================================

    function test_EventEmits_viaCEA_True() public {
        uint256 amount = 100 ether;
        bytes memory payload = _defaultPayload();
        bytes memory sigData = abi.encodePacked(bytes32(uint256(42)));

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: mappedUEA,
            token: address(tokenA),
            amount: amount,
            payload: payload,
            revertRecipient: address(0x456),
            signatureData: sigData
        });

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),       // sender = CEA
            mappedUEA,          // recipient = mapped UEA (not address(0))
            address(tokenA),
            amount,
            payload,
            address(0x456),
            TX_TYPE.FUNDS_AND_PAYLOAD,
            sigData,
            true                // viaCEA = true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

    function test_NormalSendUniversalTx_StillEmits_viaCEA_False() public {
        // Regression: normal path still emits viaCEA = false
        uint256 gasAmount = 0.001 ether;
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(0),
            amount: 0,
            payload: bytes(""),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            user1,
            address(0),
            address(0),
            gasAmount,
            bytes(""),
            address(0x456),
            TX_TYPE.GAS,
            bytes(""),
            false               // viaCEA = false
        );

        vm.prank(user1);
        gateway.sendUniversalTx{ value: gasAmount }(req);
    }

    function test_EventRecipientIsNeverZero_ForViaCEA() public {
        uint256 amount = 50 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), amount, payload
        );

        vm.recordLogs();
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);

        // Find the UniversalTx event and verify recipient != address(0)
        bytes32 eventSig = keccak256(
            "UniversalTx(address,address,address,uint256,bytes,address,uint8,bytes,bool)"
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                // topics[2] is the indexed recipient
                address emittedRecipient = address(uint160(uint256(logs[i].topics[2])));
                assertEq(emittedRecipient, mappedUEA, "Recipient must be mapped UEA");
                assertTrue(emittedRecipient != address(0), "Recipient must not be zero");
                found = true;
                break;
            }
        }
        assertTrue(found, "UniversalTx event not found");
    }

    // =====================================================
    //  11. RECIPIENT OVERRIDE ATTACK TESTS
    // =====================================================

    function test_SpoofRecipient_AttackerEOA_Reverts() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: attacker,
            token: address(tokenA),
            amount: 100 ether,
            payload: _defaultPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

    function test_SpoofRecipient_SomeContract_Reverts() public {
        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(gateway), // random contract
            token: address(tokenA),
            amount: 100 ether,
            payload: _defaultPayload(),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.expectRevert(Errors.InvalidRecipient.selector);
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

    // =====================================================
    //  16. MINIMAL E2E SCENARIO TESTS
    // =====================================================

    function test_E2E_ERC20_FundsAndPayload_ViaCEA() public {
        uint256 amount = 200 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), amount, payload
        );

        uint256 vaultBefore = tokenA.balanceOf(address(this));

        vm.expectEmit(true, true, false, true, address(gateway));
        emit UniversalTx(
            address(cea),
            mappedUEA,
            address(tokenA),
            amount,
            payload,
            address(0x456),
            TX_TYPE.FUNDS_AND_PAYLOAD,
            bytes(""),
            true
        );

        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);

        assertEq(
            tokenA.balanceOf(address(this)),
            vaultBefore + amount,
            "Vault received ERC20"
        );
    }

    function test_E2E_Native_FundsAndPayload_NoBatching_ViaCEA() public {
        // Batching disallowed — only exact amount succeeds
        uint256 fundsAmount = 5 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(0), fundsAmount, payload
        );

        uint256 tssBefore = tss.balance;

        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA{ value: fundsAmount }(req);

        assertEq(tss.balance, tssBefore + fundsAmount, "TSS received exact amount");
    }

    function test_E2E_InvalidCEA_Reverts() public {
        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), 100 ether, _defaultPayload()
        );

        // Attacker is not a CEA
        vm.expectRevert(Errors.InvalidInput.selector);
        vm.prank(attacker);
        gateway.sendUniversalTxViaCEA(req);
    }

    // =====================================================
    //  17. RECIPIENT FORCED TO ADDRESS(0) REGRESSION
    // =====================================================

    function test_Regression_FundsAndPayload_ViaCEA_RecipientNotZero() public {
        uint256 amount = 100 ether;
        bytes memory payload = _defaultPayload();

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), amount, payload
        );

        vm.recordLogs();
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);

        bytes32 eventSig = keccak256(
            "UniversalTx(address,address,address,uint256,bytes,address,uint8,bytes,bool)"
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                address emittedRecipient = address(uint160(uint256(logs[i].topics[2])));
                assertTrue(
                    emittedRecipient != address(0),
                    "REGRESSION: viaCEA must never emit recipient=address(0)"
                );
                assertEq(
                    emittedRecipient,
                    mappedUEA,
                    "REGRESSION: recipient must be mapped UEA"
                );
                return;
            }
        }
        revert("Event not found");
    }

    function test_Regression_NormalFundsAndPayload_RecipientStillZero() public {
        // Non-viaCEA path preserves address(0) recipient for FUNDS_AND_PAYLOAD
        uint256 amount = 100 ether;
        UniversalPayload memory payload = buildDefaultPayload();

        UniversalTxRequest memory req = UniversalTxRequest({
            recipient: address(0),
            token: address(tokenA),
            amount: amount,
            payload: abi.encode(payload),
            revertRecipient: address(0x456),
            signatureData: bytes("")
        });

        vm.recordLogs();
        vm.prank(user1);
        gateway.sendUniversalTx(req);

        bytes32 eventSig = keccak256(
            "UniversalTx(address,address,address,uint256,bytes,address,uint8,bytes,bool)"
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSig) {
                address emittedRecipient = address(uint160(uint256(logs[i].topics[2])));
                assertEq(
                    emittedRecipient,
                    address(0),
                    "Non-viaCEA FUNDS_AND_PAYLOAD must keep recipient=address(0)"
                );
                return;
            }
        }
        revert("Event not found");
    }

    // =====================================================
    //  PAUSE / REENTRANCY SAFETY
    // =====================================================

    function test_RevertWhen_Paused() public {
        vm.prank(admin);
        gateway.pause();

        UniversalTxRequest memory req = _buildViaCEARequest(
            address(tokenA), 100 ether, _defaultPayload()
        );

        vm.expectRevert();
        vm.prank(address(cea));
        gateway.sendUniversalTxViaCEA(req);
    }

}
