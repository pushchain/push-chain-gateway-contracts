# **SDK Outbound Transaction Guide**

> *Find all possible outbound flows here → https://github.com/pushchain/push-chain-gateway-contracts/blob/cea_dev/contracts/evm-gateway/docs/4_OutboundTx_Flows.md*
> 

This document is the definitive reference for the Push Chain SDK team to construct the correct `data` payload for every outbound transaction flow. It maps 1-to-1 with every case in `docs/4_OutboundTx_Flows.md` and provides the exact encoding, function selectors, and TypeScript/ethers.js snippets needed to build and test each flow end-to-end.

---

## **0. Prerequisites and Shared Types**

```solidity
// src/libraries/Types.sol

struct Multicall {
    address to;      // Target contract address for this call
    uint256 value;   // Native token (wei) to forward with this call
    bytes data;      // ABI-encoded calldata
}

struct UniversalOutboundTxRequest {
    address token;           // PRC20 token address on Push Chain
    uint256 amount;          // Amount to burn (0 for no-burn / payload-only)
    uint256 gasLimit;        // Gas limit for fee quote; 0 → use BASE_GAS_LIMIT
    bytes   payload;         // ABI-encoded Multicall[] (the TSS data), OR bytes("") for FUNDS
    address revertRecipient; // Address to receive funds on Push Chain if tx is reverted
}

struct UniversalTxRequest {
    address recipient;       // Must equal BOB's UEA (anti-spoof check in sendUniversalTxFromCEA)
    address token;           // address(0) for native, ERC20 address otherwise
    uint256 amount;          // Amount to bridge back
    bytes   payload;         // Empty for FUNDS, non-empty for FUNDS_AND_PAYLOAD
    address revertRecipient; // Address to receive funds if this inbound tx is reverted
    bytes   signatureData;   // Leave bytes("") for CEA-originated calls
}

struct RevertInstructions {
    address revertRecipient; // Who receives the refunded tokens
    bytes   revertMsg;       // Arbitrary memo (can be bytes(""))
}
```

### **0.2 Payload Format Reference**

The `data` field passed to `Vault.finalizeUniversalTx` (and forwarded to `CEA.executeUniversalTx`) follows **two distinct formats** depending on the operation:

| Format | When used | Structure |
| --- | --- | --- |
| **Multicall** | All standard flows | `MULTICALL_SELECTOR + abi.encode(Multicall[])` |
| **Legacy (v0)** | Backwards compat, avoid in SDK | `abi.encode(Multicall[])` (no selector prefix) |
| **Migration** | CEA upgrade only | `MIGRATION_SELECTOR` (4 bytes only, no array) |
| **Empty** | Null execution / pre-fund | `bytes("")` |

> **SDK rule**: Always use the `MULTICALL_SELECTOR`-prefixed format for new payloads. The legacy format (no selector) is supported for backwards compatibility only.
> 

### **0.3 Selectors**

```tsx
// These 4-byte selectors are defined in Types.sol (future addition)
// The SDK should treat them as constants:

// MULTICALL_SELECTOR = bytes4(keccak256("multicall(Multicall[])"))
const MULTICALL_SELECTOR: string = "0x<to-be-defined-in-Types.sol>";

// MIGRATION_SELECTOR = bytes4(keccak256("migrateCEA()"))
const MIGRATION_SELECTOR: string = ethers.id("migrateCEA()").slice(0, 10); // "0x" + first 4 bytes
// = keccak256("migrateCEA()")[0:4]
```

> Until `MULTICALL_SELECTOR` is exported from Types.sol, derive it as: `bytes4(keccak256("multicall(Multicall[])"))` or check the deployed CEA contract ABI.
> 

### **0.5 Key Invariants the SDK Must Enforce**

| Rule | Source |
| --- | --- |
| `Multicall.to` must not be `address(0)` | `CEA._handleMulticall` |
| Self-calls to CEA (i.e. `to == ceaAddress`) must have `value == 0` | `CEA._handleMulticall` |
| Migration payload must be sent with `msg.value == 0` | `CEA._handleMigration` |
| `req.recipient` in `sendUniversalTxFromCEA` must equal `CEAFactory.getUEAForCEA(callerCEA)` | `UniversalGateway.sendUniversalTxFromCEA:359` |
| For ERC20 CEA→UEA bridges: CEA must approve gateway **before** calling `sendUniversalTxFromCEA` | `UniversalGateway._handleDeposits` |
| Native token flow: `Vault.finalizeUniversalTx{value: amount}` — `msg.value` must equal `amount` | `Vault._validateParams` |
| ERC20 flow: `Vault.finalizeUniversalTx{value: 0}` — `msg.value` must be 0 | `Vault._validateParams` |

---

## **1. Push Chain Call: `UniversalGatewayPC.sendUniversalTxOutbound`**

This is what BOB (the SDK user) calls on Push Chain. The `payload` field of this struct is the **multicall data** that TSS will pass verbatim to `Vault.finalizeUniversalTx` on the external chain. For **FUNDS-only** transactions, `payload` is empty.

```solidity
// UniversalGatewayPC.sendUniversalTxOutbound(UniversalOutboundTxRequest)
function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req) external;
```

### **TX_TYPE inference table (Push Chain)**

| `req.payload` | `req.amount` | TX_TYPE inferred | PRC20 burned? |
| --- | --- | --- | --- |
| `bytes("")` | `> 0` | `FUNDS` | Yes |
| non-empty | `> 0` | `FUNDS_AND_PAYLOAD` | Yes |
| non-empty | `== 0` | `GAS_AND_PAYLOAD` | No |
| `bytes("")` | `== 0` | ❌ reverts | — |

### **Approvals required before calling**

```tsx
// Always required: approve gasToken for gasFee (collected by UniversalGatewayPC._moveFees)
await gasTokenContract.approve(UNIVERSAL_GATEWAY_PC_ADDRESS, gasFee);

// For FUNDS or FUNDS_AND_PAYLOAD (amount > 0): also approve PRC20 token for burn
await prc20TokenContract.approve(UNIVERSAL_GATEWAY_PC_ADDRESS, amount);
```

