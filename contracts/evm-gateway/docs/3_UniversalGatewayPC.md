# UniversalGatewayPC — Outbound Gateway Overview

A **UniversalGateway** is a chain-facing gateway contract that standardizes how users initiate cross-chain transactions.

**UniversalGatewayPC** is the **outbound** gateway deployed **only on Push Chain**. It is used when a user wants to exit Push Chain back to an origin chain by withdrawing (burning) a token on Push Chain and optionally attaching an execution payload for the origin chain. It charges a protocol fee (gas fee) collected into **VaultPC**, burns the user’s token to represent the withdrawal request, and emits a single outbound event (`UniversalTxOutbound`) that drives the rest of the outbound pipeline.

---

## 2. `sendUniversalTxOutbound` — Outbound Transaction Entry Point

`sendUniversalTxOutbound(UniversalOutboundTxRequest req)` is the single public entry point for outbound requests from Push Chain.

At a high level, the function performs the following actions:

1. **Validate common request fields**
   - `target` must be non-empty (destination address on origin chain, encoded as bytes).
   - `token` must be non-zero.
   - `amount` must be non-zero (burn amount).
   - `revertRecipient` must be non-zero.

2. **Infer the outbound transaction type (`TX_TYPE`)**
   - The gateway does not require users to explicitly specify tx type.
   - Instead it infers it using `_fetchTxType(req)` based on whether a payload exists and whether funds are included.

3. **Calculate execution fees using `gasLimit`**
   - Computes `gasToken`, `gasFee`, `gasLimitUsed`, and `protocolFee`.
   - If `req.gasLimit == 0`, it defaults to `UniversalCore.BASE_GAS_LIMIT()`.

4. **Collect the gas fee into VaultPC**
   - Pulls `gasFee` from the user in `gasToken` into `VaultPC` via `transferFrom`.
   - Requires the user to have approved `gasToken` to the gateway beforehand.

5. **Burn PRC20 as the withdrawal representation**
   - Pulls `amount` of `token` (PRC20) from the user into the gateway.
   - Burns the PRC20 amount from the gateway’s balance.

6. **Create a canonical outbound transaction ID**
   - Uses an incrementing `nonce` and hashes the request fields to form `txId`.

7. **Emit the outbound event**
   - Emits `UniversalTxOutbound(...)` containing all essential data for relayers/executors.

---

### 2.1 `_fetchTxType(req)` — How TX_TYPE is inferred

The outbound gateway infers `TX_TYPE` using two decision variables:

- **hasPayload** = `req.payload.length > 0`
- **hasFunds** = `req.amount > 0`

| Inferred TX_TYPE | hasPayload | hasFunds | Meaning |
|---|---|---|---|
| `TX_TYPE.FUNDS` | NO | YES | Funds-only outbound withdrawal (burn → unlock on origin) |
| `TX_TYPE.FUNDS_AND_PAYLOAD` | YES | YES | Withdraw funds and execute a payload on the origin chain |
| `TX_TYPE.GAS_AND_PAYLOAD` | YES | NO | Execute payload-only on origin chain (no funds burned) |

Notes:
- In this contract version, `_validateCommon` currently requires `amount > 0`, which means the practical reachable types are `FUNDS` and `FUNDS_AND_PAYLOAD`.
- `GAS_AND_PAYLOAD` exists in inference logic to support an execution-only route conceptually.

---

### 2.2 Gas limit and fee computation

The gateway uses `_calculateGasFeesWithLimit(req.token, req.gasLimit)` to compute outbound execution fees:

- `gasLimitUsed`:
  - If `req.gasLimit == 0`, use `UniversalCore.BASE_GAS_LIMIT()`
  - Else use `req.gasLimit`

- `(gasToken, gasFee)`:
  - Fetched via `UniversalCore.withdrawGasFeeWithGasLimit(token, gasLimitUsed)`
  - `gasToken` must be non-zero and `gasFee` must be non-zero.

- `protocolFee`:
  - Read from `PRC20(token).PC_PROTOCOL_FEE()`
  - Represents the flat protocol fee portion included inside `gasFee`.

---

### 2.3 Fee movement into VaultPC (Push Chain custody vault)

Once fee parameters are computed, the gateway moves fees into `VaultPC`:

- `_moveFees(msg.sender, gasToken, gasFee)` pulls `gasFee` using:
  - `IPRC20(gasToken).transferFrom(from, VaultPC, gasFee)`
- This makes **VaultPC the fee sink** for outbound flows.
- If fee transfer fails, the transaction reverts.

---

### 2.4 PRC20 burn step

To represent withdrawal out of Push Chain:

- The gateway pulls `amount` PRC20 from the user into itself.
- It then calls `burn(amount)` on the PRC20 contract.
- This ensures the gateway does **not custody** the withdrawn value—burning is the canonical on-chain representation of “exit requested”.

---