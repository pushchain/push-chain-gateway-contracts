# UniversalGatewayPC — Outbound Gateway Overview

**UniversalGatewayPC** is the outbound gateway deployed **only on Push Chain**. It handles user requests to exit Push Chain back to an origin chain by burning PRC20 tokens and optionally attaching execution payloads.

Gas fees are paid in native PC, swapped to the origin chain's gas token PRC20 via UniversalCore. The gas-cost portion (`gasFee`) is **burned** — freeing the backing tokens for TSS relayers to spend on origin-chain gas. The protocol-fee portion (`protocolFee`) is sent to **VaultPC** as revenue. Unused PC is refunded directly to the caller.

---

## 1. Contract Layout

| Section | Description |
| --- | --- |
| **UGPC_1: Admin Actions** | `initialize`, `pause`/`unpause`, `setVaultPC` |
| **UGPC_2: Outbound TX** | `sendUniversalTxOutbound` — single public entry point |
| **UGPC_3: Internal Helpers** | TX_TYPE inference, fee quoting, swap+burn, PRC20 burn |

---

## 2. `sendUniversalTxOutbound` — Entry Point

`sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req)` is the single public entry point. It is `payable` (native PC for gas fees), `whenNotPaused`, and `nonReentrant`.

**Execution flow:**

1. **Validate** — `token` must be non-zero, `revertRecipient` must be non-zero.
2. **Infer TX_TYPE** — via `_fetchTxType(req)` based on payload and amount presence.
3. **Quote fees** — via `_fetchOutboundTxInfo(req.token, req.gasLimit)` returning `gasToken`, `gasFee`, `gasLimitUsed`, `protocolFee`, and `chainNamespace`.
4. **Burn PRC20** — if `amount > 0`, pulls and burns the user's PRC20 tokens.
5. **Swap and split fees** — swaps `msg.value` (native PC) to gas token PRC20 via `UniversalCore.swapAndBurnGas()`:
   - `gasFee` worth of gas token is **burned** (supply freed for TSS relayers).
   - `protocolFee` worth of gas token is **sent to VaultPC** (protocol revenue).
   - Unused PC is **refunded** to the caller.
6. **Generate subTxId** — `keccak256(sender, recipient, token, amount, payloadHash, chainNamespace, nonce)`.
7. **Emit `UniversalTxOutbound`** — contains all data for relayers/executors.

---

### 2.1 TX_TYPE Inference (`_fetchTxType`)

The gateway infers `TX_TYPE` from two decision variables — users never specify it explicitly:

| hasPayload | hasFunds (`amount > 0`) | TX_TYPE | Behavior |
| --- | --- | --- | --- |
| NO | YES | `FUNDS` | Burn tokens, unlock on origin chain |
| YES | YES | `FUNDS_AND_PAYLOAD` | Burn tokens + execute payload on origin chain |
| YES | NO | `GAS_AND_PAYLOAD` | Execute payload using existing CEA funds (no burn) |
| NO | NO | — | Reverts with `InvalidInput` (empty transaction) |

`GAS_AND_PAYLOAD` enables payload-only transactions where the user's CEA on the origin chain already holds sufficient funds for execution.

---

### 2.2 Fee Quoting (`_fetchOutboundTxInfo`)

Fetches gas fee quote and chain metadata from `UniversalCore.getOutboundTxGasAndFees(token, gasLimitUsed)`:

- **`gasLimitUsed`** — if `req.gasLimit == 0`, defaults to `UniversalCore.BASE_GAS_LIMIT()`.
- **`gasToken`** — the PRC20 gas token for the target chain (e.g., pETH for Ethereum).
- **`gasFee`** — gas cost only: `gasPrice * gasLimit`. Excludes protocol fee.
- **`protocolFee`** — flat protocol fee in gas token units.
- **`chainNamespace`** — chain identifier string for the target chain.

Reverts with `InvalidData` if `gasToken == address(0)` or `gasFee + protocolFee == 0`.

---

### 2.3 Fee Swap and Split (`_swapAndCollectFees`)

The user pays gas fees in native PC via `msg.value`. The gateway calls `UniversalCore.swapAndBurnGas{value: msg.value}(...)` which:

1. Swaps native PC → gas token PRC20 (total = `gasFee + protocolFee`).
2. **Burns** the `gasFee` portion — the backing tokens on the origin chain are freed for TSS relayers to spend on execution gas.
3. **Sends** the `protocolFee` portion to VaultPC as protocol revenue.
4. **Refunds** any excess PC directly to the caller.

This replaces the previous model where the entire fee was sent to VaultPC. The burn ensures no supply mismatch between the PRC20 representation on Push Chain and the backing tokens held by TSS on the origin chain.

---

### 2.4 PRC20 Burn (`_burnPRC20`)

When `amount > 0`, the gateway:

1. Pulls `amount` PRC20 from the user into itself via `transferFrom`.
2. Burns the PRC20 via `burn(amount)`.

The gateway never custodies withdrawn value — burning is the canonical on-chain representation of "exit requested". For `GAS_AND_PAYLOAD` (amount = 0), the burn step is skipped entirely.

---

## 3. Access Control

| Role | Permissions |
| --- | --- |
| `DEFAULT_ADMIN_ROLE` | `initialize`, `setVaultPC` |
| `PAUSER_ROLE` | `pause`, `unpause` |

---

## 4. Key Interfaces

| Interface | Function | Purpose |
| --- | --- | --- |
| `IUniversalCore` | `BASE_GAS_LIMIT()` | Default gas limit when user passes 0 |
| `IUniversalCore` | `getOutboundTxGasAndFees(token, gasLimit)` | Quote gas fee, protocol fee, gas token, chain namespace |
| `IUniversalCore` | `swapAndBurnGas(gasToken, vault, fee, gasFee, protocolFee, deadline, caller)` | Swap PC → gas token, burn gasFee, send protocolFee to vault |
| `IPRC20` | `transferFrom`, `burn` | Pull and burn PRC20 tokens |
| `IVaultPC` | (address only) | Receives protocol fee portion of gas token |
