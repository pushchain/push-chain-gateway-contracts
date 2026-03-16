# Threat Model — SVM Universal Gateway

## 1. System Overview

The SVM gateway is a single Anchor program deployed on Solana. It accepts inbound deposits from Solana users (locking funds in a PDA-controlled vault) and processes outbound release instructions that are authorized exclusively by TSS ECDSA signatures. TSS (Threshold Signature Scheme) signs and authorizes outbound content; Universal Validators (UVs) observe `UniversalTxOutbound` events emitted by `UniversalGatewayPC` on Push Chain, build the Solana transactions, and submit them as the `caller` account.

For Push Chain / UEA / PRC20 burn-and-mint mechanics shared with EVM, see the EVM threat model. This document covers only the SVM program.

---

## 2. Scope & Exclusions

**In scope:**
- `programs/universal-gateway/src/` — all instructions, state, and utilities

**Out of scope:**
- `programs/test-counter/` — test-only CPI target program
- TypeScript test helpers and CLI scripts
- Off-chain Universal Validator (UV) and TSS implementation
- Solana runtime, SPL Token Program, Associated Token Program, System Program internals

**Reviewed at commit:** `b82b3c07074c1a7088bddea217b872464f71dbae`

---

## 3. Trust Boundaries & Actor Definitions

| Actor | Type | Trust Level | Capabilities |
|-------|------|-------------|--------------|
| `Config.admin` | Solana `Pubkey` (EOA / multisig) | Highest | Update all config fields, set TSS address, update authorities |
| `Config.pauser` | Solana `Pubkey` (EOA / multisig) | Medium | Pause and unpause gateway only |
| TSS (Threshold Sig Authority) | Off-chain multi-party | High | Authorize all outbound operations (withdraw, execute, revert, rescue) via ECDSA signature |
| Universal Validator (UV) | Off-chain service | Untrusted for content | Submit Solana transactions, pay tx fees; all outbound-critical fields must be TSS-signed |
| Public User | Solana wallet | Untrusted | Call `send_universal_tx` only |
| Pyth oracle | External on-chain account | Trusted-external | Provide SOL/USD price for inbound rate limit checks |
| SPL Token / Associated Token Program | Solana system programs | Trusted-external | Token transfers and ATA creation |

**Trust boundary summary:**

```
[ Public User ] ──→ [ send_universal_tx ] ──→ [ Vault (SOL) ]
                                                [ Vault ATA (SPL) ]
                                                      │
                                            [ UniversalTx event ]
                                                      │
                                             (Push Chain observes)

[ UV ] ────────────→ [ finalize_universal_tx ]  ← TSS signature required
                    [ revert_universal_tx   ]  ← TSS signature required
                    [ rescue_funds          ]  ← TSS signature required
                              │
                       validates signature
                       creates ExecutedSubTx PDA (replay protection)
                       releases from Vault / FeeVault
```

- **UV is structurally untrusted:** the program revalidates every outbound-critical field (recipient, amount, gas_fee, token, accounts) against the TSS message hash on every call. The UV cannot alter any field without invalidating the signature.
- **Vault and FeeVault are separated by design:** `Vault` holds bridge-backed user funds; `FeeVault` holds protocol fees and UV reimbursements for `revert_universal_tx` and `rescue_funds`. `finalize_universal_tx` currently reimburses gas from `Vault` as part of the outbound release path.
- **CEA has no private key:** it is a PDA and only signs via `invoke_signed` inside the gateway. No external party can make CEA sign.
- **Replay protection is on-chain:** `ExecutedSubTx` PDA creation with `init` constraint prevents reusing any `sub_tx_id`.

---

## 4. `universal-gateway` Program

**What this program does:** Single Anchor program. Accepts inbound SOL/SPL deposits, infers TX_TYPE, enforces dual rate limits (per-slot USD caps for instant route, epoch limits for standard route), emits `UniversalTx` events. Processes outbound withdrawals, CPI executions, reverts, and rescues — all gated behind TSS ECDSA signature verification. Uses a PDA vault model: no admin or UV key holds custody.

### Access Control Table

| Authority | Stored At | Protected Instructions |
|-----------|-----------|----------------------|
| `Config.admin` | `Config` PDA | `set_authorities`, `set_caps_usd`, `set_pyth_price_feed`, `set_pyth_confidence_threshold`, `set_block_usd_cap`, `update_epoch_duration`, `set_token_rate_limit`, `set_protocol_fee`, `update_tss`, `init_tss` |
| `Config.pauser` OR `Config.admin` | `Config` PDA | `pause`, `unpause` |
| TSS ECDSA signature (recovered vs `TssPda.tss_eth_address`) | `TssPda` PDA | `finalize_universal_tx` (withdraw/execute), `revert_universal_tx`, `rescue_funds` |
| *(none — public)* | — | `send_universal_tx` |

