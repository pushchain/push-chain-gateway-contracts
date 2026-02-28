# Push Chain Gateway - Technical Documentation

**Program:** Universal Gateway (Solana/SVM)
**Version:** 0.1.0
**Purpose:** Cross-chain bridge between Solana and Push Chain with CEA execution model

---

## 📖 Documentation Index

### Core Flows
1. [**DEPOSIT (Inbound)**](./FLOWS/1-DEPOSIT.md) - User deposits to bridge funds/gas to Push Chain
2. [**WITHDRAW & EXECUTE (Outbound)**](./FLOWS/2-WITHDRAW-EXECUTE.md) - TSS-authorized outbound transfers and program execution
3. [**REVERT (Outbound Recovery)**](./FLOWS/3-REVERT.md) - TSS-authorized revert of failed transactions
4. [**CEA (Chain Executor Account)**](./FLOWS/4-CEA.md) - Persistent user identity and execution authority

### Security
- [**TSS Validation**](./SECURITY/TSS-VALIDATION.md) - ECDSA signature verification and replay protection
- [**Invariants**](./SECURITY/INVARIANTS.md) - System-level guarantees and constraints
- [**Trust Assumptions**](./SECURITY/TRUST-ASSUMPTIONS.md) - Trust model and threat analysis

### Reference
- [**Accounts**](./REFERENCE/ACCOUNTS.md) - All PDA structures and account types
- [**Events**](./REFERENCE/EVENTS.md) - Event emissions and monitoring
- [**Errors**](./REFERENCE/ERRORS.md) - Error codes and handling

---

## 🎯 Quick Start for Auditors

### Critical Security Areas
1. **TSS Signature Validation** - See [TSS-VALIDATION.md](./SECURITY/TSS-VALIDATION.md)
   - Replay protection via `ExecutedSubTx` PDA (per sub_tx_id)
   - Message hash construction
   - ECDSA secp256k1 recovery

2. **CEA Authority Model** - See [CEA.md](./FLOWS/4-CEA.md)
   - PDA-based signing authority
   - Persistent user identity
   - Program invocation via invoke_signed

3. **Token Transfers** - See flows 1, 2, 3
   - Vault custody model
   - SPL token validation
   - ATA creation and validation

4. **Rate Limiting** - See [DEPOSIT.md](./FLOWS/1-DEPOSIT.md#rate-limiting)
   - Block-based USD caps
   - Token-specific epoch limits
   - Pyth oracle integration

---

## 🏗️ Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    PUSH CHAIN GATEWAY                        │
│                         (Solana)                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  INBOUND (Users)           OUTBOUND (TSS)                   │
│  ┌──────────────┐          ┌──────────────┐                │
│  │   DEPOSIT    │          │  WITHDRAW &  │                │
│  │   (Native/   │          │   EXECUTE    │                │
│  │    SPL)      │          │  (TSS auth)  │                │
│  └──────┬───────┘          └──────┬───────┘                │
│         │                          │                         │
│         ▼                          ▼                         │
│  ┌─────────────────────────────────────────┐                │
│  │           VAULT (SOL + SPL)              │                │
│  │    • Native SOL custody                  │                │
│  │    • SPL token ATAs                      │                │
│  │    • PDA-controlled                      │                │
│  └─────────────────────────────────────────┘                │
│                                                              │
│  ┌─────────────────────────────────────────┐                │
│  │       CEA (Chain Executor Account)       │                │
│  │    • Per-user PDA (seeded by sender)     │                │
│  │    • Signing authority for programs      │                │
│  │    • Persistent identity                 │                │
│  └─────────────────────────────────────────┘                │
│                                                              │
│  ┌─────────────────────────────────────────┐                │
│  │           TSS VALIDATION                 │                │
│  │    • ECDSA secp256k1 signatures          │                │
│  │    • sub_tx_id-based replay protection (ExecutedSubTx PDA) │    │
│  │    • Message hash verification           │                │
│  └─────────────────────────────────────────┘                │
└─────────────────────────────────────────────────────────────┘
```

---

## 🔐 Security Checklist for Auditors

### Access Control
- [ ] Admin functions properly gated
- [ ] TSS signature required for outbound
- [ ] Pause mechanism works correctly
- [ ] No unauthorized PDA derivation

### Token Safety
- [ ] Vault ATA validation
- [ ] User ATA validation
- [ ] Mint verification
- [ ] Amount overflow checks

### Replay Protection
- [ ] ExecutedSubTx PDA creation (sub_tx_id uniqueness via init)
- [ ] Message hash integrity
- [ ] No replay of sub_tx_id (PDA exists check)

### CEA Security
- [ ] PDA derivation correctness
- [ ] Signer validation
- [ ] No unauthorized signing
- [ ] Account ownership checks

### Rate Limiting
- [ ] Block USD cap enforcement
- [ ] Token epoch limits
- [ ] Oracle price validation
- [ ] Overflow protection

---

## 📊 Key Metrics

| Metric | Value |
|--------|-------|
| **Total Instructions** | 17 public functions |
| **PDA Types** | 7 (Config, Vault, TssPda, CEA, ExecutedSubTx, RateLimitConfig, TokenRateLimit) |
| **Event Types** | 8 (1 defined but never emitted: TSSAddressUpdated) |
| **Error Codes** | 32 (6000-6031) |
| **LOC (Rust)** | ~1,836 lines |

---

## 🔄 State Transitions

```
DEPOSIT:
User → Config (check paused)
User → Vault (transfer SOL/SPL)
User → RateLimit (check + update)
User → Event (emit UniversalTx)

WITHDRAW/EXECUTE:
TSS → Config (check paused)
TSS → TssPda (validate signature)
TSS → ExecutedSubTx (init - replay protection)
TSS → Vault → CEA (transfer amount)
TSS → Vault → Caller (transfer gas fee)
TSS → CEA → Target (execute if mode=2, transfer if mode=1)
TSS → Event (emit UniversalTxFinalized)

REVERT:
TSS → Config (check paused)
TSS → TssPda (validate signature)
TSS → ExecutedSubTx (init - replay protection)
TSS → Vault → Recipient (transfer amount)
TSS → Vault → Caller (transfer gas fee)
TSS → Event (emit RevertUniversalTx)
```

---

## 🧪 Testing Coverage

Recommended test areas:
1. ✅ TSS signature validation (valid/invalid)
2. ✅ Replay protection (duplicate sub_tx_id)
3. ✅ Rate limiting (block cap, epoch limit)
4. ✅ CEA execution (program invocation)
5. ✅ Token transfers (SOL, SPL)
6. ✅ Admin functions (pause, caps, rate limits)
7. ✅ Revert flows (SOL, SPL)

---

## 📞 Contact

For audit questions or clarifications:
- Technical Lead: [Contact Info]
- Security Contact: [Contact Info]
- Documentation: This repository

---

**Last Updated:** 2026-02-11
**Audit Version:** Pre-audit documentation v1.0