---

## **2. External Chain: Vault Call**

SDK constructs and calls `Vault.finalizeUniversalTx` after observing the `UniversalTxOutbound` event. 

The `data` parameter is the multicall payload.

```solidity
// Vault.finalizeUniversalTx
function finalizeUniversalTx(
    bytes32 subTxId,         // from the UniversalTxOutbound event
    bytes32 universalTxId,   // from the UniversalTxOutbound event
    address pushAccount,     // BOB's UEA address on Push Chain (= event.sender)
    address token,           // address(0) for native, ERC20 address for tokens
    uint256 amount,          // amount to fund CEA with (0 for no-burn flows)
    bytes calldata data      // the multicall payload (or bytes("") for null execution)
) external payable;
```

**Funding rule**:

- Native: call with `{value: amount}` — Vault forwards to CEA via `executeUniversalTx{value: amount}`
- ERC20: call with `{value: 0}` — Vault calls `safeTransfer(cea, amount)` then `executeUniversalTx`

---

## **Full Flow Reference Table**

| Flow ref | Category | TX_TYPE (Push) | Burn Token on PC? | Vault token | Multicall steps | Native `msg.value` to Vault |
| --- | --- | --- | --- | --- | --- | --- |
| 2.1 | Withdrawal | FUNDS | Yes | `address(0)` | `[{to: recipient, value: amount, data: "0x"}]` | `amount` |
| 2.2 | Withdrawal | FUNDS | Yes | ERC20 | `[{to: token, data: transfer(recipient)}]` | 0 |
| 3.1 | ExecuteUniversalTx() | FUNDS_AND_PAYLOAD | Yes | `address(0)` | `[{to: protocol, value: amount, data: protocolCall}]` | `amount` |
| 3.2 | ExecuteUniversalTx() | GAS_AND_PAYLOAD | No | `address(0)` | `[{to: protocol, value: ceaBal, data: protocolCall}]` | 0 |
| 3.3 | ExecuteUniversalTx() | FUNDS_AND_PAYLOAD | Yes | `address(0)` | `[{to: protocol, value: burn+cea, data: protocolCall}]` | `burnAmt` |
| 3.4 | ExecuteUniversalTx() | FUNDS_AND_PAYLOAD | Yes | ERC20 | `[approve, protocolCall]` | 0 |
| 3.5 | ExecuteUniversalTx() | GAS_AND_PAYLOAD | No | `address(0)` | `[approve, protocolCall]` | 0 |
| 3.6 | ExecuteUniversalTx() | FUNDS_AND_PAYLOAD | Yes | ERC20 | `[approve(combined), protocolCall]` | 0 |
| 4.1 | Self-call | FUNDS_AND_PAYLOAD | Yes | `address(0)` | `[{to: gateway, value: amount, data: fromCEA}]` | `amount` |
| 4.2 | Self-call | FUNDS_AND_PAYLOAD | Yes | ERC20 | `[approve(gw), {to: gateway, data: fromCEA}]` | 0 |
| 4.3 | Self-call hybrid | FUNDS_AND_PAYLOAD | Yes | `address(0)` | `[{to: gateway, value: burn+cea, data: fromCEA}]` | `burnAmt` |
| 4.4 | Self-call hybrid | FUNDS_AND_PAYLOAD | Yes | ERC20 | `[approve(combined), {to: gateway, data: fromCEA}]` | 0 |
| 4.5–4.8 | Self-call + payload | FUNDS_AND_PAYLOAD | Yes | varies | same as 4.1–4.4 + `payload: pushChainPayload` | varies |
| 5.1 | Revert | — | — | ERC20 | no multicall | — |
| 5.2 | Revert native | — | — | none | no multicall | — |
| Null | Pre-fund | — | — | any | `"0x"` | varies |
| Migration | CEA upgrade | GAS_AND_PAYLOAD | No | `address(0)` | `MIGRATION_SELECTOR` (4 bytes) | 0 |

## **3. Category 1 — Withdrawal Flows**

These flows deliver tokens to an address on the external chain. 

The CEA receives tokens from Vault and immediately transfers them to the specified recipient via its multicall of caller’s CEA.

### **3.1 Native Withdrawal — WITH BURN**

**When**: BOB burns PRC20-ETH and withdraws ETH to a recipient on the external chain.

**Push Chain call (BOB)**:

```tsx
const req: UniversalOutboundTxRequest = {
    token:           PRC20_ETH_ADDRESS,
    amount:          ethers.parseEther("1"),   // 1 ETH
    gasLimit:        0n,                        // use BASE_GAS_LIMIT
    payload:         "0x",                      // empty → FUNDS type
    revertRecipient: BOB_PUSH_ADDRESS
};
// TX_TYPE.FUNDS — no multicall payload sent from Push Chain side
```

**SDK constructs multicall** (the `data` passed to `finalizeUniversalTx`):

```tsx
const calls = [
    {
        to:    recipientAddress,           // EOA or contract on external chain
        value: ethers.parseEther("1"),     // send the 1 ETH
        data:  "0x"                        // no calldata — pure ETH transfer
    }
];
const data = encodeMulticallPayload(calls);

// TSS call:
await vault.finalizeUniversalTx(
    subTxId, universalTxId,
    BOB_UEA,
    ethers.ZeroAddress,          // native token
    ethers.parseEther("1"),
    data,
    { value: ethers.parseEther("1") }   // must match amount
);
```

**What CEA executes**: `recipientAddress.call{value: 1 ether}("")`

---

### **3.2 Token Withdrawal — WITH BURN (Flow 2.2)**

**When**: BOB burns PRC20-USDC and withdraws USDC to a recipient.

**Push Chain call (BOB)**:

