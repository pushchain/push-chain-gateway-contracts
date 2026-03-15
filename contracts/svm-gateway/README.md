# Push Chain Solana Gateway

Production-ready Solana program for bidirectional cross-chain bridging between Push Chain (EVM) and Solana with TSS-verified withdrawals.

## Architecture Overview

**Inbound:** Solana → Push Chain (deposits)
**Outbound:** Push Chain → Solana (withdrawals, executions, reverts)

## Program ID

**Devnet:** `DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp`
**Mainnet:** TBD

## Core Functions

### Inbound (Deposits)
- **`send_universal_tx`** - Universal entrypoint for deposits from Solana → Push Chain
  - Routes to GAS or FUNDS handlers based on tx type
  - Supports native SOL and SPL tokens
  - Rate limiting per token via dynamic thresholds
  - Pyth oracle price validation for USD caps

### Outbound (Withdrawals & Executions)
- **`withdraw_and_execute`** - Unified entrypoint for Push Chain → Solana operations
  - **instruction_id = 1:** Withdraw (direct transfer to recipient)
  - **instruction_id = 2:** Execute (CPI to target program with CEA as signer)
  - TSS signature verification (ECDSA secp256k1)
  - CEA (Cross-chain Execution Account) architecture for persistent user identity
  - Optional accounts enforcement (recipient XOR destination_program)

### Revert Functions
- **`revert_universal_tx`** - Revert failed transactions (SOL)
- **`revert_universal_tx_token`** - Revert failed transactions (SPL tokens)

### Admin Functions
- **`initialize`** - Deploy gateway with admin/pauser authorities
- **`pause` / `unpause`** - Emergency stop controls
- **`set_rate_limit`** - Configure per-token rate limits (replaces whitelist)
- **`init_tss`** - Initialize TSS with ETH address, chain ID, nonce

## Key Concepts

### CEA (Cross-chain Execution Account)
- PDA derived from user's EVM address: `[b"push_identity", sender[20]]`
- Persistent identity across all user transactions
- Vault → CEA → Recipient flow ensures recipient sees CEA as sender
- CEA signs CPIs in execute mode (cross-chain program interactions)

### Rate Limiting (Not Whitelist)
- Dynamic threshold per token (configurable via `set_rate_limit`)
- Token supported if `rate_limit_threshold > 0`
- No fixed whitelist - flexible token management
- Separate rate limits for inbound/outbound per token

### TSS Signature Verification
- TSS signs message hash with ECDSA secp256k1
- Nonce-based replay protection
- Message format: `PREFIX | instruction_id | chain_id | nonce | amount | tx_id | universal_tx_id | sender | token | gas_fee | [mode-specific]`
- **Common fields** (same order for both withdraw and execute):
  1. `tx_id` (32 bytes) - matches function parameter order
  2. `universal_tx_id` (32 bytes)
  3. `sender` (20 bytes, EVM address)
  4. `token` (32 bytes, Pubkey)
  5. `gas_fee` (u64 BE)
- **Withdraw-specific**: `recipient` (32 bytes)
- **Execute-specific**: `target_program` (32 bytes), `accounts_buf` (variable), `ix_data_buf` (variable), `rent_fee` (u64 BE)
- Public key recovered from signature, validated against TSS ETH address

## Account Structure (PDAs)

```
config          → [b"config"]                    // Gateway config, authorities, caps
vault_sol       → [b"vault"]                     // SOL vault (also ATA authority)
tss_pda         → [b"tsspda"]                    // TSS state (eth_address, nonce, chain_id)
cea_authority   → [b"push_identity", sender]     // User's CEA (sender = 20-byte EVM address)
executed_tx     → [b"executed_tx", tx_id]        // Replay protection (32-byte tx_id)
rate_limit_config → [b"rate_limit_config"]       // Rate limit global config
token_rate_limit  → [b"rate_limit", mint]        // Per-token rate limit state
```

## CLI Commands

### Token Management
```bash
# Create test token
npm run token:create -- -n "Test Token" -s "TEST" -d "Test token description"

# Mint tokens to address
npm run token:mint -- -m TEST -r <ADDRESS> -a 1000

# Set rate limit (enable token)
npm run token:set-rate-limit -- -m <MINT> -t 1000000000

# List all tokens
npm run token:list
```

### Testing
```bash
# Run all tests
anchor test

# Run specific test suite
TEST_FILE=tests/execute.test.ts anchor test
npm run test:execute
npm run test:withdraw

# Integration test
npx ts-node app/gateway-test.ts
```

