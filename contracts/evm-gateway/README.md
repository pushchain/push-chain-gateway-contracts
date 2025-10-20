## Universal Gateway

The Universal Gateway is the on-chain entrypoint for bridging funds and executing payloads from EVM chains into Push Chain. It supports both fee-abstraction (gas funded in native or arbitrary ERC-20) and universal transaction routes (movement of high-value funds with or without payload), with strong safety guarantees (oracle checks, rate limits, pausability, and role-gated withdrawals).

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

The gateway exposes two categories of routes:

- Fee Abstraction Route
  - `sendTxWithGas(payload, revertInstruction, signatureData)` (native ETH)
  - `sendTxWithGas(tokenIn, amountIn, payload, revertInstruction, amountOutMinETH, deadline, signatureData)` (gas paid in arbitrary ERC-20 → swapped to native)
- Universal Transaction Route
  - `sendFunds(recipient, bridgeToken, bridgeAmount, revertInstruction)`
  - `sendTxWithFunds(bridgeToken, bridgeAmount, payload, revertInstruction, signatureData)` (gas in native)
  - `sendTxWithFunds(bridgeToken, bridgeAmount, gasToken, gasAmount, amountOutMinETH, deadline, payload, revertInstruction, signatureData)` (gas paid in ERC-20)

All successful deposits emit a single, unified event: `UniversalTx`.

## Architecture and Roles

`UniversalGateway` is an upgradeable, access-controlled contract composed of:

- OpenZeppelin upgradeable base contracts: `Initializable`, `ContextUpgradeable`, `PausableUpgradeable`, `ReentrancyGuardUpgradeable`, `AccessControlUpgradeable`.
- Roles
  - `DEFAULT_ADMIN_ROLE`: admin for all config
  - `PAUSER_ROLE`: can pause/unpause
  - `TSS_ROLE`: Push Chain TSS authority; only TSS can withdraw or revert-withdraw

Key storage:
- `TSS_ADDRESS`: current TSS address
- USD caps for fee-abstraction gas route: `MIN_CAP_UNIVERSAL_TX_USD`, `MAX_CAP_UNIVERSAL_TX_USD`
- Per-block USD budget for gas route: `BLOCK_USD_CAP`
- Per-token epoch limits: `tokenToLimitThreshold[token]` with usage tracked in `_usage[token]`
- Uniswap v3 config: `WETH`, `uniV3Router`, `uniV3Factory`, `v3FeeOrder`, `defaultSwapDeadlineSec`
- Chainlink config: `ethUsdFeed`, `chainlinkEthUsdDecimals`, `chainlinkStalePeriod`, `l2SequencerFeed`, `l2SequencerGracePeriodSec`

## Transaction Routes

### Fee Abstraction Route

For quick funding or payload execution that can finalize with lower block confirmations. Strict USD caps enforced on the gas leg.

- Native ETH gas:
  - `sendTxWithGas(payload, revertInstruction, signatureData)` (payable)
- ERC-20 gas (swap to native via Uniswap v3):
  - `sendTxWithGas(tokenIn, amountIn, payload, revertInstruction, amountOutMinETH, deadline, signatureData)`

Both paths internally call `_sendTxWithGas(...)`, perform USD cap checks (`_checkUSDCaps`), optional per-block budget (`_checkBlockUSDCap`), forward native to `TSS_ADDRESS`, and emit `UniversalTx`.

### Universal Transaction Route

For moving high-value funds (with or without payload). No strict USD caps; uses per-token epoch rate-limits.

- Funds only (to arbitrary recipient):
  - `sendFunds(recipient, bridgeToken, bridgeAmount, revertInstruction)`
- Funds + payload to user’s UEA (recipient implicit = 0):
  - `sendTxWithFunds(bridgeToken, bridgeAmount, payload, revertInstruction, signatureData)` (gas in native)
  - `sendTxWithFunds(bridgeToken, bridgeAmount, gasToken, gasAmount, amountOutMinETH, deadline, payload, revertInstruction, signatureData)` (gas paid in ERC-20)

