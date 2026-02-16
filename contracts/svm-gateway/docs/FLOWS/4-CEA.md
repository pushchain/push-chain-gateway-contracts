# CEA - Chain Executor Account

**Full Name:** Chain Executor Account
**Type:** PDA (Program Derived Address)
**Purpose:** Persistent on-chain identity and signing authority for Push Chain users

---

## 🎯 Core Concept

CEA is a **persistent Solana PDA** that represents a Push Chain user on Solana. It serves as:
1. **Signing authority** for program invocations via `invoke_signed`
2. **Persistent identity** across multiple transactions
3. **Temporary custody** for funds during execution

---

## 🔑 PDA Derivation

```rust
// Seed structure
seeds = [
    b"push_identity",  // Constant prefix
    sender,            // 20-byte Push Chain address
    bump              // Canonical bump
]

// Derivation
let (cea_pubkey, cea_bump) = Pubkey::find_program_address(
    &[b"push_identity", sender.as_ref()],
    &gateway_program_id
);
```

**Key Properties:**
- **Deterministic:** Same sender → same CEA pubkey
- **No private key:** Only gateway can sign via `invoke_signed`
- **Auto-created:** Solana runtime creates account on first SOL transfer
- **Persistent:** Survives across transactions

---

## 🔄 Lifecycle

### 1. Creation (First Interaction)
```
User deposits on Solana
  → Event emitted to Push Chain
    → User receives UEA on Push Chain
      → TSS authorizes withdraw/execute
        → First vault→CEA transfer auto-creates CEA account
```

**Important:** CEA is created by Solana runtime, not by init constraint.

### 2. Active Use
```
Multiple execute transactions:
  Vault → CEA (amount + rent_fee)
    → CEA signs for target program
      → Target program executes
        → CEA may retain balance or forward to vault
```

### 3. Withdrawal (CEA → Vault)
```
Special execute mode where target = gateway itself:
  CEA → Vault (withdraw amount)
    → Emit UniversalTx event (FUNDS type)
      → Unlocks funds on Push Chain
```

---

## 💡 Why CEA?

### Problem Without CEA
```
User on Push Chain wants to call Solana program X
  → Who signs for program X?
  → Vault? (shared by all users, security issue)
  → Gateway? (not user-specific)
  → Relayer? (untrusted third party)
```

### Solution With CEA
```
Each Push Chain user has unique CEA PDA
  → CEA is deterministic: f(sender_address)
  → CEA can sign via invoke_signed (only gateway controls seeds)
  → Programs see CEA as the caller (proper authority model)
  → CEA persists across transactions (stateful identity)
```

---

## 🔐 Security Model

### Trust Boundaries

```
┌─────────────────────────────────────────┐
│         Gateway Program                  │
│  (Trusted: controls CEA signing)         │
│                                          │
│  ┌────────────────────────────────┐     │
│  │  CEA PDA                       │     │
│  │  • No private key              │     │
│  │  • Signs via invoke_signed     │     │
│  │  • Seeds: ["push_identity",    │     │
│  │            sender, bump]       │     │
│  └────────────────────────────────┘     │
│                                          │
└─────────────────────────────────────────┘
          │
          │ invoke_signed(&[cea_seeds])
          ▼
┌─────────────────────────────────────────┐
│      Target Program                      │
│  (Sees CEA as signer)                    │
│                                          │
│  if ctx.accounts.signer.key == CEA:      │
│    // CEA is authorized                 │
│                                          │
└─────────────────────────────────────────┘
```

### Key Security Properties

1. **No Private Key Exposure**
   - CEA has no private key
   - Only gateway can make CEA sign (via seeds)

2. **Deterministic Authority**
   - Same Push Chain user → same CEA
   - Programs can trust CEA identity

3. **Isolated Per-User**
   - User A's CEA ≠ User B's CEA
   - No cross-user contamination

4. **TSS-Gated**
   - CEA only signs when TSS authorizes
   - TSS validates Push Chain transaction first

---

## 📊 CEA vs Vault

