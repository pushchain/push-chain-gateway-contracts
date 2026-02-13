# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Universal Gateway** for Push Chain - A Solidity smart contract system that acts as the inbound entry point for bridging funds and executing payloads from external EVM chains to Push Chain. The gateway supports fee abstraction (gas paid in native or arbitrary ERC-20), universal transaction routing, and enforces strong safety guarantees through oracle price feeds, rate limits, pausability, and role-gated withdrawals.

## Build and Test Commands

### Building
```bash
forge build
```

### Testing
```bash
# Run all tests with verbosity
forge test -vv

# Run specific test file
forge test --match-path test/gateway/1_adminActions.t.sol -vv

# Run specific test function
forge test --match-test testFunctionName -vv

# Run with maximum verbosity (trace)
forge test -vvvv
```

### Coverage
```bash
# Generate coverage report (uses --ir-minimum to work around stack issues with IR modes)
forge coverage --ir-minimum
```

### Gas Reports
```bash
# Run tests with gas reporting
forge test --gas-report
```

### Deployment
```bash
# Deploy gateway with proxy (requires .env with SEPOLIA_RPC_URL and KEY)
forge script script/1_DeployGatewayWithProxy.sol:DeployGatewayWithProxy \
  --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast

# Upgrade gateway implementation
forge script script/3_UpgradeGatewayNewImpl.sol:UpgradeGatewayNewImpl \
  --rpc-url $SEPOLIA_RPC_URL --private-key $KEY --broadcast
```

### Contract Verification
```bash
# Verify TransparentUpgradeableProxy
forge verify-contract --chain sepolia \
  --constructor-args $(cast abi-encode "constructor(address,address,bytes)" <IMPL_ADDR> <ADMIN_ADDR> 0x) \
  <PROXY_ADDR> lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy

# Verify Gateway Implementation
forge verify-contract --chain sepolia \
  --constructor-args $(cast abi-encode "constructor()") \
  <IMPL_ADDR> src/UniversalGatewayV0.sol:UniversalGatewayV0

# Verify ProxyAdmin
forge verify-contract --chain sepolia \
  --constructor-args $(cast abi-encode "constructor(address)" <DEPLOYER_ADDR>) \
  <ADMIN_ADDR> lib/openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol:ProxyAdmin
```

## Architecture

### Core Contracts

- **`UniversalGateway.sol`**: Main gateway contract (latest version) - handles transaction routing, rate limiting, oracle integration, and Uniswap v3 swaps
- **`UniversalGatewayV0.sol`**: Legacy gateway version
- **`UniversalGatewayPC.sol`**: Push Chain-side gateway for outbound transactions
- **`Vault.sol`**: Outbound token custody contract on external EVM chains - manages TSS-controlled withdrawals and executions via CEA contracts
- **`VaultPC.sol`**: Push Chain-side vault contract

## Vault Architecture - CEA Execution Model

**Vault.sol** is deployed on external EVM chains (Ethereum, Base, Arbitrum, etc.) and serves as the token custody contract for outbound flows from Push Chain. It is exclusively controlled by the Push Chain TSS (Threshold Signature Scheme) authority.

### Core Design Principles

1. **CEA-Based Execution**: All operations route through deterministic Chain Execution Account (CEA) contracts
2. **TSS Authority**: Only TSS_ROLE can trigger withdrawals and executions
3. **Unified Execution Path**: Single `executeUniversalTx` function handles both withdrawals (empty payload) and executions (multicall payload)
4. **Token Gating**: Token support is validated via `UniversalGateway.isSupportedToken()` as a single source of truth
5. **Deterministic CEA Deployment**: CEAFactory uses CREATE2 for predictable CEA addresses per UEA (Universal Execution Account)

### CEA (Chain Execution Account) Model

