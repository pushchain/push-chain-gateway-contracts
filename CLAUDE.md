# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Push Chain Gateway Contracts** - A monorepo containing bidirectional bridge gateway implementations between Push Chain and external blockchain ecosystems:

- **EVM Gateway** (`contracts/evm-gateway/`) - Solidity contracts for Ethereum and EVM-compatible chains
- **SVM Gateway** (`contracts/svm-gateway/`) - Anchor programs for Solana (SVM)

Both implementations provide:
- **Inbound bridging**: External chains → Push Chain (deposit funds/payloads)
- **Outbound bridging**: Push Chain → External chains (withdraw/execute via TSS)
- **Transaction routing**: Automatic TX_TYPE inference based on request structure
- **Rate limiting**: Dual-system (instant vs standard confirmations)
- **Fee abstraction**: Gas payment in native or arbitrary tokens
- **Cross-chain execution**: Payload execution on destination chains

## Quick Start

### EVM Gateway (Foundry)
```bash
cd contracts/evm-gateway

# Build
forge build

# Run all tests
forge test -vv

# Run specific test file
forge test --match-path test/gateway/1_adminActions.t.sol -vv

# Coverage
forge coverage --ir-minimum

# Deploy (requires .env)
forge script script/1_DeployGatewayWithProxy.sol:DeployGatewayWithProxy \
  --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
```

**See `contracts/evm-gateway/CLAUDE.md` for complete EVM-specific guidance.**

### SVM Gateway (Anchor)
```bash
cd contracts/svm-gateway

# Install dependencies
npm install

# Build programs
anchor build

# Run all tests (uses Anchor.toml test script)
anchor test
# or
npm test

# Run specific test file
TEST_FILE=tests/execute.test.ts npm test
# or use convenience scripts:
npm run test:execute
npm run test:withdraw
npm run test:admin
npm run test:rate-limit
npm run test:universal-tx

# Deploy to devnet
anchor deploy --provider.cluster devnet

# Upgrade program (requires upgrade authority keypair)
anchor upgrade target/deploy/universal_gateway.so \
  --program-id <PROGRAM_ID> \
  --provider.wallet ./upgrade-keypair.json
```

**CLI Tools (SVM):**
```bash
cd contracts/svm-gateway

# Token management
npm run token:create      # Create SPL token
npm run token:mint        # Mint tokens
npm run token:whitelist   # Add token to rate limits
npm run token:list        # List whitelisted tokens

# Gateway configuration
npm run config:show                    # Display config
npm run config:tss-init                # Initialize TSS
npm run config:tss-update              # Update TSS address
npm run config:pause                   # Pause gateway
npm run config:unpause                 # Unpause gateway
npm run config:caps-set                # Set USD caps
npm run config:pyth-set-feed           # Set Pyth price feed
npm run config:rate-set-block-usd-cap  # Set block USD cap
npm run config:rate-set-epoch          # Set epoch duration
npm run config:rate-set-token          # Set token rate limit
```

## Architecture

### Shared Concepts (EVM + SVM)

Both gateways implement the same high-level architecture with platform-specific adaptations:

**1. Transaction Type System (TX_TYPE)**

Transaction types are **automatically inferred** - users never specify TX_TYPE explicitly.

| TX_TYPE | Route | Description | Rate Limiting |
|---------|-------|-------------|---------------|
| `GAS` | Instant | Gas-only funding for UEA | USD caps (min/max) + block cap |
| `GAS_AND_PAYLOAD` | Instant | Gas + payload execution | USD caps (min/max) + block cap |
| `FUNDS` | Standard | High-value transfer only | Per-token epoch limits |
| `FUNDS_AND_PAYLOAD` | Standard | High-value + payload | Per-token epoch limits |

**TX_TYPE Inference Rules:**

**EVM (Inbound):**
```
hasPayload = payload.length > 0
hasFunds = bridgeAmount > 0
fundsIsNative = bridgeToken == address(0)
hasNativeValue = msg.value > 0

if !hasFunds:
    if hasPayload: return GAS_AND_PAYLOAD
    if hasNativeValue: return GAS
    revert InvalidInput

if hasPayload:
    if fundsIsNative:
        require msg.value >= bridgeAmount
    return FUNDS_AND_PAYLOAD

// FUNDS (no payload)
if fundsIsNative:
    require msg.value == bridgeAmount
else:
    require msg.value == 0
return FUNDS
```

**SVM (Inbound):**
```
hasPayload = req.payload.len() > 0
hasFunds = req.amount > 0
fundsIsNative = req.token == Pubkey::default()
hasNativeValue = native_amount > 0

if !hasFunds:
    if hasPayload: return GAS_AND_PAYLOAD
    if hasNativeValue: return GAS
    revert InvalidInput

if hasPayload:
    if fundsIsNative:
        require native_amount >= req.amount
    return FUNDS_AND_PAYLOAD

// FUNDS (no payload)
if fundsIsNative:
    require native_amount == req.amount
else:
    require !hasNativeValue
return FUNDS
```

