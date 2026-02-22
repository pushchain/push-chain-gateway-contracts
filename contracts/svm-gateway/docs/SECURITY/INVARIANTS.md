# System Invariants

**Purpose:** Formal guarantees that must hold at all times
**Audience:** Auditors, formal verification

---

## 💰 Balance Invariants

### 1. Total Supply Conservation
```
Sum(all user deposits) == Sum(vault balances) + Sum(withdrawn amounts)
```
**Enforcement:** No minting/burning, only transfers

### 2. Vault Ownership
```
∀ token T: vault_ata(T).owner == vault_pda
```
**Enforcement:** ATA validation on every SPL transfer

### 3. Non-Negative Balances
```
vault.lamports >= 0
vault_ata.amount >= 0
```
**Enforcement:** Checked arithmetic, balance checks before transfers

---

## 🔒 Access Control Invariants

### 4. Admin Functions
```
pause() ⟹ signer == config.admin || signer == config.pauser
set_caps() ⟹ signer == config.admin
```
**Enforcement:** Anchor constraints on admin functions

### 5. TSS Authorization
```
withdraw_and_execute() succeeds ⟹ valid TSS signature
revert() succeeds ⟹ valid TSS signature
```
**Enforcement:** `validate_message()` in every outbound function

### 6. CEA Signing Authority
```
CEA signs for program P ⟹ TSS authorized the transaction
```
**Enforcement:** invoke_signed only called after TSS validation

---

## 🔄 State Transition Invariants

### 7. Config Immutability (During Transaction)
```
config state unchanged during deposit/withdraw/revert
(except pause state via admin)
```
**Enforcement:** Read-only access in user transactions

### 9. Vault Bump Persistence
```
config.vault_bump never changes after initialization
```
**Enforcement:** Set once in initialize(), never modified

---

## 🛡️ Replay Protection Invariants

### 10. Transaction Uniqueness
```
∀ tx_id: executed_tx(tx_id) exists ⟹ transaction executed
```
**Enforcement:** init constraint on ExecutedTx PDA

---

## 📊 Rate Limiting Invariants

### 12. Block USD Cap
```
At any slot S:
  Sum(usd_amounts in slot S) <= block_usd_cap
  (if block_usd_cap > 0)
```
**Enforcement:** check_block_usd_cap() before deposit

### 13. Token Epoch Limit
```
Within epoch E for token T:
  Sum(amounts deposited) <= token_rate_limit(T).limit_threshold
  (if limit_threshold > 0)
```
**Enforcement:** consume_rate_limit() before deposit

### 14. Epoch Reset
```
New epoch detected ⟹ epoch_usage.used reset to 0
```
**Enforcement:** Epoch calculation and conditional reset

---

## 🎯 Mode-Specific Invariants

### 15. Withdraw Mode (instruction_id=1)
```
withdraw succeeds ⟹
  amount > 0 ∧
  sender != [0u8; 20] ∧
  writable_flags == [] ∧
  ix_data == [] ∧
  rent_fee == 0 ∧
  remaining_accounts == []
```
**Enforcement:** validate_mode_specific_params()

### 16. Execute Mode (instruction_id=2)
```
execute succeeds ⟹
  destination_program.executable ∧
  rent_fee <= gas_fee ∧
  writable_flags.len() == ceil(accounts.len() / 8)
```
**Enforcement:** validate_mode_specific_params() + program check

---

## 🔐 CEA Invariants

### 17. CEA Determinism
```
∀ sender S: CEA(S) == find_program_address([b"push_identity", S])
```
**Enforcement:** Anchor seeds derivation

### 18. CEA Signer Exclusivity
```
∀ account A in remaining_accounts: A.is_signer == false
```
**Enforcement:** validate_remaining_accounts()

### 19. CEA Balance Flow
```
execute mode:
  cea.lamports_after >= 0 (may increase/decrease based on program logic)

withdraw mode:
  if recipient == cea:
    cea receives amount (no second transfer)
  if recipient != cea:
    cea transfers exactly amount to recipient
    (CEA may retain prior balance beyond amount)
```
**Enforcement:** Transfer logic in internal_withdraw()

---

## 💱 Token Invariants

### 20. SPL Account Derivation
```
∀ token T, owner O:
  ATA(O, T) == get_associated_token_address(O, T)
```
**Enforcement:** ATA derivation checks

### 21. SPL Mint Consistency
```
vault_ata.mint == cea_ata.mint == recipient_ata.mint == token
```
**Enforcement:** Mint validation on every SPL transfer

### 22. Token Support
```
deposit(token T) succeeds ⟹ token_rate_limit(T).limit_threshold > 0
```
**Enforcement:** validate_token_and_consume_rate_limit()

---

## ⚖️ Economic Invariants

### 23. Gas Fee Split
```
gas_fee == rent_fee + relayer_fee
rent_fee <= gas_fee
relayer_fee >= 0
```
**Enforcement:** checked_sub for relayer_fee calculation

