# Trust Assumptions & Threat Model

**Purpose:** Define trust boundaries and security assumptions
**Audience:** Security auditors, risk assessment

---

## 🎭 Trust Roles

### 1. Trusted Entities

#### Admin
- **Controls:** Config, rate limits, TSS address (as TssPda.authority which defaults to admin), pause
- **Trust Level:** FULL
- **Assumption:** Acts in protocol's best interest
- **Risk:**
  - Can pause gateway (DoS)
  - Can change USD caps and rate limits (economic attack)
  - ⚠️ **CRITICAL: Can update TSS address and drain ALL vault funds**
    - Admin has TssPda.authority (tss.rs:51)
    - Admin can call update_tss to change TSS address to attacker-controlled address
    - New TSS can sign withdrawals of all vault funds (SOL + all SPL tokens)
    - **TRUST ASSUMPTION:** Admin is trusted not to drain funds or get compromised

#### TSS (Threshold Signature Scheme)
- **Controls:** All outbound operations (withdraw, execute, revert)
- **Trust Level:** CRITICAL
- **Assumption:** Honest majority of TSS participants
- **Risk:** Can authorize any outbound transfer or execution

#### Pyth Oracle
- **Controls:** SOL/USD price for USD cap validation
- **Trust Level:** HIGH
- **Assumption:** Provides accurate, timely prices
- **Risk:** Price manipulation affects cap enforcement (but not fund safety)

### 2. Untrusted Entities

#### Users
- **Controls:** Deposit transactions
- **Trust Level:** ZERO
- **Assumption:** May be malicious
- **Protection:** Rate limits, caps, validation

#### Relayers
- **Controls:** Submit TSS-signed transactions
- **Trust Level:** ZERO
- **Assumption:** May be malicious or censoring
- **Protection:** TSS signature required, anyone can relay

#### Target Programs (Execute Mode)
- **Controls:** Execute arbitrary logic with CEA as signer
- **Trust Level:** ZERO
- **Assumption:** May be malicious
- **Protection:** CEA balance isolation, TSS authorizes each call

---

## 🛡️ Security Assumptions

### Cryptographic Assumptions

1. **ECDSA secp256k1 is secure**
   - Cannot forge signatures without private key
   - secp256k1_recover correctly validates signatures

2. **Keccak256 is collision-resistant**
   - Cannot find two messages with same hash
   - Message hash uniquely identifies transaction

3. **TSS majority is honest**
   - ≥ threshold of TSS participants are honest
   - TSS participants validate Push Chain state correctly

### System Assumptions

4. **Solana consensus is secure**
   - No long-range attacks
   - Finality guarantees hold
   - No double-spending

5. **Admin key is secure**
   - Private key not compromised
   - Multi-sig or hardware wallet used

6. **Anchor framework is secure**
   - No bugs in Anchor constraints
   - PDA derivation is secure
   - Account deserialization is safe

7. **Pyth oracle is accurate**
   - Price feeds are timely (< 60s staleness)
   - Prices reflect market reality
   - Confidence intervals are reasonable

---

## ⚠️ Threat Model

### In-Scope Threats (Mitigated)

| Threat | Attack Vector | Mitigation |
|--------|---------------|------------|
| **Replay attack** | Reuse valid signature | ExecutedSubTx PDA (per sub_tx_id init constraint) |
| **Front-running** | Execute TSS tx in different order | Each tx independently TSS-signed (no shared state) |
| **Signature forgery** | Fake TSS signature | ECDSA verification |
| **Amount manipulation** | Change amount in message | Message hash binding |
| **Unauthorized withdrawal** | Withdraw without TSS | TSS signature required |
| **CEA impersonation** | Fake CEA signature | PDA seeds controlled by gateway |
| **Token substitution** | Wrong token in ATA | Mint validation |
| **ATA spoofing** | Fake vault/CEA ATA | Derivation + ownership checks |
| **Reentrancy** | Recursive calls | No external calls before state updates |
| **Integer overflow** | Amount overflow | checked_* arithmetic |
| **Rate limit bypass** | Exceed caps via multiple txs | Slot/epoch tracking |

### Out-of-Scope Threats (Accepted Risks)

| Threat | Reason | Consequence |
|--------|--------|-------------|
| **TSS compromise** | Assumed honest majority | Can authorize arbitrary outbound |
| **Admin compromise** | Assumed secure key management | Can pause, change config |
| **Pyth oracle failure** | Assumed accurate prices | USD cap enforcement fails |
| **Solana halt** | Assumed liveness | Bridge stops (but funds safe) |
| **Push Chain reorg** | Cross-chain assumption | TSS handles via revert |
| **Gas griefing** | Relayer can delay | User can relay themselves |

### External Threats (Outside Protocol)

