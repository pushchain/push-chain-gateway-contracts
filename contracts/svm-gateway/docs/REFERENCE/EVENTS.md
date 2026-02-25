# Event Reference

All events emitted by the gateway for monitoring and cross-chain coordination.

---

## Deposit Events

### UniversalTx
```rust
#[event]
pub struct UniversalTx {
    pub sender: Pubkey,                // User who deposited (or CEA for from_cea=true)
    pub recipient: [u8; 20],           // Push Chain destination ([0; 20] = UEA)
    pub token: Pubkey,                 // Token (Pubkey::default() = SOL)
    pub amount: u64,                   // Bridge amount
    pub payload: Vec<u8>,              // Execution payload
    pub revert_instruction: RevertInstructions,
    pub tx_type: TxType,               // Gas/GasAndPayload/Funds/FundsAndPayload
    pub signature_data: Vec<u8>,       // User signature data
    pub from_cea: bool,                 // true = emitted from CEA withdrawal; Push Chain UE uses recipient directly as existing UEA
}
```

**Emitted:**
- Gas route: After SOL transfer to vault
- Funds route: After SOL/SPL transfer to vault
- Batched route: Twice (gas event + funds event)

**Purpose:** Notify Push Chain relayers of deposit

---

## Outbound Events

### UniversalTxFinalized
```rust
#[event]
pub struct UniversalTxFinalized {
    pub sub_tx_id: [u8; 32],               // Unique transaction ID
    pub universal_tx_id: [u8; 32],     // Cross-chain ID
    pub push_account: [u8; 20],              // Push Chain sender
    pub target: Pubkey,                // Recipient or program
    pub token: Pubkey,                 // Token transferred
    pub amount: u64,                   // Amount transferred
    pub payload: Vec<u8>,              // Instruction data (execute mode)
}
```

**Emitted:** After successful withdraw (mode 1) or execute (mode 2) where target != gateway program
**NOT emitted for CEA withdrawal** (target == gateway): `UniversalTx` is emitted instead (via `send_universal_tx_to_uea`)
**Purpose:** Confirm execution on Solana

---

### RevertUniversalTx
```rust
#[event]
pub struct RevertUniversalTx {
    pub universal_tx_id: [u8; 32],     // Cross-chain ID
    pub sub_tx_id: [u8; 32],               // Transaction ID
    pub fund_recipient: Pubkey,        // Who received reverted funds
    pub token: Pubkey,                 // Token (Pubkey::default() = SOL)
    pub amount: u64,                   // Reverted amount
    pub revert_instruction: RevertInstructions,
}
```

**Emitted:** After successful revert (SOL or SPL)
**Purpose:** Notify Push Chain of failed transaction

---

## Admin Events

### CapsUpdated
```rust
#[event]
pub struct CapsUpdated {
    pub min_cap_usd: u128,  // New minimum cap (8 decimals)
    pub max_cap_usd: u128,  // New maximum cap (8 decimals)
}
```

**Emitted:** When admin updates USD caps
**Purpose:** Track configuration changes

### TSSAddressUpdated
```rust
#[event]
pub struct TSSAddressUpdated {
    pub old_tss: Pubkey,
    pub new_tss: Pubkey,
}
```

**Emitted:** NEVER - Defined but not emitted by any function (including `update_tss`)
**Purpose:** Reserved for future use to track TSS changes
**Note:** Currently `update_tss` does not emit this event

### BlockUsdCapUpdated
```rust
#[event]
pub struct BlockUsdCapUpdated {
    pub block_usd_cap: u128,  // New block cap (8 decimals)
}
```

**Emitted:** When admin sets block USD cap
**Purpose:** Track rate limit configuration

### EpochDurationUpdated
```rust
#[event]
pub struct EpochDurationUpdated {
    pub epoch_duration_sec: u64,  // New epoch duration (seconds)
}
```

**Emitted:** When admin updates epoch duration
**Purpose:** Track rate limit configuration

### TokenRateLimitUpdated
```rust
#[event]
pub struct TokenRateLimitUpdated {
    pub token_mint: Pubkey,
    pub limit_threshold: u128,  // New limit (0 = disabled)
}
```

**Emitted:** When admin sets token rate limit
**Purpose:** Track token whitelisting and limits

---

## Supporting Types

### TxType
```rust
pub enum TxType {
    Gas,              // Gas-only funding
    GasAndPayload,    // Gas + execution
    Funds,            // Pure bridge
    FundsAndPayload,  // Bridge + execution
}
```

### RevertInstructions
```rust
pub struct RevertInstructions {
    pub fund_recipient: Pubkey,  // Where to send reverted funds
    pub revert_msg: Vec<u8>,     // Error message/reason
}
```

---

## Event Emission Patterns

### Deposit Flow
```
send_universal_tx()
  → UniversalTx emitted (1 or 2 times)
```

### Withdraw Flow
```
finalize_universal_tx(instruction_id=1)
  → UniversalTxFinalized emitted
```

### Execute Flow
```
finalize_universal_tx(instruction_id=2)
  → UniversalTxFinalized emitted
  → (Target program may emit its own events)
```

### Revert Flow
```
revert_universal_tx() or revert_universal_tx_token()
  → RevertUniversalTx emitted
```

### CEA Withdrawal Flow
```
finalize_universal_tx(target=gateway)
  → UniversalTx emitted (Funds or FundsAndPayload, from_cea=true)
```

---

## Monitoring Best Practices

1. **Index by sub_tx_id** - Track transaction lifecycle
2. **Monitor TxType** - Distinguish gas vs funds
3. **Track sender→recipient** - User flow analysis
4. **Watch revert events** - Failure monitoring
5. **Alert on config changes** - Security monitoring

---

**Last Updated:** 2026-02-11
