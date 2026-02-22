## Universal Gateway

The Universal Gateway is the on-chain entrypoint for bridging funds and executing payloads from EVM chains into Push Chain. It supports fee-abstraction (gas funded in native or arbitrary ERC-20) and universal transaction routes (movement of high-value funds with or without payload), with strong safety guarantees (oracle checks, rate limits, pausability, and role-gated withdrawals).

This package contains the core `src/UniversalGateway.sol` implementation, its public `src/interfaces/IUniversalGateway.sol`, and a comprehensive Foundry test suite under `test/`.

## Table of Contents

- Overview
- Architecture and Roles
- Transaction Routes
- Events and Types
- Safety and Rate Limits
- Oracle Integration
- Uniswap v3 Integration
- Public API (Interface)
- Admin and Operations
- Testing and Coverage
- Local Development
- Deployment and Verification
- Security Notes

## Overview

The gateway exposes a single entry point `sendUniversalTx` (and its CEA variant `sendUniversalTxFromCEA`) that automatically infers the transaction type from the request structure. All successful deposits emit a single unified event: `UniversalTx`.

Transaction types (inferred automatically — never set explicitly by callers):

| TX_TYPE | Condition | Route |
|---------|-----------|-------|
| `GAS` | No payload, no funds, `msg.value > 0` | Instant (low confirmations) |
| `GAS_AND_PAYLOAD` | Payload present, no funds | Instant |
| `FUNDS` | Funds present, no payload | Standard (high confirmations) |
| `FUNDS_AND_PAYLOAD` | Funds present, payload present | Standard |

## Architecture and Roles

`UniversalGateway` is an upgradeable, access-controlled contract built on:

- OpenZeppelin upgradeable base contracts: `Initializable`, `ContextUpgradeable`, `PausableUpgradeable`, `ReentrancyGuardUpgradeable`, `AccessControlUpgradeable`
- Roles:
  - `DEFAULT_ADMIN_ROLE`: full administrative control
  - `PAUSER_ROLE`: can pause/unpause
  - `TSS_ROLE`: Push Chain TSS authority; only TSS can revert-withdraw
  - `VAULT_ROLE`: granted to the `Vault` contract; required to call `revertUniversalTxToken`

Key storage:
- `TSS_ADDRESS`: current TSS address
- `VAULT`: Vault contract address
- `CEA_FACTORY`: CEAFactory address for CEA identity validation
- USD caps for gas route: `MIN_CAP_UNIVERSAL_TX_USD`, `MAX_CAP_UNIVERSAL_TX_USD`
- Per-block USD budget: `BLOCK_USD_CAP`
- Per-token epoch limits: `tokenToLimitThreshold[token]` with usage in `_usage[token]`
- Uniswap v3: `WETH`, `uniV3Router`, `uniV3Factory`, `v3FeeOrder`, `defaultSwapDeadlineSec`
- Chainlink: `ethUsdFeed`, `chainlinkEthUsdDecimals`, `chainlinkStalePeriod`, `l2SequencerFeed`, `l2SequencerGracePeriodSec`

## Transaction Routes

### Entry Points

```solidity
// Native gas payment
function sendUniversalTx(UniversalTxRequest calldata req) external payable;

// ERC-20 gas payment (swapped to native via Uniswap v3)
function sendUniversalTx(UniversalTokenTxRequest calldata reqToken) external payable;

// CEA-originated transaction (CEA contracts only)
function sendUniversalTxFromCEA(UniversalTxRequest calldata req) external payable;
```

### Instant Route (GAS / GAS_AND_PAYLOAD)

For quick funding or payload execution with lower block confirmation requirements.

- USD cap range enforced per transaction: `_checkUSDCaps`
- Optional per-block USD budget enforced: `_checkBlockUSDCap`
- Native ETH forwarded to `TSS_ADDRESS`
- Emits `UniversalTx`

### Standard Route (FUNDS / FUNDS_AND_PAYLOAD)

For moving high-value funds with or without payload.

