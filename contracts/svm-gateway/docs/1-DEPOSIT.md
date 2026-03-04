# Deposit (Inbound)

**Function:** `send_universal_tx`
**Direction:** Solana → Push Chain
**Authorization:** User signature

The gateway infers `TX_TYPE` automatically from the request structure. Users never specify it explicitly.

---

## TX_TYPE Routing

| TX_TYPE | req.amount | req.payload | req.token | native_amount |
|---------|-----------|-------------|-----------|---------------|
| `Gas` | 0 | empty | any | > 0 |
| `GasAndPayload` | 0 | non-empty | any | >= 0 |
| `Funds` (SOL) | > 0 | empty | default | == req.amount (exact) |
| `Funds` (SPL) | > 0 | empty | mint | == 0 |
| `FundsAndPayload` (SOL) | > 0 | non-empty | default | >= req.amount |
| `FundsAndPayload` (SPL) | > 0 | non-empty | mint | any |

`native_amount` mirrors `msg.value` on EVM — total native SOL sent by the user.

---

## Protocol Fee

A flat fee in lamports is deducted from `native_amount` before routing. The adjusted amount is what all routing and cap checks see. Fee goes to `FeeVault`, not `Vault`, preserving the 1:1 bridge invariant. Fee of 0 disables it.

---

## Gas Route (Instant)

Applies to `Gas` and `GasAndPayload`. After fee deduction:

> **Note:** GAS route payload validation is currently disabled (matching EVM V0). The gateway accepts `Gas` with a non-empty payload and `GasAndPayload` with an empty payload without error.

1. USD cap check: `min_cap_usd <= lamports_to_usd(amount) <= max_cap_usd` (Pyth SOL/USD)
2. Block USD cap check: per-slot budget; resets each slot
3. Transfer: `User → Vault` (native SOL)
4. Emit `UniversalTx` with `recipient = [0u8; 20]` (→ UEA on Push Chain)

If `gas_amount == 0` (payload-only, user already has UEA gas): emit event only, no transfer.

---

## Funds Route (Standard Bridge)

Applies to `Funds` and `FundsAndPayload`.

- Token must be whitelisted (`limit_threshold > 0`)
- Epoch-based rate limit: `epoch_used + amount <= limit_threshold` (resets per epoch)
- Native SOL: `User → Vault`
- SPL: `User ATA → Vault ATA` — both `user_token_account` and `gateway_token_account` must be provided
- Emit `UniversalTx` with `recipient = req.recipient`

For `FundsAndPayload`, if there is excess `native_amount` beyond `req.amount`, the excess is processed as a gas deposit first.

---

## Token Accounts (Inbound)

`user_token_account` and `gateway_token_account` are optional accounts:
- **Native SOL routes:** pass `null` for both
- **SPL routes:** pass both — the gateway validates owner and mint before transferring

---

## Key Errors

| Error | Cause |
|-------|-------|
| `BelowMinCap` / `AboveMaxCap` | Gas amount outside USD cap range |
| `BlockUsdCapExceeded` | Per-slot budget exhausted |
| `NotSupported` | Token not whitelisted |
| `RateLimitExceeded` | Epoch limit reached for token |
| `InvalidOwner` | SPL token account owner mismatch |
| `InvalidMint` | SPL token account mint mismatch |
| `InsufficientProtocolFee` | `native_amount < protocol_fee` |
| `Paused` | Gateway is paused |
