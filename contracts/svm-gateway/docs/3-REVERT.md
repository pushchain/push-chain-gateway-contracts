# Revert (Outbound Recovery)

**Functions:** `revert_universal_tx` (SOL), `revert_universal_tx_token` (SPL)
**Direction:** Vault → Recipient
**Authorization:** TSS ECDSA secp256k1 signature

Returns deposited funds to the user when a Push Chain transaction fails.

---

## Flow

1. Verify TSS signature
2. Create `ExecutedSubTx` PDA (replay protection)
3. `Vault → Recipient` (amount)
4. Emit `RevertUniversalTx`
5. `FeeVault → Caller` (gas_fee, relayer reimbursement)

The funds transfer comes from the bridge `Vault`. The relayer reimbursement comes from `FeeVault` — not from `Vault`. This preserves the 1:1 bridge invariant. If `FeeVault` has insufficient balance, the reimbursement fails with `InsufficientFeePool`.

Event is emitted after the funds transfer but before the relayer reimbursement.

---

## TSS Message Format

```
message = PREFIX || instruction_id (1 byte) || chain_id || amount (8 BE) || additional_data
hash = keccak256(message)
```

### SOL Revert (instruction_id=3) — additional_data
```
sub_tx_id[32] | universal_tx_id[32] | recipient[32] | gas_fee (8 BE)
```

### SPL Revert (instruction_id=4) — additional_data
```
sub_tx_id[32] | universal_tx_id[32] | mint[32] | recipient[32] | gas_fee (8 BE)
```

`PREFIX = b"PUSH_CHAIN_SVM"`

---

## Recipient Validation

The `recipient` must match `revert_instruction.fund_recipient` from the original deposit. This value was included in the `UniversalTx` event emitted at deposit time. TSS reads it from chain state to construct the revert.

`recipient` must not be `Pubkey::default()`.

---

## Key Errors

| Error | Cause |
|-------|-------|
| `TssAuthFailed` | Signature invalid or TSS address mismatch |
| `MessageHashMismatch` | Message reconstruction mismatch |
| account init failure | `sub_tx_id` reused — `ExecutedSubTx` PDA already exists |
| `InvalidRecipient` | Recipient is zero address or doesn't match original deposit |
| `InvalidRecipient` | Recipient ATA owner doesn't match `fund_recipient`, or recipient is zero address |
| `InvalidMint` | Recipient ATA mint doesn't match `token_mint` |
| `Paused` | Gateway is paused |