**Note on paused-mode availability:** instructions using `AdminAction` (which enforces `!config.paused`) require the gateway to be unpaused. The following admin instructions have **no** paused guard and remain callable while paused: `set_authorities` (`SetAuthoritiesAction`), `set_protocol_fee` (`FeeVaultAdminAction`), `init_tss` (`InitTss`), and `update_tss` (`UpdateTss`). This is intentional — admin must be able to rotate TSS address and update authorities as part of an emergency response even when the gateway is paused.

### External Dependencies

| Dependency | Interface | Trust Assumption | Risk if Compromised |
|------------|-----------|------------------|---------------------|
| Pyth `PriceUpdateV2` account | `get_price_unchecked` + feed ID check | Returns correct SOL/USD price; account is the one stored in `Config.pyth_price_feed` | Manipulated or stale price bypasses USD cap checks on inbound gas-route deposits (staleness not enforced — see threat 2) |
| SPL Token Program (`TokenkegQfez...`) | `spl_token::instruction::transfer` | Executes token transfers correctly | Malicious token program not possible — program ID is hardcoded as `spl_token::ID` in `pda_spl_transfer` |
| Associated Token Program | `create_associated_token_account` | Creates ATAs correctly | ATA creation failure blocks CEA SPL receive; no fund loss, tx reverts |
| System Program | `system_instruction::transfer` | Executes SOL transfers correctly | Solana system program is trusted by runtime |

### Threat Scenarios

**1. TSS key compromise**
A compromised TSS private key (or threshold-reaching subset) can authorize arbitrary `finalize_universal_tx`, `revert_universal_tx`, and `rescue_funds` calls, directing any funds held in `Vault` or `FeeVault` to attacker-controlled addresses. All bridge custody is at risk. Mitigated by: TSS is a threshold scheme (multiple parties required); `Config.paused` enables emergency stop by pauser/admin before more transactions settle; admin can update TSS address via `update_tss`. Residual risk: no on-chain timelock on `update_tss`; a single-block attack is possible if admin key is also compromised.

**2. Oracle price manipulation / staleness (Pyth)**
An attacker submits a stale or manipulated Pyth `PriceUpdateV2` account to `send_universal_tx`. The inbound rate limit USD caps (`min_cap_usd`, `max_cap_usd`, `block_usd_cap`) are computed from this price; manipulated data could allow gas-route deposits that violate the protocol's intended USD bounds. Mitigated by: `deposit.rs` enforces `price_update.key() == config.pyth_price_feed` via Anchor constraint — only the admin-configured account is accepted (an attacker cannot substitute a different account); `pricing.rs` checks the feed ID matches the hardcoded `FEED_ID` constant and asserts `price > 0`. Residual risk: `pricing.rs` calls `get_price_unchecked`, which skips Pyth's built-in staleness and confidence checks — a stale or low-confidence price is accepted as long as the account identity and feed ID match. The `pyth_confidence_threshold` config field exists and has a setter, but is not currently used in the pricing path (marked TODO in code). Staleness and confidence enforcement are deferred. Zero-pubkey oracle is prevented at initialization and setter (`require!(price_feed != Pubkey::default())`), so the "not yet configured" path does not exist.

**3. CPI abuse via `remaining_accounts` (execute mode)**
In execute mode, `remaining_accounts` are passed to `invoke_signed` as the CPI account list. An attacker-controlled UV could attempt to: (a) inject accounts with `is_signer = true` to gain signer authority on behalf of CEA, or (b) pass accounts in a different order or with different writable flags than what TSS signed. Mitigated by: `validate_remaining_accounts()` rejects any account with `is_signer = true` (`UnexpectedOuterSigner`); account pubkeys and writable flags are part of the TSS-signed `accounts_buf`, so any mismatch causes `MessageHashMismatch`; the one-way writable rule (signed-writable → actual must be writable) prevents privilege escalation via flag downgrade.

**4. Admin key compromise — cascade attack**
A compromised `Config.admin` key can update TSS address (`update_tss`), change Pyth oracle config, update USD caps, and modify rate limits in a single block. Effective result: all subsequent outbound authorizations flow to the attacker's TSS key. Mitigated by: `Config.paused` can be set by pauser (separate key) to halt all outbound operations; no cross-instruction dependency means the attacker must submit multiple transactions. Residual risk: no timelock on any admin setter; if both admin and pauser keys are compromised simultaneously, the attack is unobstructed. Recommendation: use multisig for both admin and pauser.