```tsx
const req: UniversalOutboundTxRequest = {
    token:           PRC20_USDC_ADDRESS,
    amount:          1000n * 10n**6n,      // 1000 USDC (6 decimals)
    gasLimit:        0n,
    payload:         "0x",                 // empty → FUNDS type
    revertRecipient: BOB_PUSH_ADDRESS
};
```

**SDK constructs multicall**:

```tsx
const usdcInterface = new ethers.Interface(["function transfer(address to, uint256 amount)"]);

const calls = [
    {
        to:    USDC_ADDRESS,
        value: 0n,
        data:  usdcInterface.encodeFunctionData("transfer", [recipientAddress, 1000n * 10n**6n])
    }
];
const data = encodeMulticallPayload(calls);

// TSS call:
await vault.finalizeUniversalTx(
    subTxId, universalTxId,
    BOB_UEA,
    USDC_ADDRESS,
    1000n * 10n**6n,
    data,
    { value: 0n }   // ERC20 flow: no native value
);
```

**What Vault does**: `USDC.safeTransfer(cea, 1000e6)` → then calls `CEA.executeUniversalTx(data)`

**What CEA executes**: `USDC.transfer(recipientAddress, 1000e6)`

---

### **3.3 Native Withdrawal — WITHOUT BURN, CEA balance**

**When**: CEA already holds ETH. BOB spends it without burning any PRC20.

**Push Chain call (BOB)**:

```tsx
// CEA holds 0.5 ETH pre-existing. Build the multicall first.
const calls = [
    {
        to:    recipientAddress,
        value: ethers.parseEther("0.5"),   // spend CEA's own ETH
        data:  "0x"
    }
];
const multicallData = encodeMulticallPayload(calls);

const req: UniversalOutboundTxRequest = {
    token:           PRC20_ETH_ADDRESS,    // still need a token for gas fee reference
    amount:          0n,                   // NO burn
    gasLimit:        0n,
    payload:         multicallData,        // non-empty → GAS_AND_PAYLOAD
    revertRecipient: BOB_PUSH_ADDRESS
};
// TX_TYPE.GAS_AND_PAYLOAD — no PRC20 burned
```

**TSS passes `multicallData` directly** as the `data` arg to `finalizeUniversalTx`:

```tsx
await vault.finalizeUniversalTx(
    subTxId, universalTxId,
    BOB_UEA,
    ethers.ZeroAddress,   // token=address(0), but amount=0
    0n,                   // amount = 0
    multicallData,
    { value: 0n }         // no ETH from Vault — CEA uses own balance
);
```

---

### **3.4 Token Withdrawal — WITHOUT BURN, CEA balance (Flow 2.4)**

**When**: CEA holds USDC from prior activity. BOB sends it out without burning PRC20.

```tsx
const usdcInterface = new ethers.Interface(["function transfer(address to, uint256 amount)"]);

const calls = [
    {
        to:    USDC_ADDRESS,
        value: 0n,
        data:  usdcInterface.encodeFunctionData("transfer", [recipientAddress, 200n * 10n**6n])
    }
];
const multicallData = encodeMulticallPayload(calls);

const req: UniversalOutboundTxRequest = {
    token:           PRC20_USDC_ADDRESS,   // for gas fee reference
    amount:          0n,                   // NO burn
    gasLimit:        0n,
    payload:         multicallData,        // GAS_AND_PAYLOAD
    revertRecipient: BOB_PUSH_ADDRESS
};
```

**TSS call**:

```tsx
await vault.finalizeUniversalTx(
    subTxId, universalTxId,
    BOB_UEA,
    ethers.ZeroAddress,   // token=address(0) because amount=0; token not relevant for funding
    0n,
    multicallData,
    { value: 0n }
);
```

> **Note**: When `amount == 0` and the payload is non-empty, Vault does not transfer any tokens to the CEA. CEA's pre-existing balance powers the execution.
> 

---

## **4. Category 2 — DeFi / Arbitrary Execution Flows**

These flows call arbitrary external protocols from the CEA. The multicall contains the protocol interaction steps. All patterns are identical to Category 1 from an encoding perspective — only the multicall content differs.

### **4.1 Execute with Native — BURN only (Flow 3.1)**

**Scenario**: BOB burns 1 PRC20-ETH and uses the ETH to call a DeFi protocol (e.g. Uniswap swap).

**Push Chain call (BOB)**:

```tsx
// BOB encodes the DeFi call as the multicall payload
const uniswapInterface = new ethers.Interface([
    "function exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160) params) returns (uint256)"
]);
const swapParams = {
    tokenIn:           WETH_ADDRESS,
    tokenOut:          USDC_ADDRESS,
    fee:               3000,
    recipient:         CEA_ADDRESS,
    deadline:          Math.floor(Date.now() / 1000) + 600,
    amountIn:          ethers.parseEther("1"),
    amountOutMinimum:  1800n * 10n**6n,
    sqrtPriceLimitX96: 0n
};

const calls = [
    {
        to:    UNISWAP_ROUTER_ADDRESS,
        value: ethers.parseEther("1"),   // forward 1 ETH from Vault into swap
        data:  uniswapInterface.encodeFunctionData("exactInputSingle", [Object.values(swapParams)])
    }
];
const multicallData = encodeMulticallPayload(calls);

const req: UniversalOutboundTxRequest = {
    token:           PRC20_ETH_ADDRESS,
    amount:          ethers.parseEther("1"),
    gasLimit:        0n,
    payload:         multicallData,    // non-empty → FUNDS_AND_PAYLOAD
    revertRecipient: BOB_PUSH_ADDRESS
};
```

**TSS call**:

```tsx
await vault.finalizeUniversalTx(
    subTxId, universalTxId,
    BOB_UEA,
    ethers.ZeroAddress,
    ethers.parseEther("1"),
    multicallData,
    { value: ethers.parseEther("1") }
);
```

---

### **4.2 Execute with Native — CEA Balance only, no burn (Flow 3.2)**

