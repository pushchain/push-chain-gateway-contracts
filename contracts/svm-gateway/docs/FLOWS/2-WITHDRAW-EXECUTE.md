# WITHDRAW & EXECUTE Flow (Outbound)

**Function:** `withdraw_and_execute`
**Direction:** Vault → User/Program (Push Chain → Solana)
**Authorization:** TSS signature (ECDSA secp256k1)

---

## 📋 Overview

The unified outbound entrypoint supports two modes:
1. **Withdraw (instruction_id=1):** Vault → CEA → Recipient (simple transfer)
2. **Execute (instruction_id=2):** Vault → CEA → Target Program (CPI execution)

Both modes use TSS signature verification for authorization and CEA as signing authority.

---

## 🎯 Entry Point

```rust
pub fn withdraw_and_execute(
    ctx: Context<WithdrawAndExecute>,
    instruction_id: u8,            // 1=withdraw, 2=execute
    tx_id: [u8; 32],               // Unique transaction ID
    universal_tx_id: [u8; 32],     // Cross-chain transaction ID
    amount: u64,                   // Transfer amount
    sender: [u8; 20],              // Push Chain sender (20-byte address)
    writable_flags: Vec<u8>,       // Bitmap of writable accounts (execute mode)
    ix_data: Vec<u8>,              // Instruction data (execute mode)
    gas_fee: u64,                  // Relayer reimbursement
    rent_fee: u64,                 // Rent for CEA (execute mode)
    signature: [u8; 64],           // TSS signature
    recovery_id: u8,               // ECDSA recovery ID
    message_hash: [u8; 32],        // Pre-computed message hash
) -> Result<()>
```

---

## 🔄 Unified Flow Diagram

```
TSS Request
  │
  ├─ Phase 1: Validation
  │    ├─ Check paused (Config)
  │    ├─ Validate instruction_id (1 or 2)
  │    ├─ Derive token (mint or Pubkey::default())
  │    ├─ Validate account presence (SOL vs SPL)
  │    ├─ Derive target:
  │    │    ├─ Mode 1 (withdraw): target = recipient
  │    │    └─ Mode 2 (execute): target = destination_program
  │    └─ Validate mode-specific params
  │
  ├─ Phase 2: TSS Validation
  │    ├─ Build additional_data array
  │    ├─ Reconstruct message hash
  │    ├─ Verify ECDSA signature
  │    └─ Validate remaining_accounts (execute mode only)
  │
  ├─ Phase 3: Transfers
  │    ├─ Create executed_tx PDA (replay protection)
  │    ├─ If rent_fee > 0:
  │    │    └─ Transfer: Vault → CEA (rent_fee)
  │    ├─ If amount > 0:
  │    │    ├─ Native: Transfer Vault → CEA (amount)
  │    │    └─ SPL: Transfer Vault ATA → CEA ATA (amount)
  │    └─ Transfer: Vault → Caller (gas_fee - rent_fee)
  │
  ├─ Phase 4: Mode-Specific Action
  │    ├─ Mode 1 (Withdraw):
  │    │    ├─ If recipient == CEA:
  │    │    │    └─ DONE (funds stay in CEA)
  │    │    ├─ Native: Transfer CEA → Recipient (amount)
  │    │    └─ SPL: Transfer CEA ATA → Recipient ATA (amount)
  │    │
  │    └─ Mode 2 (Execute):
  │         ├─ If target == gateway itself:
  │         │    └─ Handle CEA Withdrawal (special case)
  │         ├─ Build CPI instruction:
  │         │    ├─ program_id = target
  │         │    ├─ accounts = signed_accounts (CEA as signer)
  │         │    └─ data = ix_data
  │         └─ invoke_signed(cpi_ix, &[cea_seeds])
  │
  └─ Emit: UniversalTxExecuted event
```

---

## 🔐 TSS Message Format

The message hash is constructed from:
```
PREFIX = "PUSH_CHAIN_SVM"
message = PREFIX
        || instruction_id (1 byte)
        || chain_id (string bytes)
        || amount (8 bytes BE)
        || additional_data
hash = keccak256(message)
```

### Withdraw Mode (instruction_id=1) Additional Data:
```rust
[
    tx_id[32],           // 0 - common
    universal_tx_id[32], // 1 - common
    sender[20],          // 2 - common
    token[32],           // 3 - common
    gas_fee_be[8],       // 4 - common
    target[32],          // 5 - withdraw specific (recipient pubkey)
]
```