**Outbound (Push Chain → External):**
```
hasPayload = payload.length > 0 (EVM) or req.payload.len() > 0 (SVM)
hasFunds = amount > 0

if !hasPayload && hasFunds: return FUNDS
if hasPayload && hasFunds: return FUNDS_AND_PAYLOAD
if hasPayload && !hasFunds: return GAS_AND_PAYLOAD
if !hasPayload && !hasFunds: revert InvalidInput (empty tx)
```

**2. Dual Rate Limiting**

**Instant Route** (GAS, GAS_AND_PAYLOAD):
- Per-transaction USD caps: `MIN_CAP` to `MAX_CAP`
- Per-block USD budget: `BLOCK_USD_CAP`
- Uses price oracles (Chainlink for EVM, Pyth for SVM)

**Standard Route** (FUNDS, FUNDS_AND_PAYLOAD):
- Per-token epoch-based limits
- Epoch duration: configurable (e.g., 86400 sec = 24 hours)
- Usage resets on epoch rollover
- Token threshold in natural token units

**3. Cross-Chain Execution Flow**

**Inbound (External → Push Chain):**
```
1. User deposits via send_universal_tx / sendUniversalTx
2. Gateway validates and applies rate limits
3. Funds locked in Vault
4. UniversalTx event emitted
5. Push Chain relayers detect event
6. User's UEA credited on Push Chain
```

**Outbound (Push Chain → External):**
```
1. User initiates on Push Chain
2. TSS validates and signs (ECDSA secp256k1)
3. Relayer submits to external chain
4. Gateway validates TSS signature
5. Funds released: Vault → CEA → Target
6. UniversalTxExecuted event emitted
7. Push Chain confirms
```

### EVM-Specific Architecture

**Core Contracts:**
- `UniversalGateway.sol` - Main gateway (current version)
- `UniversalGatewayV0.sol` - Legacy version
- `UniversalGatewayPC.sol` - Push Chain side (outbound)
- `Vault.sol` / `VaultPC.sol` - Fund management

**Tech Stack:**
- Foundry (Solidity 0.8.26, via_ir=true)
- OpenZeppelin upgradeable contracts
- Chainlink price feeds
- Uniswap v3 for token swaps

**Key Patterns:**
- Upgradeable proxy pattern (TransparentUpgradeableProxy)
- Role-based access control (DEFAULT_ADMIN_ROLE, PAUSER_ROLE, TSS_ROLE)
- Reentrancy guards on all deposit/withdraw paths
- Pausable for emergency stops

### SVM-Specific Architecture

**Core Programs:**
- `universal-gateway` - Main gateway program (Anchor)
- `test-counter` - Test program for CPI execution testing

**Tech Stack:**
- Anchor Framework 0.31.1
- Pyth price feeds (via Hermes client)
- SPL Token Program

**Key Patterns:**
- PDA-based architecture (no external signers for protocol operations)
- TSS validation via ECDSA secp256k1 signature recovery
- CEA (Chain Executor Account) - per-user PDA for signing authority
- Replay protection via ExecutedTx PDAs (account existence check)

**PDAs and Seeds:**
```rust
CONFIG_SEED: b"config"           // Global config
VAULT_SEED: b"vault"             // SOL vault (no data, just authority)
TSS_SEED: b"tsspda"              // TSS state (address, nonce, chain_id)
RATE_LIMIT_CONFIG_SEED: b"rate_limit_config"  // Rate limit settings
RATE_LIMIT_SEED: b"rate_limit"   // Per-token rate limit state
EXECUTED_TX_SEED: b"executed_tx" // Replay protection
CEA_SEED: b"push_identity"       // Per-user signing authority
```

**Account Structure:**
- `Config` - Admin, TSS, pauser addresses; USD caps; Pyth oracle config
- `TssPda` - TSS Ethereum address, chain ID, nonce (replay protection)
- `RateLimitConfig` - Block USD cap, epoch duration
- `TokenRateLimit` - Per-token epoch usage tracking
- `ExecutedTx` - 8-byte discriminator only (existence = executed)

## Outbound Transaction Handling

### Unified Entrypoint Pattern

Both EVM and SVM use unified outbound entrypoints with instruction_id routing:

**EVM:** `withdrawFunds(instruction_id, ...)`
**SVM:** `withdraw_and_execute(instruction_id, ...)`