BOB instructs CEA to use its own ETH balance. Identical pattern to Flow 2.3 but the multicall targets a DeFi protocol instead of a plain recipient.

```tsx
const calls = [
    {
        to:    TARGET_PROTOCOL_ADDRESS,
        value: ethers.parseEther("0.5"),   // CEA's own ETH
        data:  targetInterface.encodeFunctionData("someFunction", [/* args */])
    }
];
const multicallData = encodeMulticallPayload(calls);

const req: UniversalOutboundTxRequest = {
    token: PRC20_ETH_ADDRESS, amount: 0n, gasLimit: 0n,
    payload: multicallData, revertRecipient: BOB_PUSH_ADDRESS
};
```

---

### **4.3 Execute with Native — BURN + CEA balance, hybrid (Flow 3.3)**

**Scenario**: CEA holds 0.3 ETH. BOB burns 0.5 PRC20-ETH. Total available: 0.8 ETH. The multicall uses the combined balance.

```tsx
// Vault will fund CEA with 0.5 ETH. CEA already has 0.3 ETH → total 0.8 ETH available.
const calls = [
    {
        to:    TARGET_PROTOCOL_ADDRESS,
        value: ethers.parseEther("0.8"),   // draws on BOTH Vault-supplied + pre-existing
        data:  targetInterface.encodeFunctionData("someFunction", [/* args */])
    }
];
const multicallData = encodeMulticallPayload(calls);

const req: UniversalOutboundTxRequest = {
    token:  PRC20_ETH_ADDRESS,
    amount: ethers.parseEther("0.5"),   // only burns 0.5 ETH worth of PRC20
    gasLimit: 0n,
    payload: multicallData,             // FUNDS_AND_PAYLOAD
    revertRecipient: BOB_PUSH_ADDRESS
};
```

**TSS call**: `{ value: 0.5 ether }` — Vault adds this to CEA. CEA's call in the multicall spends 0.8 ETH total (0.5 new + 0.3 pre-existing). No enforcement that `sum(call.value) == msg.value`.

---

### **4.4 Execute with Token — BURN only (Flow 3.4)**

**Scenario**: BOB burns PRC20-USDC and deposits 500 USDC into Aave via CEA.

ERC20 execution **always requires an approve step in the multicall before the protocol call**, because the CEA (not the user) is the token holder and must grant allowance to the protocol.

```tsx
const erc20Interface = new ethers.Interface([
    "function approve(address spender, uint256 amount) returns (bool)"
]);
const aaveInterface = new ethers.Interface([
    "function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)"
]);

const calls = [
    // Step 1: CEA approves Aave pool to pull USDC
    {
        to:    USDC_ADDRESS,
        value: 0n,
        data:  erc20Interface.encodeFunctionData("approve", [AAVE_POOL_ADDRESS, 500n * 10n**6n])
    },
    // Step 2: CEA calls Aave supply — tokens are pulled from CEA
    {
        to:    AAVE_POOL_ADDRESS,
        value: 0n,
        data:  aaveInterface.encodeFunctionData("supply", [USDC_ADDRESS, 500n * 10n**6n, CEA_ADDRESS, 0])
    }
];
const multicallData = encodeMulticallPayload(calls);

const req: UniversalOutboundTxRequest = {
    token:  PRC20_USDC_ADDRESS,
    amount: 500n * 10n**6n,
    gasLimit: 0n,
    payload: multicallData,
    revertRecipient: BOB_PUSH_ADDRESS
};
```

> **Pattern**: Approve → Protocol call. This 2-step approve+interact pattern is required for every ERC20 protocol interaction where the protocol pulls tokens from CEA.
> 

---

### **4.5 Execute with Token — CEA Balance only, no burn (Flow 3.5)**

CEA already holds 200 USDC. Same approve+interact pattern, just `amount=0` on Push Chain.

```tsx
// Same calls as 4.4 but for 200 USDC from CEA's own balance
const calls = [
    { to: USDC_ADDRESS, value: 0n,
      data: erc20Interface.encodeFunctionData("approve", [AAVE_POOL_ADDRESS, 200n * 10n**6n]) },
    { to: AAVE_POOL_ADDRESS, value: 0n,
      data: aaveInterface.encodeFunctionData("supply", [USDC_ADDRESS, 200n * 10n**6n, CEA_ADDRESS, 0]) }
];
const multicallData = encodeMulticallPayload(calls);

const req: UniversalOutboundTxRequest = {
    token: PRC20_USDC_ADDRESS, amount: 0n,  // no burn
    gasLimit: 0n, payload: multicallData, revertRecipient: BOB_PUSH_ADDRESS
};
```

---

### **4.6 Execute with Token — BURN + CEA balance, hybrid (Flow 3.6)**

CEA holds 100 USDC. BOB burns 500 PRC20-USDC → Vault supplies 500 USDC → CEA has 600 USDC. Multicall approves + deposits all 600 USDC.

```tsx
const calls = [
    { to: USDC_ADDRESS, value: 0n,
      data: erc20Interface.encodeFunctionData("approve", [AAVE_POOL_ADDRESS, 600n * 10n**6n]) },
    { to: AAVE_POOL_ADDRESS, value: 0n,
      data: aaveInterface.encodeFunctionData("supply", [USDC_ADDRESS, 600n * 10n**6n, CEA_ADDRESS, 0]) }
];
// req.amount = 500e6 (burn 500 USDC), multicall uses combined 600 USDC
```

---

## **5. Category 3 — CEA Self-Call Flows (sendUniversalTxFromCEA)**

These flows bridge tokens **from the external chain back to BOB's UEA on Push Chain**. The CEA calls `UniversalGateway.sendUniversalTxFromCEA`.

### **Critical requirements for all Category 3 flows**

