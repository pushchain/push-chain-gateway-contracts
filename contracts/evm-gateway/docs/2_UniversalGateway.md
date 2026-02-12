# UniversalGateway — Overview & Architecture

The **UniversalGateway** is the canonical inbound entry point that allows users on external chains to interact with **Push Chain** in a unified, deterministic way. It abstracts away chain-specific complexity and provides a single interface to deposit gas, bridge funds, and execute arbitrary payloads on Push Chain through a user’s **Universal Execution Account (UEA)**.

Instead of forcing users or SDKs to explicitly specify transaction intent, the UniversalGateway **infers intent automatically** based on the structure of the request (presence of payload, funds, and native value). This design removes ambiguity, reduces user error, and enforces protocol safety by construction.

UniversalGateway supports both **instant, low-value actions** (like gas top-ups and small payload executions) and **high-value fund transfers** that require stronger security guarantees. Internally, each request is classified into a well-defined transaction type and routed through the appropriate execution path with strict rate limits and validation.

In short, UniversalGateway is the bridge between external chains and Push Chain’s execution layer—simple on the outside, highly structured and secure on the inside.

---

## 2. `sendUniversalTx` and Transaction Types

UniversalGateway exposes `sendUniversalTx` as the primary entry point.  
Users do **not** pass a transaction type explicitly. Instead, the gateway **infers `TX_TYPE` internally** using a fixed decision matrix derived from four signals:

- **hasPayload** → `payload.length > 0`
- **hasFunds** → `amount > 0`
- **fundsIsNative** → `token == address(0)`
- **hasNativeValue** → `nativeValue > 0` (ETH or swapped gas)

### Supported TX_TYPEs

| TX_TYPE | hasPayload | hasFunds | fundsIsNative | hasNativeValue |
|------|-----------|----------|---------------|----------------|
| **TX_TYPE.GAS** | NO | NO | not-needed | YES |
| **TX_TYPE.GAS_AND_PAYLOAD** | YES | NO | not-needed | YES or NO *(NO = payload-only)* |
| **TX_TYPE.FUNDS (Native)** | NO | YES | YES | YES |
| **TX_TYPE.FUNDS (ERC-20)** | NO | YES | NO | NO |
| **TX_TYPE.FUNDS_AND_PAYLOAD (No batching)** | YES | YES | NO | NO |
| **TX_TYPE.FUNDS_AND_PAYLOAD (Native + Gas batching)** | YES | YES | YES | YES |
| **TX_TYPE.FUNDS_AND_PAYLOAD (ERC-20 + Gas batching)** | YES | YES | NO | YES |

### Key Design Notes

- **GAS vs FUNDS is unambiguous**  
  GAS routes always have `amount == 0`. FUNDS routes always have `amount > 0`.

- **Payload-only execution is supported**  
  Users may execute payloads with zero gas if their UEA is already funded.

- **Batching is implicit**  
  If both funds and native value are present, the gateway automatically batches gas and funds internally—no extra user input required.

Once inferred, the `TX_TYPE` determines the internal routing and validation path.

---

## 3. Rate Limits and Confirmation Model

UniversalGateway enforces **two distinct rate-limit systems**, aligned with different security and confirmation requirements.

### A. Instant Transactions (Low Block Confirmation)

Applies to:
- `TX_TYPE.GAS`
- `TX_TYPE.GAS_AND_PAYLOAD`

Characteristics:
- Designed for frequent, low-value interactions
- Requires fewer block confirmations
- Enforces:
  - **Per-transaction USD caps** (minimum and maximum)
  - **Per-block USD caps** to prevent burst abuse

These routes prioritize speed and UX while remaining economically bounded.

---

### B. Standard Transactions (High Block Confirmation)

Applies to:
- `TX_TYPE.FUNDS`
- `TX_TYPE.FUNDS_AND_PAYLOAD`

Characteristics:
- Designed for high-value fund movements
- Requires stronger finality guarantees
- Enforces:
  - **Per-token epoch rate limits**
  - Longer confirmation requirements before execution

This separation ensures that large fund transfers remain secure, while smaller actions remain fast and efficient.

---