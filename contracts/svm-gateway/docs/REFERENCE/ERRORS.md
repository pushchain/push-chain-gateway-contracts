# Error Reference

Complete list of custom errors with causes and solutions.

---

## Access Control Errors

| Error | Code | Cause | Solution |
|-------|------|-------|----------|
| **Unauthorized** | 6000 | Signer is not admin/pauser | Use correct authority |
| **Paused** | 6009 | Contract is paused | Wait for unpause |

---

## Amount Validation Errors

| Error | Code | Cause | Solution |
|-------|------|-------|----------|
| **InvalidAmount** | 6001 | Amount is 0 or invalid | Use positive amount |
| **BelowMinCap** | 6003 | Amount < $1 USD | Increase amount |
| **AboveMaxCap** | 6004 | Amount > $10 USD | Decrease or use Funds route |
| **InsufficientBalance** | 6013 | User balance too low | Add more funds |

---

## Address Validation Errors

| Error | Code | Cause | Solution |
|-------|------|-------|----------|
| **InvalidRecipient** | 6002 | Recipient is zero address | Provide valid recipient |
| **ZeroAddress** | 6005 | Address is Pubkey::default() | Use valid address |
| **InvalidOwner** | 6008 | ATA owner mismatch | Verify account ownership |

---

## Configuration Errors

| Error | Code | Cause | Solution |
|-------|------|-------|----------|
| **InvalidCapRange** | 6006 | min_cap > max_cap | Fix cap values |
| **InvalidPrice** | 6007 | Pyth price invalid or ≤ 0 | Check oracle feed |

---

## Input Validation Errors

| Error | Code | Cause | Solution |
|-------|------|-------|----------|
| **InvalidInput** | 6010 | Generic invalid parameter | Check all parameters |
| **InvalidTxType** | 6011 | Unknown TxType | Use valid TxType |
| **InvalidMint** | 6012 | Token mint mismatch | Use correct token |
| **InvalidToken** | 6014 | Token not in expected form | Verify token address |
| **InvalidAccount** | 6017 | Account invalid/unexpected | Check account list |
| **InvalidInstruction** | 6031 | instruction_id not 1 or 2 | Use 1 (withdraw) or 2 (execute) |

---

## Rate Limiting Errors

| Error | Code | Cause | Solution |
|-------|------|-------|----------|
| **BlockUsdCapExceeded** | 6015 | Too much USD in this slot | Wait for next slot |
| **RateLimitExceeded** | 6016 | Token epoch limit hit | Wait for next epoch |
| **NotSupported** | 6018 | Token not whitelisted | Use supported token |

---

## TSS Validation Errors

| Error | Code | Cause | Solution |
|-------|------|-------|----------|
| **MessageHashMismatch** | 6019 | Computed hash ≠ provided | Verify message construction |
| **TssAuthFailed** | 6020 | Signature invalid | Check TSS signature |
| **NonceMismatch** | 6021 | Nonce ≠ expected | Get current nonce |

---

## Execute Mode Errors

| Error | Code | Cause | Solution |
|-------|------|-------|----------|
| **AccountListLengthMismatch** | 6022 | remaining_accounts count wrong | Match signed accounts |
| **AccountPubkeyMismatch** | 6023 | Account pubkey doesn't match | Verify account order |
| **AccountWritableFlagMismatch** | 6024 | Writable flag mismatch | Check is_writable flags |
| **UnexpectedOuterSigner** | 6025 | Account has is_signer=true | Remove signer flags |
| **TargetProgramMismatch** | 6026 | Program ID doesn't match | Use correct program |
| **InvalidProgram** | 6027 | Program not executable | Check deployment |
| **NoWritableRecipient** | 6030 | No writable recipient found | Add writable recipient |

---

## Replay Protection Errors

| Error | Code | Cause | Solution |
|-------|------|-------|----------|
| **PayloadExecuted** | 6028 | tx_id already used | Use unique tx_id |

---

## Internal Errors

| Error | Code | Cause | Solution |
|-------|------|-------|----------|
| **SerializationError** | 6029 | Borsh serialization failed | Check data format |

---

## Error Handling Patterns

### Deposit Errors
```rust
// Common deposit failures:
- Paused (6009)
- InsufficientBalance (6013)
- BelowMinCap (6003) / AboveMaxCap (6004)
- BlockUsdCapExceeded (6015)
- RateLimitExceeded (6016)
- NotSupported (6018)
```

### Withdraw/Execute Errors
```rust
// Common outbound failures:
- Paused (6009)
- MessageHashMismatch (6019)
- TssAuthFailed (6020)
- NonceMismatch (6021)
- PayloadExecuted (6028)
- InvalidProgram (6027) [execute only]
```

### Revert Errors
```rust
// Common revert failures:
- Paused (6009)
- TssAuthFailed (6020)
- NonceMismatch (6021)
- PayloadExecuted (6028)
- InvalidAmount (6001)
```

---

## Debugging Guide

### MessageHashMismatch (6019)
1. Check message construction order
2. Verify all bytes are big-endian where required
3. Confirm chain_id matches cluster
4. Validate additional_data array order

### TssAuthFailed (6020)
1. Verify TSS address in TssPda
2. Check signature format (64 bytes)
3. Confirm recovery_id is 0 or 1
4. Validate ECDSA signature generation

### NonceMismatch (6021)
1. Get current nonce: `tss_pda.nonce`
2. Ensure sequential execution
3. Check for skipped nonces
4. Verify no concurrent transactions

### AccountPubkeyMismatch (6023)
1. Verify remaining_accounts order
2. Check account derivation
3. Confirm no extra/missing accounts
4. Match exact order from signed list

### PayloadExecuted (6028)
**Status:** DEFINED BUT NOT USED IN PRACTICE

**Actual Behavior:**
- Duplicate tx_id detection relies on Anchor's PDA init constraint (execute.rs:65, revert.rs:41)
- Code: `#[account(init, seeds=[EXECUTED_TX_SEED, tx_id], ...)]`
- Reused tx_id causes Anchor "account already initialized" error, NOT this error code
- This error code (6028) exists but is never explicitly thrown

**Solution:**
1. tx_id must be globally unique
2. If duplicate tx_id: Anchor constraint error (not PayloadExecuted error)
3. Use fresh tx_id for each transaction

### Unused Error Codes

The following error codes are defined in `errors.rs` but are **NEVER thrown** in the actual program code:

- **PayloadExecuted (6028)** - Replay protection uses PDA init failure instead (documented above)
- **TargetProgramMismatch (6027)** - Defined but not used
- **SerializationError (6029)** - Defined but not used
- **NoWritableRecipient (6030)** - Defined but not used

**Note:** These error codes exist in the enum for potential future use or for compatibility, but the current program implementation does not throw them explicitly.

---

## Error Code Mapping

| Range | Category |
|-------|----------|
| 6000-6009 | Access & Configuration |
| 6010-6014 | Validation & Input |
| 6015-6018 | Rate Limiting |
| 6019-6021 | TSS & Signatures |
| 6022-6031 | Execute & Internal |

---

**Last Updated:** 2026-02-11