1. **Anti-spoof**: `UniversalTxRequest.recipient` MUST equal `CEAFactory.getUEAForCEA(ceaAddress)`. The gateway verifies this unconditionally (`UniversalGateway.sol:359`). Never use `address(0)` here.
2. **ERC20 pre-approval**: For ERC20 bridges, the **first multicall step** must approve the `UniversalGateway` address to pull tokens from the CEA. Without this, `_handleDeposits` will fail when trying `safeTransferFrom(CEA, Vault, amount)`.
3. **Native bridge**: For native bridges, the multicall step must forward the correct `value` to `sendUniversalTxFromCEA`. The gateway deposits it to TSS immediately.
4. **`signatureData`**: Set to `bytes("")` for all CEA-originated calls.

```tsx
// Helper to build the UniversalTxRequest for sendUniversalTxFromCEA
interface InboundTxRequest {
    recipient:       string;   // BOB's UEA address (anti-spoof enforced)
    token:           string;   // address(0) for native, ERC20 address for tokens
    amount:          bigint;
    payload:         string;   // "0x" for FUNDS, non-empty for FUNDS_AND_PAYLOAD
    revertRecipient: string;   // where funds go if inbound tx is rejected on Push Chain
    signatureData:   string;   // always "0x" for CEA calls
}

// ABI for encoding the inner call
const gatewayInterface = new ethers.Interface([
    "function sendUniversalTxFromCEA((address recipient, address token, uint256 amount, bytes payload, address revertRecipient, bytes signatureData) req) payable"
]);
```

---

### **5.1 FUNDS Native — with BURN (Flow 4.1)**

Vault funds CEA with ETH. CEA bridges it back to BOB's UEA immediately.

**Push Chain call (BOB)** — must include multicall in `payload` because BOB specifies the bridge-back intent:

```tsx
const ceaAddress   = await ceaFactory.getCEAForPushAccount(BOB_UEA);    // predict CEA address
const bridgeAmount = ethers.parseEther("1");

const innerReq: InboundTxRequest = {
    recipient:       BOB_UEA,           // anti-spoof: must match CEAFactory mapping
    token:           ethers.ZeroAddress, // native
    amount:          bridgeAmount,
    payload:         "0x",              // empty → FUNDS type on external chain
    revertRecipient: BOB_PUSH_ADDRESS,
    signatureData:   "0x"
};

const calls = [
    {
        to:    UNIVERSAL_GATEWAY_ADDRESS,
        value: bridgeAmount,             // forward ETH into gateway
        data:  gatewayInterface.encodeFunctionData("sendUniversalTxFromCEA", [innerReq])
    }
];
const multicallData = encodeMulticallPayload(calls);

const req: UniversalOutboundTxRequest = {
    token:           PRC20_ETH_ADDRESS,
    amount:          bridgeAmount,       // burn 1 PRC20-ETH
    gasLimit:        0n,
    payload:         multicallData,      // FUNDS_AND_PAYLOAD
    revertRecipient: BOB_PUSH_ADDRESS
};
```

**TSS call**:

```tsx
await vault.finalizeUniversalTx(
    subTxId, universalTxId,
    BOB_UEA,
    ethers.ZeroAddress,
    bridgeAmount,
    multicallData,
    { value: bridgeAmount }
);
```

**What happens on-chain**:

1. Vault: `CEA.executeUniversalTx{value: 1 ETH}(data)`
2. CEA: calls `UniversalGateway.sendUniversalTxFromCEA{value: 1 ETH}(innerReq)`
3. Gateway: verifies CEA identity and anti-spoof, infers `TX_TYPE.FUNDS`, deposits 1 ETH to TSS
4. Gateway emits `UniversalTx(sender=CEA, recipient=BOB_UEA, fromCEA=true)`
5. Push Chain: mints 1 PRC20-ETH to BOB_UEA

---

### **5.2 FUNDS ERC20 — with BURN (Flow 4.2)**

Vault sends USDC to CEA. CEA approves gateway, then calls `sendUniversalTxFromCEA`.

```tsx
const bridgeAmount = 500n * 10n**6n;  // 500 USDC

const innerReq: InboundTxRequest = {
    recipient:       BOB_UEA,
    token:           USDC_ADDRESS,
    amount:          bridgeAmount,
    payload:         "0x",             // FUNDS — no Push Chain payload
    revertRecipient: BOB_PUSH_ADDRESS,
    signatureData:   "0x"
};

const calls = [
    // Step 1: CEA approves gateway to pull USDC via safeTransferFrom(CEA, Vault, amount)
    {
        to:    USDC_ADDRESS,
        value: 0n,
        data:  erc20Interface.encodeFunctionData("approve", [UNIVERSAL_GATEWAY_ADDRESS, bridgeAmount])
    },
    // Step 2: CEA calls gateway — gateway pulls USDC from CEA into Vault
    {
        to:    UNIVERSAL_GATEWAY_ADDRESS,
        value: 0n,
        data:  gatewayInterface.encodeFunctionData("sendUniversalTxFromCEA", [innerReq])
    }
];
const multicallData = encodeMulticallPayload(calls);

const req: UniversalOutboundTxRequest = {
    token:           PRC20_USDC_ADDRESS,
    amount:          bridgeAmount,
    gasLimit:        0n,
    payload:         multicallData,
    revertRecipient: BOB_PUSH_ADDRESS
};
```

**TSS call**:

```tsx
await vault.finalizeUniversalTx(
    subTxId, universalTxId,
    BOB_UEA, USDC_ADDRESS, bridgeAmount, multicallData, { value: 0n }
);
```

**What happens on-chain**:

1. Vault: `USDC.safeTransfer(CEA, 500e6)` then `CEA.executeUniversalTx(data)`
2. CEA: Step 1 — `USDC.approve(UniversalGateway, 500e6)`
3. CEA: Step 2 — `UniversalGateway.sendUniversalTxFromCEA(innerReq)`
4. Gateway: `USDC.safeTransferFrom(CEA, Vault, 500e6)` — locks in Vault
5. Gateway emits `UniversalTx(fromCEA=true, recipient=BOB_UEA, token=USDC, amount=500e6)`
6. Push Chain: mints 500 PRC20-USDC to BOB_UEA