### Execute Mode (instruction_id=2) Additional Data:
```rust
[
    tx_id[32],               // 0 - common
    universal_tx_id[32],     // 1 - common
    sender[20],              // 2 - common
    token[32],               // 3 - common
    gas_fee_be[8],           // 4 - common
    target_program[32],      // 5 - execute specific
    accounts_buf[variable],  // 6 - execute specific
    ix_data_buf[variable],   // 7 - execute specific
    rent_fee_be[8],          // 8 - execute specific
]
```

**accounts_buf format:**
```
[accounts_count (4 bytes BE)]
[pubkey_1 (32 bytes)][is_writable_1 (1 byte)]
[pubkey_2 (32 bytes)][is_writable_2 (1 byte)]
...
```

**ix_data_buf format:**
```
[length (4 bytes BE)]
[data bytes...]
```

---

## 🔒 Security Checks

### 1. Pause State
```rust
require!(!config.paused, GatewayError::Paused);
```

### 2. Instruction ID Validation
```rust
require!(
    instruction_id == 1 || instruction_id == 2,
    GatewayError::InvalidInstruction
);
```

### 3. Account Presence (SOL vs SPL)
```rust
if is_native {
    // All SPL accounts must be None
    require!(vault_ata.is_none() && cea_ata.is_none() && ...);
} else {
    // All SPL accounts must be Some
    require!(vault_ata.is_some() && cea_ata.is_some() && ...);
}
```

### 4. Mode-Specific Account Validation
```rust
// Withdraw mode
if is_withdraw {
    require!(recipient.is_some(), ...);
    // destination_program is not Option<> - pass system_program (ignored)
    require!(remaining_accounts.is_empty(), ...);
}

// Execute mode
if is_execute {
    require!(recipient.is_none(), ...);
    require!(destination_program.executable, ...);
}
```

**Design Note:** `destination_program` is NOT `Option<>` because:
- For execute mode: needs to be the actual target program
- For withdraw mode: pass `system_program` (ignored by withdraw logic)
- For CEA self-withdraw: pass `gateway_program` (triggers special handler)
- Cannot use `Option<gateway_program>` because None-conversion loses the program ID

### 5. Mode-Specific Parameter Validation
```rust
// Withdraw mode
require!(amount > 0, ...);
require!(sender != [0u8; 20], ...);
require!(writable_flags.is_empty(), ...);
require!(ix_data.is_empty(), ...);
require!(rent_fee == 0, ...);

// Execute mode
require!(writable_flags.len() == (accounts_count + 7) / 8, ...);
require!(rent_fee <= gas_fee, ...);
```

### 6. TSS Signature Validation
```rust
// Rebuild message
let computed_hash = keccak::hash(&message_bytes);
require!(computed_hash == message_hash, GatewayError::MessageHashMismatch);

// Recover signer
let pubkey = secp256k1_recover(&message_hash, recovery_id, &signature)?;
let address = keccak::hash(&pubkey.to_bytes())[12..32];
require!(address == tss_pda.tss_eth_address, GatewayError::TssAuthFailed);
```

### 7. Replay Protection
```rust
// ExecutedTx PDA creation with init constraint
// If tx_id was already used, init will fail
#[account(
    init,
    payer = caller,
    space = ExecutedTx::LEN,
    seeds = [EXECUTED_TX_SEED, tx_id.as_ref()],
    bump
)]
pub executed_tx: Account<'info, ExecutedTx>,
```

### 8. Remaining Accounts Validation (Execute Mode)
```rust
// No outer signer allowed
for account in remaining_accounts {
    require!(!account.is_signer, GatewayError::UnexpectedOuterSigner);
}

// Pubkey matches
require!(actual.key == signed.pubkey, ...);

// Writable flag matches
if signed.is_writable && !actual.is_writable {
    return err!(...);
}
```

### 9. SPL Account Validation
```rust
// Vault ATA
let parsed = SplAccount::unpack(&vault_ata_data)?;
require!(parsed.owner == vault.key(), GatewayError::InvalidOwner);
require!(parsed.mint == mint.key(), GatewayError::InvalidMint);

// CEA ATA (created if missing)
let expected_cea_ata = get_associated_token_address(&cea_authority, &mint);
require!(cea_ata.key() == expected_cea_ata, ...);
```

### 10. Target Program Validation (Execute Mode)
```rust
require!(
    destination_program.executable,
    GatewayError::InvalidProgram
);
```

