# Universal Gateway Backend Integration Guide

Technical guide for backend teams to implement the relayer service that processes Push Chain events and executes transactions on Solana.

## 1. Execution Flow

### 1.1 High-Level Flow

```
User (EVM) → Push Chain → Event Emission → Backend Service → TSS Signing → Solana Execution
```

**Step-by-step:**
1. User calls `UniversalGatewayPC.withdrawAndExecute()` on Push Chain
2. Push Chain burns tokens, emits `UniversalTxOutbound` event
3. Backend service watches events, extracts event data
4. Backend decodes payload to get `instructionId` (1=withdraw, 2=execute) + accounts + ixData + rentFee
5. Backend builds mode-specific TSS message hash (format varies by instructionId), signs with ECDSA secp256k1
6. Backend constructs Solana transaction calling unified `withdraw_and_execute` function
7. Backend submits transaction to Solana network
8. Gateway program verifies signature, then routes based on instructionId:
   - **Withdraw (1)**: vault→CEA→recipient (direct transfer)
   - **Execute (2)**: vault→CEA→CPI to target program
   - **Revert (3/4)**: separate revert functions
9. All successful outcomes emit `UniversalTxExecuted` (withdraw/execute) or `RevertUniversalTx` (revert)

### 1.2 Event Structure (Push Chain)

**Event**: `UniversalTxOutbound`
```solidity
event UniversalTxOutbound(
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

### 1.3 Unified Entrypoint Architecture

**Key Concept**: The gateway uses a **single unified function** `withdraw_and_execute` for both withdraw and execute operations.

**How it works**:
1. **instruction_id parameter** determines the operation mode:
   - `1` = Withdraw mode (vault→CEA→recipient, direct transfer)
   - `2` = Execute mode (vault→CEA→CPI to target program)

2. **No target parameter**: The target is derived from mode-specific accounts:
   - Withdraw (1): Target derived from `recipient` account key
   - Execute (2): Target derived from `destination_program` account key

3. **Mode-specific account enforcement**:
   - `destination_program` is ALWAYS required (non-optional account)
     - Withdraw mode: Pass `SystemProgram.programId` (used as sentinel, target comes from recipient)
     - Execute mode: Pass target program pubkey (must be executable)
   - `recipient` is optional:
     - Withdraw mode: Must be provided (contains recipient pubkey)
     - Execute mode: Must be None/null

4. **Mode-specific validation**:
   - Withdraw: `rent_fee` must be 0, `writable_flags` empty, `ix_data` empty, `amount` > 0
   - Execute: `rent_fee` <= `gas_fee`, `writable_flags` present, `ix_data` present

5. **TSS message format**: Hash construction differs by instruction_id (see section 3.2)

**Benefits**:
- Reduces program size and complexity
- Shared validation logic
- Single transaction pattern for backend
- Easier maintenance and upgrades

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
[instruction_id: 1 byte (u8)]
```

**Total size**: `4 + (33 * accounts_count) + 4 + ix_data_length + 8 + 1`

**Instruction ID values**:
- `1` = Withdraw (SOL or SPL; vault→CEA→recipient)
- `2` = Execute (SOL or SPL; vault→CEA→CPI to target program)

### 2.2 Decoding Payload

**Input**: `payload` bytes from event

**Output**:
- `accounts`: Array of `{ pubkey: 32 bytes, isWritable: bool }`
- `ixData`: Raw instruction data bytes
- `rentFee`: u64 big-endian
- `instructionId`: u8 (1 = withdraw, 2 = execute)

**Algorithm**:
1. Read first 4 bytes → `accounts_count` (u32 BE)
2. For each account (0 to accounts_count-1):
   - Read 32 bytes → `pubkey`
   - Read 1 byte → `is_writable` (0 = false, 1 = true)
3. Read next 4 bytes → `ix_data_length` (u32 BE)
4. Read `ix_data_length` bytes → `ix_data`
5. Read next 8 bytes → `rent_fee` (u64 BE)
6. Read last 1 byte → `instruction_id` (u8)
7. Validate: total bytes consumed == payload length

### 2.3 Encoding Payload (For Testing/Validation)

**Input**: `accounts[]`, `ixData`, `rentFee`, `instructionId`

