# System Architecture

**Gateway Version:** 0.1.0
**Chain:** Solana (SVM)
**Purpose:** Bidirectional bridge between Solana and Push Chain

---

## 🏗️ High-Level Design

```
┌───────────────────────────────────────────────────────────────┐
│                        SOLANA SIDE                             │
├───────────────────────────────────────────────────────────────┤
│                                                                │
│  ┌─────────────┐          ┌──────────────┐                   │
│  │   Users     │──────────│   Gateway    │                   │
│  │  (Wallets)  │ Deposit  │   Program    │                   │
│  └─────────────┘          └──────┬───────┘                   │
│                                   │                            │
│                          ┌────────┴────────┐                  │
│                          │                 │                  │
│                    ┌─────▼─────┐    ┌─────▼─────┐            │
│                    │   Vault   │    │    CEA    │            │
│                    │(SOL+SPL)  │    │   (PDA)   │            │
│                    └───────────┘    └─────┬─────┘            │
│                                            │                   │
│                                     ┌──────▼──────┐           │
│                                     │   Target    │           │
│                                     │  Programs   │           │
│                                     └─────────────┘           │
└───────────────────────────────────────────────────────────────┘
                            │
                ┌───────────┴───────────┐
                │    Cross-Chain       │
                │   Event Monitoring   │
                └───────────┬───────────┘
                            │
┌───────────────────────────────────────────────────────────────┐
│                      PUSH CHAIN SIDE                           │
├───────────────────────────────────────────────────────────────┤
│                                                                │
│  ┌─────────────┐          ┌──────────────┐                   │
│  │     TSS     │──────────│   Relayers   │                   │
│  │ (Threshold) │ Sign     │              │                   │
│  └─────────────┘          └──────────────┘                   │
│                                                                │
│  ┌─────────────────────────────────────────────────┐         │
│  │           Universal Execution Account           │         │
│  │  (UEA - User's account on Push Chain)           │         │
│  └─────────────────────────────────────────────────┘         │
└───────────────────────────────────────────────────────────────┘
```

---

## 🔄 Transaction Flows

### Inbound (Solana → Push Chain)

```
1. User deposits SOL/SPL
2. Gateway validates + applies rate limits
3. Funds locked in Vault
4. UniversalTx event emitted
5. Push Chain relayers detect event
6. User's UEA credited on Push Chain
```

### Outbound (Push Chain → Solana)

```
1. User initiates on Push Chain
2. TSS validates and signs
3. Relayer submits to Solana
4. Gateway validates TSS signature
5. Funds released: Vault → CEA → Target
6. UniversalTxExecuted event emitted
7. Push Chain confirms
```

---

## 🏛️ Core Components

### 1. Vault (Fund Custody)
- **Type:** PDA with no data
- **Purpose:** Holds all deposited SOL
- **SPL Tokens:** Separate ATAs per token
- **Control:** Only gateway can sign transfers

### 2. CEA (Chain Executor Account)
- **Type:** Per-user PDA
- **Purpose:** Persistent identity + signing authority
- **Derivation:** `[b"push_identity", sender[20]]`
- **Role:** Signs for target programs via invoke_signed

### 3. Config (System Parameters)
- **Type:** Global PDA
- **Contains:** Admin, caps, oracle settings, pause state
- **Access:** Read-only for users, mutable for admin

### 4. TSS PDA (Authorization State)
- **Type:** Global PDA (`[b"tsspda_v2"]`)
- **Contains:** TSS address, chain ID
- **Purpose:** ECDSA signature verification

### 5. Rate Limit Accounts
- **RateLimitConfig:** Global block/epoch settings
- **TokenRateLimit:** Per-token epoch tracking
- **Purpose:** DoS protection, economic security

### 6. ExecutedTx (Replay Protection)
- **Type:** Per-transaction PDA
- **Contains:** Only discriminator (8 bytes)
- **Purpose:** Account existence = transaction executed

---

## 🎯 Instruction Categories

### User Instructions (Inbound)
- `send_universal_tx` - Deposit with routing

### TSS Instructions (Outbound)
- `withdraw_and_execute` - Unified outbound (withdraw or execute)
- `revert_universal_tx` - Revert SOL
- `revert_universal_tx_token` - Revert SPL

### Admin Instructions
- `initialize` - One-time setup
- `pause` / `unpause` - Emergency controls
- `set_caps_usd` - Configure USD caps
- `set_pyth_price_feed` - Update oracle
- `set_block_usd_cap` - Rate limit config
- `update_epoch_duration` - Rate limit config
- `set_token_rate_limit` - Token whitelist + limits

### TSS Management
- `init_tss` - Initialize TSS state
- `update_tss` - Update TSS address

### View Functions
- `get_sol_price` - Query current SOL/USD price

---

## 🔐 Security Layers

