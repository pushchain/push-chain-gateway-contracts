# DEPOSIT Flow (Inbound)

**Function:** `send_universal_tx`
**Direction:** User → Vault (Solana → Push Chain)
**Authorization:** User signature (standard Solana transaction)

---

## 📋 Overview

The deposit flow allows users to bridge assets from Solana to Push Chain. It supports:
- **Gas-only deposits** - Fund UEA gas balance on Push Chain
- **Funds-only deposits** - Bridge SOL or SPL tokens
- **Combined deposits** - Batch gas + funds in single transaction

---

## 🎯 Entry Point

```rust
pub fn send_universal_tx(
    ctx: Context<SendUniversalTx>,
    req: UniversalTxRequest,
    native_amount: u64,
) -> Result<()>
```

**Parameters:**
- `req: UniversalTxRequest` - Bridge request details
- `native_amount: u64` - Native SOL sent (mirrors EVM `msg.value`)

---

## 📊 Transaction Type Routing

```
┌────────────────────────────────────────────────────────────┐
│                    fetchTxType()                            │
│  Derives tx_type from req + native_amount                  │
│  Inputs: has_payload, has_funds, funds_is_native,          │
│          has_native_value                                   │
└──────────────┬─────────────────────────────────────────────┘
               │
               ▼
       ┌───────────────────┐
       │ has_funds?        │
       │ (req.amount > 0)  │
       └────┬──────────┬───┘
            │          │
         NO │          │ YES
            │          │
            ▼          ▼
    ┌──────────────┐  ┌────────────────────┐
    │ has_payload? │  │  has_payload?      │
    └──┬────────┬──┘  └──┬──────────────┬──┘
       │        │        │              │
    NO │        │ YES NO │              │ YES
       │        │        │              │
       ▼        ▼        ▼              ▼
    ┌─────┐ ┌──────────┐ ┌───────┐  ┌────────────────┐
    │ GAS │ │GAS_AND   │ │ FUNDS │  │ FUNDS_AND      │
    │     │ │_PAYLOAD  │ │       │  │ _PAYLOAD       │
    └──┬──┘ └────┬─────┘ └───┬───┘  └────┬───────────┘
       │         │            │           │
       │         │            │           │
       ▼         ▼            ▼           ▼
  Require:   (no check   Validate:   Validate:
  native_amt  on native  - SOL:      - SOL:
  > 0         _amount)    native=     native>=
  (line 71)              req.amt     req.amt
                         - SPL:      (line 77)
                          native=0
                         (lines 84-87)
```

### TxType Definitions

| Type | req.amount | req.payload | req.token | native_amount | Use Case |
|------|------------|-------------|-----------|---------------|----------|
| `Gas` | 0 | empty | any | > 0 | Pure gas funding |
| `GasAndPayload` | 0 | non-empty | any | >= 0 | Gas + execution |
| `Funds` | > 0 | empty | Pubkey::default() | == req.amount (EXACT) | SOL bridge only |
| `Funds` | > 0 | empty | SPL mint | == 0 (MUST BE ZERO) | SPL bridge only |
| `FundsAndPayload` | > 0 | non-empty | Pubkey::default() | >= req.amount | SOL bridge + exec |
| `FundsAndPayload` | > 0 | non-empty | SPL mint | any (0 or >0) | SPL bridge + exec |

---

## 🔄 Flow Diagram

### Gas Route (Instant)
```
User
  │
  ├─ Check paused (Config)
  │
  ├─ Validate balance (user.lamports >= native_amount)
  │
  ├─ Derive TxType (Gas or GasAndPayload)
  │
  ├─ If gas_amount == 0:
  │    └─ Emit event only (user already has UEA with gas)
  │       └─ RETURN
  │
  ├─ USD Cap Validation:
  │    ├─ Get SOL price from Pyth oracle
  │    ├─ Convert lamports → USD (8 decimals)
  │    ├─ Check: min_cap <= USD <= max_cap
  │    └─ Error if out of range
  │
  ├─ Block USD Cap (Rate Limiting):
  │    ├─ Check current slot != last_slot?
  │    │    └─ YES: Reset consumed_usd_in_block = 0
  │    ├─ Check: consumed + current <= block_usd_cap
  │    └─ Update: consumed_usd_in_block += current
  │
  ├─ Transfer: User → Vault (native_amount)
  │
  └─ Emit: UniversalTx event
       └─ recipient: [0u8; 20] (→ UEA on Push Chain)
```