### 24. USD Cap Range
```
min_cap_usd <= max_cap_usd
(Note: min_cap_usd can be 0, only ordering is enforced)
```
**Enforcement:** set_caps_usd validation

### 25. Price Oracle Validity
```
⚠️ CRITICAL: Gas deposit succeeds ⟹ pyth_price > 0 (NO staleness or confidence checks)
```
**Enforcement:** calculate_sol_price() (utils.rs:20-23) uses `get_price_unchecked()`:
```rust
let price = price_update.get_price_unchecked(&feed_id);
// TODO: check time in mainnet (utils.rs:20 comment)
require!(price.price > 0, GatewayError::InvalidPrice);  // ONLY check
```

**⚠️ CRITICAL SECURITY LIMITATIONS:**
- **NO publish_time/freshness check** - Stale prices from hours/days ago are accepted
- **NO confidence threshold enforcement** - Despite storing `pyth_confidence_threshold` (state.rs:90), it is NEVER used
- Code comment says "TODO: check time in mainnet" but check is not implemented
- Admin can configure confidence threshold via `set_pyth_confidence_threshold`, but the value is ignored

**ATTACK VECTOR:**
1. Attacker waits for Pyth oracle to become stale (e.g., price feed paused)
2. Attacker uses outdated price to bypass USD caps:
   - If SOL price dropped: deposit more SOL than cap allows (thinks SOL is worth more)
   - If SOL price spiked: deposit less SOL than minimum (thinks SOL is worth less)
3. Rate limiting is bypassed via price manipulation

**MITIGATION:**
- Admin MUST monitor Pyth oracle health externally
- Consider implementing staleness check (e.g., require publish_time within last 60 seconds)
- Consider using `get_price_no_older_than()` instead of `get_price_unchecked()`

---

## 🔄 Event Invariants

### 26. Deposit Event
```
deposit succeeds ⟹ exactly 1 or 2 UniversalTx events emitted
(1 for simple, 2 for batched)
```
**Enforcement:** emit! in gas/funds routes

### 27. Execute Event
```
withdraw_and_execute succeeds ⟹ exactly 1 UniversalTxExecuted event
```
**Enforcement:** emit! at end of withdraw_and_execute

### 28. Revert Event
```
revert succeeds ⟹ exactly 1 RevertUniversalTx event
```
**Enforcement:** emit! in revert functions

---

## 🧮 Arithmetic Invariants

### 29. No Overflow
```
⚠️ CRITICAL: Arithmetic operations use UNCHECKED operators - overflow WILL occur if admin misconfigures limits
```
**Enforcement:** Rate limit arithmetic (utils.rs:149, 154, 176, 181) uses unchecked `+` operator:
```rust
rate_limit_config.consumed_usd_in_block += usd_amount;  // utils.rs:154 - UNCHECKED
token_rate_limit.epoch_usage.used += amount;            // utils.rs:181 - UNCHECKED
```

**⚠️ CRITICAL RISK:**
- Code does NOT use checked_add/checked_sub
- If admin sets `block_usd_cap` or `limit_threshold` near u128::MAX, overflow WILL occur
- Overflow will wrap to 0, breaking rate limiting entirely
- **MITIGATION:** Admin MUST configure reasonable limits (<<< u128::MAX)
- **TRUST ASSUMPTION:** Admin will not misconfigure limits to values that could overflow

**Recommended Fix:** Use checked_add() and return error on overflow instead of relying on admin configuration

### 30. Amount Precision
```
Amounts stored/transferred in native units:
  SOL: lamports (1e9 per SOL)
  SPL: token's natural decimals
  USD: 8 decimals (Pyth format)
```
**Enforcement:** Consistent decimal handling

---

## 📏 Size Invariants

### 31. Account Sizes
```
Config::LEN == actual serialized size
TssPda::LEN == actual serialized size
ExecutedTx::LEN == 8 (discriminator only)
```
**Enforcement:** Space allocation in init constraints

### 32. Chain ID Bounds
```
1 <= chain_id.len() <= 64
```
**Enforcement:** init_tss and update_tss validation

---

## 🎭 Pause Invariants

### 33. Pause Scope
```
paused == true ⟹
  deposit fails ∧
  withdraw fails ∧
  execute fails ∧
  revert fails ∧
  admin functions still work
```
**Enforcement:** require!(!config.paused) in user functions

### 34. Pause Authority
```
pause() ⟹ signer == admin || signer == pauser
unpause() ⟹ signer == admin || signer == pauser
```
**Enforcement:** PauseAction constraint

---

## 🔍 Testing Checklist

For each invariant:
- [ ] Unit test verifying property holds
- [ ] Integration test with edge cases
- [ ] Fuzz test for boundary conditions
- [ ] Formal verification (if applicable)

---

**Last Updated:** 2026-02-11