| Threat | Responsibility | Notes |
|--------|---------------|-------|
| **Target program bugs** | Target program | CEA isolation limits blast radius |
| **User key compromise** | User | Cannot affect other users |
| **Frontend attack** | Frontend security | Users should verify tx params |
| **MEV extraction** | Market dynamics | Acceptable in public blockchain |

---

## 🔒 Trust Boundaries

```
┌────────────────────────────────────────────────────────┐
│                  TRUSTED CORE                          │
│  ┌─────────────────────────────────────────────────┐   │
│  │          Gateway Smart Contract                 │   │
│  │  • PDA derivation                               │   │
│  │  • TSS validation                               │   │
│  │  • Amount transfers                             │   │
│  │  • State updates                                │   │
│  └─────────────────────────────────────────────────┘   │
│                                                        │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │
│  │    Admin    │  │     TSS     │  │Pyth Oracle  │   │
│  │  (Trusted)  │  │ (Trusted)   │  │ (Trusted)   │   │
│  └─────────────┘  └─────────────┘  └─────────────┘   │
└────────────────────────────────────────────────────────┘
               │                    │
               ▼                    ▼
    ┌──────────────────┐  ┌──────────────────┐
    │  UNTRUSTED       │  │  UNTRUSTED       │
    │  Users           │  │  Target Programs │
    │  • Deposits      │  │  • Execute logic │
    │  • Can be evil   │  │  • Can be evil   │
    └──────────────────┘  └──────────────────┘
```

---

## 💣 Blast Radius Analysis

### If Admin Compromised
- ❌ Can update TSS address (TssPda.authority is set to admin), enabling fund drain
- ⚠️ Can pause (DoS)
- ⚠️ Can change USD caps (economic impact)
- ⚠️ Can update TSS chain_id (disrupts message signing)
- **Mitigation:** Multi-sig, time-lock, separate TSS authority from admin

### If TSS Compromised
- ❌ Can withdraw all funds
- ❌ Can execute arbitrary programs as any CEA
- ❌ Can revert any transaction
- **Mitigation:** TSS threshold, key rotation, monitoring

### If Pyth Oracle Fails
- ✅ Vault funds safe
- ⚠️ USD cap enforcement broken (can bypass min/max)
- ⚠️ Rate limiting still works (based on amounts)
- **Actual Code Behavior:**
  - Only checks `price > 0` (utils.rs:23)
  - Does NOT enforce staleness checks
  - Does NOT enforce confidence thresholds (despite storing pyth_confidence_threshold)
- **Mitigation:** Admin must monitor oracle health externally and pause gateway if oracle is compromised

### If User Compromised
- ✅ Only their deposits affected
- ✅ Cannot affect other users
- ✅ Cannot affect vault
- **Mitigation:** User responsibility

### If Target Program is Malicious
- ✅ Vault funds safe (CEA receives funds first)
- ⚠️ Can drain CEA balance for that user
- ✅ Cannot affect other users' CEAs
- **Mitigation:** CEA isolation, TSS validates program

---

## 🎯 Security Properties

### Guaranteed (Unconditional)
1. **Balance conservation:** No minting/burning
2. **Access control:** Only admin/TSS can execute privileged ops
3. **Replay protection:** Each sub_tx_id executes once
4. **PDA security:** Only gateway controls CEA signing

### Guaranteed (Conditional on Assumptions)
1. **Fund safety:** IF TSS honest THEN funds safe
2. **Cap enforcement:** IF Pyth accurate THEN caps enforced
3. **Rate limiting:** IF slot/epoch tracking works THEN limits enforced
4. **Authorization:** IF ECDSA secure THEN only TSS authorizes

### NOT Guaranteed
1. **Liveness:** Admin can pause anytime
2. **Censorship resistance:** Relayers can censor (but users can relay)
3. **Target program behavior:** Target may do anything with CEA funds
4. **Price accuracy:** Depends on Pyth oracle

---

## 🧪 Recommended Security Practices

### For Deployers
- [ ] Use multi-sig for admin key (e.g., 3-of-5)
- [ ] Implement time-lock for sensitive operations
- [ ] Monitor TSS signatures for anomalies
- [ ] Set up alerting for pause events
- [ ] Regular security audits

### For Users
- [ ] Verify transaction parameters before signing
- [ ] Use hardware wallet for large amounts
- [ ] Understand target program risks (execute mode)
- [ ] Monitor CEA balance
- [ ] Be aware of rate limits

### For TSS Operators
- [ ] Secure key management (HSM)
- [ ] Validate Push Chain state before signing
- [ ] Implement rate limiting
- [ ] Log all signatures
- [ ] Monitor for replay attempts

---

**Last Updated:** 2026-02-11