**Instruction IDs:**
- `1` = Withdraw (Vault → CEA → Recipient)
- `2` = Execute (Vault → CEA → Target Program via CPI)
- `3` = Revert SOL
- `4` = Revert SPL

### TSS Signature Validation

Both implementations validate TSS signatures using ECDSA secp256k1:

**Message Format:**
```
PREFIX = "PUSH_CHAIN_SVM" (SVM) or "PUSH_CHAIN_EVM" (EVM)
message = keccak256(PREFIX || instruction_id || chain_id || nonce || [additional_data])
```

**Additional Data Array Pattern (SVM):**

Common fields come first (matching function parameter order):
```rust
// Common (both modes): [tx_id, universal_tx_id, sender, token, gas_fee]
// Withdraw adds: [recipient]
// Execute adds: [target_program, accounts_buf, ix_data_buf, rent_fee]
```

**Rationale:** Consistent ordering reduces errors, matches function signatures.

### Execute Mode (instruction_id=2)

**SVM Flow:**
```
1. Vault → CEA transfer (amount + rent_fee)
2. Vault → Relayer transfer (gas_fee - rent_fee)
3. Build CPI instruction with CEA as signer
4. invoke_signed(cpi_ix, &[cea_seeds])
```

**Key Components:**
- `writable_flags`: Bitmap encoding which accounts are writable (1 byte per 8 accounts)
- `ix_data`: Target program instruction data
- `rent_fee`: Rent for CEA to handle target program account creation
- `gas_fee`: Relayer reimbursement (includes executed_tx rent + CEA ATA rent if needed)

**CEA as Signer:**
- CEA PDA derives from: `[b"push_identity", sender[20]]`
- Uses `invoke_signed` with CEA seeds for CPI
- Allows target programs to receive signed transactions from consistent identity

## Development Patterns

### Testing Conventions

**EVM:**
- Tests inherit from `BaseTest` (provides setup, mocks, helpers)
- Numbered test files (1_adminActions.t.sol, 2_deposits.t.sol, etc.)
- Fork tests for mainnet integration (e.g., 3_sendUniversalTx_token_fork.t.sol)
- Use `forge test --match-test testFunctionName -vv` for specific tests

**SVM:**
- Tests use Mocha + Chai
- Helper modules in `tests/helpers/`:
  - `tss.ts` - TSS signing and validation helpers
  - `test-setup.ts` - Gateway initialization
  - `token-mint.ts` - SPL token creation
  - `price-feed.ts` - Pyth mock setup
- Shared state in `tests/shared-state.ts` for cross-test data
- Test organization:
  - `execute.test.ts` - CPI execution (163 KB, comprehensive)
  - `withdraw.test.ts` - Withdrawal flows
  - `universal-tx.test.ts` - Inbound deposits
  - `rate-limit.test.ts` - Rate limiting
  - `admin.test.ts` - Admin operations

### TSS Testing Helpers (SVM)

**Building TSS Signatures:**
```typescript
import { signTssMessage, buildExecuteAdditionalData, TssInstruction } from './helpers/tss';

// For withdraw (instruction_id=1)
const withdrawAdditionalData = [
  tx_id,
  universal_tx_id,
  sender,
  token.toBuffer(),
  gas_fee_buffer,
  recipient.toBuffer(),
];

// For execute (instruction_id=2)
const executeAdditionalData = buildExecuteAdditionalData({
  tx_id,
  universal_tx_id,
  sender,
  token,
  gas_fee,
  target_program,
  accounts_buf,
  ix_data_buf,
  rent_fee,
});

const tssSignature = await signTssMessage({
  instruction: TssInstruction.Execute,
  nonce: tss_nonce,
  additional: executeAdditionalData,
});
```

### Fee Calculation Patterns (SVM)

**SOL Execute:**
```typescript
const { gasFee, rentFee } = await calculateSolExecuteFees(
  connection,
  BASE_RENT_FEE  // rent for target program
);
// gasFee = rentFee + executed_tx_rent + compute_buffer
```

**SPL Execute:**
```typescript
const { gasFee, rentFee } = await calculateSplExecuteFees(
  connection,
  ceaAta,
  BASE_RENT_FEE
);
// gasFee = rentFee + executed_tx_rent + cea_ata_rent (if created) + compute_buffer
```

**Components:**
- `rent_fee`: Transferred to CEA for target program rent needs
- `executed_tx_rent`: Gateway PDA creation (reimbursed from gas_fee)
- `cea_ata_rent`: CEA ATA creation if needed (reimbursed from gas_fee)
- `compute_buffer`: Transaction fees and compute units (~100k lamports)

### Instruction Data Encoding (SVM)

