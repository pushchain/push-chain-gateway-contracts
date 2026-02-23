# REVERT Flow (Outbound Recovery)

**Functions:** `revert_universal_tx`, `revert_universal_tx_token`
**Purpose:** Return funds to user when Push Chain transaction fails
**Authorization:** TSS signature (ECDSA secp256k1)

---

## 📋 Overview

Revert allows TSS to return deposited funds when cross-chain transaction fails on Push Chain. Two variants:
- **SOL revert:** `revert_universal_tx` (instruction_id=3)
- **SPL revert:** `revert_universal_tx_token` (instruction_id=4)

---

## 🔄 Flow

```
TSS Request
  │
  ├─ Validate TSS signature (message hash, ECDSA)
  ├─ Create executed_tx PDA (replay protection)
  ├─ Transfer: Vault → Recipient (amount)
  ├─ Emit: RevertUniversalTx event  ← **EMITTED AFTER funds transfer, BEFORE gas transfer (revert.rs:114, 269)**
  └─ Transfer: Vault → Caller (gas_fee, relayer reimbursement)
```

---

## 🔐 TSS Message Format

### SOL Revert (instruction_id=3)
```rust
message = PREFIX
        || instruction_id (1 byte = 3)
        || chain_id (string bytes)
        || amount (8 bytes BE)
        || universal_tx_id[32]
        || tx_id[32]
        || recipient_pubkey[32]
        || gas_fee_be[8]

hash = keccak256(message)
```

### SPL Revert (instruction_id=4)
```rust
message = PREFIX
        || instruction_id (1 byte = 4)
        || chain_id (string bytes)
        || amount (8 bytes BE)
        || universal_tx_id[32]
        || tx_id[32]
        || mint_pubkey[32]
        || recipient_pubkey[32]
        || gas_fee_be[8]

hash = keccak256(message)
```

---

## 🔒 Key Security Checks

| Check | Validation |
|-------|------------|
| **Pause state** | `require!(!config.paused)` |
| **Amount** | `require!(amount > 0)` |
| **Recipient** | `require!(recipient != Pubkey::default())` |
| **Recipient match** | `require!(recipient == revert_instruction.fund_recipient)` |
| **TSS signature** | ECDSA secp256k1 recovery + address match |
| **Replay** | ExecutedTx PDA init (fails if tx_id reused) |
| **SPL ATA** | Owner == vault, Mint == token_mint |
| **SPL recipient** | ATA owner == recipient, mint == token_mint |

---

## 💰 State Changes

### Vault → Recipient
- **SOL:** `vault.lamports -= amount`
- **SPL:** `vault_ata.amount -= amount`

### Vault → Caller (Relayer)
- **SOL:** `vault.lamports -= gas_fee`

### Replay Protection
- **ExecutedTx PDA created** for tx_id

---

## 📤 Event

```rust
#[event]
pub struct RevertUniversalTx {
    pub universal_tx_id: [u8; 32],
    pub tx_id: [u8; 32],
    pub fund_recipient: Pubkey,
    pub token: Pubkey,              // Pubkey::default() for SOL
    pub amount: u64,
    pub revert_instruction: RevertInstructions,
}
```

---

## ⚠️ Critical Differences from Withdraw

| Aspect | Withdraw | Revert |
|--------|----------|--------|
| **Trigger** | User request on Push Chain | Failed tx on Push Chain |
| **CEA involved** | Yes (as intermediary) | No (direct vault → recipient) |
| **instruction_id** | 1 (withdraw), 2 (execute) | 3 (SOL), 4 (SPL) |
| **Message format** | Different additional_data | Different additional_data |
| **Event** | UniversalTxExecuted | RevertUniversalTx |

---

## 🔍 Key Invariants

1. **One revert per tx_id:** ExecutedTx PDA ensures uniqueness
2. **TSS authorization only:** No user can trigger revert
3. **Amount validation:** Code only validates `amount > 0` (revert.rs:68, 205) - NO enforcement that amount matches original deposit
   - **Note:** "Exact amount" revert is a business-layer expectation, not an on-chain invariant
   - TSS is responsible for signing correct revert amounts
4. **Recipient validation:** Must match revert_instruction.fund_recipient

---

**Last Updated:** 2026-02-23