**Algorithm**:
1. Write `accounts.length` as u32 BE (4 bytes)
2. For each account: write `pubkey` (32 bytes) + `is_writable` (1 byte)
3. Write `ixData.length` as u32 BE (4 bytes)
4. Write `ixData` bytes
5. Write `rentFee` as u64 BE (8 bytes)
6. Write `instructionId` as u8 (1 byte)

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
   - `1` = Withdraw (SOL or SPL; unified, vault→CEA→recipient)
   - `2` = Execute (SOL or SPL; unified, vault→CEA→CPI)
   - `3` = Revert SOL
   - `4` = Revert SPL
2. `chain_id`: UTF-8 bytes (see 3.1.2 above) - **NO length prefix**
3. `nonce`: u64 BE (8 bytes) - current TSS nonce from on-chain TSS PDA
4. `amount`: u64 BE (8 bytes) - present for all instructions

**Additional fields** (order-critical, depends on instruction):

**IMPORTANT**: Common fields come first in the same order for both modes, followed by mode-specific fields.

**Common Fields (same for Execute and Withdraw):**
```
tx_id (32 bytes)           // First parameter in function signature
universal_tx_id (32 bytes) // Second parameter in function signature
sender (20 bytes, EVM address)
token (32 bytes)           // Pubkey::default() for SOL, mint pubkey for SPL
gas_fee (u64 BE)
```

**For Execute (2, unified SOL+SPL):**
```
[common fields above]
target_program (32 bytes, pubkey)  // Execute-specific: target program for CPI
accounts_buf (see 3.3)             // Execute-specific: accounts for CPI
ix_data_buf (see 3.3)              // Execute-specific: instruction data
rent_fee (u64 BE)                  // Execute-specific: rent for target accounts
```

**For Withdraw (1, unified SOL+SPL):**
```
[common fields above]
target (32 bytes, recipient pubkey) // Withdraw-specific: recipient address
```
- **SOL**: `token` = `Pubkey::default()` (32 zero bytes), `target` = SOL recipient pubkey
- **SPL**: `token` = mint pubkey, `target` = recipient owner pubkey (recipient ATA derived on-chain)

**Rationale**: This ordering ensures consistency across modes and matches the function parameter order, making it easier to maintain and less error-prone.

**For Revert SOL (3):**
```
universal_tx_id (32 bytes)
tx_id (32 bytes)
recipient_pubkey (32 bytes)
gas_fee (u64 BE)
```

**For Revert SPL (4):**
```
universal_tx_id (32 bytes)
tx_id (32 bytes)
mint_pubkey (32 bytes)
recipient_pubkey (32 bytes)
gas_fee (u64 BE)
```

**IMPORTANT**: All fields listed above (including `universal_tx_id`, `tx_id`, `sender`) **must** be included in the `additional` array when calling `signTssMessage()`. The helper function does **not** auto-inject these fields.

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
- Functions: `signTssMessage()`, `buildExecuteAdditionalData()`, `buildWithdrawAdditionalData()`
- Test usage: `contracts/svm-gateway/tests/execute.test.ts` and `tests/withdraw.test.ts` (search for `signTssMessage`)
- **Note**: Use the `buildWithdrawAdditionalData()` or `buildExecuteAdditionalData()` helpers to construct the `additional` array with correct ordering (common fields first)

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

### 4.1 Unified Withdraw & Execute Function

**Function**: `withdraw_and_execute`

This single entrypoint handles both withdraw (instruction_id=1) and execute (instruction_id=2) operations.

**Parameters**:
- `instruction_id`: u8 (`1` for withdraw, `2` for execute)
- `tx_id`: [u8; 32] - deterministic transaction identifier
- `universal_tx_id`: [u8; 32] - source chain transaction hash
- `amount`: u64 - amount to transfer
- `sender`: [u8; 20] - EVM address (Push Chain user)
- `writable_flags`: Vec<u8> - bitpacked writable flags (empty for withdraw, see 3.4 for execute)
- `ix_data`: Vec<u8> - CPI instruction data (empty for withdraw, from decoded payload for execute)
- `gas_fee`: u64 - total gas fee (includes relayer reimbursement)
- `rent_fee`: u64 - rent for target program (must be 0 for withdraw, from decoded payload for execute)
- `signature`: [u8; 64] - TSS signature
- `recovery_id`: u8 - signature recovery ID (0 or 1)
- `message_hash`: [u8; 32] - keccak256 hash of TSS message
- `nonce`: u64 - TSS nonce (must match current on-chain nonce)

