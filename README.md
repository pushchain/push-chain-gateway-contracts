# Push Chain Gateway Contracts

This repository contains the gateway smart contracts that connect Push Chain to external blockchain ecosystems. The system enables bidirectional bridging of funds, gas abstraction, and cross-chain payload execution between Push Chain and supported external chains.

The gateway is implemented for two ecosystems:

- **EVM Gateway** (`contracts/evm-gateway/`) — Solidity contracts for Ethereum and EVM-compatible chains (Foundry)
- **SVM Gateway** (`contracts/svm-gateway/`) — Anchor programs for Solana (Anchor)

## Getting Started

### EVM Gateway

**Dependencies:** [Foundry](https://getfoundry.sh)

```bash
cd contracts/evm-gateway
forge build
```

```bash
forge test -vv                                                 # all tests
forge test --match-path test/gateway/1_adminActions.t.sol -vv  # single file
forge test --match-test testFunctionName -vv                   # single test
forge test -vvvv                                               # full traces
forge test --gas-report                                        # gas report
forge coverage --ir-minimum                                    # coverage
```

### SVM Gateway

**Dependencies:** Rust + Cargo, Solana CLI, Anchor CLI 0.31.1, Node.js 20+

```bash
cd contracts/svm-gateway
npm install
anchor build
```

```bash
anchor test                                        # all tests
TEST_FILE=tests/execute.test.ts anchor test        # single file
npm run test:execute                               # convenience script
# also: test:withdraw, test:admin, test:rate-limit, test:universal-tx,
#        test:rescue, test:cea-to-uea, test:execute-heavy
```

---

## Docs and Tooling

### EVM Gateway

- [UniversalGateway — Overview & Architecture](contracts/evm-gateway/docs/2_UniversalGateway.md)
- [UniversalGatewayPC — Outbound Gateway](contracts/evm-gateway/docs/3_UniversalGatewayPC.md)
- [Outbound Transaction Flows](contracts/evm-gateway/docs/4_OutboundTx_Flows.md)
- [Inbound Transaction Flows](contracts/evm-gateway/docs/5_InboundTx_Flows.md)
- [Revert Handling](contracts/evm-gateway/docs/Revert_Handling.md)
- [Threat Modelling](contracts/evm-gateway/docs/THREAT_MODELLING_DOC.md)
- [EVM Gateway Upgrade Plan](contracts/evm-gateway/docs/EVM_Gateway_Upgrade_Plan.md)

### SVM Gateway

- [SVM Gateway Overview](contracts/svm-gateway/docs/0-SVM-GATEWAY.md)
- [Deposit / Inbound](contracts/svm-gateway/docs/1-DEPOSIT.md)
- [Withdraw + Execute](contracts/svm-gateway/docs/2-WITHDRAW-EXECUTE.md)
- [Revert](contracts/svm-gateway/docs/3-REVERT.md)
- [CEA](contracts/svm-gateway/docs/4-CEA.md)
- [Rescue](contracts/svm-gateway/docs/5-RESCUE.md)
- [Threat Model](contracts/svm-gateway/docs/THREAT_MODEL.md)
- [Runbook](contracts/svm-gateway/docs/RUNBOOK.md)
- [Integration Guide](contracts/svm-gateway/INTEGRATION_GUIDE.md)

### Deployed Addresses

- [Ethereum Sepolia](contracts/evm-gateway/docs/addresses/sepolia.md)
- [BSC Testnet](contracts/evm-gateway/docs/addresses/bsc-testnet.md)

### Push Chain

- **Testnet RPC:** `https://rpc.testnet.push.org`
- **Docs:** [https://push.org/docs/](https://push.org/docs/)

---

## License

MIT (EVM) / ISC (SVM)
