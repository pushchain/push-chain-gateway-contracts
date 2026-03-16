# CEA → UEA: SVM Design Rationale vs EVM

Explains why SVM deviates from the EVM CEA→UEA pattern and the reasons behind those deviations.

---

## EVM Pattern (Reference)

### How the call chain works

```
TSS authorizes → relayer calls gateway.withdrawFunds(target=CEA_contract)
  → gateway calls CEA.executeUniversalTx(multicall_payload)
      multicall executes steps:
        step N: CEA calls address(this).sendUniversalTxToUEA(token, amount, push_payload)
                  ├─ push_payload empty  → gateway.sendUniversalTx()       [fromCEA=false]
                  └─ push_payload filled → gateway.SendUniversalTxToUEA() [fromCEA=true]
```

### How access control works

**CEA side** — `sendUniversalTxToUEA` is protected by:
```solidity
if (msg.sender != address(this)) revert Unauthorized();
```
Only the CEA contract calling itself (via multicall) can invoke this function.

**Gateway side** — `SendUniversalTxToUEA` is protected by:
```solidity
if (!ICEAFactory(CEA_FACTORY).isCEA(_msgSender())) revert InvalidInput();
address mappedUEA = ICEAFactory(CEA_FACTORY).getUEAForCEA(_msgSender());
if (req.recipient != mappedUEA) revert InvalidRecipient();
```
Gateway verifies the caller is a real CEA and that `req.recipient` matches the CEA's registered UEA.

**FUNDS-only (no payload):** CEA calls `gateway.sendUniversalTx()` directly. The gateway does not check `isCEA` on this path — it processes it as a normal deposit from `msg.sender`. Event emits `fromCEA=false`.

---

## What SVM Cannot Do

### The CEA multicall architecture

In EVM, the CEA is a smart contract with a multicall executor. It can call itself (`address(this).sendUniversalTxToUEA(...)`) to trigger the outbound flow. This self-call pattern — where the CEA is both the initiator and the gated caller — has no equivalent in SVM. The SVM CEA is a System Account PDA with no code. It cannot execute instructions, has no multicall executor, and cannot call anything. The entire EVM call chain (`CEA.executeUniversalTx` → multicall → `CEA.sendUniversalTxToUEA`) simply does not exist.

---

## What SVM Could Do But Shouldn't

### 1. Emit `fromCEA=false` for FUNDS-only to match EVM

We could branch in `send_universal_tx_to_uea` on `tx_type`: if `Funds` (empty payload), emit `fromCEA=false`; if `FundsAndPayload`, emit `fromCEA=true`. This would match EVM event output exactly.

Should not be done: in EVM, `fromCEA=false` on FUNDS is an accident of routing — the gateway genuinely cannot tell it is a CEA calling `sendUniversalTx`. In SVM, the gateway always knows it is handling a CEA withdrawal (`destination_program == gateway_program_id`). Emitting `fromCEA=false` would misrepresent the sender. The flag should reflect reality, not mimic an EVM implementation detail caused by a different architecture.

### 2. PDA signer via self-CPI to replicate `address(this) == msg.sender`

We could create an auth PDA (`[b"cea_withdrawal_auth", sender]`), add a dedicated instruction `send_universal_tx_to_uea` that requires this PDA as a signer, and have `finalize_universal_tx` call it via `invoke_signed`. Solana's runtime does allow a program to invoke itself directly (self-CPI) — the reentrancy guard in `invoke_context.rs` only blocks indirect reentrancy (A→B→A), not direct self-calls (A→A). So this is technically possible.

Should not be done: the auth PDA signature would be the gateway proving to itself that it authorized something it already validated via TSS. The only path that can make the auth PDA sign is `finalize_universal_tx` after TSS validation — so the PDA check is entirely redundant. The EVM problem the pattern solves (external callers directly invoking `sendUniversalTxToUEA`) does not exist in SVM: the CEA has no code, no multicall executor, and no external caller to guard against.

### 3. Add a `send_universal_tx_to_uea` instruction as a standalone entrypoint

We could add a dedicated instruction that accepts `SendUniversalTxToUEAArgs` directly, skipping the `destination_program == gateway` routing. This would look more like EVM's dedicated gateway function.

Should not be done: authorization on this path comes from the TSS signature over `ix_data_buf` and `target_program` — that validation only exists inside `finalize_universal_tx`. A standalone instruction would require duplicating TSS validation or accepting calls from anyone.

---

## What SVM Does and Why

```
TSS authorizes → gateway.finalize_universal_tx(instruction_id=2, destination_program=gateway_program_id)
  ix_data = [discriminator(send_universal_tx_to_uea)] ++ borsh(SendUniversalTxToUEAArgs { token, amount, payload, revert_recipient })
    ├─ Gateway detects: target == program_id → send_universal_tx_to_uea
    ├─ CEA transfers funds back to vault
    ├─ tx_type = Funds (empty payload) | FundsAndPayload (non-empty payload)
    ├─ emit UniversalTx { sender=CEA, recipient=UEA, revert_recipient=args.revert_recipient, fromCEA=true }
    └─ emit UniversalTxFinalized { target=gateway_program_id, payload=[] }  ← dual-event (emitted by parent finalize_universal_tx)
```

**Authorization:** The TSS signature covers `target_program=gateway_program_id` and `ix_data_buf` (which includes the discriminator and the entire `SendUniversalTxToUEAArgs`). The relayer cannot forge or modify either field. This replaces both EVM guards:
- `address(this) == msg.sender` → replaced by TSS signing over `ix_data_buf`
- `isCEA(msg.sender)` → replaced by TSS signing over `target_program` + CEA PDA derivation from `push_account`

**`fromCEA` always true:** The gateway always knows this is a CEA withdrawal. There is no ambiguous path.

**No composability:** The UEA can specify arbitrary bytes in `SendUniversalTxToUEAArgs.payload` to execute on Push Chain after the withdrawal. It cannot compose arbitrary Solana-side operations (DeFi, swaps) in the same call. Each Solana-side action requires a separate TSS-authorized transaction.

---

## Summary Table

| Property | EVM | SVM |
|---|---|---|
| CEA type | Smart contract | System Account PDA (no code) |
| Self-authorization mechanism | `msg.sender == address(this)` | Does not exist for PDAs |
| Gateway identity check | `ICEAFactory.isCEA(msg.sender)` | TSS signature over `target_program` + PDA derivation |
| Composable Solana-side steps | Yes (arbitrary multicall in one call) | No — each action is a separate TSS-authorized tx |
| FUNDS route | `sendUniversalTx`, `fromCEA=false` (gateway unaware it's a CEA) | `send_universal_tx_to_uea`, `fromCEA=true` + `UniversalTxFinalized { target=gateway }` (dual-event) |
| FUNDS_AND_PAYLOAD route | `SendUniversalTxToUEA`, `fromCEA=true` | `send_universal_tx_to_uea`, `fromCEA=true` + `UniversalTxFinalized { target=gateway }` (dual-event) |
| Push Chain payload authorization | CEA executes freely within TSS-authorized multicall scope | TSS explicitly signs over `ix_data_buf` containing the payload |
| Gas batching on withdrawal | Disallowed | Not applicable |

---

**Last Updated:** 2026-02-19
