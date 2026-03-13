// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import { Vault } from "../../src/Vault.sol";
import { IVault } from "../../src/interfaces/IVault.sol";
import { UniversalGateway } from "../../src/UniversalGateway.sol";
import { Errors } from "../../src/libraries/Errors.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockCEAFactory } from "../mocks/MockCEAFactory.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract EthRejecter {
    receive() external payable {
        revert("no ETH");
    }
}

contract VaultRescueFundsTest is Test {
    Vault public vault;
    UniversalGateway public gateway;
    MockERC20 public token;
    MockERC20 public delistedToken;
    MockCEAFactory public ceaFactory;

    address public admin;
    address public pauser;
    address public tss;
    address public recipient;
    address public attacker;
    address public weth;

    bytes32 constant UNIVERSAL_TX_ID = bytes32(uint256(42));

    event FundsRescued(
        bytes32 indexed universalTxId,
        address indexed token,
        uint256 amount,
        address indexed recipient
    );

    function setUp() public {
        admin = makeAddr("admin");
        pauser = makeAddr("pauser");
        tss = makeAddr("tss");
        recipient = makeAddr("recipient");
        attacker = makeAddr("attacker");
        weth = makeAddr("weth");

        // Deploy UniversalGateway
        UniversalGateway gatewayImpl = new UniversalGateway();
        bytes memory gatewayInitData = abi.encodeWithSelector(
            UniversalGateway.initialize.selector,
            admin,
            tss,
            address(this),
            1e18,
            10e18,
            address(0),
            address(0),
            weth
        );
        ERC1967Proxy gatewayProxy = new ERC1967Proxy(
            address(gatewayImpl),
            gatewayInitData
        );
        gateway = UniversalGateway(payable(address(gatewayProxy)));

        // Deploy CEAFactory
        ceaFactory = new MockCEAFactory();

        // Deploy Vault
        Vault vaultImpl = new Vault();
        bytes memory vaultInitData = abi.encodeWithSelector(
            Vault.initialize.selector,
            admin,
            pauser,
            tss,
            address(gateway),
            address(ceaFactory)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            vaultInitData
        );
        vault = Vault(address(vaultProxy));

        // Deploy tokens
        token = new MockERC20("Test Token", "TST", 18, 1_000_000e18);
        delistedToken = new MockERC20("Delisted", "DEL", 18, 1_000_000e18);

        // Fund vault
        token.mint(address(vault), 100_000e18);
        delistedToken.mint(address(vault), 100_000e18);
        vm.deal(address(vault), 100 ether);

        // Support token in gateway (but NOT delistedToken)
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(0);
        uint256[] memory thresholds = new uint256[](2);
        thresholds[0] = 1_000_000e18;
        thresholds[1] = 1_000_000 ether;
        vm.prank(admin);
        gateway.setTokenLimitThresholds(tokens, thresholds);
    }

    function testRescueFundsERC20Success() public {
        uint256 amount = 1000e18;
        uint256 vaultBefore = token.balanceOf(address(vault));
        uint256 recipientBefore = token.balanceOf(recipient);

        vm.prank(tss);
        vm.expectEmit(true, true, true, true);
        emit FundsRescued(UNIVERSAL_TX_ID, address(token), amount, recipient);
        vault.rescueFunds(UNIVERSAL_TX_ID, address(token), amount, recipient);

        assertEq(token.balanceOf(address(vault)), vaultBefore - amount);
        assertEq(token.balanceOf(recipient), recipientBefore + amount);
    }

    function testRescueFundsNativeSuccess() public {
        uint256 amount = 5 ether;
        uint256 vaultBefore = address(vault).balance;
        uint256 recipientBefore = recipient.balance;

        vm.prank(tss);
        vm.expectEmit(true, true, true, true);
        emit FundsRescued(UNIVERSAL_TX_ID, address(0), amount, recipient);
        vault.rescueFunds(UNIVERSAL_TX_ID, address(0), amount, recipient);

        assertEq(address(vault).balance, vaultBefore - amount);
        assertEq(recipient.balance, recipientBefore + amount);
    }

    function testRescueFundsRevertNotTSS() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.rescueFunds(UNIVERSAL_TX_ID, address(token), 100e18, recipient);
    }

    function testRescueFundsRevertWhenPaused() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(tss);
        vm.expectRevert();
        vault.rescueFunds(UNIVERSAL_TX_ID, address(token), 100e18, recipient);
    }

    function testRescueFundsRevertZeroAmount() public {
        vm.prank(tss);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.rescueFunds(UNIVERSAL_TX_ID, address(token), 0, recipient);
    }

    function testRescueFundsRevertZeroRecipient() public {
        vm.prank(tss);
        vm.expectRevert(Errors.InvalidRecipient.selector);
        vault.rescueFunds(UNIVERSAL_TX_ID, address(token), 100e18, address(0));
    }

    function testRescueFundsRevertInsufficientBalanceERC20() public {
        uint256 vaultBalance = token.balanceOf(address(vault));

        vm.prank(tss);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.rescueFunds(
            UNIVERSAL_TX_ID,
            address(token),
            vaultBalance + 1,
            recipient
        );
    }

    function testRescueFundsRevertInsufficientBalanceNative() public {
        uint256 vaultBalance = address(vault).balance;

        vm.prank(tss);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        vault.rescueFunds(
            UNIVERSAL_TX_ID,
            address(0),
            vaultBalance + 1,
            recipient
        );
    }

    function testRescueFundsDelistedToken() public {
        uint256 amount = 500e18;
        uint256 vaultBefore = delistedToken.balanceOf(address(vault));

        vm.prank(tss);
        vault.rescueFunds(
            UNIVERSAL_TX_ID,
            address(delistedToken),
            amount,
            recipient
        );

        assertEq(
            delistedToken.balanceOf(address(vault)),
            vaultBefore - amount
        );
        assertEq(delistedToken.balanceOf(recipient), amount);
    }

    function testRescueFundsNativeTransferFailure() public {
        EthRejecter rejecter = new EthRejecter();

        vm.prank(tss);
        vm.expectRevert(Errors.WithdrawFailed.selector);
        vault.rescueFunds(
            UNIVERSAL_TX_ID,
            address(0),
            1 ether,
            address(rejecter)
        );
    }
}
