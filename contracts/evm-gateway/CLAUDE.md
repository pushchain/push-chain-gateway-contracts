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
- **`Vault.sol` / `VaultPC.sol`**: Fund management contracts

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

### Directory Structure

```
src/
├── UniversalGateway.sol           # Main gateway implementation
├── UniversalGatewayV0.sol         # Legacy version
├── UniversalGatewayPC.sol         # Push Chain side
├── Vault.sol / VaultPC.sol        # Vault contracts
├── interfaces/                     # All contract interfaces
│   ├── IUniversalGateway.sol      # Main gateway interface
│   ├── IUniversalGatewayV0.sol
│   ├── IUniversalGatewayPC.sol
│   ├── IVault.sol / IVaultPC.sol
│   └── IWETH.sol, ISwapRouterSepolia.sol, etc.
└── libraries/
    ├── Types.sol                   # Core enums and structs (TX_TYPE, RevertInstructions, UniversalPayload, etc.)
    ├── TypesV0.sol                 # Legacy types
    └── Errors.sol                  # Custom error definitions

test/
├── BaseTest.t.sol                  # Abstract base test with setup, mocks, and helpers
├── gateway/                        # Main test suite (15+ test files)
│   ├── 1_adminActions.t.sol       # Admin setter tests
│   ├── 2-9_sendUniversalTx*.t.sol # Transaction routing tests
│   ├── 10_withdrawTokens.t.sol    # TSS withdrawal tests
│   ├── 11_executeUniversalTx.t.sol # Execution tests
│   ├── 12_rateLimit_BlockBased.t.sol # Block-based rate limit tests
│   ├── 13_rateLimit_EpochBased.t.sol # Epoch-based rate limit tests
│   └── 14_gatewayPC.t.sol         # Push Chain gateway tests
├── oracle/                         # Oracle integration tests
├── vault/                          # Vault tests
└── mocks/                          # Mock contracts (MockERC20, MockAggregatorV3, etc.)

script/
├── 1_DeployGatewayWithProxy.sol    # Deploy proxy + implementation + admin
├── 2_DeployGatewayImpl.sol         # Deploy new implementation only
├── 3_UpgradeGatewayNewImpl.sol     # Upgrade to new implementation
└── DeployCommands.md               # Deployment and verification command reference

docs/
├── 1_PUSH_CHAIN.md                 # Push Chain overview
├── 2_UniversalGateway.md           # Gateway architecture and design
├── 3_UniversalGatewayPC.md         # Push Chain side gateway
└── 4_OutboundTx_Flows.md           # Outbound transaction flows
```

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