**IMPORTANT - No `target` parameter**: The target is derived from mode-specific optional accounts:
- **Withdraw (instruction_id=1)**: Derived from `recipient` account key
- **Execute (instruction_id=2)**: Derived from `destination_program` account key

**Required Accounts** (all cases):
- `caller`: Relayer keypair (signer, payer)
- `config`: PDA `["config"]`
- `vault_sol`: PDA `["vault"]` (uses config.vault_bump)
- `cea_authority`: PDA `["push_identity", sender]`
- `tss_pda`: PDA `["tsspda"]`
- `executed_tx`: PDA `["executed_tx", tx_id]` (will be created)
- `system_program`: System program

**Mode-Specific Accounts**:
- `destination_program`: UncheckedAccount (ALWAYS REQUIRED, non-optional)
  - **Withdraw mode**: Pass `SystemProgram.programId` (sentinel value, actual target from recipient)
  - **Execute mode**: Pass target program pubkey (must be executable)
- `recipient`: Option<UncheckedAccount> - Mode-dependent (optional account)
  - **Withdraw mode**: Must be provided (mut)
  - **Execute mode**: Must be None

**SPL Optional Accounts** (all-or-none based on `mint` presence):
- `vault_ata`: Vault ATA for the mint (validated: owner == vault_sol, mint == mint)
- `cea_ata`: CEA ATA for the mint (created if missing; relayer pays rent)
- `mint`: Token mint pubkey
- `token_program`: SPL Token program
- `rent`: Rent sysvar
- `associated_token_program`: Associated Token program
- `recipient_ata`: **Withdraw only** - Recipient ATA (must exist; derived from recipient + mint)

**Anchor client note**:
- For execute mode: pass `recipient: null`, `destinationProgram: targetProgramPubkey`
- For withdraw mode: pass `recipient: recipientPubkey`, `destinationProgram: SystemProgram.programId`
- `destination_program` is NEVER null/omitted (always required, use SystemProgram as sentinel for withdraw)

**Remaining Accounts** (execute only):
- Pass decoded `accounts` from payload as `remaining_accounts`
- Each account: `{ pubkey, isWritable, isSigner: false }`
- Order must match the order in the decoded payload
- `writable_flags` is bitpacked: bit i corresponds to `remaining_accounts[i]`
- **Withdraw mode**: remaining_accounts must be empty

**Mode Enforcement Rules**:

| Rule | Withdraw (1) | Execute (2) |
|------|-------------|-------------|
| `recipient` | required | must be None |
| `destination_program` | SystemProgram.programId | required + executable |
| `remaining_accounts` | must be empty | required for CPI |
| `writable_flags` | must be empty | length = ceil(accounts/8) |
| `ix_data` | must be empty | CPI data |
| `rent_fee` | must be 0 | <= gas_fee |
| `amount` | must be > 0 | any (can be 0) |
| `recipient_ata` | SPL only | must be None |

**Reference**: See `WithdrawAndExecute` struct in `contracts/svm-gateway/programs/universal-gateway/src/instructions/execute.rs`

**CEA ATA Derivation**:
- Use standard ATA derivation: `[authority (CEA), token_program_id, mint]`
- Check if exists before transaction; if not, program will create it (relayer pays rent)

### 4.2 Example: Execute Mode (instruction_id=2)

**Use case**: Execute a CPI to a target program with transferred funds

