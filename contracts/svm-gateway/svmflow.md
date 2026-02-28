# SVM SDK Outbound Request Guide (Current Contracts)

**Scope**: `UniversalGatewayPC.sendUniversalTxOutbound()` on Push Chain.

**Out of scope**: relayer/TSS signing and Solana transaction construction (see `contracts/svm-gateway/INTEGRATION_GUIDE.md`).

---

## 1. Contract Shape (as implemented)

```solidity
struct UniversalOutboundTxRequest {
    bytes   target;           // required, non-empty
    address token;            // required, non-zero PRC20 on Push Chain
    uint256 amount;           // burn amount (0 allowed for payload-only route)
    uint256 gasLimit;         // 0 => uses BASE_GAS_LIMIT from UniversalCore
    bytes   payload;          // empty for FUNDS, non-empty for *_AND_PAYLOAD
    address revertRecipient;  // required, non-zero
}

function sendUniversalTxOutbound(UniversalOutboundTxRequest calldata req) external;
```

### Important notes

- `target` is **still required** in this branch.
- `payload` is **not required** for FUNDS.
- For Solana, SDK should encode `target` as a 32-byte pubkey (`bytes32`-style raw bytes in `bytes`).
- Contract only enforces `target.length > 0`; 32-byte enforcement is SDK/relayer responsibility for Solana.

---

## 2. TX_TYPE Inference

`UniversalGatewayPC` infers tx type from `amount` and `payload.length`:

| `amount` | `payload` | TX_TYPE |
| --- | --- | --- |
| `> 0` | empty | `FUNDS` |
| `> 0` | non-empty | `FUNDS_AND_PAYLOAD` |
| `== 0` | non-empty | `GAS_AND_PAYLOAD` |
| `== 0` | empty | revert `InvalidInput` |

### SDK rule

- Use **empty payload** for simple withdraws (`FUNDS`).
- Use non-empty payload only for execute routes.

---

## 3. Field-by-Field Guidance

### `target` (bytes)

- Required by `_validateCommon`.
- For Solana:
  - `FUNDS`: recipient wallet pubkey bytes (32 bytes).
  - `FUNDS_AND_PAYLOAD` / `GAS_AND_PAYLOAD`: target program pubkey bytes (32 bytes).
- For execute flows, keep `req.target` aligned with decoded payload `targetProgram`.

### `token` (address)

- PRC20 token on Push Chain representing the Solana-side asset route.
- Must not be `address(0)`.

### `amount` (uint256)

- `> 0`: token burn occurs.
- `0`: payload-only execution path (no burn).

### `gasLimit` (uint256)

- `0` => uses `BASE_GAS_LIMIT` from `UniversalCore`.
- Non-zero => explicit quote input.

### `payload` (bytes)

- Empty for `FUNDS`.
- Non-empty for `FUNDS_AND_PAYLOAD` and `GAS_AND_PAYLOAD`.
- For Solana execute flows, payload uses the binary format in section 4.

### `revertRecipient` (address)

- Must not be `address(0)`.
- Push Chain recipient for revert flows.

---

## 4. Solana Execute Payload Format (non-empty payload only)

Used when `payload.length > 0`:

```text
[accounts_len: 4 bytes, u32 BE]
[account_0: 33 bytes = 32 pubkey + 1 writable_flag]
...
[ix_data_len: 4 bytes, u32 BE]
[ix_data: variable]
[rent_fee: 8 bytes, u64 BE]
[instruction_id: 1 byte]
[target_program: 32 bytes]
```

Notes:

- This is the format in `contracts/svm-gateway/app/execute-payload.ts`.
- For SDK outbound execute flows, use `instruction_id = 2`.
- `target_program` must match `req.target` for Solana execute requests.

Reference helper (existing in repo):

- `encodeExecutePayload()` in `contracts/svm-gateway/app/execute-payload.ts`

---

## 5. Validation and Event Expectations

### On-chain validations

- `req.target.length > 0`
- `req.token != address(0)`
- `req.revertRecipient != address(0)`
- `!(req.amount == 0 && req.payload.length == 0)`

### Token movements

- Gas fee transfer always happens.
- Burn only happens when `req.amount > 0`.

### Event emitted

```solidity
event UniversalTxOutbound(
    bytes32 indexed txID,
    address indexed sender,
    string chainNamespace,
    address indexed token,
    bytes target,
    uint256 amount,
    address gasToken,
    uint256 gasFee,
    uint256 gasLimit,
    bytes payload,
    uint256 protocolFee,
    address revertRecipient,
    TX_TYPE txType
);
```

`txID` derivation:

```solidity
keccak256(abi.encode(
    sender,
    req.token,
    req.amount,
    keccak256(req.payload),
    chainNamespace,
    nonce
));
```

---

## 6. SDK Examples

### 6.1 FUNDS (withdraw only)

```ts
import { PublicKey } from "@solana/web3.js";
import { ethers } from "ethers";

const recipient = new PublicKey("Recipient11111111111111111111111111111111111");

const req = {
  target: ethers.hexlify(recipient.toBytes()), // 32-byte Solana recipient
  token: PRC20_SOL_ADDRESS,
  amount: 1_000_000_000n,
  gasLimit: 0n,
  payload: "0x", // MUST be empty for FUNDS
  revertRecipient: userPushAddress,
};

await gatewayPC.sendUniversalTxOutbound(req);
// inferred txType: FUNDS
```

### 6.2 FUNDS_AND_PAYLOAD (burn + execute)

```ts
import { PublicKey } from "@solana/web3.js";
import { ethers } from "ethers";
import { encodeExecutePayload } from "../app/execute-payload";

const targetProgram = new PublicKey("Counter111111111111111111111111111111111111");

const payload = encodeExecutePayload({
  instructionId: 2,
  targetProgram,
  accounts: [{ pubkey: SOME_PDA, isWritable: true }],
  ixData: someIxData,
  rentFee: 0n,
});

const req = {
  target: ethers.hexlify(targetProgram.toBytes()), // keep aligned with payload.targetProgram
  token: PRC20_SOL_ADDRESS,
  amount: 500_000_000n,
  gasLimit: 200_000n,
  payload: ethers.hexlify(payload),
  revertRecipient: userPushAddress,
};

await gatewayPC.sendUniversalTxOutbound(req);
// inferred txType: FUNDS_AND_PAYLOAD
```

### 6.3 GAS_AND_PAYLOAD (execute only)

```ts
const req = {
  target: ethers.hexlify(targetProgram.toBytes()),
  token: PRC20_SOL_ADDRESS,
  amount: 0n,
  gasLimit: 200_000n,
  payload: ethers.hexlify(payload), // non-empty
  revertRecipient: userPushAddress,
};

await gatewayPC.sendUniversalTxOutbound(req);
// inferred txType: GAS_AND_PAYLOAD
```

---

## 7. Pre-Handoff Checklist for SDK

1. For FUNDS, send `payload = 0x` (empty).
2. Always populate non-empty `target`.
3. For Solana execute flows, set `target` to 32-byte target program pubkey and keep it equal to payload `targetProgram`.
4. Ensure `token` and `revertRecipient` are non-zero addresses.
5. Approve gas token spend before calling.
6. If `amount > 0`, approve `token` spend for burn.

---

## Related Docs

- Solana relayer/backend flow: `contracts/svm-gateway/INTEGRATION_GUIDE.md`
- Push Chain outbound contract: `contracts/evm-gateway/src/UniversalGatewayPC.sol`
- Shared types: `contracts/evm-gateway/src/libraries/Types.sol`