**What is a CEA?**
- A CEA is a smart contract wallet deployed deterministically for each UEA (user's account on Push Chain)
- Acts as the execution context for all user operations on the external chain
- One-to-one mapping: `UEA (Push Chain) ↔ CEA (External Chain)`
- Deployed via CREATE2 using `CEAFactory.deployCEA(originCaller)`

**CEA Execution Flow**:

```
User UEA on Push Chain → TSS signs → Vault.executeUniversalTx() → CEA.executeUniversalTx() → Multicall execution
```

**Key Functions**:
- `getCEAForUEA(uea)`: Returns (ceaAddress, isDeployed) - predictable even before deployment
- `deployCEA(uea)`: Deploys CEA if not already deployed (idempotent, reverts if already exists)

### Multicall Payload Structure

All operations use a **multicall payload** (`abi.encode(Multicall[])`):

```solidity
struct Multicall {
    address to;      // Target contract address
    uint256 value;   // Native token amount to send with call
    bytes data;      // Call data to execute
}
```

**Examples**:
- **Withdrawal (empty payload)**: `bytes("")` → CEA receives funds, no execution
- **Single call**: `abi.encode([Multicall(target, value, data)])`
- **Multi-step execution**: `abi.encode([call1, call2, call3])`

### Vault Operations

#### 1. executeUniversalTx (Main Entry Point)

**Signature**:
```solidity
function executeUniversalTx(
    bytes32 txID,
    bytes32 universalTxID,
    address originCaller,      // UEA on Push Chain
    address token,             // address(0) for native
    address target,            // kept for backward compatibility (not used for routing)
    uint256 amount,            // amount to fund CEA with
    bytes calldata data        // multicall payload: abi.encode(Multicall[])
) external payable nonReentrant whenNotPaused onlyRole(TSS_ROLE)
```

**Flow** (`Vault.sol:136-154`):
1. Get or deploy CEA for the `originCaller` (UEA)
2. Fund CEA with tokens/native
3. Call `CEA.executeUniversalTx(txID, universalTxID, originCaller, data)`
4. Emit `VaultUniversalTxExecuted` event

**Funding Logic**:
- **ERC20**: Transfer tokens to CEA first, then call `CEA.executeUniversalTx()`
- **Native**: Forward value during `CEA.executeUniversalTx{value: amount}()` call

#### 2. revertUniversalTxToken (Revert/Refund)

**Signature**:
```solidity
function revertUniversalTxToken(
    bytes32 txID,
    bytes32 universalTxID,
    address token,
    uint256 amount,
    RevertInstructions calldata revertInstruction
) external nonReentrant whenNotPaused onlyRole(TSS_ROLE)
```

**Flow** (`Vault.sol:157-174`):
1. Validate token support and amount
2. Transfer tokens from Vault to UniversalGateway
3. Call `gateway.revertUniversalTxToken()` to handle refund logic
4. Emit `VaultUniversalTxReverted` event

**Use Case**: Return funds to users when execution fails or is rejected on Push Chain

### Validation & Safety

**Parameter Validation** (`_validateParams`):
- `originCaller != address(0)`: Valid UEA address
- `target != address(0)`: Valid target (even if not used for routing)
- Token support check via `gateway.isSupportedToken(token)`
- **Token/Value Invariants**:
  - Native flow: `token == address(0)` → `msg.value == amount`
  - ERC20 flow: `token != address(0)` → `msg.value == 0`

**Token Support Enforcement** (`_enforceSupported`):
- All token operations validated against `UniversalGateway.isSupportedToken(token)`
- Single source of truth for supported tokens across Vault and Gateway

**Balance Checks**:
- ERC20 operations verify `IERC20(token).balanceOf(address(this)) >= amount`
- Prevents overdraft or insufficient balance reverts

### Access Control & Roles

**Vault.sol Role System**:

| Role | Permissions | Critical Actions |
|------|-------------|------------------|
| `DEFAULT_ADMIN_ROLE` | Full administrative control | `setGateway()`, `setTSS()`, `sweep()` |
| `TSS_ROLE` | Execute operations | `executeUniversalTx()`, `revertUniversalTxToken()` |
| `PAUSER_ROLE` | Emergency pause | `pause()`, `unpause()` |

**Security Properties**:
- ✅ Only TSS can execute withdrawals and executions
- ✅ Only TSS can trigger reverts
- ✅ Admin can update TSS address (transfers role atomically)
- ✅ Admin can sweep stuck tokens (emergency recovery)
- ✅ Pausable for emergency situations
- ✅ ReentrancyGuard on all external entry points

### Admin Operations

**Update Gateway** (`setGateway`):
- Updates `IUniversalGateway` reference
- Only `DEFAULT_ADMIN_ROLE`
- Emits `GatewayUpdated(old, new)`

**Update TSS** (`setTSS`):
- Revokes `TSS_ROLE` from old TSS
- Grants `TSS_ROLE` to new TSS
- Updates `TSS_ADDRESS` state variable
- Only `DEFAULT_ADMIN_ROLE`
- Emits `TSSUpdated(old, new)`

**Sweep Tokens** (`sweep`):
- Emergency recovery of stuck ERC20 tokens
- Only `DEFAULT_ADMIN_ROLE`
- Does not support native token sweep (use withdrawal operations)

**Pause/Unpause**:
- `pause()`: Halts all operations (only `PAUSER_ROLE`)
- `unpause()`: Resumes operations (only `PAUSER_ROLE`)

### Events

```solidity
event VaultUniversalTxExecuted(
    bytes32 indexed txID,
    bytes32 indexed universalTxID,
    address indexed originCaller,
    address target,
    address token,
    uint256 amount,
    bytes data
);

event VaultUniversalTxReverted(
    bytes32 indexed txID,
    bytes32 indexed universalTxID,
    address indexed token,
    uint256 amount,
    RevertInstructions revertInstruction
);

event GatewayUpdated(address indexed oldGateway, address indexed newGateway);
event TSSUpdated(address indexed oldTSS, address indexed newTSS);
```

### Integration Points

**Vault Dependencies**:
- `IUniversalGateway`: Token support validation and revert handling
- `ICEAFactory`: CEA deployment and address prediction
- `ICEA`: Multicall execution interface

**Related Files**:
- `src/Vault.sol`: Main Vault implementation (241 lines)
- `src/interfaces/IVault.sol`: Vault interface
- `src/interfaces/ICEA.sol`: CEA execution interface
- `src/interfaces/ICEAFactory.sol`: CEA factory interface
- `src/libraries/Types.sol`: Multicall and RevertInstructions structs

### Testing Guidelines

When testing Vault operations:

**CEA Deployment Tests**:
- Verify deterministic CEA addresses via `getCEAForUEA()`
- Test first-time deployment vs. existing CEA
- Ensure idempotency (no double-deployment)

**Execution Tests**:
- Empty payload → funds transfer only (withdrawal)
- Single Multicall → single contract call
- Multiple Multicalls → batched execution
- Native vs. ERC20 funding paths

**Revert Tests**:
- Token revert flow via `revertUniversalTxToken()`
- Gateway integration for refund processing
- Balance validation before transfer

**Access Control Tests**:
- TSS_ROLE exclusivity for executions
- Admin operations (setGateway, setTSS, sweep)
- Pause/unpause functionality

**Security Tests**:
- Reentrancy protection
- Token/value invariant enforcement
- Balance sufficiency checks
- Zero address validations

### Key Components

1. **Transaction Type System** (`src/libraries/Types.sol`)
   - `TX_TYPE.GAS`: Gas-only deposits to fund Universal Execution Accounts (UEAs)
   - `TX_TYPE.GAS_AND_PAYLOAD`: Gas + payload execution (instant route)
   - `TX_TYPE.FUNDS`: High-value fund transfers only
   - `TX_TYPE.FUNDS_AND_PAYLOAD`: High-value funds + payload execution

   **Transaction types are inferred automatically** based on request structure (hasPayload, hasFunds, fundsIsNative, hasNativeValue) - users never explicitly specify TX_TYPE.

2. **Access Control & Roles**
   - `DEFAULT_ADMIN_ROLE`: Full administrative control
   - `PAUSER_ROLE`: Can pause/unpause the gateway
   - `TSS_ROLE`: Push Chain TSS authority - only role that can withdraw or revert-withdraw funds
   - Built on OpenZeppelin's upgradeable contracts: `Initializable`, `ContextUpgradeable`, `PausableUpgradeable`, `ReentrancyGuardUpgradeable`, `AccessControlUpgradeable`

3. **Rate Limiting (Dual System)**

   **A. Instant Transactions (Low Block Confirmation)**
   - Applies to: `TX_TYPE.GAS` and `TX_TYPE.GAS_AND_PAYLOAD`
   - Per-transaction USD caps: `MIN_CAP_UNIVERSAL_TX_USD` to `MAX_CAP_UNIVERSAL_TX_USD` (enforced via `_checkUSDCaps`)
   - Per-block USD budget: `BLOCK_USD_CAP` (enforced via `_checkBlockUSDCap`)
   - Uses Chainlink ETH/USD oracle for USD valuation

   **B. Standard Transactions (High Block Confirmation)**
   - Applies to: `TX_TYPE.FUNDS` and `TX_TYPE.FUNDS_AND_PAYLOAD`
   - Per-token epoch-based rate limits via `tokenToLimitThreshold` mapping
   - Epoch duration controlled by `epochDurationSec`
   - Usage tracked in `EpochUsage` structs that reset on epoch rollover
   - Enforced via `_consumeRateLimit(token, amount)`

4. **Oracle Integration**
   - Chainlink ETH/USD price feed (`ethUsdFeed`)
   - Staleness checks via `chainlinkStalePeriod`
   - L2 sequencer uptime monitoring (`l2SequencerFeed`, `l2SequencerGracePeriodSec`)
   - `getEthUsdPrice()` returns USD per ETH with 1e18 scaling
   - `quoteEthAmountInUsd1e18(amountWei)` converts wei to USD(1e18)

5. **Uniswap v3 Integration**
   - `swapToNative(tokenIn, amountIn, amountOutMinETH, deadline)` for ERC-20 → native gas conversion
   - Supports WETH unwrapping
   - Scans `v3FeeOrder` for optimal direct `tokenIn/WETH` pool
   - Uses `_findV3PoolWithNative(tokenIn)` to locate pools



## Development Patterns

### Testing Patterns

1. **Inherit from `BaseTest`**: All test contracts extend `test/BaseTest.t.sol` which provides:
   - Complete gateway setup with proxy pattern
   - Mock actors (governance, admin, pauser, tss, users, attacker, recipient)
   - Mock tokens (tokenA, usdc, weth)
   - Mock Chainlink oracles (ethUsdFeedMock, sequencerMock)
   - Helper functions for common operations
   - Default configuration constants

2. **Test Organization**: Tests are numbered and grouped by functionality:
   - Admin actions (1_)
   - Transaction routing (2-9_)
   - Withdrawals (10_)
   - Execution (11_)
   - Rate limits (12-13_)
   - Push Chain side (14_)

3. **Fork Testing**: Some tests include fork variants (e.g., `3_sendUniversalTx_token_fork.t.sol`) for testing against mainnet state

### Configuration

The gateway uses Foundry with:
- Solidity 0.8.26
- Optimizer enabled with 99999 runs
- `via_ir = true` (IR-based compilation)
- EVM version: shanghai
- Remappings for OpenZeppelin, Uniswap v3, Chainlink, and forge-std

Key foundry.toml profiles:
- `default`: Standard development (1000 fuzz runs)
- `ci`: CI/CD with increased fuzz runs (2000)
- `coverage`: Coverage reporting with lcov output
- `debug`: Maximum verbosity, optimizer off, FFI enabled
- `gas`: Gas optimization with 10000 optimizer runs
- `fork`: Fork testing configuration

### Security Considerations

1. **Only TSS_ROLE can withdraw**: All fund withdrawals require TSS authority
2. **Non-reentrant**: All deposit/withdraw paths use `nonReentrant`
3. **Pausable**: Critical functions can be paused by `PAUSER_ROLE`
4. **Oracle safety**: Price feeds have staleness checks and L2 sequencer uptime validation
5. **Rate limits**: Dual rate-limit system protects both instant and standard routes
6. **Swap safety**: Uniswap v3 integration enforces slippage protection via `amountOutMinETH`

### Common Development Tasks

When modifying rate limits:
- Update `_checkUSDCaps` or `_checkBlockUSDCap` for instant routes
- Update `_consumeRateLimit` for standard routes
- Test both paths in `test/gateway/12_rateLimit_BlockBased.t.sol` and `13_rateLimit_EpochBased.t.sol`

When adding new transaction routes:
- The gateway infers TX_TYPE automatically - do not require users to specify it
- Ensure proper rate limit application based on route type
- Update `_routeUniversalTx` internal logic if needed
- Add comprehensive tests following the numbered test pattern

When modifying oracle integration:
- Update oracle tests in `test/oracle/`
- Ensure staleness and sequencer uptime checks remain enforced
- Verify USD cap calculations in rate limit tests

When upgrading the gateway:
- Use `script/2_DeployGatewayImpl.sol` to deploy new implementation
- Use `script/3_UpgradeGatewayNewImpl.sol` to upgrade proxy
- Ensure storage layout compatibility (OpenZeppelin upgradeable pattern)
- Run full test suite before and after upgrade

## Key Design Principles

1. **Intent Inference**: Users never specify transaction types explicitly - the gateway infers them from the request structure
2. **Dual Security Model**: Instant routes (low confirmation) have strict USD caps; standard routes (high confirmation) use per-token epoch limits
3. **Unified Interface**: Single entry point (`sendUniversalTx`) handles all transaction types
4. **Deterministic Routing**: Transaction routing is algorithmic and predictable based on fixed rules
5. **Defense in Depth**: Multiple layers of protection (pausability, reentrancy guards, rate limits, oracle checks, role-based access control)

## UniversalGatewayPC - Outbound Transaction Handling

**UniversalGatewayPC** is deployed on Push Chain and handles outbound transactions from Push Chain to external chains. It supports three TX_TYPE values (GAS is not supported on outbound).

### TX_TYPE Inference on Push Chain (`_fetchTxType()`)

The gateway automatically infers TX_TYPE based on the request structure. **Users never specify TX_TYPE explicitly.**

**Inference Logic** (`src/UniversalGatewayPC.sol:141-166`):

```solidity
function _fetchTxType(UniversalOutboundTxRequest calldata req) private pure returns (TX_TYPE)
{
    bool hasPayload = req.payload.length > 0;
    bool hasFunds = req.amount > 0;

    // Case 1: No payload + Funds → FUNDS (funds-only withdrawal)
    if (!hasPayload && hasFunds) {
        return TX_TYPE.FUNDS;
    }

    // Case 2: Payload + Funds → FUNDS_AND_PAYLOAD (funds + execution)
    if (hasPayload && hasFunds) {
        return TX_TYPE.FUNDS_AND_PAYLOAD;
    }

    // Case 3: Payload only (no funds) → GAS_AND_PAYLOAD (execution-only)
    if (hasPayload && !hasFunds) {
        return TX_TYPE.GAS_AND_PAYLOAD;
    }

    // Case 4: No payload + No funds → Invalid (empty transaction)
    revert Errors.InvalidInput();
}
```

### TX_TYPE Decision Matrix

| Payload (`req.payload.length`) | Amount (`req.amount`) | TX_TYPE | Behavior |
|--------------------------------|----------------------|---------|----------|
| Empty (0 bytes) | > 0 | **FUNDS** | Burns tokens, unlocks on origin chain |
| Non-empty | > 0 | **FUNDS_AND_PAYLOAD** | Burns tokens, executes payload on origin chain |
| Non-empty | 0 | **GAS_AND_PAYLOAD** | No burn, executes payload using existing CEA funds |
| Empty (0 bytes) | 0 | **❌ Reverts** | Empty transaction rejected with `InvalidInput` |

### Payload-Only Transaction Support (NEW)

**Key Feature**: Users can send **payload-only transactions** without burning additional tokens.

**Use Case**: Execute payloads on the origin chain using funds already held in the user's CEA (Chain Execution Account), without requiring additional token burns from Push Chain.

### Validation Flow

**Function**: `_validateCommon(req.target, req.token, req.revertRecipient)`


**Note**: Amount validation is intentionally NOT in `_validateCommon()` because it's context-dependent:
- For `FUNDS`: Amount must be > 0
- For `GAS_AND_PAYLOAD`: Amount can be 0 (payload-only execution)

Amount validation happens in `_fetchTxType()` which rejects empty transactions (amount=0 AND no payload).

### Important Implementation Notes

1. **Empty Transaction Rejection**: Transactions with both `amount = 0` AND `payload.length = 0` are rejected by `_fetchTxType()` with `Errors.InvalidInput()`

2. **Conditional Token Burn**: Tokens are only burned when `amount > 0`. For payload-only transactions (GAS_AND_PAYLOAD with amount=0), the burn is skipped entirely.

3. **Gas Fees Always Required**: Even for payload-only transactions, users must pay gas fees via `_moveFees()` to prevent spam/DoS.

4. **Supported TX_TYPEs on Push Chain**:
   - ✅ `TX_TYPE.FUNDS` - Withdraw tokens only
   - ✅ `TX_TYPE.FUNDS_AND_PAYLOAD` - Withdraw + execute
   - ✅ `TX_TYPE.GAS_AND_PAYLOAD` - Execute using existing CEA funds (amount=0)
   - ❌ `TX_TYPE.GAS` - Not supported (inbound only)

### Testing Guidelines

When testing UniversalGatewayPC:

**Payload-Only Tests** (should succeed):
- `req.amount = 0` with `req.payload = abi.encodeWithSignature("function()")`
- Verify `TX_TYPE.GAS_AND_PAYLOAD` is emitted
- Verify no token burn occurs
- Verify gas fees are still collected
- Verify nonce increments

**Empty Transaction Tests** (should revert):
- `req.amount = 0` with `req.payload = bytes("")`
- Expect revert with `Errors.InvalidInput.selector`
- Test in `_fetchTxType()` directly and via `sendUniversalTxOutbound()`

**Standard Transaction Tests**:
- `req.amount > 0` with empty payload → `TX_TYPE.FUNDS`
- `req.amount > 0` with payload → `TX_TYPE.FUNDS_AND_PAYLOAD`

### Related Files

- `src/UniversalGatewayPC.sol:83-119` - `sendUniversalTxOutbound()` main function
- `src/UniversalGatewayPC.sol:141-166` - `_fetchTxType()` inference logic
- `src/UniversalGatewayPC.sol:168-182` - `_validateCommon()` validation
- `test/gateway/14_gatewayPC.t.sol` - Comprehensive test suite (79 tests)
- `test/gateway/9_sendUniversalTxFetchTxType.t.sol` - TX_TYPE inference tests (27 tests)
