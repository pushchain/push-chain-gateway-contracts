# Push Chain SVM Gateway

Solana-side gateway for Push Chain universal transactions.  
This program handles:
- inbound deposits (`send_universal_tx`)
- outbound finalize (`finalize_universal_tx`)
- outbound revert (`revert_universal_tx`)
- outbound rescue (`rescue_funds`)

## Getting Started

### Dependencies
- Rust + Cargo
- Solana CLI + Anchor CLI
- Node.js + npm

### Setup
```bash
cd contracts/svm-gateway
npm install
anchor build
```

### Test
```bash
anchor test

# focused suites
npm run test:withdraw
npm run test:execute
npm run test:rescue
npm run test:cea-to-uea
```

---

## Instruction Map

| Function | Direction | instruction_id | Notes |
|---|---|---|---|
| `send_universal_tx` | Solana → Push Chain | N/A | Inbound deposit entrypoint |
| `finalize_universal_tx` | Push Chain → Solana | `1` / `2` | `1=withdraw`, `2=execute` |
| `revert_universal_tx` | Push Chain → Solana | `3` | Unified SOL + SPL revert |
| `rescue_funds` | Push Chain → Solana | `4` | Emergency fund release |

---

## Documentation

### Program Docs (`contracts/svm-gateway/docs/`)
- [SVM Gateway Overview](./docs/0-SVM-GATEWAY.md)
- [Deposit / Inbound](./docs/1-DEPOSIT.md)
- [Withdraw + Execute](./docs/2-WITHDRAW-EXECUTE.md)
- [Revert](./docs/3-REVERT.md)
- [CEA](./docs/4-CEA.md)
- [Rescue](./docs/5-RESCUE.md)
- [Threat Model](./docs/THREAT_MODEL.md)
- [Runbook](./docs/RUNBOOK.md)

### Integration Docs
- [Integration Guide](./INTEGRATION_GUIDE.md)


---

## Devnet Program IDs

- Main: `CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS`
- Dummy: `DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp`

---

## CLI Entry Points

- Config/admin: `app/config-cli.ts`
- Token tooling: `app/token-cli.ts`
- End-to-end devnet script: `app/gateway-test.ts`
- ALT helper: `app/create-universal-alt.ts`

---

License: ISC
