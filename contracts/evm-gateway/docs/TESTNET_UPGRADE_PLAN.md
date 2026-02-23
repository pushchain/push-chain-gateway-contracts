# Testnet Upgrade Plan — Vault + UniversalGatewayV0 on Sepolia

## Status Legend
- [ ] Pending
- [x] Complete

---

## Overview

This document is the authoritative step-by-step execution plan for upgrading the Push Chain
gateway system on Ethereum Sepolia testnet. It covers:

1. Vault is already deployed ✅
2. Upgrade the live UniversalGatewayV0 proxy (Upgrade 1 — with `moveFunds_temp`)
3. Register Vault and CEAFactory on the upgraded gateway
4. Migrate USDT held in Gateway → Vault via `moveFunds_temp`
5. Upgrade the proxy again (Upgrade 2 — clean, no `moveFunds_temp`)
6. Etherscan verification of both implementations

---

## Key Addresses (Sepolia, Chain ID 11155111)

| Name                     | Address                                      |
| ------------------------ | -------------------------------------------- |
| UniversalGatewayV0 Proxy | `0x4DCab975cDe839632db6695e2e936A29ce3e325E` |
| Vault Proxy (deployed ✅) | `0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294` |
| Vault Implementation     | `0x2917e434fA9AB956f5e6ac288C90b9D70Ec9137F` |
| CEAFactory               | `0xE86655567d3682c0f141d0F924b9946999DC3381` |
| USDT on Sepolia          | `0x7169D38820dfd117C3FA1f22a697dBA58d90BA06` |
| Deployer (KEY)           | `0xe520d4A985A2356Fa615935a822Ce4eFAcA24aB6` |

---

## Pre-flight Checklist

Run these before starting. All must pass.

```bash
source .env

# 1. Confirm deployer key resolves to expected address
cast wallet address --private-key $KEY
# Expected: 0xe520d4A985A2356Fa615935a822Ce4eFAcA24aB6

# 2. Confirm ETH balance (need gas for ~4 broadcast transactions)
cast balance 0xe520d4A985A2356Fa615935a822Ce4eFAcA24aB6 --rpc-url $SEPOLIA_RPC_URL --ether

# 3. Confirm gateway proxy exists
cast code 0x4DCab975cDe839632db6695e2e936A29ce3e325E --rpc-url $SEPOLIA_RPC_URL | head -c 10

# 4. Confirm vault proxy exists
cast code 0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294 --rpc-url $SEPOLIA_RPC_URL | head -c 10

# 5. Check current USDT balance in Gateway (record this — it's what we will migrate)
cast call 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06 \
  "balanceOf(address)(uint256)" \
  0x4DCab975cDe839632db6695e2e936A29ce3e325E \
  --rpc-url $SEPOLIA_RPC_URL
# Note: this is the amount that must land in Vault after Phase 5

# 6. Check current USDT balance in Vault (should be 0 before migration)
cast call 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06 \
  "balanceOf(address)(uint256)" \
  0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294 \
  --rpc-url $SEPOLIA_RPC_URL

# 7. Confirm current gateway TSS_ADDRESS (must survive both upgrades unchanged)
cast call 0x4DCab975cDe839632db6695e2e936A29ce3e325E \
  "TSS_ADDRESS()(address)" \
  --rpc-url $SEPOLIA_RPC_URL

# 8. Build passes cleanly
forge build
```

---

## Phase 1 — Vault Deployment [COMPLETE ✅]

Already deployed in a prior session. No action needed.

- Vault Proxy:          `0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294`
- Vault Implementation: `0x2917e434fA9AB956f5e6ac288C90b9D70Ec9137F`
- Script used:          `script/vault/deployVault.s.sol`

---

## Phase 2 — Code Preparation [COMPLETE ✅]

All code changes are implemented and the full test suite passes (686/686). Summary:

### `src/UniversalGatewayV0.sol` changes
- Imports `Types.sol` (instead of `TypesV0.sol`), adds `ICEAFactory`
- All original V0 storage slots preserved in exact order
- Gap reduced: `uint256[40] __gap` → `uint256[38] __gap`
- New storage appended after gap: `address public VAULT`, `address public CEA_FACTORY`
- Added role: `VAULT_ROLE`
- Renamed: `setTSSAddress` → `setTSS`
- `onlyTSS` modifier error: `WithdrawFailed()` → `Unauthorized()`
- **Removed:** `withdraw`, `withdrawTokens`, `executeUniversalTx` (both overloads), `getEthUsdPrice_old`, `_resetApproval`, `_safeApprove`, `_executeCall`
- **Added:** `setVault`, `setCEAFactory`, `sendUniversalTxFromCEA`, `_isCallerCEA`, `moveFunds_temp`
- `revertUniversalTxToken`: access changed `onlyTSS` → `onlyRole(VAULT_ROLE)`
- `_handleDeposits`: ERC20 now transferred to `VAULT` instead of `address(this)`
- `UniversalTx` event: new shape — `revertRecipient` (address) + `fromCEA` (bool)
- `swapToNative`: uses `ISwapRouterSepolia` (no `deadline` field — Sepolia router)
- Rate-limit functions present with bodies intact; call sites remain commented out