### ALT Management
```bash
# Create Protocol ALT (7 accounts for SPL, 4 for SOL)
npx ts-node scripts/create-protocol-alt.ts

# Create Token-Specific ALTs (2 accounts per token)
npx ts-node scripts/create-token-alt.ts

# Extend existing ALT
npx ts-node scripts/extend-alt.ts --alt <ALT_ADDRESS> --accounts <PUBKEY1,PUBKEY2>

# Deactivate ALT (irreversible)
npx ts-node scripts/deactivate-alt.ts --alt <ALT_ADDRESS>
```

## Integration Examples

### Withdraw (Push Chain → Solana)

```typescript
import {
  buildWithdrawAdditionalData,
  signTssMessage,
  TssInstruction,
} from "./tests/helpers/tss";

// 1. Derive PDAs
const [configPda] = PublicKey.findProgramAddressSync([Buffer.from("config")], programId);
const [vaultSol] = PublicKey.findProgramAddressSync([Buffer.from("vault")], programId);
const [tssPda] = PublicKey.findProgramAddressSync([Buffer.from("tsspda")], programId);
const [ceaAuthority] = PublicKey.findProgramAddressSync(
  [Buffer.from("push_identity"), Buffer.from(sender)], // sender = 20-byte EVM address
  programId
);
const [executedTx] = PublicKey.findProgramAddressSync(
  [Buffer.from("executed_tx"), txId], // txId = 32 bytes
  programId
);

// 2. Fetch TSS state
const tssAccount = await program.account.tssPda.fetch(tssPda);
const { nonce, chainId } = tssAccount;

// 3. Build TSS message (withdraw)
const additional = buildWithdrawAdditionalData(
  universalTxId,
  txId,
  Buffer.from(sender),   // 20-byte EVM address
  tokenMint,             // Pubkey::default() for SOL
  recipient,
  BigInt(gasFee)
);

const { signature, recoveryId, messageHash } = await signTssMessage({
  instruction: TssInstruction.Withdraw,
  nonce,
  amount: BigInt(withdrawAmount),
  additional,
  chainId,
});

// 4. Submit withdraw transaction
await program.methods
  .withdrawAndExecute(
    1,                        // instruction_id (withdraw)
    txId,                     // [u8; 32] - tx_id
    Array.from(universalTxId), // [u8; 32] - universal_tx_id
    new anchor.BN(amount),    // u64 - amount
    sender,                   // [u8; 20] - sender (EVM address)
    Buffer.from([]),          // Vec<u8> - writable_flags (empty for withdraw)
    Buffer.from([]),          // Vec<u8> - ix_data (empty for withdraw)
    new anchor.BN(gasFee),    // u64 - gas_fee
    new anchor.BN(0),         // u64 - rent_fee (must be 0 for withdraw)
    signature,                // [u8; 64] - signature
    recoveryId,               // u8 - recovery_id
    messageHash,              // [u8; 32] - message_hash
    nonce,                    // u64 - nonce
  )
  .accounts({
    caller: relayerKeypair.publicKey,
    config: configPda,
    vaultSol,
    ceaAuthority,
    tssPda,
    executedTx,
    systemProgram: SystemProgram.programId,
    destinationProgram: SystemProgram.programId, // Sentinel (not used)
    recipient: recipientPubkey,                  // Target recipient
    // SPL accounts (null for SOL):
    vaultAta: null,
    ceaAta: null,
    mint: null,
    tokenProgram: null,
    rent: null,
    associatedTokenProgram: null,
    recipientAta: null,
  })
  .remainingAccounts([]) // Must be empty for withdraw
  .rpc();
```

### Execute (Push Chain → Solana CPI)