### Layer 1: Access Control
- Admin-only for configuration
- TSS-only for outbound operations
- User-initiated for deposits

### Layer 2: Rate Limiting
- Block-based USD cap (per slot)
- Token-based epoch limits
- Prevents DoS and economic attacks

### Layer 3: Validation
- TSS ECDSA signature verification
- Per-tx replay protection via `ExecutedTx` PDA (seeded by `tx_id`)
- Account ownership validation
- Amount/balance checks

### Layer 4: Isolation
- CEA per-user isolation
- Vault-CEA-Target separation
- Target program cannot access vault directly

---

## 📊 Data Flow

### Deposit (Native SOL)
```
User Wallet [100 SOL]
    │
    ├─ Gas validation (USD caps, rate limits)
    ├─ Transfer: User → Vault [100 SOL]
    └─ Emit: UniversalTx event
         └─ Relayed to Push Chain
              └─ UEA credited
```

### Withdraw (Native SOL)
```
TSS signs withdrawal [50 SOL, tx_id=0xABC]
    │
    ├─ Validate signature (ECDSA)
    ├─ Create ExecutedTx PDA for tx_id (replay protection)
    ├─ Transfer: Vault → CEA [50 SOL]
    ├─ Transfer: CEA → Recipient [50 SOL]
    └─ Emit: UniversalTxExecuted event
```

### Execute (Program Call)
```
TSS signs execute [amount=10, target=DeFi_Program]
    │
    ├─ Validate signature
    ├─ Transfer: Vault → CEA [10 SOL]
    ├─ CEA invokes target program (invoke_signed)
    │    └─ Target sees CEA as signer
    ├─ Program executes logic
    └─ Emit: UniversalTxExecuted event
```

---

## 🎨 Design Patterns

### 1. Unified Entrypoint (Withdraw/Execute)
**Pattern:** Single function with mode parameter
**Benefit:** Code reuse, consistent TSS validation
**Trade-off:** More complex than separate functions

### 2. PDA-Based Authority
**Pattern:** Use PDAs as signers via invoke_signed
**Benefit:** No private keys, deterministic, secure
**Trade-off:** More compute for derivation

### 3. Optional Account Pattern
**Pattern:** `Option<Account<'info, T>>` for SPL accounts
**Benefit:** Single instruction for SOL/SPL
**Trade-off:** Runtime validation complexity

### 4. Event-Driven Architecture
**Pattern:** Emit events for cross-chain coordination
**Benefit:** Decoupled, observable, replay-safe
**Trade-off:** Depends on indexer reliability

### 5. Rate Limit Separation
**Pattern:** Separate PDA for rate limit config
**Benefit:** Backward compatible, pay-for-what-you-need
**Trade-off:** Extra account in transactions

---

## 🔧 Technical Decisions

### Why Anchor?
- Type safety
- Account validation
- PDA derivation helpers
- Event emission

### Why ECDSA secp256k1?
- Ethereum compatibility
- TSS can use same key across chains
- Standard libraries available

### Why Keccak256?
- Ethereum compatibility
- Consistent with EVM gateway
- Solana syscall available

### Why Per-User CEA?
- Persistent identity
- Isolated blast radius
- Program compatibility (expects user signer)

### Why Unified `withdraw_and_execute`?
- Code reuse (TSS validation, transfers)
- Smaller program size
- Single audit surface

---

## 📏 Constraints & Limits

| Resource | Limit | Rationale |
|----------|-------|-----------|
| **Gas deposit USD** | Configurable (set via set_caps_usd) | Fee abstraction cap (not fixed) |
| **Chain ID length** | 64 bytes | Cluster pubkey max |
| **tx_id uniqueness** | Global | Replay protection |
| **Block USD cap** | Configurable | DoS protection |
| **Token epoch limit** | Per-token | Economic security |

---

## 🚀 Performance Characteristics

| Operation | Accounts | Compute Units (est.) |
|-----------|----------|----------------------|
| **Deposit (SOL)** | 6-8 | ~50,000 CU |
| **Deposit (SPL)** | 8-10 | ~70,000 CU |
| **Withdraw (SOL)** | 8-10 | ~80,000 CU |
| **Execute (SOL)** | 10+ | ~100,000+ CU (depends on target) |
| **Revert** | 8-10 | ~80,000 CU |

**Note:** Actual CU depends on:
- Number of remaining_accounts (execute mode)
- Target program complexity
- ATA creation needs

---

## 🔮 Future Considerations

### Potential Enhancements
1. Multi-token execute (transfer multiple tokens in one tx)
2. Batch withdrawals (multiple recipients)
3. Scheduled execution (time-locked)
4. Delegated execution (CEA can delegate to sub-accounts)

### Upgrade Path
- Program is NOT upgradeable by default
- Admin can deploy new version
- Users migrate funds to new version
- Old version can be frozen/deprecated

---

**Last Updated:** 2026-02-23