All paths call `_sendTxWithFunds(...)` and emit `UniversalTx`.

## Events and Types

From `IUniversalGateway.sol`:

- `event UniversalTx(address indexed sender, address indexed recipient, address token, uint256 amount, bytes payload, RevertInstructions revertInstruction, TX_TYPE txType, bytes signatureData)`
- `event WithdrawFunds(address indexed recipient, uint256 amount, address tokenAddress)`
- `event CapsUpdated(uint256 minCapUsd, uint256 maxCapUsd)`
- `event EpochDurationUpdated(uint256 oldDuration, uint256 newDuration)`
- `event TokenLimitThresholdUpdated(address indexed token, uint256 newThreshold)`

Core structs and enums in `src/libraries/Types.sol`:
- `TX_TYPE`: `GAS`, `GAS_AND_PAYLOAD`, `FUNDS`, `FUNDS_AND_PAYLOAD`
- `RevertInstructions { address fundRecipient; bytes revertContext; }`
- `UniversalPayload { to, value, data, gasLimit, maxFeePerGas, maxPriorityFeePerGas, nonce, deadline, vType }`
- `EpochUsage { uint64 epoch; uint192 used; }`

## Safety and Rate Limits

Rate limiting protects the protocol across both routes. All USD values below are scaled to 1e18 (USD with 18 decimals).

### Fee Abstraction Route (Instant / Low Confirmations)

- Transaction-level USD cap range
  - Enforced by `_checkUSDCaps(amountWei)` using Chainlink price via `quoteEthAmountInUsd1e18(amountWei)`.
  - Configured bounds (inclusive): `MIN_CAP_UNIVERSAL_TX_USD` and `MAX_CAP_UNIVERSAL_TX_USD`.
  - Applies to the gas leg for both native and ERC-20 gas flows (after swap-to-native).

- Per-block USD budget (optional)
  - Enforced by `_checkBlockUSDCap(amountWei)`.
  - Configured by `BLOCK_USD_CAP` (USD 1e18). When set to 0, feature is disabled.
  - Tracks the total USD consumed in the current block; resets automatically on new blocks.

- Where applied
  - Both overloads of `sendTxWithGas(...)` call internal `_sendTxWithGas(...)`, which performs:
    - `_checkUSDCaps`, `_checkBlockUSDCap`, `_handleNativeDeposit`, then emits `UniversalTx`.

### Universal Transaction Route (Standard Confirmations)

- Epoch-based per-token rate limiting
  - Enforced by `_consumeRateLimit(token, amount)`.
  - Thresholds configured in `tokenToLimitThreshold[token]` (natural token units). A value of 0 means the token is unsupported.
  - Epoch length configured by `epochDurationSec`. Epoch index is `uint64(block.timestamp / epochDurationSec)`.
  - Usage state tracked in `EpochUsage { uint64 epoch; uint192 used; }` and resets on epoch rollover (no carryover).
  - Read current usage via `currentTokenUsage(token) -> (used, remaining)`.

- Where applied
  - `sendFunds` and both `sendTxWithFunds` overloads call `_consumeRateLimit(...)` on the relevant bridge token (and native for funds when applicable) before depositing.
  - After limits are consumed, `_handleTokenDeposit` or `_handleNativeDeposit` is invoked, followed by `_sendTxWithFunds(...)` which emits `UniversalTx`.

### Admin configuration (summarized)

- Fee abstraction caps: `setCapsUSD(minCapUsd, maxCapUsd)`
- Per-block budget: `setBlockUsdCap(cap1e18)`
- Per-token epoch thresholds: `setTokenLimitThresholds(tokens[], thresholds[])`, `updateTokenLimitThreshold(tokens[], thresholds[])`
- Epoch duration: `updateEpochDuration(newDurationSec)`