### `script/gatewayV0/` scripts (all created)
| Script                            | Purpose                                                              |
| --------------------------------- | -------------------------------------------------------------------- |
| `upgradeGatewayV0_upgrade1.s.sol` | Upgrade 1: deploy new impl (with `moveFunds_temp`) and upgrade proxy |
| `registerVault.s.sol`             | Call `setVault()` + `setCEAFactory()` on upgraded gateway            |
| `moveFunds.s.sol`                 | Call `moveFunds_temp()` to migrate USDT from Gateway to Vault        |
| `upgradeGatewayV0_upgrade2.s.sol` | Upgrade 2: deploy clean impl (no `moveFunds_temp`), upgrade proxy    |

---

**NOTE: Quick Instructions for accurate task tracking from Phase 3 onwards**
- add a new file in docs/ called Test_Upgrade_Logs.md
- after every phase ( phase 3 onwards ) include briefl logs in this new file to accurately provide info of:
  -  what was done in the given phase
  -  did it succeedded/failed
  -  what was the outcome?
-
---
## Phase 3 — Upgrade 1: Deploy Implementation with `moveFunds_temp`

**Script:** `script/gatewayV0/upgradeGatewayV0_upgrade1.s.sol:UpgradeGatewayV0_1`

```bash
source .env
forge script script/gatewayV0/upgradeGatewayV0_upgrade1.s.sol:UpgradeGatewayV0_1 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $KEY \
  --broadcast \
  -vvv
```

**What the script does:**
1. Reads ProxyAdmin address from EIP-1967 admin slot of the proxy
2. Verifies caller is ProxyAdmin owner
3. Records current (old) implementation address
4. Deploys new `UniversalGatewayV0` implementation (includes `moveFunds_temp`)
5. Calls `ProxyAdmin.upgradeAndCall(proxy, newImpl, "")` — no re-initialization
6. Verifies: `TSS_ADDRESS` unchanged, `VAULT` is `address(0)` (not yet set), new impl active

**Record the implementation address** from the script output — needed for Etherscan verification.

**Post-upgrade verification:**
```bash
# TSS_ADDRESS must be unchanged
cast call 0x4DCab975cDe839632db6695e2e936A29ce3e325E \
  "TSS_ADDRESS()(address)" --rpc-url $SEPOLIA_RPC_URL

# VAULT must be address(0) — not yet registered
cast call 0x4DCab975cDe839632db6695e2e936A29ce3e325E \
  "VAULT()(address)" --rpc-url $SEPOLIA_RPC_URL
# Expected: 0x0000000000000000000000000000000000000000

# Version should be 2.0.0
cast call 0x4DCab975cDe839632db6695e2e936A29ce3e325E \
  "version()(string)" --rpc-url $SEPOLIA_RPC_URL
# Expected: "2.0.0"
```

---

## Phase 4 — Register Vault and CEAFactory

**Script:** `script/gatewayV0/registerVault.s.sol:RegisterVault`

```bash
forge script script/gatewayV0/registerVault.s.sol:RegisterVault \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $KEY \
  --broadcast \
  -vvv
```

**What the script does:**
1. Verifies Vault and CEAFactory contracts exist on-chain
2. Calls `gateway.setVault(0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294)`
   - Sets `VAULT` storage variable
   - Grants `VAULT_ROLE` to the Vault contract
3. Calls `gateway.setCEAFactory(0xE86655567d3682c0f141d0F924b9946999DC3381)`
   - Sets `CEA_FACTORY` storage variable
4. Verifies both addresses are set and `VAULT_ROLE` is granted

**Post-registration verification:**
```bash
cast call 0x4DCab975cDe839632db6695e2e936A29ce3e325E \
  "VAULT()(address)" --rpc-url $SEPOLIA_RPC_URL
# Expected: 0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294

cast call 0x4DCab975cDe839632db6695e2e936A29ce3e325E \
  "CEA_FACTORY()(address)" --rpc-url $SEPOLIA_RPC_URL
# Expected: 0xE86655567d3682c0f141d0F924b9946999DC3381
```