### Funds Route (Standard Bridge)
```
User
  │
  ├─ Check paused (Config)
  │
  ├─ Derive TxType (Funds or FundsAndPayload)
  │
  ├─ Validate: req.amount > 0
  │
  ├─ Token-specific rate limit:
  │    ├─ Check: limit_threshold > 0 (token supported?)
  │    ├─ Calculate current epoch (timestamp / epoch_duration)
  │    ├─ Reset if new epoch
  │    ├─ Check: epoch_used + amount <= limit_threshold
  │    └─ Update: epoch_used += amount
  │
  ├─ If req.token == Pubkey::default() (Native SOL):
  │    ├─ Validate: native_amount == req.amount
  │    └─ Transfer: User → Vault (SOL)
  │
  ├─ If req.token != Pubkey::default() (SPL Token):
  │    ├─ Validate: native_amount == 0
  │    ├─ Validate vault ATA:
  │    │    ├─ Parse ATA data
  │    │    ├─ Check: owner == vault
  │    │    └─ Check: mint == req.token
  │    └─ Transfer: User ATA → Vault ATA (SPL)
  │
  └─ Emit: UniversalTx event
       └─ recipient: req.recipient (explicit destination)
```

### Batched Route (Gas + Funds)
```
User
  │
  ├─ TxType = FundsAndPayload
  │
  ├─ If req.token == Pubkey::default() (Native SOL bridge):
  │    ├─ Validate: native_amount >= req.amount
  │    ├─ Split: gas_amount = native_amount - req.amount
  │    ├─ If gas_amount > 0:
  │    │    └─ Call send_tx_with_gas_route(gas_amount)
  │    └─ Continue with funds bridge for req.amount
  │
  ├─ If req.token != Pubkey::default() (SPL bridge):
  │    ├─ If native_amount > 0:
  │    │    └─ Call send_tx_with_gas_route(native_amount)
  │    └─ Continue with SPL token bridge for req.amount
  │
  └─ Emit: UniversalTx event (funds portion only)
```

---

## 🔒 Security Checks

### 1. Pause State
```rust
require!(!config.paused, GatewayError::Paused);
```

### 2. Balance Validation
```rust
require!(
    ctx.accounts.user.lamports() >= native_amount,
    GatewayError::InsufficientBalance
);
```

### 3. USD Cap Validation (Gas Route)
```rust
// Get price from Pyth oracle
let price_data = calculate_sol_price(&price_update)?;

// Convert to USD (8 decimals)
let usd_amount = calculate_usd_amount(lamports, &price_data)?;

// Check range
require!(usd_amount >= min_cap_usd, GatewayError::BelowMinCap);
require!(usd_amount <= max_cap_usd, GatewayError::AboveMaxCap);
```

### 4. Block USD Cap (Rate Limiting)
```rust
// Reset if new slot
if current_slot != last_slot {
    consumed_usd_in_block = 0;
    last_slot = current_slot;
}

// Check limit
require!(
    consumed_usd_in_block + usd_amount <= block_usd_cap,
    GatewayError::BlockUsdCapExceeded
);

// Update
consumed_usd_in_block += usd_amount;
```

### 5. Token Support Check
```rust
// Check if token is whitelisted
require!(
    token_rate_limit.limit_threshold > 0,
    GatewayError::NotSupported
);
```

### 6. Epoch-based Rate Limit
```rust
let current_epoch = timestamp / epoch_duration;

// Reset if new epoch
if current_epoch > last_epoch {
    epoch_used = 0;
    last_epoch = current_epoch;
}

// Check limit
require!(
    epoch_used + amount <= limit_threshold,
    GatewayError::RateLimitExceeded
);

// Update
epoch_used += amount;
```

### 7. SPL Token Validation
```rust
// Validate vault ATA ownership and mint
let parsed = SplAccount::unpack(&vault_ata_data)?;
require!(parsed.owner == vault.key(), GatewayError::InvalidOwner);
require!(parsed.mint == req.token, GatewayError::InvalidMint);
```

### 8. Revert Recipient Validation
```rust
require!(
    *revert_recipient != [0u8; 20],
    GatewayError::InvalidRecipient
);
```

---

## 📤 Events Emitted