```typescript
import {
  buildExecuteAdditionalData,
  signTssMessage,
  TssInstruction,
} from "./tests/helpers/tss";

// Similar to withdraw, but:
// - instruction_id = 2
// - destination_program = target program pubkey (must be executable)
// - recipient = SystemProgram.programId (sentinel, not used)
// - writable_flags = bitpacked flags for remaining_accounts
// - ix_data = instruction data for target program
// - rent_fee = rent for target program accounts (can be > 0)
// - remaining_accounts = accounts for target program CPI

// Build TSS message (execute)
const additional = buildExecuteAdditionalData(
  universalTxId,
  txId,
  targetProgramId,
  sender,
  accountsForTarget,  // AccountMeta[]
  ixData,
  gasFee,
  rentFee,
  tokenMint  // Pubkey::default() for SOL
);

const { signature, recoveryId, messageHash } = await signTssMessage({
  instruction: 2, // Execute
  nonce,
  amount,
  additional,
  chainId,
});

await program.methods
  .withdrawAndExecute(
    2,                        // instruction_id (execute)
    txId,                     // [u8; 32] - tx_id
    Array.from(universalTxId), // [u8; 32] - universal_tx_id
    new anchor.BN(amount),    // u64 - amount
    sender,                   // [u8; 20] - sender (EVM address)
    writableFlags,            // Vec<u8> - Bitpacked: ceil(accounts/8) bytes
    ixData,                   // Vec<u8> - Target program instruction data
    new anchor.BN(gasFee),    // u64 - gas_fee
    new anchor.BN(rentFee),   // u64 - rent_fee (for target program rent)
    signature,                // [u8; 64] - signature
    recoveryId,               // u8 - recovery_id
    messageHash,              // [u8; 32] - message_hash
    nonce,                    // u64 - nonce
  )
  .accounts({
    caller: relayerKeypair.publicKey,
    config: configPda,
    vaultSol,
    ceaAuthority,
    tssPda,
    executedTx,
    systemProgram: SystemProgram.programId,
    destinationProgram: targetProgramId,  // Target for CPI
    recipient: SystemProgram.programId,   // Sentinel (not used)
    // SPL accounts (null for SOL, required for SPL):
    vaultAta: null,           // or vaultAtaAddress for SPL
    ceaAta: null,             // or ceaAtaAddress for SPL
    mint: null,               // or tokenMint for SPL
    tokenProgram: null,       // or TOKEN_PROGRAM_ID for SPL
    rent: null,               // or SYSVAR_RENT_PUBKEY for SPL
    associatedTokenProgram: null, // or ASSOCIATED_TOKEN_PROGRAM_ID for SPL
    recipientAta: null,       // Must be null for execute mode
  })
  .remainingAccounts(accountsForTargetProgram)
  .rpc();
```

### TSS Helper Functions

The `tests/helpers/tss.ts` file provides utilities for building and signing TSS messages. Both helpers use **consistent ordering** with common fields first:

```typescript
import {
  signTssMessage,
  buildWithdrawAdditionalData,
  buildExecuteAdditionalData,
  TssInstruction,
} from "./tests/helpers/tss";

// For withdraw (instruction_id = 1)
// Returns: [tx_id, universal_tx_id, sender, token, gas_fee, recipient]
const withdrawAdditional = buildWithdrawAdditionalData(
  universalTxId,  // 32 bytes
  txId,           // 32 bytes
  sender,         // 20 bytes (EVM address)
  tokenMint,      // Pubkey (Pubkey::default() for SOL)
  recipient,      // Pubkey
  gasFee          // bigint
);

// For execute (instruction_id = 2)
// Returns: [tx_id, universal_tx_id, sender, token, gas_fee, target_program, accounts_buf, ix_data_buf, rent_fee]
const executeAdditional = buildExecuteAdditionalData(
  universalTxId,
  txId,
  targetProgram,
  sender,
  accountsForTarget,  // GatewayAccountMeta[] = {pubkey, isWritable}[]
  ixData,             // Uint8Array
  gasFee,
  rentFee,
  tokenMint
);

// Sign the message
const { signature, recoveryId, messageHash, nonce } = await signTssMessage({
  instruction: TssInstruction.Withdraw,  // or TssInstruction.Execute
  nonce,
  amount: BigInt(withdrawAmount),
  additional: withdrawAdditional,
  chainId,
});
```

**Note**: Common fields (tx_id, universal_tx_id, sender, token, gas_fee) are in the same order for both modes, making the system easier to maintain and understand.

### Deposit (Solana → Push Chain)

```typescript
const universalTxRequest = {
  recipient: Array.from(Buffer.from(evmRecipient.slice(2), 'hex')), // 20 bytes
  token: tokenMint,          // Pubkey::default() for SOL
  amount: new anchor.BN(amount),
  payload: [],               // Empty for simple transfer
  revertInstruction: {
    fundRecipient: userPubkey,
    revertMsg: Buffer.from("Revert if failed")
  },
  signatureData: Buffer.from([]), // Reserved for future use
};

await program.methods
  .sendUniversalTx(universalTxRequest, nativeAmount) // nativeAmount = SOL to send
  .accounts({
    config: configPda,
    vault: vaultSol,
    user: userKeypair.publicKey,
    userTokenAccount: userAta,      // For SPL only
    gatewayTokenAccount: vaultAta,  // For SPL only
    priceUpdate: pythFeedAddress,   // For USD cap validation
    rateLimitConfig,
    tokenRateLimit,
    tokenProgram: TOKEN_PROGRAM_ID,
    systemProgram: SystemProgram.programId,
  })
  .rpc();
```

