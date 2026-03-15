# Universal Gateway

The Universal Gateway is the on-chain entry point for bridging funds and executing payloads from external EVM chains into Push Chain. It abstracts chain-specific complexity behind a single interface — users deposit gas, bridge tokens, or attach execution payloads and the gateway infers intent automatically from the request structure.

The system includes inbound contracts (deployed on external EVM chains) and outbound contracts (deployed on Push Chain), connected by the Push Chain TSS (Threshold Signature Scheme) relayer network.

---

## Getting Started

### Dependencies

- [Foundry](https://getfoundry.sh) — build, test, and scripting toolchain

Install Foundry:
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Install contract dependencies:
```bash
forge install
```

### Build

```bash
forge build
```

### Test

```bash
# Run all tests
forge test -vv

# Run a specific test file
forge test --match-path test/gateway/1_adminActions.t.sol -vv

# Run a specific test function
forge test --match-test testFunctionName -vv

# Maximum verbosity (full traces)
forge test -vvvv
```

### Gas Report

```bash
forge test --gas-report
```

### Coverage

```bash
forge coverage --ir-minimum
```

> **Optional — lcov for HTML reports:**
> ```bash
> # Ubuntu
> sudo apt install lcov
>
> # macOS
> brew install lcov
> ```

---

## Docs and Tooling

### Protocol Documentation

- [Push Chain Overview](./docs/1_PUSH_CHAIN.md)
- [UniversalGateway — Overview & Architecture](./docs/2_UniversalGateway.md)
- [UniversalGatewayPC — Outbound Gateway](./docs/3_UniversalGatewayPC.md)
- [Outbound Transaction Flows](./docs/4_OutboundTx_Flows.md)
- [Inbound Transaction Flows](./docs/5_InboundTx_Flows.md)
- [Revert Handling](./docs/Revert_Handling.md)
- [Threat Modelling](./docs/THREAT_MODELLING_DOC.md)
- [EVM Gateway Upgrade Plan](./docs/EVM_Gateway_Upgrade_Plan.md)

### Push Chain

- **Testnet RPC:** `https://rpc.testnet.push.org`
- **Docs:** [https://push.org/docs/](https://push.org/docs/)

---

## License

MIT
