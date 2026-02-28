# Account Reference

Quick reference for all account types in the gateway.

---

## PDA Accounts

| Account | Seeds | Size | Purpose |
|---------|-------|------|---------|
| **Config** | `[b"config"]` | 279 bytes | Gateway configuration (admin, caps, oracle) |
| **Vault** | `[b"vault"]` | System | Native SOL custody (no data) |
| **TssPda** | `[b"tsspda_v2"]` | 129 bytes | TSS address, chain ID |
| **CEA** | `[b"push_identity", push_account[20]]` | System | Per-user execution authority |
| **ExecutedSubTx** | `[b"executed_sub_tx", sub_tx_id[32]]` | 8 bytes | Replay protection (discriminator only) |
| **RateLimitConfig** | `[b"rate_limit_config"]` | 157 bytes | Global rate limit settings |
| **TokenRateLimit** | `[b"rate_limit", token_mint]` | 181 bytes | Per-token epoch limits |

---

## Config Account

```rust
pub struct Config {
    pub admin: Pubkey,                      // 32 bytes
    pub tss_address: Pubkey,                // 32 bytes (unused, kept for storage layout)
    pub pauser: Pubkey,                     // 32 bytes
    pub min_cap_universal_tx_usd: u128,     // 16 bytes (8 decimals: 1e8 = $1)
    pub max_cap_universal_tx_usd: u128,     // 16 bytes (8 decimals: 1e10 = $10)
    pub paused: bool,                       // 1 byte
    pub bump: u8,                           // 1 byte
    pub vault_bump: u8,                     // 1 byte
    pub pyth_price_feed: Pubkey,            // 32 bytes
    pub pyth_confidence_threshold: u64,     // 8 bytes
}
```

**Authority:** Admin-only for updates
**Initialized:** Once during deployment

---

## TssPda Account

```rust
pub struct TssPda {
    pub tss_eth_address: [u8; 20],  // 20 bytes - Ethereum address
    pub chain_id: String,            // Variable (max 64) - Cluster pubkey
    pub authority: Pubkey,           // 32 bytes - Admin who can update
    pub bump: u8,                    // 1 byte
}
```

**Authority:** Admin-only for updates
**Replay protection:** Per-tx via `ExecutedSubTx` PDA (seeded by `sub_tx_id`), not a global nonce

---

## RateLimitConfig Account

```rust
pub struct RateLimitConfig {
    pub block_usd_cap: u128,         // 16 bytes (0 = disabled)
    pub epoch_duration_sec: u64,     // 8 bytes (0 = disabled)
    pub last_slot: u64,              // 8 bytes
    pub consumed_usd_in_block: u128, // 16 bytes
    pub bump: u8,                    // 1 byte
}
```

**Authority:** Admin-only for settings
**Updated:** Automatically during deposits (consumed tracking)

---

## TokenRateLimit Account

```rust
pub struct TokenRateLimit {
    pub token_mint: Pubkey,           // 32 bytes
    pub limit_threshold: u128,        // 16 bytes (0 = not supported)
    pub epoch_usage: EpochUsage,      // 24 bytes
    pub bump: u8,                     // 1 byte
}

pub struct EpochUsage {
    pub epoch: u64,    // 8 bytes - Current epoch index
    pub used: u128,    // 16 bytes - Amount used in epoch
}
```

**Authority:** Admin sets threshold
**Updated:** Automatically during deposits (epoch tracking)
**Token Support:** `limit_threshold > 0` means token is whitelisted

---

## ExecutedSubTx Account

```rust
pub struct ExecutedSubTx {}  // Empty, discriminator only
```

**Purpose:** Replay protection via account existence
**Creation:** Init constraint (fails if exists)
**Size:** 8 bytes (Anchor discriminator)

---

## Associated Token Accounts (ATAs)

Not PDAs of gateway, but validated:

| ATA | Owner | Mint | Purpose |
|-----|-------|------|---------|
| **Vault ATA** | Vault PDA | Token | Token custody |
| **CEA ATA** | CEA PDA | Token | CEA's token balance |
| **User ATA** | User wallet | Token | User's token balance |
| **Recipient ATA** | Recipient | Token | Withdraw destination |

**Validation:** Owner and mint checked on every transfer

---

## Account Access Patterns

### Read-Only
- Config (in user transactions)
- Pyth price feed

### Mutable (Admin)
- Config (caps, oracle, pause)
- RateLimitConfig (settings)
- TokenRateLimit (threshold)
- TssPda (address, chain_id)

### Mutable (System)
- Vault (balances)
- CEA (balances)
- RateLimitConfig (consumed tracking)
- TokenRateLimit (epoch tracking)

### Init (One-Time)
- ExecutedSubTx (per sub_tx_id)
- CEA (auto-created by Solana on first transfer)

---

**Last Updated:** 2026-02-23
