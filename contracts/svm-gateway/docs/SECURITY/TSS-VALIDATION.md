# TSS Signature Validation

**Purpose:** Verify TSS authorization for all outbound operations
**Algorithm:** ECDSA secp256k1 (Ethereum-compatible)
**Replay Protection:** Per-tx `ExecutedSubTx` PDA (seeded by `sub_tx_id`)

---

## 🔐 Overview

All outbound operations (withdraw, execute, revert) require TSS signature validation:
1. **Message reconstruction** - Rebuild canonical message from parameters
2. **Hash verification** - Verify pre-computed hash matches
3. **ECDSA recovery** - Recover public key from signature
4. **Address validation** - Verify recovered address matches stored TSS address

---

## 📝 Message Format

### Common Structure
```
message = PREFIX
        || instruction_id (1 byte)
        || chain_id (UTF-8 string bytes)
        || amount (8 bytes, big-endian) [optional]
        || additional_data (variable)

message_hash = keccak256(message)
```

**Prefix:** `"PUSH_CHAIN_SVM"` (14 bytes)

### Chain ID
Solana cluster identifier as string:
- **Mainnet:** `"5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"`
- **Devnet:** `"EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"`
- **Testnet:** `"4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY"`

---

## 🎯 Instruction-Specific Formats

### 1. Withdraw (instruction_id = 1)
```rust
additional_data = [
    sub_tx_id[32],
    universal_tx_id[32],
    push_account[20],
    token[32],
    gas_fee_be[8],
    target[32],  // recipient pubkey
]
```

### 2. Execute (instruction_id = 2)
```rust
additional_data = [
    sub_tx_id[32],
    universal_tx_id[32],
    push_account[20],
    token[32],
    gas_fee_be[8],
    target_program[32],
    accounts_buf[variable],
    ix_data_buf[variable],
    rent_fee_be[8],
]
```

### 3. Revert SOL (instruction_id = 3)
```rust
additional_data = [
    universal_tx_id[32],
    sub_tx_id[32],
    recipient[32],
    gas_fee_be[8],
]
```

### 4. Revert SPL (instruction_id = 4)
```rust
additional_data = [
    universal_tx_id[32],
    sub_tx_id[32],
    mint[32],
    recipient[32],
    gas_fee_be[8],
]
```

---

## 🔍 Validation Steps

### Step 1: Message Reconstruction
```rust
let mut message = Vec::new();
message.extend_from_slice(b"PUSH_CHAIN_SVM");
message.push(instruction_id);
message.extend_from_slice(tss_pda.chain_id.as_bytes());
if let Some(amt) = amount {
    message.extend_from_slice(&amt.to_be_bytes());
}
for data in additional_data {
    message.extend_from_slice(data);
}
```

### Step 2: Hash Verification
```rust
let computed_hash = keccak::hash(&message).to_bytes();
require!(
    computed_hash == message_hash,
    GatewayError::MessageHashMismatch
);
```
**Purpose:** Ensure message integrity

### Step 3: ECDSA Recovery
```rust
let recovered_pubkey = secp256k1_recover(
    &message_hash,
    recovery_id,
    &signature
).map_err(|_| GatewayError::TssAuthFailed)?;
```
**Output:** 64-byte uncompressed public key (without 0x04 prefix)

### Step 4: Address Derivation
```rust
// Ethereum address = last 20 bytes of keccak256(pubkey)
let pubkey_hash = keccak::hash(&recovered_pubkey.to_bytes()).to_bytes();
let recovered_address = &pubkey_hash[12..32];  // 20 bytes
```

### Step 5: Address Validation
```rust
require!(
    recovered_address == tss_pda.tss_eth_address,
    GatewayError::TssAuthFailed
);
```

---

## 🛡️ Security Properties

### 1. Replay Protection
```
Transaction A with sub_tx_id=0xABC executes
  → ExecutedSubTx PDA created at [b"executed_sub_tx", 0xABC]
    → Replay of A fails (Anchor init constraint: account already exists)
```

**Invariant:** Each sub_tx_id used exactly once — no global ordering required

### 2. Message Integrity
```
Attacker modifies amount: 100 → 1000
  → message_hash changes
    → Signature no longer valid
      → TssAuthFailed
```

**Invariant:** Signature binds to exact message content

### 3. Authorization
```
Only TSS private key can produce valid signature
  → secp256k1_recover validates signature
    → Recovered address must match tss_eth_address
      → No other entity can authorize
```

**Invariant:** Only TSS can authorize outbound operations

### 4. Ordering
```
No global nonce → transactions can execute in any order
sub_tx_id is included in the signed message → cannot reuse signature with different sub_tx_id
ExecutedSubTx PDA uniqueness → each sub_tx_id executes exactly once
```

**Invariant:** No ordering constraint; each tx executes at most once

---

## ⚠️ Critical Attack Vectors (Mitigated)

### 1. Replay Attack
**Attack:** Reuse valid signature for same transaction
**Mitigation:**
- ExecutedSubTx PDA prevents duplicate sub_tx_id (init constraint fails if PDA exists)
- sub_tx_id is included in TSS-signed message (cannot reuse signature with different sub_tx_id)

### 2. Message Tampering
**Attack:** Modify amount/recipient but keep signature
**Mitigation:**
- message_hash verification
- Any change invalidates signature

### 3. Signature Forgery
**Attack:** Generate signature without TSS private key
**Mitigation:**
- ECDSA mathematical hardness
- secp256k1_recover validates cryptographic proof

### 4. TSS Key Substitution
**Attack:** Use different TSS address
**Mitigation:**
- Recovered address must match tss_pda.tss_eth_address
- Only admin can update TSS address

### 5. sub_tx_id Collision
**Attack:** Reuse a sub_tx_id to re-execute a transaction
**Mitigation:**
- ExecutedSubTx PDA init constraint fails if account already exists
- sub_tx_id is included in the TSS-signed message — cannot forge a different sub_tx_id with same signature

---

## 🔄 TSS Management

### Initialization
```rust
pub fn init_tss(
    ctx: Context<InitTss>,
    tss_eth_address: [u8; 20],
    chain_id: String,
) -> Result<()>
```
**Admin-only, one-time setup**

### Update
```rust
pub fn update_tss(
    ctx: Context<UpdateTss>,
    tss_eth_address: [u8; 20],
    chain_id: String,
) -> Result<()>
```
**Admin-only**

---

## 📊 Validation Performance

| Operation | Cost (CU) | Note |
|-----------|-----------|------|
| Message reconstruction | ~5,000 | Linear in message size |
| Keccak hash | ~3,000 | Per hash |
| secp256k1_recover | ~25,000 | Expensive syscall |
| Address comparison | ~100 | Cheap |
| **Total** | **~33,100 CU** | Per validation |

---

## 🔍 Key Invariants

1. **Per-tx uniqueness:**
   ```
   Each sub_tx_id can execute exactly once (ExecutedSubTx PDA init)
   ```

2. **Signature uniqueness:**
   ```
   Each (message_hash, signature) pair used once
   ```

3. **Authorization exclusivity:**
   ```
   Only TSS can generate valid signatures
   ```

4. **Message binding:**
   ```
   Signature binds to exact message content including sub_tx_id
   Any modification → invalid signature
   ```

---

## 📚 Related Documentation

- [Withdraw & Execute](../FLOWS/2-WITHDRAW-EXECUTE.md) - TSS usage in outbound
- [Revert](../FLOWS/3-REVERT.md) - TSS usage in revert
- [Invariants](./INVARIANTS.md) - System-level guarantees

---

**Last Updated:** 2026-02-23