- Per-token epoch rate-limits enforced: `_consumeRateLimit(token, amount)`
- Native ETH forwarded to `TSS_ADDRESS`; ERC-20 transferred to `VAULT`
- Batching supported: `FUNDS_AND_PAYLOAD` can include a gas top-up in the same call
- Emits `UniversalTx` (one event per leg when batching)

### CEA Route (`sendUniversalTxFromCEA`)

Called by CEA contracts to send transactions to their mapped UEA on Push Chain.

- Validates caller is a registered CEA via `CEAFactory.isCEA()`
- Resolves mapped UEA via `CEAFactory.getUEAForCEA()`, enforces `req.recipient == mappedUEA`
- Supports all four TX_TYPEs; emits events with `fromCEA=true` and `recipient=mappedUEA`

## Events and Types

From `IUniversalGateway.sol`:

```solidity
event UniversalTx(
    address indexed sender,
    address indexed recipient,  // address(0) = attribute to sender's UEA
    address token,
    uint256 amount,
    bytes payload,
    address revertRecipient,
    TX_TYPE txType,
    bytes signatureData,
    bool fromCEA
);

event RevertUniversalTx(
    bytes32 indexed txId,
    bytes32 indexed universalTxId,
    address indexed to,
    address token,
    uint256 amount,
    RevertInstructions revertInstruction
);

event VaultUpdated(address indexed oldVault, address indexed newVault);
event CapsUpdated(uint256 minCapUsd, uint256 maxCapUsd);
event EpochDurationUpdated(uint256 oldDuration, uint256 newDuration);
event TokenLimitThresholdUpdated(address indexed token, uint256 newThreshold);
```

Core structs and enums in `src/libraries/Types.sol`:
- `TX_TYPE`: `GAS`, `GAS_AND_PAYLOAD`, `FUNDS`, `FUNDS_AND_PAYLOAD`
- `RevertInstructions { address revertRecipient; bytes revertMsg; }`
- `UniversalTxRequest { address recipient; address token; uint256 amount; bytes payload; address revertRecipient; bytes signatureData; }`
- `EpochUsage { uint64 epoch; uint192 used; }`

## Safety and Rate Limits

All USD values are scaled to 1e18 (USD with 18 decimals).

### Instant Route (GAS / GAS_AND_PAYLOAD)

- **Per-transaction USD cap range**: `_checkUSDCaps(amountWei)` using Chainlink price. Bounds (inclusive): `MIN_CAP_UNIVERSAL_TX_USD` and `MAX_CAP_UNIVERSAL_TX_USD`.
- **Per-block USD budget** (optional): `_checkBlockUSDCap(amountWei)`. Configured by `BLOCK_USD_CAP`. Set to 0 to disable. Resets automatically each block.

### Standard Route (FUNDS / FUNDS_AND_PAYLOAD)

- **Epoch-based per-token rate limiting**: `_consumeRateLimit(token, amount)`. Thresholds in `tokenToLimitThreshold[token]` (natural units; 0 = unsupported). Epoch index: `uint64(block.timestamp / epochDurationSec)`. Usage resets on epoch rollover. Read current usage via `currentTokenUsage(token)`.

### Additional Safety

- Pausable: all deposit paths gated by `whenNotPaused`
- Reentrancy: all entry points are `nonReentrant`
- CEA blocking: `sendUniversalTx` reverts if called by a registered CEA

## Oracle Integration

`getEthUsdPrice()` reads the Chainlink ETH/USD feed and returns USD(1e18) per 1 ETH. Safety checks:
- Positive price
- `answeredInRound >= roundId`
- Freshness check vs. `chainlinkStalePeriod`
- Optional L2 sequencer uptime + grace window enforcement

`quoteEthAmountInUsd1e18(amountWei)` converts wei to USD(1e18) using the current price.

## Uniswap v3 Integration

`swapToNative(tokenIn, amountIn, amountOutMinETH, deadline)`:
- If `tokenIn == WETH`: unwraps directly to native
- Otherwise: finds a direct `tokenIn/WETH` pool across `v3FeeOrder` fee tiers and calls `exactInputSingle`
- Enforces `amountOutMinETH` post-unwrap as slippage bound

Helper: `_findV3PoolWithNative(tokenIn)` scans configured fee tiers and returns the first existing pool with WETH.