| Aspect | Vault | CEA |
|--------|-------|-----|
| **Purpose** | Global custody | Per-user identity |
| **Derivation** | `[b"vault"]` | `[b"push_identity", sender]` |
| **Scope** | All users | One user |
| **Signing** | For transfers only | For program invocations |
| **Lifetime** | Permanent | Persistent |
| **Balance** | Large (pooled funds) | Small (execution funds) |

---

## 🔄 Example: Execute Flow with CEA

### Setup
```rust
sender = 0x1234...5678 (20-byte Push Chain address)
target_program = Token2022Program
instruction = "transfer 100 USDC from CEA to Alice"
```

### Execution
```rust
// 1. Derive CEA
let (cea, bump) = Pubkey::find_program_address(
    &[b"push_identity", sender],
    &gateway_id
);

// 2. Transfer funds: Vault → CEA
transfer(vault, cea, amount);

// 3. Build CPI with CEA as signer
let accounts = [
    AccountMeta::new(cea_usdc_ata, false),    // from
    AccountMeta::new(alice_usdc_ata, false),  // to
    AccountMeta::new_readonly(cea, true),     // authority (signer!)
];

let ix = Instruction {
    program_id: Token2022Program::id(),
    accounts,
    data: transfer_ix_data,
};

// 4. Invoke with CEA seeds
let cea_seeds = &[b"push_identity", sender, &[bump]];
invoke_signed(&ix, &remaining_accounts, &[cea_seeds])?;
```

**Result:** Token2022Program sees CEA as signer and executes transfer.

---

## 💰 CEA Balance Management

### Inflow (Vault → CEA)
```rust
// During withdraw_and_execute:
vault.lamports -= (amount + rent_fee);
cea.lamports += (amount + rent_fee);
```

### Outflow (CEA → Recipient/Program)
```rust
// Withdraw mode:
cea.lamports -= amount;
recipient.lamports += amount;

// Execute mode:
// CEA balance changes depend on target program logic
// May increase, decrease, or stay same
```

### CEA Withdrawal (CEA → Vault)
```rust
// Special execute where target = gateway:
cea.lamports -= withdraw_amount;
vault.lamports += withdraw_amount;
// Emits UniversalTx event to unlock on Push Chain
```

---

## ⚠️ Critical Considerations

### 1. CEA Signing Authority
```rust
// ✅ CORRECT: Only gateway controls CEA signing
invoke_signed(&ix, accounts, &[cea_seeds])?;

// ❌ WRONG: External account cannot have CEA's private key
// (CEA has no private key!)
```

### 2. Remaining Accounts Validation
```rust
// CRITICAL: No outer signer allowed
for account in remaining_accounts {
    require!(!account.is_signer, GatewayError::UnexpectedOuterSigner);
}

// CEA becomes signer only via invoke_signed, not via outer signature
```

### 3. CEA ATA Management
```rust
// SPL execute requires CEA ATA
// Auto-created if missing during vault→CEA transfer
if cea_ata.data_is_empty() {
    create_associated_token_account(payer, cea, mint)?;
}
```

### 4. Rent Management
```rust
// rent_fee allocated to CEA for account creation during CPI
// Prevents CPI failure due to insufficient rent
```

---

## 🔍 Invariants

1. **Unique per sender:**
   ```
   ∀ sender₁ ≠ sender₂: CEA(sender₁) ≠ CEA(sender₂)
   ```

2. **Deterministic:**
   ```
   CEA(sender) is always same Pubkey for same sender
   ```

3. **Gateway-controlled:**
   ```
   Only gateway program can make CEA sign (via invoke_signed)
   ```

4. **TSS-gated:**
   ```
   CEA signs ⟹ TSS authorized the transaction
   ```

5. **Persistent:**
   ```
   CEA exists after first vault→CEA transfer
   CEA survives across multiple transactions
   ```

---

## 📚 Related Documentation

- [Withdraw & Execute](./2-WITHDRAW-EXECUTE.md) - CEA usage in execute mode
- [TSS Validation](../SECURITY/TSS-VALIDATION.md) - Authorization model
- [Invariants](../SECURITY/INVARIANTS.md) - System guarantees

---

**Last Updated:** 2026-02-11