**Execute Payloads:**
```typescript
import { encodeExecutePayload, instructionToPayloadFields, accountsToWritableFlags } from '../app/execute-payload';

// Build instruction
const targetIx = await program.methods
  .increment()
  .accounts({ counter: counterPda })
  .instruction();

// Extract fields
const { accounts_buf, ix_data_buf, writable_flags } = instructionToPayloadFields(targetIx);

// Or use all-in-one helper
const payload = encodeExecutePayload(targetIx);
```

### Common Development Tasks

**Adding a new token to SVM gateway:**
```bash
# 1. Create token (if needed)
npm run token:create

# 2. Whitelist with rate limit
npm run token:whitelist
# Prompts for: mint address, threshold (natural units)

# 3. Verify
npm run token:list
```

**Updating TSS configuration:**
```bash
# EVM
cast send $GATEWAY_ADDR "setTSS(address)" $NEW_TSS_ADDR \
  --rpc-url $RPC_URL --private-key $ADMIN_KEY

# SVM
npm run config:tss-update
# Prompts for: TSS ETH address (hex), chain ID
```

**Pausing the gateway:**
```bash
# EVM
cast send $GATEWAY_ADDR "pause()" \
  --rpc-url $RPC_URL --private-key $PAUSER_KEY

# SVM
npm run config:pause
```

## Key Files Reference

### EVM
- `src/UniversalGateway.sol` - Main gateway implementation
- `src/UniversalGatewayPC.sol` - Push Chain side (outbound)
- `src/libraries/Types.sol` - Shared types and enums
- `src/interfaces/IUniversalGateway.sol` - Public API
- `test/BaseTest.t.sol` - Test base class with setup
- `script/DeployCommands.md` - Deployment examples

### SVM
- `programs/universal-gateway/src/lib.rs` - Program entrypoints
- `programs/universal-gateway/src/instructions/deposit.rs` - Inbound deposits
- `programs/universal-gateway/src/instructions/execute.rs` - Outbound execution
- `programs/universal-gateway/src/instructions/tss.rs` - TSS validation
- `programs/universal-gateway/src/state.rs` - Account structures and PDAs
- `tests/helpers/tss.ts` - TSS signing utilities
- `app/execute-payload.ts` - Payload encoding helpers
- `app/config-cli.ts` - Gateway configuration CLI
- `app/token-cli.ts` - Token management CLI
- `docs/ARCHITECTURE.md` - System architecture
- `docs/FLOWS/2-WITHDRAW-EXECUTE.md` - Outbound flow details
- `docs/SECURITY/TSS-VALIDATION.md` - TSS security model

## Documentation

**EVM:** `contracts/evm-gateway/CLAUDE.md` - Comprehensive EVM-specific guidance
**SVM:** `contracts/svm-gateway/docs/` - Architecture, flows, security, and reference docs
**Root:** This file - Cross-cutting patterns and monorepo navigation

## Security Considerations

**Both Implementations:**
- TSS signatures are the ONLY authorization for outbound transactions
- Replay protection via nonces (EVM) or ExecutedTx PDAs (SVM)
- Pausable for emergency stops
- Rate limiting protects both instant and standard routes
- Oracle staleness checks (Chainlink for EVM, Pyth for SVM)

**EVM-Specific:**
- Reentrancy guards on all deposit/withdraw paths
- Role-based access control (DEFAULT_ADMIN_ROLE, PAUSER_ROLE, TSS_ROLE)
- Upgradeable via proxy pattern (storage layout compatibility required)
- Uniswap v3 slippage protection via `amountOutMinETH`

**SVM-Specific:**
- No external signers for protocol operations (all PDA-based)
- CEA provides persistent signing authority per user
- ExecutedTx account existence prevents replay
- SPL token account ownership validation
- CPI security: Only CEA can sign for user's identity

## Build Issues & Solutions

### SVM Known Issues

**1. Associated Token Account Dependency:**
- **Issue:** `spl-associated-token-account` as direct dependency causes `#[global_allocator]` conflict
- **Solution:** Use `anchor_spl::associated_token::spl_associated_token_account` re-export instead
- **Config:** `anchor-spl` needs `features = ["associated_token"]` in Cargo.toml

**2. Rent Sysvar Import:**
- **Issue:** `rent::ID` doesn't resolve
- **Solution:** Use `anchor_lang::solana_program::sysvar::rent as rent_sysvar` then `rent_sysvar::ID`

**3. Manual ATA Creation:**
- **Issue:** `init_if_needed` incompatible with `Option<Account>` pattern
- **Solution:** Use manual CPI via `spl_associated_token_account::instruction::create_associated_token_account`

## Version Information

- **EVM:** Solidity 0.8.26, Foundry
- **SVM:** Anchor 0.31.1, Solana 1.18+
- **Node:** 20+ (for SVM TypeScript tests and CLIs)
- **Rust:** 1.75+ (for Anchor programs)