---

### **5.3 FUNDS Native — with BURN + CEA balance, hybrid (Flow 4.3)**

CEA holds 0.2 ETH pre-existing. BOB burns 0.3 PRC20-ETH. Combined: 0.5 ETH bridged back.

```tsx
const vaultSupply  = ethers.parseEther("0.3");   // from burn
const ceaExisting  = ethers.parseEther("0.2");   // pre-existing
const totalBridge  = ethers.parseEther("0.5");   // combined total

const innerReq: InboundTxRequest = {
    recipient:       BOB_UEA,
    token:           ethers.ZeroAddress,
    amount:          totalBridge,          // bridge the full combined amount
    payload:         "0x",
    revertRecipient: BOB_PUSH_ADDRESS,
    signatureData:   "0x"
};

const calls = [
    {
        to:    UNIVERSAL_GATEWAY_ADDRESS,
        value: totalBridge,                // 0.3 from Vault + 0.2 from CEA balance
        data:  gatewayInterface.encodeFunctionData("sendUniversalTxFromCEA", [innerReq])
    }
];
const multicallData = encodeMulticallPayload(calls);

const req: UniversalOutboundTxRequest = {
    token:           PRC20_ETH_ADDRESS,
    amount:          vaultSupply,          // only burn 0.3 ETH worth of PRC20
    gasLimit:        0n,
    payload:         multicallData,
    revertRecipient: BOB_PUSH_ADDRESS
};
```

> CEA gets 0.3 ETH from Vault + already has 0.2 ETH = total 0.5 ETH available. The multicall forwards 0.5 ETH to gateway. No invariant requires `call.value == msg.value`.
> 

---

### **5.4 FUNDS ERC20 — with BURN + CEA balance, hybrid (Flow 4.4)**

CEA holds 100 USDC. BOB burns 400 PRC20-USDC. Combined: 500 USDC bridged back.

```tsx
const vaultSupply  = 400n * 10n**6n;
const totalBridge  = 500n * 10n**6n;   // 400 + 100 pre-existing

const innerReq: InboundTxRequest = {
    recipient: BOB_UEA, token: USDC_ADDRESS, amount: totalBridge,
    payload: "0x", revertRecipient: BOB_PUSH_ADDRESS, signatureData: "0x"
};

const calls = [
    // Approve the full combined amount
    { to: USDC_ADDRESS, value: 0n,
      data: erc20Interface.encodeFunctionData("approve", [UNIVERSAL_GATEWAY_ADDRESS, totalBridge]) },
    // Bridge combined amount back to Push Chain
    { to: UNIVERSAL_GATEWAY_ADDRESS, value: 0n,
      data: gatewayInterface.encodeFunctionData("sendUniversalTxFromCEA", [innerReq]) }
];
const multicallData = encodeMulticallPayload(calls);

const req: UniversalOutboundTxRequest = {
    token: PRC20_USDC_ADDRESS, amount: vaultSupply,  // burn only 400e6
    gasLimit: 0n, payload: multicallData, revertRecipient: BOB_PUSH_ADDRESS
};
```

---

### **5.5 FUNDS_AND_PAYLOAD Native — with BURN (Flow 4.5)**

Same as 5.1 but the inner `UniversalTxRequest.payload` is non-empty, causing Push Chain to execute `pushChainPayload` via BOB's UEA after crediting the bridged ETH.

```tsx
const pushChainPayload = encodeSomePushChainCall(/* ... */);

const innerReq: InboundTxRequest = {
    recipient:       BOB_UEA,
    token:           ethers.ZeroAddress,
    amount:          bridgeAmount,
    payload:         pushChainPayload,   // non-empty → FUNDS_AND_PAYLOAD on external chain
    revertRecipient: BOB_PUSH_ADDRESS,
    signatureData:   "0x"
};

const calls = [
    {
        to:    UNIVERSAL_GATEWAY_ADDRESS,
        value: bridgeAmount,
        data:  gatewayInterface.encodeFunctionData("sendUniversalTxFromCEA", [innerReq])
    }
];
// Everything else identical to 5.1
```

---

### **5.6 FUNDS_AND_PAYLOAD ERC20 — with BURN (Flow 4.6)**

Same as 5.2 but with `pushChainPayload` in the inner request.

```tsx
const innerReq: InboundTxRequest = {
    recipient: BOB_UEA, token: USDC_ADDRESS, amount: bridgeAmount,
    payload:   pushChainPayload,   // non-empty
    revertRecipient: BOB_PUSH_ADDRESS, signatureData: "0x"
};

const calls = [
    { to: USDC_ADDRESS, value: 0n,
      data: erc20Interface.encodeFunctionData("approve", [UNIVERSAL_GATEWAY_ADDRESS, bridgeAmount]) },
    { to: UNIVERSAL_GATEWAY_ADDRESS, value: 0n,
      data: gatewayInterface.encodeFunctionData("sendUniversalTxFromCEA", [innerReq]) }
];
```

---

### **5.7 FUNDS_AND_PAYLOAD Native — with BURN + CEA balance (Flow 4.7)**

Combine Flow 4.5 (with payload) and Flow 4.3 (hybrid). Same structure as 5.3 but with `pushChainPayload` in the inner request.

```tsx
const innerReq: InboundTxRequest = {
    recipient: BOB_UEA, token: ethers.ZeroAddress, amount: totalBridge,
    payload:   pushChainPayload,   // non-empty
    revertRecipient: BOB_PUSH_ADDRESS, signatureData: "0x"
};

const calls = [
    { to: UNIVERSAL_GATEWAY_ADDRESS, value: totalBridge,
      data: gatewayInterface.encodeFunctionData("sendUniversalTxFromCEA", [innerReq]) }
];
// req.amount = vaultSupply (only burn portion)
```

---

### **5.8 FUNDS_AND_PAYLOAD ERC20 — with BURN + CEA balance (Flow 4.8)**