### UniversalTx Event
```rust
#[event]
pub struct UniversalTx {
    pub sender: Pubkey,              // User who initiated
    pub recipient: [u8; 20],         // Destination on Push Chain
    pub token: Pubkey,               // Token (default = SOL)
    pub amount: u64,                 // Bridge amount
    pub payload: Vec<u8>,            // Execution payload
    pub revert_recipient: [u8; 20],  // Address to receive funds if tx is reverted
    pub tx_type: TxType,             // Gas/Funds/GasAndPayload/FundsAndPayload
    pub signature_data: Vec<u8>,     // User signature data
    pub from_cea: bool,              // true = emitted from CEA withdrawal
}
```

**When Emitted:**
- Gas route: After SOL transfer to vault
- Funds route: After SOL/SPL transfer to vault
- Batched route: Emitted twice (gas event + funds event)

---

## 💰 State Changes

### Vault Balance
- **Gas route:** `vault.lamports += native_amount`
- **Funds (SOL):** `vault.lamports += req.amount`
- **Funds (SPL):** `vault_ata.amount += req.amount`

### Rate Limit Tracking
- **Block cap:** `rate_limit_config.consumed_usd_in_block += usd_amount`
- **Token limit:** `token_rate_limit.epoch_usage.used += req.amount`

### User Balance
- **SOL:** `user.lamports -= native_amount`
- **SPL:** `user_ata.amount -= req.amount`

---

## ⚠️ Edge Cases

### 1. Payload-only execution (gas_amount == 0)
**Scenario:** User already has UEA with gas, just wants to execute payload
```rust
if gas_amount == 0 {
    // Emit event only, no transfer
    emit!(UniversalTx { amount: 0, ... });
    return Ok(());
}
```

### 2. Batched deposits (native SOL bridge + gas)
**Scenario:** User wants to bridge 5 SOL and fund 0.1 SOL gas
```rust
native_amount = 5.1 SOL
req.amount = 5 SOL
req.token = Pubkey::default()

// Split:
gas_amount = 0.1 SOL → send_tx_with_gas_route()
funds_amount = 5 SOL → send_tx_with_funds_route()
```

### 3. SPL bridge with gas batching
**Scenario:** User wants to bridge 100 USDC and fund 0.1 SOL gas
```rust
native_amount = 0.1 SOL
req.amount = 100 USDC
req.token = USDC_MINT

// Process:
1. send_tx_with_gas_route(0.1 SOL)
2. Transfer 100 USDC from user_ata → vault_ata
```

### 4. Rate limit exactly at cap
```rust
// If consumed == cap, next tx fails
// If consumed + amount == cap, tx succeeds but cap is hit
```

### 5. Epoch boundary
```rust
// At epoch transition (timestamp crosses epoch_duration boundary):
// - Previous epoch usage is discarded
// - New epoch starts with used = 0
```

---

## 🐛 Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `Paused` | Contract is paused | Wait for unpause or contact admin |
| `InsufficientBalance` | User doesn't have enough SOL | Add more SOL |
| `BelowMinCap` | Amount < $1 USD | Increase amount |
| `AboveMaxCap` | Amount > $10 USD | Decrease amount or use Funds route |
| `BlockUsdCapExceeded` | Too many deposits in this slot | Wait for next slot |
| `RateLimitExceeded` | Epoch limit reached for token | Wait for next epoch |
| `NotSupported` | Token not whitelisted | Use supported token |
| `InvalidOwner` | Vault ATA owner mismatch | Contact admin |
| `InvalidMint` | Vault ATA mint mismatch | Use correct token |

---

## 🔍 Invariants

1. **Balance Conservation:**
   ```
   Sum(user_balances_before) == Sum(user_balances_after) + Sum(vault_balances_after)
   ```

2. **Rate Limit Monotonicity:**
   ```
   consumed_usd_in_block is non-decreasing within same slot
   epoch_usage.used is non-decreasing within same epoch
   ```

3. **Event Emission:**
   ```
   Every successful deposit emits exactly 1 or 2 UniversalTx events
   (1 for simple deposit, 2 for batched deposit)
   ```

4. **USD Cap Enforcement:**
   ```
   For all gas_route deposits:
   min_cap_usd <= lamports_to_usd(amount) <= max_cap_usd
   ```

5. **Token Support:**
   ```
   Deposit succeeds => token_rate_limit.limit_threshold > 0
   ```

---

## 📚 Related Documentation

- [Withdraw & Execute](./2-WITHDRAW-EXECUTE.md) - Outbound flow
- [Rate Limiting](../SECURITY/INVARIANTS.md#rate-limiting) - Detailed rate limit logic
- [Events Reference](../REFERENCE/EVENTS.md) - Event structure details

---

**Last Updated:** 2026-02-11