**Key requirements**:
- `instruction_id = 2`
- `destination_program`: Target program pubkey (must be executable)
- `recipient`: Must be None
- `remaining_accounts`: Decoded accounts from payload
- `writable_flags`: Bitpacked flags matching accounts
- `ix_data`: Instruction data from payload
- `rent_fee`: From decoded payload (can be 0 if target doesn't need rent)
- For SPL: include all SPL accounts (vault_ata, cea_ata, mint, etc.)

**Flow**: vault→CEA→CPI to destination_program

### 4.3 Example: Withdraw Mode (instruction_id=1)

**Use case**: Direct transfer to recipient without CPI

**Key requirements**:
- `instruction_id = 1`
- `recipient`: Must be provided (recipient pubkey)
- `destination_program`: SystemProgram.programId (sentinel value)
- `remaining_accounts`: Must be empty
- `writable_flags`: Must be empty
- `ix_data`: Must be empty
- `rent_fee`: Must be 0
- `amount`: Must be > 0
- For SPL: include all SPL accounts including `recipient_ata`

**Flow**: vault→CEA→recipient (direct transfer)

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

**Additional Required Accounts**: Same as SPL withdraw (token_vault, recipient_token_account, token_mint, token_program)

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
2. Listen for `UniversalTxOutbound` events
3. Filter by `chainId` = Solana cluster identifier
4. Extract all event fields

### 7.2 Payload Decoding

1. Take `payload` bytes from event
2. Decode using algorithm in section 2.2
3. Extract fields:
   - `accounts[]`: Array of account metadata (pubkey + isWritable)
   - `ixData`: Instruction data for target program
   - `rentFee`: Rent fee for target program (u64)
   - `instructionId`: Operation mode (1=withdraw, 2=execute)
4. Validate:
   - `rent_fee >= 0` and `rent_fee <= gas_fee` (precheck: rent_fee cannot exceed gas_fee)
   - Gateway allows `accounts_count == 0` and `ix_data_length == 0`, but target program may fail
   - Reject if `amount > u64::MAX` or `gasFee > u64::MAX` or `rentFee > u64::MAX`
   - For withdraw (instructionId=1): `accounts` must be empty, `ixData` must be empty, `rentFee` must be 0
   - For execute (instructionId=2): `accounts` and `ixData` contain CPI data

### 7.3 TSS Message Construction

1. Determine `instruction_id` from decoded payload:
   - `1` = Withdraw (unified SOL/SPL)
   - `2` = Execute (unified SOL/SPL)
2. Fetch TSS PDA from Solana:
   - Derive TSS PDA: `["tsspda"]`
   - Read account: get `chain_id` (string) and `nonce` (u64)
3. Build message hash based on instruction_id (common fields first):
   - **Withdraw (1)**:
     `PREFIX | 0x01 | chain_id | nonce | amount | tx_id | universal_tx_id | sender | token | gas_fee | target`
   - **Execute (2)**:
     `PREFIX | 0x02 | chain_id | nonce | amount | tx_id | universal_tx_id | sender | token | gas_fee | target_program | accounts_buf | ix_data_buf | rent_fee`
4. For execute: build `accounts_buf` and `ix_data_buf` with length prefixes (section 3.3)

### 7.4 TSS Signing

1. Hash message with Keccak-256 → `message_hash`
2. Sign `message_hash` with TSS private key (secp256k1)
3. Extract `signature` (64 bytes) and `recovery_id` (0 or 1)
4. Verify: Recover public key from signature, verify matches TSS ETH address

### 7.5 Solana Transaction Construction

1. Derive all required PDAs (section 5)
2. Determine mode-specific accounts based on instruction_id:
   - **Withdraw (1)**: Set `recipient` account, `destination_program` = SystemProgram.programId, `remaining_accounts` = []
   - **Execute (2)**: Set `destination_program` account (target program), `recipient` = None, `remaining_accounts` = decoded accounts
3. Build instruction using Anchor client or raw instruction:
   - Function: `withdraw_and_execute`
   - Parameters: `instruction_id`, `tx_id`, `universal_tx_id`, `amount`, `sender`, `writable_flags`, `ix_data`, `gas_fee`, `rent_fee`, `signature`, `recovery_id`, `message_hash`, `nonce`
   - **IMPORTANT**: No `target` parameter - target is derived from optional accounts
   - Accounts: Required accounts + mode-specific optional accounts + SPL accounts (if token) + remaining_accounts (if execute)
4. For execute mode: convert accounts to writable_flags (bitpacked, see section 3.4)
5. Add instruction to transaction
6. Set recent blockhash
7. Sign with relayer keypair
8. Submit to Solana network

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

### 8.0 Unified Entrypoint Rules (NEW)

**CRITICAL - No target parameter**:
- The `withdraw_and_execute` function does **NOT** take a `target` parameter
- Target is derived from mode-specific accounts:
  - Withdraw (1): From `recipient` account key
  - Execute (2): From `destination_program` account key
- **Backend must pass correct accounts**: Passing wrong accounts will cause validation failure

**Mode-specific account enforcement**:
- `destination_program` is ALWAYS required (non-optional):
  - Withdraw mode: Pass `SystemProgram.programId` (sentinel, actual target from recipient)
  - Execute mode: Pass target program pubkey (must be executable)
- `recipient` is optional (mode-dependent):
  - Withdraw mode: Must be provided (contains recipient pubkey)
  - Execute mode: Must be None
- Violating this will cause on-chain constraint error

**instruction_id matching**:
- The `instruction_id` in the payload **must** match the `instruction_id` parameter passed to the function
- TSS message hash is built using the `instruction_id`, so any mismatch will cause signature verification failure

### 8.1 Account Consistency (Execute Mode Only)

**Requirements** (for execute mode, instruction_id=2):

**Pubkeys and Order:**
- MUST match exactly: Same pubkeys in same order between TSS message hash and `remaining_accounts`

**Writable Flags - One-Way Rule** (utils.rs:247):
- If signed metadata (in `accounts_buf`) marks account as writable → actual account MUST be writable
- If signed metadata marks account as read-only → actual account CAN be writable OR read-only
- **NOT allowed:** Signed metadata says writable, but actual account is read-only
- **Allowed:** Actual account is writable, but signed metadata says read-only (CPI won't gain extra write privileges)

**For withdraw mode** (instruction_id=1):
- `remaining_accounts` must be empty
- `writable_flags` must be empty
- No account consistency check needed (no CPI)

**Why**: On-chain validates TSS signature against reconstructed message hash. Pubkey mismatch → hash mismatch → rejection. Writable validation ensures CPI safety.

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

### Execute Flow (instruction_id=2):

1. **Event received**: `UniversalTxOutbound` with `target`, `amount`, `payload`, `gasFee`, `sender`
2. **Decode payload**: Extract `accounts[]`, `ixData`, `rentFee`, `instructionId`
   - Verify `instructionId == 2` (execute mode)
   - Validate: `rentFee <= gasFee`, accounts and ixData present
3. **Derive PDAs**: CEA authority, executed_tx, config, vault, tss_pda
4. **Fetch TSS state**: Get `chain_id` and `nonce` from TSS PDA
5. **Build writable flags**: Convert `accounts[]` to bitpacked `writable_flags` (1 bit per account, MSB first)
6. **Build TSS message**:
   - Use `buildExecuteAdditionalData()` helper (see `tests/helpers/tss.ts`)
   - instruction_id = 2
   - additional_data = [tx_id, universal_tx_id, sender, token, gas_fee, target_program, accounts_buf, ix_data_buf, rent_fee]
   - **Common fields first**: tx_id, universal_tx_id, sender, token, gas_fee
   - **Execute-specific**: target_program, accounts_buf, ix_data_buf, rent_fee
   - `accounts_buf` = length-prefixed serialized accounts (u32 BE count + accounts with pubkeys + isWritable)
   - `ix_data_buf` = length-prefixed instruction data (u32 BE length + data)
   - `token` = `Pubkey::default()` for SOL, mint pubkey for SPL
7. **Sign**: Call `signTssMessage()` → Keccak-256 hash → secp256k1 sign → signature + recovery_id
8. **Build Solana transaction**:
   - Function: `withdraw_and_execute`
   - Parameters: `instruction_id=2`, `tx_id`, `universal_tx_id`, `amount`, `sender`, `writable_flags`, `ix_data`, `gas_fee`, `rent_fee`, `signature`, `recovery_id`, `message_hash`, `nonce`
   - **IMPORTANT - No target parameter**: Target derived from `destination_program` account
   - Accounts:
     - Required: `caller`, `config`, `vault_sol`, `cea_authority`, `tss_pda`, `executed_tx`, `system_program`
     - Mode-specific: `destination_program` (target program pubkey), `recipient` = None
     - SPL (if token): `vault_ata`, `cea_ata`, `mint`, `token_program`, `rent`, `associated_token_program`
     - Remaining: decoded accounts from payload (same order, same isWritable flags)
9. **Submit**: Sign with relayer keypair, send to Solana
10. **Verify**: Wait for `UniversalTxExecuted` event (includes tx_id, universal_tx_id, sender, target, token, amount, payload)

### Withdraw Flow (instruction_id=1):

1. **Event received**: `UniversalTxOutbound` with `payload` (or no payload for simple withdraw)
2. **Decode payload** (if present): Extract `instructionId`
   - Verify `instructionId == 1` (withdraw mode)
   - Validate: `accounts` empty, `ixData` empty, `rentFee == 0`
3. **Derive PDAs**: Same as execute (see section 5)
4. **Fetch TSS state**: Get `chain_id` and `nonce` from TSS PDA
5. **Build TSS message**:
   - Use `buildWithdrawAdditionalData()` helper (see `tests/helpers/tss.ts`)
   - instruction_id = 1
   - additional_data = [tx_id, universal_tx_id, sender, token, gas_fee, target]
   - **Common fields first**: tx_id, universal_tx_id, sender, token, gas_fee
   - **Withdraw-specific**: target (recipient)
     - **SOL**: `token` = `Pubkey::default()`, `target` = SOL recipient pubkey
     - **SPL**: `token` = mint pubkey, `target` = recipient owner pubkey (recipient ATA derived on-chain)
6. **Sign**: Call `signTssMessage()` → Keccak-256 hash → secp256k1 sign → signature + recovery_id
7. **Build Solana transaction**:
   - Function: `withdraw_and_execute`
   - Parameters: `instruction_id=1`, `tx_id`, `universal_tx_id`, `amount`, `sender`, `writable_flags=[]`, `ix_data=[]`, `gas_fee`, `rent_fee=0`, `signature`, `recovery_id`, `message_hash`, `nonce`
   - **IMPORTANT - No target parameter**: Target derived from `recipient` account
   - Accounts:
     - Required: `caller`, `config`, `vault_sol`, `cea_authority`, `tss_pda`, `executed_tx`, `system_program`
     - Mode-specific: `recipient` (recipient pubkey), `destination_program` = SystemProgram.programId
     - SPL (if token): `vault_ata`, `cea_ata`, `mint`, `token_program`, `rent`, `associated_token_program`, `recipient_ata`
     - Remaining: must be empty
8. **Submit and verify**: Sign with relayer, send to Solana, wait for `UniversalTxExecuted` event

### Revert Flow:

1. **Event received**: Revert instruction from Push Chain
2. **Build TSS message**:
   - instruction_id = 3 (SOL) or 4 (SPL)
   - Call `signTssMessage()` with:
     - `additional`:
       - SOL: `[universal_tx_id, tx_id, recipient_pubkey, gas_fee_buf]`
       - SPL: `[universal_tx_id, tx_id, mint_pubkey, recipient_pubkey, gas_fee_buf]`
   - **Note**: `signTssMessage()` does **not** auto-include `universal_tx_id` / `tx_id`. Include them in `additional` as specified.
3. **Sign and submit**: 
   - `signTssMessage()` returns signature, recovery_id, message_hash, nonce
   - See account structs: `RevertUniversalTx` or `RevertUniversalTxToken` in `revert.rs`

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
- `encodeExecutePayload()` - Encodes accounts + ixData + rentFee + instructionId into payload bytes
- `decodeExecutePayload()` - Decodes payload bytes back to accounts + ixData + rentFee + instructionId
- `accountsToWritableFlags()` - Converts accounts array to bitpacked writable flags

**Usage**: See test file `contracts/svm-gateway/tests/execute.test.ts` (search for `encodeExecutePayload`)

### 11.2 TSS Message Signing

**File**: `contracts/svm-gateway/tests/helpers/tss.ts`

**Key Functions**:
- `signTssMessage()` - Builds and signs TSS message hash
  - Takes: `{ instruction, nonce, amount, additional, chainId }`
  - Returns: `{ signature, recoveryId, messageHash, nonce }`
- `buildExecuteAdditionalData()` - Constructs additional fields for execute (instruction_id=2)
  - Format: [tx_id, universal_tx_id, sender, token, gas_fee, target_program, accounts_buf, ix_data_buf, rent_fee]
  - **Common fields first**, then execute-specific
- `buildWithdrawAdditionalData()` - Constructs additional fields for withdraw (instruction_id=1)
  - Format: [tx_id, universal_tx_id, sender, token, gas_fee, target]
  - **Common fields first**, then withdraw-specific (target)

**Instruction IDs** (TssInstruction enum):
- `TssInstruction.Withdraw = 1` - Unified withdraw (SOL/SPL)
- `TssInstruction.Execute = 2` - Unified execute (SOL/SPL)
- `TssInstruction.RevertWithdrawSol = 3` - Revert SOL
- `TssInstruction.RevertWithdrawSpl = 4` - Revert SPL

**Usage**: See test file `contracts/svm-gateway/tests/execute.test.ts` (search for `signTssMessage` or `buildExecuteAdditionalData`)

### 11.3 Program Implementation

**Execute Functions**:
- `contracts/svm-gateway/programs/universal-gateway/src/instructions/execute.rs`
  - `withdraw_and_execute()` - unified withdraw + execute handler
  - `WithdrawAndExecute` struct - unified account struct for SOL/SPL execute + withdraw

**Withdraw / Revert Functions**:
- `contracts/svm-gateway/programs/universal-gateway/src/instructions/revert.rs`
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

**Unified Execute/Withdraw Struct** (see `execute.rs`):
- `WithdrawAndExecute` - Required + optional accounts for unified execute + withdraw operations
  - **Required accounts** (all modes): `caller`, `config`, `vault_sol`, `cea_authority`, `tss_pda`, `executed_tx`, `system_program`, `destination_program`
  - **Mode-specific accounts**:
    - `destination_program: UncheckedAccount` - ALWAYS required (non-optional)
      - Withdraw mode: SystemProgram.programId (sentinel)
      - Execute mode: Target program pubkey (must be executable)
    - `recipient: Option<UncheckedAccount>` - Mode-dependent optional account
      - Withdraw mode: Required (recipient address, mut)
      - Execute mode: Must be None
  - **SPL optional accounts** (all-or-none based on mint presence):
    - `vault_ata`, `cea_ata`, `mint`, `token_program`, `rent`, `associated_token_program`
    - `recipient_ata` - Withdraw only (recipient's token account)
  - **Anchor client note**: For `recipient`, pass `null` for execute mode or recipient pubkey for withdraw mode
  - **Execute mode**: `destination_program` = target program, `recipient` = None, remaining_accounts with CPI accounts
  - **Withdraw mode**: `destination_program` = SystemProgram.programId, `recipient` set, remaining_accounts empty

**Revert Structs** (see `revert.rs`):
- `RevertUniversalTx` - Required accounts for SOL revert (instruction_id=3)
- `RevertUniversalTxToken` - Required accounts for SPL revert (instruction_id=4)

**State Structures** (see `state.rs`):
- `GatewayAccountMeta` - Account metadata (pubkey + is_writable)
- `Config` - Gateway configuration (min/max caps, paused state, etc.)
- `TssPda` - TSS state (nonce, chain_id, tss_eth_address, authority, bump)
- `ExecutedTx` - Replay protection tracker (8-byte discriminator only)

---

## 12. Address Lookup Tables (ALTs) for Transaction Size Optimization

**Building Versioned Transactions:**

**For SOL transaction:**
```typescript
const instruction = await program.methods
  .withdrawAndExecute(/* ... params ... */)
  .accounts(/* ... */)
  .instruction();

// Build versioned tx with Protocol ALT (estimated ~92 bytes saved; actual depends on instruction size)
const tx = await altHelper.buildVersionedTransaction(
  [instruction],
  relayerPublicKey,
  null // mint = null for SOL
);

// Sign and send
tx.sign([relayerKeypair]);
const signature = await connection.sendTransaction(tx);
```

**For SPL transaction:**
```typescript
const usdcMint = new PublicKey('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v');

const instruction = await program.methods
  .withdrawAndExecute(/* ... params ... */)
  .accounts({
    /* ... */
    mint: usdcMint,
    vaultAta: /* ... */,
    ceaAta: /* ... */,
    /* ... */
  })
  .instruction();

// Build versioned tx with Protocol ALT + Token ALT (estimated ~215 bytes saved; actual depends on instruction size)
const tx = await altHelper.buildVersionedTransaction(
  [instruction],
  relayerPublicKey,
  usdcMint // Pass token mint
);

// Sign and send
tx.sign([relayerKeypair]);
const signature = await connection.sendTransaction(tx);
```

**Manual ALT Management (if not using AltHelper):**
```typescript
import { TransactionMessage, VersionedTransaction } from '@solana/web3.js';

// Fetch ALT accounts
const protocolAlt = await connection.getAddressLookupTable(protocolAltAddress);
const tokenAlt = await connection.getAddressLookupTable(tokenAltAddress);
if (!protocolAlt.value) throw new Error("Protocol ALT not found");
// Only required for SPL:
if (tokenAltAddress && !tokenAlt.value) throw new Error("Token ALT not found");

// Build v0 message with ALTs
const { blockhash } = await connection.getLatestBlockhash();
const messageV0 = new TransactionMessage({
  payerKey: relayerPublicKey,
  recentBlockhash: blockhash,
  instructions: [instruction],
}).compileToV0Message([
  protocolAlt.value,  // Always include Protocol ALT
  tokenAlt.value,     // Include Token ALT for SPL transactions
]);

const tx = new VersionedTransaction(messageV0);
```