### Additional Safety

- Pausable: critical functions gated by `whenNotPaused`.
- Reentrancy: deposit/withdraw paths are `nonReentrant`.

## Oracle Integration

`getEthUsdPrice()` reads Chainlink’s ETH/USD feed and returns USD(1e18) per 1 ETH. Safety checks include:
- positive price
- `answeredInRound >= roundId`
- freshness vs. `chainlinkStalePeriod`
- optional L2 sequencer uptime + grace window enforcement

`quoteEthAmountInUsd1e18(amountWei)` converts wei to USD(1e18) using current price.

## Uniswap v3 Integration

`swapToNative(tokenIn, amountIn, amountOutMinETH, deadline)`:
- If `tokenIn == WETH`, unwraps to native
- Otherwise, finds a direct `tokenIn/WETH` pool across `v3FeeOrder` and calls `exactInputSingle`
- Enforces `amountOutMinETH` post-unwrap

Helper: `_findV3PoolWithNative(tokenIn)` scans configured fee tiers and returns the first existing pool with WETH.

## Public API (Interface)

See `src/interfaces/IUniversalGateway.sol` for the complete specification of:
- Events
- Fee Abstraction functions: two `sendTxWithGas` overloads
- Universal Transaction functions: `sendFunds`, and two `sendTxWithFunds` overloads
- Withdrawals: `withdrawFunds`, `revertWithdrawFunds`

## Admin and Operations

Administrative setters (all `onlyRole(DEFAULT_ADMIN_ROLE)` and `whenNotPaused` unless noted):

- Pausing: `pause()` / `unpause()` (`PAUSER_ROLE`)
- TSS: `setTSS(address)`
- Caps: `setCapsUSD(min, max)`; block budget: `setBlockUsdCap(cap1e18)`
- Uniswap: `setRouters(factory, router)`, `setV3FeeOrder(a, b, c)`, `setDefaultSwapDeadline(deadlineSec)`
- Chainlink: `setEthUsdFeed(addr)`, `setChainlinkStalePeriod(sec)`, `setL2SequencerFeed(addr)`, `setL2SequencerGracePeriod(sec)`
- Rate limits: `setTokenLimitThresholds(tokens[], thresholds[])`, `updateTokenLimitThreshold(tokens[], thresholds[])`, `updateEpochDuration(sec)`

Withdrawals (TSS only):
- `withdrawFunds(recipient, token, amount)`
- `revertWithdrawFunds(token, amount, revertInstruction)`

## Testing and Coverage

Foundry test suites are under `test/`:
- `test/gateway/` — admin setters, native and ERC-20 deposit flows, TSS-only functions
- `test/oracle/` — oracle sanity, staleness, receive/fallback behavior

Run tests:
```bash
forge test -vv
```

Coverage (works around stack issues with IR modes):
```bash
forge coverage --ir-minimum
```

## Local Development

Prerequisites:
- Foundry (forge/cast)

Install dependencies (managed via `foundry.toml` remappings and included libs in `lib/`):
```bash
forge build
```

Useful targets:
```bash
forge test -vv
forge coverage --ir-minimum
```

## Deployment and Verification

See `script/` and `script/DeployCommands.md` for example commands. Example (Sepolia):

Deploy (proxy + implementation + admin via script):
```bash
forge script script/1_DeployGatewayWithProxy.sol:DeployGatewayWithProxy \
  --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
```

Upgrade:
```bash
forge script script/3_UpgradeGatewayNewImpl.sol:UpgradeGatewayNewImpl \
  --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
```

Verification examples are listed in `script/DeployCommands.md`.

## Security Notes

- Only `TSS_ROLE` may withdraw or revert-withdraw
- All deposit paths are non-reentrant and paused when needed
- Oracle and swap safety checks are enforced
- Rate-limit and budget controls protect fee-abstraction paths

## License

MIT
