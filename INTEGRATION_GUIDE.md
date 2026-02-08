# Universal Gateway Backend Integration Guide

Technical guide for backend teams to implement the relayer service that processes Push Chain events and executes transactions on Solana.

---

## 1. Execution Flow

### 1.1 High-Level Flow

```
User (EVM) → Push Chain → Event Emission → Backend Service → TSS Signing → Solana Execution
```

**Step-by-step:**
1. User calls `UniversalGatewayPC.withdrawAndExecute()` on Push Chain
2. Push Chain burns tokens, emits `UniversalTxWithdraw` event
3. Backend service watches events, extracts event data
4. Backend decodes payload (for execute: accounts + ixData + rentFee; for withdraw/revert: no payload)
5. Backend builds TSS message hash, signs with ECDSA secp256k1
6. Backend constructs Solana transaction with signed instruction
7. Backend submits transaction to Solana network
8. Gateway program verifies signature, then either executes target program (execute) or transfers to recipient (withdraw/revert); all successful outcomes emit `UniversalTxExecuted` (execute/withdraw) or `RevertUniversalTx` (revert)

### 1.2 Event Structure (Push Chain)

**Event**: `UniversalTxWithdraw`
```solidity
event UniversalTxWithdraw(
    address indexed sender,        // EVM address (20 bytes)
    string chainId,                // Source chain ID
    address token,                 // PRC20 token address
    bytes target,                  // Target program/contract address (32 bytes for Solana)
    uint256 amount,                // Amount to withdraw
    address gasToken,              // Gas token address
    uint256 gasFee,                // Gas fee (includes compute + rent)
    uint256 gasLimit,              // Gas limit (for EVM; not used on Solana)
    bytes payload,                 // Encoded payload (see section 2)
    uint256 protocolFee,           // Protocol fee
    address revertRecipient,       // Revert recipient address
    TX_TYPE txType                 // Transaction type
);
```

**Fields you need:**
- `sender` → Convert to 20-byte array for `sender` parameter
- `target` → 32-byte Solana program pubkey
- `amount` → u64 amount (reject if > u64::MAX, events are uint256)
- `payload` → Decode to get accounts, ixData, rentFee
- `gasFee` → u64 gas fee (reject if > u64::MAX, events are uint256)
- `revertRecipient` → For revert operations

**Missing fields (you must provide):**
- `universal_tx_id`: 32 bytes from source chain (EVM transaction hash)
- `tx_id`: 32 bytes - **MUST be deterministic and stable across retries** (no random generation)
  - **Recommended**: Use source transaction hash or hash of event fields (e.g., `keccak256(event_tx_hash || log_index)`)
  - **Critical**: Same `tx_id` must be used for all retry attempts of the same transaction

---

## 2. Payload Encoding/Decoding

### 2.1 Payload Format (Solana Execute)

The `payload` field in Push Chain event contains encoded Solana execution data:

```
[accounts_count: 4 bytes (u32 big-endian)]
[account[0].pubkey: 32 bytes]
[account[0].is_writable: 1 byte (0 or 1)]
[account[1].pubkey: 32 bytes]
[account[1].is_writable: 1 byte]
... (repeat for all accounts)
[ix_data_length: 4 bytes (u32 big-endian)]
[ix_data: N bytes]
[rent_fee: 8 bytes (u64 big-endian)]
```

**Total size**: `4 + (33 * accounts_count) + 4 + ix_data_length + 8`

### 2.2 Decoding Payload

**Input**: `payload` bytes from event

**Output**:
- `accounts`: Array of `{ pubkey: 32 bytes, isWritable: bool }`
- `ixData`: Raw instruction data bytes
- `rentFee`: u64 big-endian

**Algorithm**:
1. Read first 4 bytes → `accounts_count` (u32 BE)
2. For each account (0 to accounts_count-1):
   - Read 32 bytes → `pubkey`
   - Read 1 byte → `is_writable` (0 = false, 1 = true)
3. Read next 4 bytes → `ix_data_length` (u32 BE)
4. Read `ix_data_length` bytes → `ix_data`
5. Read last 8 bytes → `rent_fee` (u64 BE)
6. Validate: total bytes consumed == payload length

### 2.3 Encoding Payload (For Testing/Validation)

**Input**: `accounts[]`, `ixData`, `rentFee`

**Algorithm**:
1. Write `accounts.length` as u32 BE (4 bytes)
2. For each account: write `pubkey` (32 bytes) + `is_writable` (1 byte)
3. Write `ixData.length` as u32 BE (4 bytes)
4. Write `ixData` bytes
5. Write `rentFee` as u64 BE (8 bytes)