**5. `sub_tx_id` replay**
TSS replays the same `sub_tx_id` for any outbound instruction to execute it twice, doubling fund releases. Mitigated by: all outbound functions create `ExecutedSubTx` PDA with `init` constraint, seeded by `["executed_sub_tx", sub_tx_id]`. A second call with the same `sub_tx_id` fails at account creation — the PDA already exists and `init` rejects re-initialization. This is an on-chain hard guarantee, not an off-chain check.

**6. Message hash preimage substitution**
The UV supplies `message_hash` as a parameter to all outbound instructions. A malicious UV could supply a hash that matches a different pre-crafted message. Mitigated by: `validate_message` in `tss.rs` independently reconstructs the hash from on-chain inputs (prefix, instruction_id, chain_id from `TssPda`, amount, additional_data), then compares to the caller-supplied `message_hash`. Any substituted hash fails `MessageHashMismatch`. The signature is verified against the reconstructed hash, not the caller-supplied one — the supplied hash is only used as an optimization hint and cross-checked.

**7. Vault/FeeVault reimbursement model**
`revert_universal_tx` and `rescue_funds` reimburse UVs from `FeeVault`, while `finalize_universal_tx` currently reimburses `gas_fee` from `Vault`. This is the implemented economic model: finalize corresponds to a Push-side burn/release flow, while revert and rescue use protocol-fee-backed reimbursement. Mitigated by: `reimburse_relayer_from_fee_vault()` preserves `FeeVault` rent exemption and fails with `InsufficientFeePool` if revert/rescue reimbursement cannot be covered; `finalize_universal_tx` stages the bridge amount and gas from `Vault` atomically in the same transaction. Residual risk: if `FeeVault` runs dry, revert/rescue fail until replenished; if finalize gas policy changes in the future, this section must stay aligned with the code.

**8. Inbound SPL token account spoofing**
A user could pass an arbitrary `user_token_account` or `gateway_token_account` to `send_universal_tx` to direct tokens to/from an account they control. Mitigated by: `deposit_spl_to_vault` in `deposit.rs` validates `user_token_account.owner == user.key()`, `user_token_account.mint == token`, `gateway_token_account.owner == vault.key()`, and `gateway_token_account.mint == token`. An account failing any check reverts with `InvalidOwner` or `InvalidMint`.

**9. CEA funds lock**
Funds transferred `Vault → CEA` land in the CEA PDA. If the subsequent CPI (`invoke_signed`) fails (target program error, missing accounts, etc.), the transaction reverts entirely — Solana's atomic execution model rolls back all state changes including the `Vault → CEA` transfer. No funds are stranded. Residual risk: if the CEA holds a balance from a prior partial execution (not currently possible with this architecture but relevant if CEA accumulates funds over time), and the outbound CPI then fails, those pre-existing CEA funds remain in CEA. The CEA→UEA self-withdraw path (`destination_program == gateway`) provides a recovery route for CEA-held funds.

**10. Rate limit bypass via wrong `token_rate_limit` account**
`send_universal_tx` accepts `token_rate_limit` as a passed account with no seed constraint in the `SendUniversalTx` struct. A caller could attempt to pass a `TokenRateLimit` account belonging to a different token (one with a higher threshold or fresh epoch). Mitigated by: Anchor deserializes the account as a program-owned `Account<TokenRateLimit>`, rejecting any account not owned by this program; `validate_token_and_consume_rate_limit()` then checks `token_rate_limit.token_mint == expected_token_mint` — a `TokenRateLimit` account for the wrong token fails this equality check. Since admin creates `TokenRateLimit` accounts with deterministic seeds `["rate_limit", mint]`, only one valid program-owned account exists per token, and its stored `token_mint` field matches only its own mint.

**11. Pause griefing**
`Config.pauser` pauses the gateway, halting all inbound deposits and outbound operations. Mitigated by: `Config.admin` can directly call `unpause` — `PauseAction` constraint is `config.pauser == pauser.key() || config.admin == pauser.key()`, so admin satisfies it without any reassignment step. Residual risk: if admin and pauser are the same key and it is compromised, the attacker can pause with no admin override possible. Recommendation: keep admin and pauser as separate keys.