---

## 🔄 CEA (Chain Executor Account)

### PDA Derivation
```rust
seeds = [b"push_identity", sender[20], bump]
```

### Role
- **Signer for target programs:** CEA can sign via `invoke_signed`
- **Persistent identity:** Same PDA for same Push Chain user across all transactions
- **Temporary custody:** Holds funds/tokens during execution
- **Auto-created:** Solana runtime creates CEA on first SOL transfer

### Example CPI with CEA as Signer
```rust
let cea_seeds: &[&[u8]] = &[CEA_SEED, sender.as_ref(), &[cea_bump]];

invoke_signed(
    &instruction,
    &accounts,
    &[cea_seeds]  // CEA becomes signer
)?;
```

---

## 📤 Events Emitted

### UniversalTxExecuted Event
```rust
#[event]
pub struct UniversalTxExecuted {
    pub tx_id: [u8; 32],
    pub universal_tx_id: [u8; 32],
    pub sender: [u8; 20],
    pub target: Pubkey,              // Recipient or program
    pub token: Pubkey,
    pub amount: u64,
    pub payload: Vec<u8>,            // ix_data
}
```

**When Emitted:** After successful withdraw or execute

---

## 💰 State Changes

### Vault Balance
- **SOL:** `vault.lamports -= (amount + gas_fee)` (where gas_fee = rent_fee + relayer_fee)
- **SPL:** `vault_ata.amount -= amount`

### CEA Balance
- **SOL:** `cea.lamports += (amount + rent_fee)`
- **SPL:** `cea_ata.amount += amount`

### Caller Balance (Relayer)
- **SOL:** `caller.lamports += (gas_fee - rent_fee)`

### Recipient Balance (Withdraw Mode)
- **SOL:** `recipient.lamports += amount`
- **SPL:** `recipient_ata.amount += amount`

### Replay Protection
- **ExecutedTx:** New PDA created with discriminator only

---

## ⚠️ Edge Cases

### 1. Withdraw to CEA itself
**Scenario:** `recipient == cea_authority`
```rust
// Funds stay in CEA, no second transfer needed
if target == ctx.accounts.cea_authority.key() {
    return Ok(());
}
```

### 2. Execute on gateway itself (CEA withdrawal)
**Scenario:** `target_program == gateway_program_id`

**Critical Integration Detail:**

When destination_program == gateway_program_id, the gateway executes a special CEA self-withdraw handler. This requires a specific payload format:

**Payload Structure (execute.rs:451-463):**
```
[discriminator: 8 bytes]  // hash(b"global:withdraw_from_cea").to_bytes()[..8]
[borsh_args: variable]    // WithdrawFromCeaArgs (Borsh-encoded)
```

**WithdrawFromCeaArgs:** (execute.rs:429-432)
```rust
struct WithdrawFromCeaArgs {
    token: Pubkey,      // Must match derived token (Pubkey::default() for SOL, mint for SPL)
    amount: u64,        // Amount to withdraw (0 = withdraw full balance)
    // NOTE: NO recipient field - recipient comes from withdraw_and_execute accounts, NOT payload
}
```

**Validation:**
1. ix_data must be >= 8 bytes
2. First 8 bytes must match hash(b"global:withdraw_from_cea")[..8]
3. Remaining bytes must deserialize as WithdrawFromCeaArgs (token + amount only)
4. args.token must match derived token (Pubkey::default() for SOL, mint for SPL)
5. Recipient comes from the `recipient` account in withdraw_and_execute, NOT from payload

**Integration Example:**
```typescript
import { sha256 } from "js-sha3";
import { serialize } from "borsh";

// 1. Compute discriminator
const discr = Buffer.from(sha256("global:withdraw_from_cea"), "hex").slice(0, 8);

// 2. Manually Borsh-encode WithdrawFromCeaArgs (token + amount ONLY)
// NOTE: There is NO withdrawFromCea instruction in lib.rs, so we use raw Borsh encoding
class WithdrawFromCeaArgs {
  token: Uint8Array; // 32 bytes
  amount: bigint;    // u64

  constructor(token: Uint8Array, amount: bigint) {
    this.token = token;
    this.amount = amount;
  }
}

const schema = {
  struct: {
    token: { array: { type: 'u8', len: 32 } },
    amount: 'u64'
  }
};

const args = new WithdrawFromCeaArgs(
  mintPubkey.toBytes(), // or new PublicKey(0).toBytes() for SOL
  BigInt(amount)
);

const argsEncoded = serialize(schema, args);

// 3. Combine discriminator + borsh args
const ix_data = Buffer.concat([discr, Buffer.from(argsEncoded)]);

// 4. Use in withdraw_and_execute with instruction_id=2
// IMPORTANT: recipient comes from accounts, NOT from payload
await program.methods
  .withdrawAndExecute(
    2, // instruction_id: execute
    // ... other params ...
    [], // writable_flags: empty for CEA self-withdraw
    ix_data, // [discriminator][borsh(token, amount)]
    // ... signature params ...
  )
  .accounts({
    destinationProgram: gatewayProgramId, // Triggers CEA self-withdraw
    recipient: finalRecipientPubkey, // ← Recipient comes from HERE, not payload
    // ... other accounts ...
  })
  .rpc();
```