**Reference**: `contracts/svm-gateway/app/execute-payload.ts`

---

## 3. TSS Message Signing

### 3.1 Wire Format Specification

**CRITICAL**: All numeric fields use **big-endian (BE)** byte order. Any mismatch = `MessageHashMismatch`.

#### 3.1.1 Endianness and Width Table

| Field | Type | Width | Endianness | Notes |
|-------|------|-------|------------|-------|
| `accounts_count` | u32 | 4 bytes | BE | In payload and accounts_buf |
| `ix_data_length` | u32 | 4 bytes | BE | In payload and ix_data_buf |
| `nonce` | u64 | 8 bytes | BE | From TSS PDA account |
| `amount` | u64 | 8 bytes | BE | From event (reject if > u64::MAX) |
| `gas_fee` | u64 | 8 bytes | BE | From event (reject if > u64::MAX) |
| `rent_fee` | u64 | 8 bytes | BE | Decoded from payload (execute flows only, reject if > u64::MAX) |


#### 3.1.2 Chain ID Encoding (CRITICAL)

**Format**: UTF-8 bytes of the `chain_id` string stored in TSS PDA account, **NO length prefix**, **NO trimming**.

**Steps**:
1. Read `tss_pda.chain_id` from on-chain TSS PDA account (it's a Rust `String`)
   - **Note**: This should match the event's `chainId` field (source chain identifier)
2. Convert to UTF-8 bytes: `chain_id_bytes = chain_id.encode('utf-8')` (Python) or `Buffer.from(chain_id, 'utf8')` (Node.js)
3. Concatenate directly into message hash buffer (no length prefix, no padding)

**Example**:
- On-chain value: `"EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG"` (44 bytes UTF-8)
- Message hash includes: exactly these 44 bytes, nothing more, nothing less

**Reference Implementation**:
- Rust: `tss.chain_id.as_bytes()` (line 125 in `tss.rs`)
- TypeScript: `Buffer.from(chainId, 'utf8')` (line 59 in `tss.ts`)

**Common mistakes**:
- ❌ Adding length prefix (4 bytes u32)
- ❌ Trimming whitespace
- ❌ Converting to base58/base64
- ❌ Using different encoding (ASCII, Latin-1, etc.)

### 3.2 Message Hash Construction

**Prefix**: `"PUSH_CHAIN_SVM"` (14 bytes, UTF-8)

**Base fields** (always present, in this exact order):
1. `instruction_id`: 1 byte (unsigned integer)
   - `1` = Withdraw SOL
   - `2` = Withdraw SPL
   - `3` = Revert SOL
   - `4` = Revert SPL
   - `5` = Execute SOL
   - `6` = Execute SPL
2. `chain_id`: UTF-8 bytes (see 3.1.2 above) - **NO length prefix**
3. `nonce`: u64 BE (8 bytes) - current TSS nonce from on-chain TSS PDA
4. `amount`: u64 BE (8 bytes) - present for all instructions

**Additional fields** (order-critical, depends on instruction):

**For Execute (5 or 6):**
```
universal_tx_id (32 bytes)
tx_id (32 bytes)
target_program (32 bytes, pubkey)
sender (20 bytes, EVM address)
accounts_buf (see 3.2)
ix_data_buf (see 3.2)
gas_fee (u64 BE)
rent_fee (u64 BE)
```

**For Withdraw SOL (1):**
- `signTssMessage()` already injects: `universal_tx_id`, `tx_id`, `origin_caller` (see `tests/helpers/tss.ts` lines 73-81)
- `additional` array (passed to `signTssMessage`):
  ```
  [recipient_pubkey (32 bytes), gas_fee_buf (8 bytes, u64 BE)]
  ```

**For Withdraw SPL (2):**
- `signTssMessage()` already injects: `universal_tx_id`, `tx_id`, `origin_caller` (see `tests/helpers/tss.ts` lines 73-81)
- `additional` array (passed to `signTssMessage`):
  ```
  [mint_pubkey (32 bytes), recipient_token_account (32 bytes), gas_fee_buf (8 bytes, u64 BE)]
  ```

**For Revert SOL (3):**
- `signTssMessage()` already injects: `universal_tx_id`, `tx_id` (see `tests/helpers/tss.ts` lines 73-78)
- `additional` array (passed to `signTssMessage`):
  ```
  [recipient_pubkey (32 bytes), gas_fee_buf (8 bytes, u64 BE)]
  ```

**For Revert SPL (4):**
- `signTssMessage()` already injects: `universal_tx_id`, `tx_id` (see `tests/helpers/tss.ts` lines 73-78)
- `additional` array (passed to `signTssMessage`):
  ```
  [mint_pubkey (32 bytes), recipient_pubkey (32 bytes), gas_fee_buf (8 bytes, u64 BE)]
  ```

**Note**: `signTssMessage()` automatically includes `universal_tx_id`, `tx_id`, and `origin_caller` (for withdraw only) in the message hash before the `additional` array. Do NOT include these fields in the `additional` array.

### 3.3 Accounts and Instruction Data Buffers (Execute Only)

**accounts_buf format:**
```
[accounts_count: 4 bytes (u32 BE)]
[account[0].pubkey: 32 bytes]
[account[0].is_writable: 1 byte (0 = false, 1 = true)]
[account[1].pubkey: 32 bytes]
[account[1].is_writable: 1 byte]
... (repeat for all accounts)
```

**ix_data_buf format:**
```
[ix_data_length: 4 bytes (u32 BE)]
[ix_data: N bytes (raw instruction data)]
```

**CRITICAL**: The accounts in `accounts_buf` MUST exactly match:
- The `writable_flags` parameter (bitpacked, 1 bit per account, MSB first)
- The `remaining_accounts` passed to Solana transaction
- Same order, same pubkeys, writable flags match bit positions

### 3.4 Writable Flags Bitpacking (Execute Only)

**Purpose**: Compress boolean writable flags into minimal bytes for transaction size optimization.

**Format**:
- **Size**: `ceil(accounts_count / 8)` bytes
- **Bit order**: MSB-first (most significant bit first)
- **Bit mapping**: Account `i` → bit `(7 - (i % 8))` of byte `floor(i / 8)`

**Algorithm**:
```python
# Python example
def accounts_to_writable_flags(accounts):
    flags_len = (len(accounts) + 7) // 8  # Ceiling division
    flags = bytearray(flags_len)
    for i, account in enumerate(accounts):
        byte_idx = i // 8
        bit_idx = 7 - (i % 8)  # MSB first
        if account.is_writable:
            flags[byte_idx] |= (1 << bit_idx)
    return bytes(flags)
```

**Decoding** (on-chain, for reference):
```rust
// Rust (from execute.rs line 420-424)
let byte_idx = i / 8;
let bit_idx = 7 - (i % 8); // MSB first
let is_writable = (writable_flags[byte_idx] >> bit_idx) & 1 == 1;
```

**Example**: 10 accounts with writable flags `[1, 0, 1, 0, 1, 1, 0, 0, 1, 0]`

```
Account index:  0  1  2  3  4  5  6  7  8  9
Writable:       1  0  1  0  1  1  0  0  1  0

Byte 0 (bits 7-0): accounts 0-7
  Bit 7 (account 0): 1 → 0b10000000
  Bit 6 (account 1): 0 → 0b00000000
  Bit 5 (account 2): 1 → 0b00100000
  Bit 4 (account 3): 0 → 0b00000000
  Bit 3 (account 4): 1 → 0b00001000
  Bit 2 (account 5): 1 → 0b00000100
  Bit 1 (account 6): 0 → 0b00000000
  Bit 0 (account 7): 0 → 0b00000000
  Result: 0b10101100 = 0xAC

Byte 1 (bits 7-0): accounts 8-9
  Bit 7 (account 8): 1 → 0b10000000
  Bit 6 (account 9): 0 → 0b00000000
  Bits 5-0: unused (0)
  Result: 0b10000000 = 0x80

Final: [0xAC, 0x80] (2 bytes)
```

**Verification**:
- Account 0: byte 0, bit 7 → `(0xAC >> 7) & 1 = 1` ✓
- Account 2: byte 0, bit 5 → `(0xAC >> 5) & 1 = 1` ✓
- Account 4: byte 0, bit 3 → `(0xAC >> 3) & 1 = 1` ✓
- Account 8: byte 1, bit 7 → `(0x80 >> 7) & 1 = 1` ✓

**Reference Implementation**:
- TypeScript: `accountsToWritableFlags()` in `contracts/svm-gateway/app/execute-payload.ts`
- Rust: Lines 420-424 in `contracts/svm-gateway/programs/universal-gateway/src/instructions/execute.rs`

### 3.5 Signing Algorithm

1. Concatenate all segments in order: `PREFIX + instruction_id + chain_id + nonce + amount + additional_fields`
2. Compute Keccak-256 hash of concatenated bytes → `message_hash`
3. Sign `message_hash` with secp256k1 ECDSA (using TSS private key)
4. Extract:
   - `signature`: 64 bytes (r || s)
   - `recovery_id`: 0 or 1 (for public key recovery)

**Libraries**:
- Keccak-256: `js-sha3` or equivalent
- secp256k1: `@noble/secp256k1` or equivalent

**Reference Implementation**:
- File: `contracts/svm-gateway/tests/helpers/tss.ts`
- Functions: `signTssMessage()`, `buildExecuteAdditionalData()`
- Test usage: `contracts/svm-gateway/tests/execute.test.ts` (search for `signTssMessage`)
- **Note**: `signTssMessage()` automatically injects `universal_tx_id`, `tx_id`, and `origin_caller` (for withdraw) before the `additional` array (see `tss.ts` lines 73-81)

### 3.6 Getting TSS Nonce and Chain ID

**Fetch from on-chain TSS PDA**:
- PDA seeds: `["tsspda"]`
- Account contains: `{ tss_eth_address, chain_id, nonce, authority, bump }`
- Read `chain_id` (Rust `String`) and `nonce` (u64)
- **CRITICAL**: Use `chain_id` exactly as stored (UTF-8 bytes, no modification)
  - This should match the event's `chainId` field (source chain identifier)
- Use current `nonce` for signing (must match exactly, or transaction fails)
- Nonce increments after successful execution (atomic)

**Reference**: See `TssPda` struct in `contracts/svm-gateway/programs/universal-gateway/src/state.rs`

---

## 4. Solana Program Functions

### 4.1 Execute Universal Transaction (SOL)

**Function**: `execute_universal_tx`

**Parameters**:
- `tx_id`: [u8; 32]
- `universal_tx_id`: [u8; 32]
- `amount`: u64
- `target_program`: Pubkey (32 bytes)
- `sender`: [u8; 20] (EVM address)
- `writable_flags`: Vec<u8> (bitpacked writable flags, 1 bit per account, MSB first)
- `ix_data`: Vec<u8> (from decoded payload)
- `gas_fee`: u64
- `rent_fee`: u64 (from decoded payload)
- `signature`: [u8; 64]
- `recovery_id`: u8 (0 or 1)
- `message_hash`: [u8; 32]
- `nonce`: u64

**Required Accounts**:
- `caller`: Relayer keypair (signer, payer)
- `config`: PDA `["config"]`
- `vault_sol`: PDA `["vault"]` (uses config.vault_bump)
- `cea_authority`: PDA `["push_identity", sender]`
- `tss_pda`: PDA `["tsspda"]`
- `executed_tx`: PDA `["executed_tx", tx_id]` (will be created)
- `destination_program`: Target program pubkey
- `system_program`: System program

**Remaining Accounts**:
- Pass decoded `accounts` from payload as `remaining_accounts`
- Each account: `{ pubkey, isWritable, isSigner: false }`
- Order must match the order in the decoded payload
- `writable_flags` is bitpacked: bit i corresponds to `remaining_accounts[i]`

### 4.2 Execute Universal Transaction (SPL Token)

**Function**: `execute_universal_tx_token`

**Additional Parameters**: Same as SOL execute

**Additional Required Accounts**:
- `vault_ata`: Associated token account (vault_sol PDA, mint) - owner validated at runtime (must match vault_sol PDA)
- `cea_ata`: Associated token account (cea_authority, mint) - will be created if missing
- `mint`: Token mint pubkey
- `token_program`: SPL Token program
- `associated_token_program`: Associated Token program
- `rent`: Rent sysvar

**Note**: `vault_authority` account was removed (optimization). The `vault_sol` PDA is used directly for both SOL operations and as the token authority for vault_ata.

**Reference**: See `ExecuteUniversalTxToken` struct in `contracts/svm-gateway/programs/universal-gateway/src/instructions/execute.rs`

**CEA ATA Derivation**:
- Use standard ATA derivation: `[authority (CEA), token_program_id, mint]`
- Check if exists before transaction; if not, program will create it (relayer pays rent)

### 4.3 Withdraw (SOL)

**Function**: `withdraw`

**Parameters**:
- `tx_id`: [u8; 32]
- `universal_tx_id`: [u8; 32]
- `origin_caller`: [u8; 20] (EVM address from event.sender)
- `amount`: u64
- `gas_fee`: u64
- `signature`: [u8; 64]
- `recovery_id`: u8
- `message_hash`: [u8; 32]
- `nonce`: u64

**Required Accounts**:
- `caller`: Relayer keypair (signer, payer)
- `config`: PDA `["config"]`
- `vault`: PDA `["vault"]`
- `tss_pda`: PDA `["tsspda"]`
- `recipient`: Recipient pubkey (from event or derived)
- `executed_tx`: PDA `["executed_tx", tx_id]` (will be created)
- `system_program`: System program

**Reference**: See `Withdraw` struct in `contracts/svm-gateway/programs/universal-gateway/src/instructions/withdraw.rs`

### 4.4 Withdraw Tokens (SPL Token)

**Function**: `withdraw_tokens` (renamed from `withdraw_funds` to match EVM naming)

**Additional Required Accounts**:
- `token_vault`: Vault ATA for the mint (validated manually at runtime: owner == vault, mint == token_mint)
- `recipient_token_account`: Recipient ATA (must exist)
- `token_mint`: Token mint
- `vault_sol`: PDA `["vault"]` (for gas_fee transfer)
- `token_program`: SPL Token program
- `system_program`: System program

**Note**: Token support is determined by rate limit threshold > 0 (not whitelist). The `token_vault` is validated manually (matches deposit flow validation style) to ensure it's owned by the vault PDA and matches the token mint.

**Reference**: See `WithdrawTokens` struct and `withdraw_tokens()` function in `contracts/svm-gateway/programs/universal-gateway/src/instructions/withdraw.rs`

### 4.5 Revert Universal Transaction (SOL)

**Function**: `revert_universal_tx`

**Parameters**:
- `tx_id`: [u8; 32]
- `universal_tx_id`: [u8; 32]
- `amount`: u64
- `revert_instruction`: Struct `{ fund_recipient: Pubkey, revert_msg: Vec<u8> }`
- `gas_fee`: u64
- `signature`: [u8; 64]
- `recovery_id`: u8
- `message_hash`: [u8; 32]
- `nonce`: u64

**revert_instruction**:
- `fund_recipient`: Pubkey (32 bytes) - where to send reverted funds
- `revert_msg`: Vec<u8> - revert message (can be empty)

### 4.6 Revert Universal Transaction (SPL Token)

**Function**: `revert_universal_tx_token`

**Additional Required Accounts**: Same as `withdraw_tokens` (token_vault, recipient_token_account, token_mint, vault_sol, token_program, system_program)

---

## 5. PDA Derivation

All PDAs use `findProgramAddressSync` with gateway program ID.

**Gateway Program ID**: Deployed program address (check deployment)

**PDAs**:
- `config`: `["config"]`
- `vault`: `["vault"]` (bump stored in config)
- `tss_pda`: `["tsspda"]`
- `cea_authority`: `["push_identity", sender]` (sender = 20-byte EVM address)
- `executed_tx`: `["executed_tx", tx_id]` (tx_id = 32 bytes)
- `rate_limit_config`: `["rate_limit_config"]`
- `token_rate_limit`: `["rate_limit", token_mint]`

**Note**: Token whitelist PDA is no longer used. Token support is determined by rate limit threshold > 0.

**Associated Token Accounts (ATAs)**:
- Standard ATA derivation: `[authority, token_program_id, mint]`
- Use `getAssociatedTokenAddress()` helper or derive manually

---

## 6. Fee Calculation

### 6.1 Gas Fee Components

**Precheck Rule**: `rent_fee <= gas_fee` (must be validated before signing TSS message)

**For SOL Execute**:
```
gas_fee = rent_fee + executed_tx_rent + compute_buffer
```

**For SPL Execute**:
```
gas_fee = rent_fee + executed_tx_rent + cea_ata_rent (if created) + compute_buffer
```

**Components**:
- `rent_fee`: For target program account creation (transferred to CEA, used by target program if needed)
  - **Note**: This is ONLY for target program rent. Gateway account rent (executed_tx, cea_ata) is covered by validator and reimbursed via `gas_fee`
  - **Precheck**: Must be `<= gas_fee` (reject if `rent_fee > gas_fee`)
- `executed_tx_rent`: ~890,880 lamports (8-byte account, paid by relayer, reimbursed via gas_fee)
  - **Backend SHOULD compute**: Use `getMinimumBalanceForRentExemption(8)` for exact value
- `cea_ata_rent`: ~2,039,280 lamports (165-byte token account, only if CEA ATA doesn't exist, paid by relayer, reimbursed via gas_fee)
  - **Backend SHOULD compute**: Use `getMinimumBalanceForRentExemption(165)` for exact value
- `compute_buffer`: ~100,000 lamports (transaction fees + compute units)

**On-chain split**:
- `rent_fee` → CEA (if > 0, for target program use)
- `amount` → CEA (if > 0)
- `relayer_fee = gas_fee - rent_fee` → Caller (relayer, reimburses gateway account rent + compute fees)

### 6.2 Rent Fee (from Payload)

**For execute flows**: `rent_fee` is included in the `payload` bytes (see section 2.2). Backend decodes it from payload - no estimation needed.

**For payload construction** (tests/tools only): If you're building payloads off-chain, estimate `rent_fee` based on target program needs:
- If target creates accounts: estimate rent for those accounts
- If target only reads/writes: `rent_fee = 0` or small buffer
- Common values: 0 (no rent), 1,500,000 (1.5 SOL), or calculated per account size
- Use `getMinimumBalanceForRentExemption(size)` RPC call for exact values
- Add buffer for safety (~10-20%)

**Important**: `rent_fee` is ONLY for target program account creation (transferred to CEA). Gateway account rent (executed_tx, cea_ata) is covered by validator and reimbursed via `gas_fee`.

---

## 7. Backend Implementation Steps

### 7.1 Event Listener

1. Connect to Push Chain RPC
2. Listen for `UniversalTxWithdraw` events
3. Filter by `chainId` = Solana cluster identifier
4. Extract all event fields

### 7.2 Payload Decoding

1. Take `payload` bytes from event
2. Decode using algorithm in section 2.2
3. Validate:
   - `rent_fee >= 0` and `rent_fee <= gas_fee` (precheck: rent_fee cannot exceed gas_fee)
   - Gateway allows `accounts_count == 0` and `ix_data_length == 0`, but target program may fail
   - Reject if `amount > u64::MAX` or `gasFee > u64::MAX` or `rentFee > u64::MAX`
4. Store: `accounts[]`, `ixData`, `rentFee`

### 7.3 TSS Message Construction

1. Determine `instruction_id` (5 for SOL execute, 6 for SPL execute, etc.)
2. Fetch TSS PDA from Solana:
   - Derive TSS PDA: `["tsspda"]`
   - Read account: get `chain_id` (string) and `nonce` (u64)
3. Build message hash:
   - Concatenate: prefix + instruction_id + chain_id + nonce + amount + additional_fields
   - Additional fields depend on instruction (see section 3.2)
4. For execute: build `accounts_buf` and `ix_data_buf` (section 3.2)

### 7.4 TSS Signing

1. Hash message with Keccak-256 → `message_hash`
2. Sign `message_hash` with TSS private key (secp256k1)
3. Extract `signature` (64 bytes) and `recovery_id` (0 or 1)
4. Verify: Recover public key from signature, verify matches TSS ETH address

### 7.5 Solana Transaction Construction

1. Derive all required PDAs (section 5)
2. Build instruction using Anchor client or raw instruction:
   - Function: `execute_universal_tx` or `execute_universal_tx_token`
   - Parameters: All from event + decoded payload + signature data
   - Accounts: Required accounts + remaining_accounts
3. Add instruction to transaction
4. Set recent blockhash
5. Sign with relayer keypair
6. Submit to Solana network

### 7.6 Error Handling

**Common errors**:
- `MessageHashMismatch`: TSS message construction incorrect (check field order)
- `NonceMismatch`: Nonce changed (fetch latest)
- `ConstraintSeeds`: PDA derivation incorrect (check seeds)
- `InvalidAccount`: Accounts don't match (check order/flags)
- `InsufficientBalance`: Vault doesn't have enough funds
- `Paused`: Gateway is paused (check config)

**Retry logic**:
- Nonce mismatch: Fetch new nonce, rebuild message, retry
- Transaction expired: Get new blockhash, retry
- Account errors: Verify PDA derivation and account order

### 7.7 Event Verification

1. After transaction confirmation, listen for Solana events (EVM parity: `UniversalTxExecuted` for both execute and withdraw):
   - `UniversalTxExecuted` (for execute and withdraw) — field order: `tx_id`, `universal_tx_id`, `sender`, `target`, `token`, `amount`, `payload`. For withdraw, `target` = recipient, `payload` = empty.
   - `RevertUniversalTx` (for revert)
2. Verify event fields match your transaction
3. Mark transaction as completed

---

## 8. Critical Implementation Rules

### 8.1 Account Consistency

**MUST match exactly**:
- Accounts in TSS message hash (`accounts_buf` - reconstructed from `remaining_accounts` + `writable_flags`)
- Accounts in `remaining_accounts` (passed to transaction)
- Writable flags in `writable_flags` (bitpacked, bit i = `remaining_accounts[i].isWritable`)
- Same order, same pubkeys, writable flags match bit positions

**Why**: On-chain validates TSS signature against reconstructed message hash. If accounts differ, hash mismatch → rejection.

### 8.2 Universal Transaction ID

- `universal_tx_id`: 32 bytes from source chain (EVM tx hash or similar)
- Include in: TSS message hash, function parameters, event emissions
- NOT stored on-chain (only emitted in events)

### 8.3 Rent Fee Source

- `rent_fee` is NOT a top-level Push Chain event field
- For execute flows: `rent_fee` is included inside the `payload` bytes (see section 2.2)
- Backend decodes `rent_fee` from payload - no estimation needed
- Only when constructing payloads off-chain (tests/tools) do you estimate and encode it
- Can be 0 if target program doesn't need rent

### 8.4 Nonce Management

- Always fetch latest nonce from TSS PDA before signing
- Nonce increments atomically after successful execution
- If nonce mismatch: fetch new nonce, rebuild message, retry

### 8.5 Transaction Size Limits

- Solana transaction limit: 1232 bytes
- Your payload: ~50-400 bytes typically
- If too large: split into multiple transactions (not supported yet)

---

## 9. Example Implementation Flow

### Execute Flow:

1. **Event received**: `UniversalTxWithdraw` with `target`, `amount`, `payload`, `gasFee`, `sender`
2. **Decode payload**: Extract `accounts[]`, `ixData`, `rentFee`
3. **Derive PDAs**: CEA authority, executed_tx, config, vault, tss_pda
4. **Fetch TSS state**: Get `chain_id` and `nonce` from TSS PDA
5. **Build writable flags**: Convert `accounts[]` to bitpacked `writable_flags` (1 bit per account, MSB first)
6. **Build TSS message**: 
   - instruction_id = 5 (SOL) or 6 (SPL)
   - additional = [universal_tx_id, tx_id, target_program, sender, accounts_buf, ix_data_buf, gas_fee, rent_fee]
   - `accounts_buf` = serialized accounts (full format with pubkeys for TSS hash)
7. **Sign**: Keccak-256 hash → secp256k1 sign → signature + recovery_id
8. **Build Solana transaction**:
   - Function: `execute_universal_tx` or `execute_universal_tx_token`
   - Parameters: tx_id, universal_tx_id, amount, target_program, sender, writable_flags, ix_data, gas_fee, rent_fee, signature, recovery_id, message_hash, nonce
   - Accounts: All required accounts + remaining_accounts (decoded accounts, same order as payload)
9. **Submit**: Sign with relayer, send to Solana
10. **Verify**: Wait for `UniversalTxExecuted` event

### Withdraw Flow:

1. **Event received**: `UniversalTxWithdraw` (no payload, just amount)
2. **Derive PDAs**: Same as execute (see section 5)
3. **Fetch TSS state**: Get chain_id and nonce (see section 3.6)
4. **Build TSS message**:
   - instruction_id = 1 (SOL) or 2 (SPL)
   - Call `signTssMessage()` with:
     - `universalTxId`: 32 bytes (from source chain)
     - `txId`: 32 bytes (deterministic, stable across retries)
     - `originCaller`: 20 bytes (EVM address from event.sender)
     - `additional`: 
       - SOL: `[recipient_pubkey (32 bytes), gas_fee_buf (8 bytes, u64 BE)]`
       - SPL: `[mint_pubkey (32 bytes), recipient_token_account (32 bytes), gas_fee_buf (8 bytes, u64 BE)]`
   - **Note**: `signTssMessage()` automatically includes `universal_tx_id`, `tx_id`, and `origin_caller` in the message hash before `additional`
5. **Sign**: `signTssMessage()` returns signature, recovery_id, message_hash, nonce
6. **Build Solana transaction**: 
   - Function: `withdraw` or `withdraw_tokens`
   - See account structs: `Withdraw` or `WithdrawTokens` in `withdraw.rs`
7. **Submit and verify**: Same as execute (see step 9-10 above)

### Revert Flow:

1. **Event received**: Revert instruction from Push Chain
2. **Build TSS message**:
   - instruction_id = 3 (SOL) or 4 (SPL)
   - Call `signTssMessage()` with:
     - `universalTxId`: 32 bytes (from source chain)
     - `txId`: 32 bytes (deterministic, stable across retries)
     - `additional`:
       - SOL: `[recipient_pubkey (32 bytes), gas_fee_buf (8 bytes, u64 BE)]`
       - SPL: `[mint_pubkey (32 bytes), recipient_pubkey (32 bytes), gas_fee_buf (8 bytes, u64 BE)]`
   - **Note**: `signTssMessage()` automatically includes `universal_tx_id` and `tx_id` in the message hash before `additional`
3. **Sign and submit**: 
   - `signTssMessage()` returns signature, recovery_id, message_hash, nonce
   - See account structs: `RevertUniversalTx` or `RevertUniversalTxToken` in `withdraw.rs`

---

## 10. Testing Checklist

Before production:
- [ ] Payload decode matches encode (roundtrip)
- [ ] TSS message hash matches on-chain reconstruction
- [ ] Account order/flags match in all three places (hash, param, remaining)
- [ ] Nonce increments correctly
- [ ] Fee calculations correct (relayer receives gas_fee - rent_fee)
- [ ] CEA ATA creation works (SPL execute)
- [ ] Error handling for all error codes
- [ ] Event verification works

---

## 11. Reference Implementation Files

### 11.1 Payload Encoding/Decoding

**File**: `contracts/svm-gateway/app/execute-payload.ts`

**Key Functions**:
- `encodeExecutePayload()` - Encodes accounts + ixData + rentFee into payload bytes
- `decodeExecutePayload()` - Decodes payload bytes back to accounts + ixData + rentFee
- `accountsToWritableFlags()` - Converts accounts array to bitpacked writable flags

**Usage**: See test file `contracts/svm-gateway/tests/execute.test.ts` (search for `encodeExecutePayload`)

### 11.2 TSS Message Signing

**File**: `contracts/svm-gateway/tests/helpers/tss.ts`

**Key Functions**:
- `signTssMessage()` - Builds and signs TSS message hash
- `buildExecuteAdditionalData()` - Constructs additional fields for execute instructions
- `buildWithdrawAdditionalData()` - Constructs additional fields for withdraw instructions

**Usage**: See test file `contracts/svm-gateway/tests/execute.test.ts` (search for `signTssMessage`)

### 11.3 Program Implementation

**Execute Functions**:
- `contracts/svm-gateway/programs/universal-gateway/src/instructions/execute.rs`
  - `execute_universal_tx()` - SOL execution handler
  - `execute_universal_tx_token()` - SPL token execution handler
  - `ExecuteUniversalTx` struct - Account struct for SOL execute
  - `ExecuteUniversalTxToken` struct - Account struct for SPL execute

**Withdraw Functions**:
- `contracts/svm-gateway/programs/universal-gateway/src/instructions/withdraw.rs`
  - `withdraw()` - SOL withdrawal handler
  - `withdraw_tokens()` - SPL token withdrawal handler
  - `revert_universal_tx()` - SOL revert handler
  - `revert_universal_tx_token()` - SPL token revert handler

**Deposit Functions**:
- `contracts/svm-gateway/programs/universal-gateway/src/instructions/deposit.rs`
  - `send_universal_tx()` - Universal deposit entrypoint
  - `route_universal_tx()` - Routes to GAS or FUNDS handlers

**TSS Validation**:
- `contracts/svm-gateway/programs/universal-gateway/src/instructions/tss.rs`
  - `validate_message()` - Validates TSS signature and message hash

**Utilities**:
- `contracts/svm-gateway/programs/universal-gateway/src/utils.rs`
  - `validate_remaining_accounts()` - Validates account list and rejects outer signers
  - `calculate_sol_price()` - Pyth price oracle integration

### 11.4 Test Examples

**Execute Tests**:
- `contracts/svm-gateway/tests/execute.test.ts` - Complete execute flow examples
  - Search for `"should execute SOL transaction"` - Basic SOL execute
  - Search for `"should execute SPL transaction"` - Basic SPL execute
  - Search for `"should handle heavy transactions"` - Large payload examples

**Withdraw Tests**:
- `contracts/svm-gateway/tests/withdraw.test.ts` - Complete withdraw flow examples
  - Search for `"transfers SOL with a valid signature"` - SOL withdraw
  - Search for `"transfers SPL tokens with a valid signature"` - SPL withdraw

**Integration Test Script**:
- `contracts/svm-gateway/app/gateway-test.ts` - End-to-end integration test script
  - Tests all flows: execute, withdraw, revert (SOL and SPL)
  - Includes transaction size limit testing

### 11.5 Account Structures (Rust)

**Execute Account Structs** (see `execute.rs`):
- `ExecuteUniversalTx` - Required accounts for SOL execute
- `ExecuteUniversalTxToken` - Required accounts for SPL execute

**Withdraw Account Structs** (see `withdraw.rs`):
- `Withdraw` - Required accounts for SOL withdraw
- `WithdrawTokens` - Required accounts for SPL withdraw
- `RevertUniversalTx` - Required accounts for SOL revert
- `RevertUniversalTxToken` - Required accounts for SPL revert

**State Structures** (see `state.rs`):
- `GatewayAccountMeta` - Account metadata (pubkey + is_writable)
- `Config` - Gateway configuration
- `TssPda` - TSS state (nonce, chain_id, etc.)
- `ExecutedTx` - Replay protection tracker

---

## 12. Known Limitations

- **Single signer**: Only CEA can sign (affects <5% of programs)
- **Single instruction**: One instruction per execute (no transaction composition)
- **Transaction size**: 1232 bytes limit (usually fine, but large payloads may fail)