Combine Flow 4.6 (with payload) and Flow 4.4 (hybrid). Same as 5.4 but with `pushChainPayload`.

```tsx
const innerReq: InboundTxRequest = {
    recipient: BOB_UEA, token: USDC_ADDRESS, amount: totalBridge,
    payload:   pushChainPayload,   // non-empty
    revertRecipient: BOB_PUSH_ADDRESS, signatureData: "0x"
};

const calls = [
    { to: USDC_ADDRESS, value: 0n,
      data: erc20Interface.encodeFunctionData("approve", [UNIVERSAL_GATEWAY_ADDRESS, totalBridge]) },
    { to: UNIVERSAL_GATEWAY_ADDRESS, value: 0n,
      data: gatewayInterface.encodeFunctionData("sendUniversalTxFromCEA", [innerReq]) }
];
// req.amount = vaultSupply (only burn portion)
```

---

## **6. Category 4 — Revert Flows**

Revert flows are TSS-only — the SDK does not construct payloads for these. They are initiated when a cross-chain transaction must be refunded. Documented here for completeness and testing purposes.

### **6.1 Revert ERC20 Token (Flow 5.1)**

TSS calls `Vault.revertUniversalTxToken`. No multicall payload is involved.

```tsx
const revertInstruction = {
    revertRecipient: RECIPIENT_ON_EXTERNAL_CHAIN,
    revertMsg:       "0x"   // optional bytes memo
};

// TSS call (no multicall data — Vault handles transfer directly):
await vault.revertUniversalTxToken(
    subTxId,
    universalTxId,
    USDC_ADDRESS,
    refundAmount,
    revertInstruction
);
```

**What Vault does**:

1. Validates: token supported, sufficient balance, revertRecipient != address(0)
2. `USDC.safeTransfer(gateway, refundAmount)`
3. Calls `gateway.revertUniversalTxToken(...)` — gateway transfers to `revertRecipient`
4. Emits `VaultUniversalTxReverted`

**Testing**: Verify `VaultUniversalTxReverted` event is emitted, and that `revertRecipient` balance increased by `refundAmount`.

---

### **6.2 Revert Native Token (Flow 5.2)**

For native token reverts, TSS calls `UniversalGateway.revertUniversalTx` directly. Vault is not involved in native reverts.

```tsx
// TSS call directly to gateway — native ETH held by gateway from original deposit:
await gateway.revertUniversalTx(
    subTxId,
    universalTxId,
    refundAmountWei,
    { revertRecipient: RECIPIENT, revertMsg: "0x" },
    { value: refundAmountWei }   // TSS sends the ETH
);
```

**What gateway does**:

1. Checks `isExecuted[subTxId]` for replay protection, marks as executed
2. `payable(revertRecipient).call{value: amount}("")`
3. Emits `RevertUniversalTx`

---

## **7. Null Execution (CEA Pre-funding)**

Pre-funding stages tokens in the CEA without executing anything. TSS calls `Vault.finalizeUniversalTx` with `data = bytes("")` (or `"0x"`).

```tsx
// TSS pre-funds CEA with 500 USDC — no execution:
await vault.finalizeUniversalTx(
    subTxId, universalTxId,
    BOB_UEA,
    USDC_ADDRESS,
    500n * 10n**6n,
    "0x",           // EMPTY payload — CEA receives tokens and holds them
    { value: 0n }
);

// Or pre-fund with ETH:
await vault.finalizeUniversalTx(
    subTxId, universalTxId,
    BOB_UEA,
    ethers.ZeroAddress,
    ethers.parseEther("1"),
    "0x",
    { value: ethers.parseEther("1") }
);
```

**What happens**: Vault deploys CEA if needed, funds it, calls `CEA.executeUniversalTx("0x")`. CEA receives the funds. If payload is empty, `_handleExecution` is called with empty bytes — it falls through to `_handleSingleCall` which calls `abi.decode(bytes(""), (Multicall[]))` and executes zero calls (no-op). Tokens sit in CEA awaiting a future execution.

**Retrieve later**: BOB sends a `GAS_AND_PAYLOAD` outbound with `amount=0` and a multicall that draws on the pre-funded balance (Flows 2.3, 2.4, 3.2, 3.5, or any Category 3 no-burn pattern).

---

## **8. CEA Migration (Special Case)**

Migration upgrades a user's CEA to a new implementation via `delegatecall`. It uses a special 4-byte selector instead of a `Multicall[]` array.

### **8.1 Migration Payload Format**

```tsx
// Migration payload = just the MIGRATION_SELECTOR (4 bytes, no array data)
// MIGRATION_SELECTOR = bytes4(keccak256("migrateCEA()"))
const MIGRATION_SELECTOR: string = ethers.id("migrateCEA()").slice(0, 10);
// e.g. "0xabcd1234"

const migrationPayload: string = MIGRATION_SELECTOR;   // exactly 4 bytes, nothing more
```

> Do NOT wrap migration in a `Multicall[]`. It is a top-level selector, not a multicall step. The CEA checks: `isMulticall? No. isMigration? Yes.` and routes to `_handleMigration()`.
> 

### **8.2 Push Chain Call for Migration**

```tsx
// Migration requires NO token burn and NO token transfer
const req: UniversalOutboundTxRequest = {
    token:           PRC20_ETH_ADDRESS,   // any valid PRC20 for gas fee reference
    amount:          0n,                  // NO burn — migration is logic-only
    gasLimit:        0n,
    payload:         MIGRATION_SELECTOR,  // the 4-byte migration selector
    revertRecipient: BOB_PUSH_ADDRESS
};
// TX_TYPE.GAS_AND_PAYLOAD (non-empty payload, amount=0)
```

### **8.3 TSS Call for Migration**

```tsx
// TSS observes UniversalTxOutbound with GAS_AND_PAYLOAD, recognises migration selector
await vault.finalizeUniversalTx(
    subTxId, universalTxId,
    BOB_UEA,
    ethers.ZeroAddress,   // no token transfer
    0n,                   // no amount
    MIGRATION_SELECTOR,   // the 4-byte payload
    { value: 0n }         // NO native value — migration rejects msg.value > 0
);
```