---

## Phase 5 — Migrate USDT: Gateway → Vault

**Script:** `script/gatewayV0/moveFunds.s.sol:MoveFunds`

> **Prerequisites:** Phase 3 and Phase 4 must be complete. VAULT must be set on gateway.

```bash
forge script script/gatewayV0/moveFunds.s.sol:MoveFunds \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $KEY \
  --broadcast \
  -vvv
```

**What the script does:**
1. Validates gateway, vault, and USDT addresses are configured correctly
2. Checks that `VAULT` is registered on the gateway (fails fast if not)
3. Records USDT balances before (both gateway and vault)
4. Requires `gatewayBalance > 0` (fails if nothing to migrate)
5. Calls `gateway.moveFunds_temp()` — transfers all USDT from Gateway to Vault
6. Records balances after
7. Asserts: gateway balance == 0, vault balance increased by exact migrated amount

**Post-migration verification (must both pass before continuing):**
```bash
# Gateway USDT must be 0
cast call 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06 \
  "balanceOf(address)(uint256)" \
  0x4DCab975cDe839632db6695e2e936A29ce3e325E \
  --rpc-url $SEPOLIA_RPC_URL
# Expected: 0

# Vault USDT must equal the amount recorded in pre-flight step 5
cast call 0x7169D38820dfd117C3FA1f22a697dBA58d90BA06 \
  "balanceOf(address)(uint256)" \
  0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294 \
  --rpc-url $SEPOLIA_RPC_URL
# Expected: [amount from pre-flight]
```

**DO NOT proceed to Phase 6 unless both checks above pass.**

---

## Phase 6 — Remove `moveFunds_temp` from Source

This is a manual edit — no script involved.

1. Open `src/UniversalGatewayV0.sol`
2. Delete the entire `moveFunds_temp()` function (the block under `// UG_4: TEMPORARY MIGRATION`)
3. Rebuild:
   ```bash
   forge build
   # Must complete with no errors
   ```
4. Run full test suite:
   ```bash
   forge test -vv
   # Expected: all tests pass
   ```

> **Note on Etherscan verification:** If you intend to verify Impl1 on Etherscan (Phase 8),
> do it **before** this step, or save a copy of the pre-removal source file. Once
> `moveFunds_temp` is removed, you cannot regenerate the Impl1 bytecode without restoring it.

---

## Phase 7 — Upgrade 2: Deploy Clean Implementation

**Script:** `script/gatewayV0/upgradeGatewayV0_upgrade2.s.sol:UpgradeGatewayV0_2`

> **Prerequisites:** Phase 6 must be complete (`moveFunds_temp` removed from source).
> The script pre-condition check verifies gateway USDT balance == 0 before proceeding.

```bash
forge script script/gatewayV0/upgradeGatewayV0_upgrade2.s.sol:UpgradeGatewayV0_2 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $KEY \
  --broadcast \
  -vvv
```

**What the script does:**
1. Validates: proxy exists, caller is ProxyAdmin owner
2. Pre-condition checks: `VAULT` is set, `CEA_FACTORY` is set, gateway USDT balance == 0
3. Records old (Upgrade 1) implementation address
4. Deploys new clean `UniversalGatewayV0` implementation (no `moveFunds_temp`)
5. Calls `ProxyAdmin.upgradeAndCall(proxy, newImpl, "")` — no re-initialization
6. Verifies: implementation changed, `TSS_ADDRESS` intact, `VAULT` and `CEA_FACTORY` intact

**Record the new implementation address** from the script output — needed for Etherscan verification.

**Post-upgrade verification:**
```bash
# Confirm moveFunds_temp is gone (call must revert)
cast call 0x4DCab975cDe839632db6695e2e936A29ce3e325E \
  "moveFunds_temp()" --rpc-url $SEPOLIA_RPC_URL
# Expected: revert

# Confirm all critical state preserved
cast call 0x4DCab975cDe839632db6695e2e936A29ce3e325E \
  "TSS_ADDRESS()(address)" --rpc-url $SEPOLIA_RPC_URL

cast call 0x4DCab975cDe839632db6695e2e936A29ce3e325E \
  "VAULT()(address)" --rpc-url $SEPOLIA_RPC_URL
# Expected: 0xe8D77b8BC708aeA8E3735f686DcD33004a7Cd294

cast call 0x4DCab975cDe839632db6695e2e936A29ce3e325E \
  "CEA_FACTORY()(address)" --rpc-url $SEPOLIA_RPC_URL
# Expected: 0xE86655567d3682c0f141d0F924b9946999DC3381
```