## Public API (Interface)

See `src/interfaces/IUniversalGateway.sol` for the complete specification.

Key functions:
- `sendUniversalTx(UniversalTxRequest)` — native gas
- `sendUniversalTx(UniversalTokenTxRequest)` — ERC-20 gas (swap to native)
- `sendUniversalTxFromCEA(UniversalTxRequest)` — CEA-originated
- `revertUniversalTxToken(txId, universalTxId, token, amount, revertCFG)` — ERC-20 revert (Vault only)
- `revertUniversalTx(txId, universalTxId, amount, revertCFG)` — native revert (TSS only)
- `isSupportedToken(token)` — token support check
- `getMinMaxValueForNative()` — current min/max native amounts
- `currentTokenUsage(token)` — epoch usage query

## Admin and Operations

Administrative setters (all `onlyRole(DEFAULT_ADMIN_ROLE)` unless noted):

- Pausing: `pause()` / `unpause()` — `DEFAULT_ADMIN_ROLE`
- TSS: `setTSS(address)`
- Vault: `setVault(address)` — requires `whenPaused`
- CEAFactory: `setCEAFactory(address)`
- Caps: `setCapsUSD(min, max)`; block budget: `setBlockUsdCap(cap1e18)`
- Uniswap: `setRouters(factory, router)`, `setV3FeeOrder(a, b, c)`, `setDefaultSwapDeadline(sec)`
- Chainlink: `setEthUsdFeed(addr)`, `setChainlinkStalePeriod(sec)`, `setL2SequencerFeed(addr)`, `setL2SequencerGracePeriod(sec)`
- Rate limits: `setTokenLimitThresholds(tokens[], thresholds[])`, `updateEpochDuration(sec)`

Revert paths (role-gated):
- `revertUniversalTxToken(...)` — `VAULT_ROLE`
- `revertUniversalTx(...)` — `TSS_ROLE`

## Testing and Coverage

Foundry test suites under `test/`:

| File | Coverage |
|------|----------|
| `test/gateway/1_adminActions.t.sol` | Admin setters, role checks |
| `test/gateway/2-9_sendUniversalTx*.t.sol` | All TX_TYPE routing paths |
| `test/gateway/10_withdrawTokens.t.sol` | Revert/refund paths |
| `test/gateway/12_rateLimit_BlockBased.t.sol` | Per-block USD cap |
| `test/gateway/13_rateLimit_EpochBased.t.sol` | Epoch rate limits |
| `test/gateway/14_gatewayPC.t.sol` | UniversalGatewayPC (Push Chain side) |
| `test/gateway/15_sendUniversalTxViaCEA.t.sol` | CEA route (`sendUniversalTxFromCEA`) |
| `test/vault/Vault.t.sol` | Vault finalization, CEA deployment |
| `test/vault/VaultWithdrawal.t.sol` | Vault withdrawal paths |
| `test/vault/VaultPC.t.sol` | VaultPC (Push Chain side) |
| `test/oracle/OracleTest.t.sol` | Oracle price feed, sequencer checks |

Run tests:
```bash
forge test -vv
```

Coverage:
```bash
forge coverage --ir-minimum
```

Gas report:
```bash
forge test --gas-report
```

## Local Development

Prerequisites: Foundry (`forge`, `cast`)

Build:
```bash
forge build
```

## Deployment and Verification

See `script/` and `script/DeployCommands.md` for example commands.

Deploy proxy + implementation (Sepolia):
```bash
forge script script/1_DeployGatewayWithProxy.sol:DeployGatewayWithProxy \
  --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
```

Upgrade:
```bash
forge script script/3_UpgradeGatewayNewImpl.sol:UpgradeGatewayNewImpl \
  --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
```

## Security Notes

- Only `TSS_ROLE` may trigger native reverts; only `VAULT_ROLE` may trigger ERC-20 reverts
- CEA contracts cannot call `sendUniversalTx` directly — must use `sendUniversalTxFromCEA`
- All deposit paths are `nonReentrant` and pausable
- Oracle and swap safety checks enforced on all gas-route paths
- Rate-limit and per-block budget controls protect instant routes

## License

MIT