**12. Outbound recipient not validated for SOL revert/rescue**
The `recipient` account in `revert_universal_tx` and `rescue_funds` is `UncheckedAccount` (no data validation). If the TSS message contains the correct recipient pubkey, funds land there regardless of the account's on-chain state. This is intentional — SOL transfers to any Solana address are valid. The TSS message hash binds the recipient, so the UV cannot redirect funds. No vulnerability: recipient correctness is enforced by signature, not by account type.

**13. Cap setter invariant**
If admin sets `max_cap_usd < min_cap_usd`, all inbound gas-route deposits would revert (above-max check fires before below-min). Mitigated by: `set_caps_usd` requires `min_cap_usd <= max_cap_usd`. Note: `pyth_confidence_threshold` has a setter (`set_pyth_confidence_threshold`) and requires `threshold > 0`, but the field is not currently read in the pricing path (`get_price_unchecked` is used). The setter is harmless but the threshold has no effect until the pricing code is updated.

---

## 5. Cross-Program Threat Scenarios

**1. TSS + admin key simultaneous compromise**
If both `Config.admin` and TSS are compromised simultaneously, all bridge funds can be drained: TSS drains `Vault` via `finalize_universal_tx`/`rescue_funds`, and admin prevents recovery by updating pauser before any operator can halt the system. There is no on-chain defense against this. Mitigated operationally by: threshold TSS (requires multiple parties); multisig admin with time-locked governance; separate cold-stored pauser key. This is the highest-severity risk in the system.

**2. Off-chain TSS / UV liveness failure**
A user deposits via `send_universal_tx`, the `UniversalTx` event is emitted, but Universal Validators (UVs) never credit the UEA. The user's SOL/SPL is locked in `Vault` indefinitely. Alternatively, a Push Chain outbound event is emitted (PRC20 burned) but the UV never submits `finalize_universal_tx`. There is no on-chain timeout or user-initiated recovery path for either case. Mitigated by: threshold TSS reduces single-party liveness dependence; events are on-chain and independently verifiable; off-chain monitoring required.

**3. `ExecutedSubTx` account rent exhaustion**
Every outbound operation creates a new `ExecutedSubTx` PDA (8 bytes, roughly `890_880` lamports rent-exempt at current local test settings). The `gas_fee` is intended to cover this rent via UV reimbursement. If `gas_fee` is set too low by TSS (below rent cost), the UV is underpaid. The transaction still succeeds — the `caller` pays the rent and the reimbursement is insufficient. This is an economic risk to the UV, not a security risk to funds.

**4. Pyth oracle account removal / key rotation**
If the Pyth protocol rotates the `PriceUpdateV2` account address for the SOL/USD feed, all inbound instant-route deposits will fail (`InvalidAccount` constraint). Admin must update `Config.pyth_price_feed` to the new account. Until updated, the `send_universal_tx` gas route is effectively DOSed. Outbound operations are unaffected.

**5. Epoch reset manipulation**
The epoch boundary is `unix_timestamp / epoch_duration_sec`. A depositor could time a high-value `FUNDS` deposit at the exact epoch boundary to exploit a fresh reset — the prior epoch's usage is zero'd and the full `limit_threshold` is available. This is by design (identical to EVM behavior). An attacker would need to control both timing and hold a deposit large enough to matter. Rate limit thresholds must be set conservatively relative to bridge liquidity.

---

## 6. Explicit Non-Goals & Deferred Assumptions

- **Off-chain UV behavior:** the program assumes the UV submits well-formed Solana transactions with correct account ordering. Incorrect account lists cause `AccountPubkeyMismatch` or constraint failures, not fund loss.
- **Pyth staleness and confidence:** `pricing.rs` uses `get_price_unchecked`, which skips Pyth's built-in staleness and confidence validation. The `pyth_confidence_threshold` config field and its setter exist but are not currently read in the pricing path (marked TODO). This is a known deferred hardening item, not a deployed control.
- **SPL token rebasing / fee-on-transfer:** the gateway does not account for tokens whose balance changes on transfer. Depositing such a token would result in a `UniversalTx` event with a higher amount than was actually received by the vault — an overstatement of bridge credit. Token whitelist should be restricted to standard SPL tokens.
- **CEA-held balance recovery:** if a CEA accumulates funds without a clear outbound path (e.g., target program logic error in an execute flow), the CEA→UEA self-withdraw path is the only on-chain recovery. No admin sweep function exists for CEA balances.
- **FeeVault replenishment:** if `FeeVault` is drained, outbound operations block at reimbursement. No automated replenishment mechanism exists; this requires manual admin top-up.