---

## Phase 8 — Etherscan Verification

Verify both implementation contracts so the proxy shows verified source on Etherscan.
Substitute `<IMPL1_ADDR>` and `<IMPL2_ADDR>` from the script outputs in Phases 3 and 7.

### Implementation 1 (with `moveFunds_temp`)

> Verify this using the source **before** removing `moveFunds_temp` (Phase 6).

```bash
forge verify-contract --chain sepolia \
  --constructor-args $(cast abi-encode "constructor()") \
  <IMPL1_ADDR> \
  src/UniversalGatewayV0.sol:UniversalGatewayV0 \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### Implementation 2 (clean, no `moveFunds_temp`)

> Verify this using the source **after** removing `moveFunds_temp` (Phase 6).

```bash
forge verify-contract --chain sepolia \
  --constructor-args $(cast abi-encode "constructor()") \
  <IMPL2_ADDR> \
  src/UniversalGatewayV0.sol:UniversalGatewayV0 \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

---

## Full Execution Sequence (Summary)

```
Phase 1  [DONE]  Vault deployed
Phase 2  [DONE]  Code changes implemented, scripts created, 686 tests passing

Phase 3  Run upgradeGatewayV0_upgrade1.s.sol  -->  record IMPL1_ADDR
Phase 8a Verify IMPL1 on Etherscan            -->  (do this BEFORE Phase 6)
Phase 4  Run registerVault.s.sol              -->  sets VAULT + CEA_FACTORY
Phase 5  Run moveFunds.s.sol                  -->  USDT migrated to Vault
         Verify: gateway USDT == 0, vault USDT == migrated amount
Phase 6  Manual: remove moveFunds_temp() from source, forge build, forge test
Phase 7  Run upgradeGatewayV0_upgrade2.s.sol  -->  record IMPL2_ADDR
Phase 8b Verify IMPL2 on Etherscan
```

---

## Invariants That Must Hold Throughout

| Invariant                                  | Verification Command                                                                     |
| ------------------------------------------ | ---------------------------------------------------------------------------------------- |
| TSS_ADDRESS unchanged across both upgrades | `cast call <proxy> "TSS_ADDRESS()(address)"`                                             |
| MIN_CAP_UNIVERSAL_TX_USD preserved         | `cast call <proxy> "MIN_CAP_UNIVERSAL_TX_USD()(uint256)"`                                |
| MAX_CAP_UNIVERSAL_TX_USD preserved         | `cast call <proxy> "MAX_CAP_UNIVERSAL_TX_USD()(uint256)"`                                |
| BLOCK_USD_CAP preserved                    | `cast call <proxy> "BLOCK_USD_CAP()(uint256)"`                                           |
| epochDurationSec preserved                 | `cast call <proxy> "epochDurationSec()(uint256)"`                                        |
| VAULT_ROLE granted to Vault                | `cast call <proxy> "hasRole(bytes32,address)(bool)" $(cast keccak "VAULT_ROLE") <VAULT>` |
| Gateway USDT balance == 0 after Phase 5    | `cast call <USDT> "balanceOf(address)(uint256)" <GATEWAY>`                               |
| Vault USDT balance == migrated amount      | `cast call <USDT> "balanceOf(address)(uint256)" <VAULT>`                                 |
| moveFunds_temp() reverts after Phase 7     | `cast call <proxy> "moveFunds_temp()"` — must revert                                     |

---

## Risk Notes

1. **No re-initialization**: `initialize()` is NOT called during upgrades. All storage from V0 is preserved as-is — no data is lost or reset.
2. **VAULT_ROLE grant**: `setVault()` grants `VAULT_ROLE` to the Vault, enabling it to call `revertUniversalTxToken()`. Confirm the Vault contract is correct before Phase 4.
3. **moveFunds_temp safety**: Hard-coded USDT address. Callable only by `DEFAULT_ADMIN_ROLE`. Reverts if `VAULT == address(0)` or balance is 0.
4. **Etherscan verification order**: Impl1 must be verified **before** `moveFunds_temp` is removed from source. Once removed, Impl1 bytecode cannot be reproduced without restoring the function.
5. **Sequential execution required**: Phases 3 → 4 → 5 → 6 → 7 must not be reordered. Each phase has pre-condition checks that enforce this.