## Transaction Size Optimization (ALTs)

### Savings
- **SOL transactions:** 92 bytes (Protocol ALT with 4 accounts)
- **SPL transactions:** 215 bytes (Protocol ALT: 185 bytes + Token ALT: 30 bytes)

### Setup
1. **Create Protocol ALT** (shared by all transactions)
2. **Create Token ALTs** (one per SPL token)
3. **Load configs** in backend:
   ```typescript
   const altHelper = new AltHelper(connection);
   altHelper.loadFromConfigFiles('./alt-config-protocol.json', './alt-config-tokens.json');
   await altHelper.fetchAltAccounts();
   ```
4. **Build v0 transactions:**
   ```typescript
   const tx = await altHelper.buildVersionedTransaction(
     [instruction],
     relayerPubkey,
     mintPubkey // null for SOL
   );
   ```

See [ALT Integration Guide](../../INTEGRATION_GUIDE.md#12-address-lookup-tables-alts-for-transaction-size-optimization) for details.

## Security Features

- **TSS Signature Verification** - ECDSA secp256k1 with ETH address recovery
- **Nonce-Based Replay Protection** - executed_tx PDA prevents double-execution
- **Pause Functionality** - Emergency stop for all user operations
- **Rate Limiting** - Dynamic thresholds per token, configurable by admin
- **USD Caps** - Pyth oracle price validation (min/max caps)
- **Mode Enforcement** - Withdraw/execute modes validated (recipient XOR destination_program)
- **Account Validation** - Ownership, mint, ATA derivation checks
- **CEA Architecture** - Isolated execution context per user

## Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `MessageHashMismatch` | Wrong TSS message construction | Verify field order and endianness (see tss.ts) |
| `NonceMismatch` | Using wrong nonce | Fetch latest nonce from TSS PDA |
| `InvalidAccount` | Account derivation error | Check PDA seeds and ATA derivation |
| `RateLimitExceeded` | Token threshold reached | Wait for rate limit reset or increase threshold |
| `ExecutedTx` | Transaction already executed | tx_id must be unique (check executed_tx PDA) |
| `Paused` | Gateway is paused | Wait for unpause or check pause status |
| `InsufficientBalance` | User/vault low balance | Verify balances (1:1 backing guarantees vault) |
| `InvalidProgram` | Target program not executable | Ensure destination_program.executable == true |

## Development

```bash
# Build
anchor build

# Deploy
anchor deploy

# Test
anchor test

# Generate IDL types
anchor build && cp target/idl/*.json target/idl/*.ts .
```

## Documentation

- **[Integration Guide](../../INTEGRATION_GUIDE.md)** - Complete backend integration reference
- **[CLAUDE.md](../../CLAUDE.md)** - Unified entrypoint architecture reference
- **[Test Files](tests/)** - Comprehensive test examples
- **[Scripts](scripts/)** - ALT management and token utilities

## Project Structure

```
contracts/svm-gateway/
├── programs/
│   └── universal-gateway/
│       └── src/
│           ├── lib.rs                    # Program entrypoint
│           ├── instructions/
│           │   ├── deposit.rs            # send_universal_tx (inbound)
│           │   ├── withdraw_execute.rs   # withdraw_and_execute (outbound)
│           │   ├── revert.rs             # revert functions
│           │   ├── tss.rs                # TSS signature validation
│           │   ├── admin.rs              # Admin functions
│           │   ├── initialize.rs         # Gateway initialization
│           │   └── mod.rs                # Module exports
│           ├── state.rs                  # Account structs
│           ├── errors.rs                 # Error codes
│           └── utils.rs                  # Helper functions
├── tests/                                # Test suites
├── scripts/                              # CLI utilities
├── app/                                  # Integration helpers
└── README.md                             # This file
```

## Status

**Current:** ✅ Unified outbound flow implemented and tested
**Next:** Security audit + mainnet deployment preparation

---

Built for Push Chain by the Push Protocol team.