### **8.4 What CEA Executes**

```
CEA.executeUniversalTx(subTxId, universalTxId, BOB_UEA, MIGRATION_SELECTOR)
  → _handleExecution(payload = MIGRATION_SELECTOR)
  → isMulticall?  No (MIGRATION_SELECTOR ≠ MULTICALL_SELECTOR)
  → isMigration?  Yes (bytes4(payload[0:4]) == MIGRATION_SELECTOR)
  → _handleMigration():
      1. Rejects if msg.value > 0  → CEAErrors.InvalidInput()
      2. migrationContract = factory.CEA_MIGRATION_CONTRACT()
      3. Rejects if migrationContract == address(0)  → CEAErrors.InvalidCall()
      4. (bool ok,) = migrationContract.delegatecall(abi.encodeWithSignature("migrateCEA()"))
      5. Rejects if !ok  → CEAErrors.ExecutionFailed()
  → emit UniversalTxExecuted(txId, uTxId, BOB_UEA, address(CEA), MIGRATION_SELECTOR)
```

### **8.5 Preconditions to Verify Before Sending**

```tsx
// 1. Check migration contract is set
const migrationContract = await ceaFactory.CEA_MIGRATION_CONTRACT();
if (migrationContract === ethers.ZeroAddress) throw new Error("Migration contract not set");

// 2. Check CEA exists (migration requires existing CEA)
const [ceaAddress, isDeployed] = await ceaFactory.getCEAForPushAccount(BOB_UEA);
if (!isDeployed) throw new Error("CEA not deployed — deploy first via any funded tx");

// 3. Never include msg.value in the Vault call
// 4. Payload must be exactly 4 bytes
if (migrationPayload.length !== 10) throw new Error("Migration payload must be 4 bytes (10 hex chars with 0x)");
```

### **8.6 Error Conditions**

| Condition | Error |
| --- | --- |
| `msg.value > 0` in Vault call | `CEAErrors.InvalidInput()` |
| `CEA_MIGRATION_CONTRACT == address(0)` | `CEAErrors.InvalidCall()` |
| `delegatecall migrateCEA()` fails | `CEAErrors.ExecutionFailed()` |
| CEA not yet deployed | Vault deploys it first; migration then runs (harmless) |
| Sent as a Multicall step (wrong format) | Routes to `_handleMulticall`, not migration — silently fails to upgrade |

---

## **9. Just for examples: Multi-Step Multicall Patterns ( Optional )**

The multicall model supports any number of sequential calls in a single execution. Here are compound patterns the SDK should support.

### **9.1 DeFi + Bridge Back (Compound: Execute then Self-Call)**

BOB swaps USDC to DAI on Uniswap, then bridges DAI back to Push Chain — all in one `finalizeUniversalTx` call.

```tsx
const swapAmount   = 500n * 10n**6n;   // 500 USDC in
const minDaiOut    = 490n * 10n**18n;  // min 490 DAI out

const uniswapInterface = new ethers.Interface([
    "function exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160)) returns (uint256)"
]);

const innerReq: InboundTxRequest = {
    recipient:       BOB_UEA,
    token:           DAI_ADDRESS,
    amount:          minDaiOut,     // minimum; actual may be more
    payload:         "0x",
    revertRecipient: BOB_PUSH_ADDRESS,
    signatureData:   "0x"
};

const calls = [
    // Step 1: approve Uniswap to pull USDC from CEA
    { to: USDC_ADDRESS, value: 0n,
      data: erc20Interface.encodeFunctionData("approve", [UNISWAP_ROUTER, swapAmount]) },
    // Step 2: swap USDC → DAI, output goes to CEA
    { to: UNISWAP_ROUTER, value: 0n,
      data: uniswapInterface.encodeFunctionData("exactInputSingle", [{
          tokenIn: USDC_ADDRESS, tokenOut: DAI_ADDRESS, fee: 100,
          recipient: CEA_ADDRESS, deadline: deadline,
          amountIn: swapAmount, amountOutMinimum: minDaiOut, sqrtPriceLimitX96: 0n
      }]) },
    // Step 3: approve gateway to pull DAI from CEA
    { to: DAI_ADDRESS, value: 0n,
      data: erc20Interface.encodeFunctionData("approve", [UNIVERSAL_GATEWAY_ADDRESS, minDaiOut]) },
    // Step 4: bridge DAI back to Push Chain
    { to: UNIVERSAL_GATEWAY_ADDRESS, value: 0n,
      data: gatewayInterface.encodeFunctionData("sendUniversalTxFromCEA", [innerReq]) }
];
const multicallData = encodeMulticallPayload(calls);
```

> **Important**: Steps 3 and 4 approve/bridge `minDaiOut`. If the swap returns more DAI, the SDK should fetch the actual output first (off-chain simulation) and use that amount, or use a max-approval pattern.
> 

### **9.2 Multi-Token Withdrawal (Batch Send)**

Send both ETH and USDC to a recipient in one CEA execution:

```tsx
const calls = [
    // Send ETH
    { to: recipientAddress, value: ethers.parseEther("0.5"), data: "0x" },
    // Send USDC
    { to: USDC_ADDRESS, value: 0n,
      data: erc20Interface.encodeFunctionData("transfer", [recipientAddress, 200n * 10n**6n]) }
];
```

### **9.3 Self-Call Rule Reminder**

If a multicall step targets the CEA itself (e.g., calling a CEA-specific admin function), `value` for that step MUST be 0:

```tsx
// Valid self-call:
{ to: CEA_ADDRESS, value: 0n, data: ceaInterface.encodeFunctionData("someFunction", []) }

// INVALID — will revert with CEAErrors.InvalidInput():
{ to: CEA_ADDRESS, value: ethers.parseEther("1"), data: "0x" }
```

---

---

##