### 3. SPL CEA ATA doesn't exist
```rust
// Auto-create via CPI
if cea_ata_info.data_is_empty() {
    let create_ata_ix = create_associated_token_account(...);
    invoke_signed(&create_ata_ix, &accounts, &[])?;
}
```

### 4. Zero amount transfer
```rust
// Allowed for execute mode (pure execution, no value transfer)
// Skips transfer if amount == 0
if amount > 0 {
    // ... do transfer
}
```

### 5. Rent fee allocation
```rust
// Rent fee goes to CEA, not directly to target
// Allows CEA to pay for account creation during downstream CPI
// NOTE: CEA ATA creation is paid by caller (payer=caller)
//       rent_fee is for target program's account creation needs
rent_fee: Vault → CEA
relayer_fee = gas_fee - rent_fee: Vault → Caller
```

---

## 🐛 Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `MessageHashMismatch` | TSS message reconstruction failed | Check message format |
| `TssAuthFailed` | Signature invalid or wrong TSS address | Verify TSS key |
| Anchor Init Error | tx_id already used (PDA exists) | Use unique tx_id - replay protection via init failure |
| `AccountListLengthMismatch` | remaining_accounts count wrong | Check accounts array |
| `AccountPubkeyMismatch` | Account at position doesn't match | Verify account order |
| `UnexpectedOuterSigner` | Account in remaining has is_signer=true | Remove signer flag |
| `InvalidProgram` | Target program not executable | Check program deployment |
| `InvalidOwner` | ATA owner mismatch | Validate ATA derivation |

---

## 🔍 Invariants

1. **Replay Protection:**
   ```
   Each tx_id can execute exactly once
   ExecutedTx PDA exists <=> tx executed
   Transactions can execute in any order (no global nonce)
   ```

3. **Balance Conservation:**
   ```
   vault_before == vault_after + amount + gas_fee
   (where gas_fee = rent_fee + relayer_fee)
   ```

4. **CEA Signer Authority:**
   ```
   Only CEA (via invoke_signed) can sign for target program
   No external account can have is_signer=true in remaining_accounts
   ```

5. **Mode Consistency:**
   ```
   instruction_id=1 => recipient.is_some() && remaining_accounts.is_empty()
   instruction_id=2 => recipient.is_none() && destination_program.executable
   ```

6. **Gas Fee Split:**
   ```
   gas_fee = rent_fee + relayer_fee
   rent_fee <= gas_fee
   ```

---

## 📊 Withdraw vs Execute Comparison

| Aspect | Withdraw (ID=1) | Execute (ID=2) |
|--------|-----------------|----------------|
| **Target** | recipient (user wallet) | destination_program (contract) |
| **CEA Role** | Temporary holder → forwards to recipient | Signer for CPI |
| **amount** | Must be > 0 | Can be 0 (pure execution) |
| **rent_fee** | Always 0 | May be > 0 (for target program's account creation in CPI) |
| **writable_flags** | Must be empty | Required (bitmap) |
| **ix_data** | Must be empty | Required (instruction data) |
| **remaining_accounts** | Must be empty | Required (target accounts) |
| **Final state** | Funds with recipient | Depends on program execution |

---

## 📚 Related Documentation

- [CEA Details](./4-CEA.md) - Chain Executor Account deep dive
- [TSS Validation](../SECURITY/TSS-VALIDATION.md) - Signature verification
- [Deposit Flow](./1-DEPOSIT.md) - Inbound counterpart
- [Revert Flow](./3-REVERT.md) - Error recovery

---

**Last Updated:** 2026-02-23
