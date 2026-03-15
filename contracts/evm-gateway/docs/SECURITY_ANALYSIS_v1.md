# Security Review — evm-gateway (Push Chain Universal Gateway)

```

██████╗  █████╗ ███████╗██╗  ██╗ ██████╗ ██╗   ██╗     ███████╗██╗  ██╗██╗██╗     ██╗     ███████╗
██╔══██╗██╔══██╗██╔════╝██║  ██║██╔═══██╗██║   ██║     ██╔════╝██║ ██╔╝██║██║     ██║     ██╔════╝
██████╔╝███████║███████╗███████║██║   ██║██║   ██║     ███████╗█████╔╝ ██║██║     ██║     ███████╗
██╔═══╝ ██╔══██║╚════██║██╔══██║██║   ██║╚██╗ ██╔╝     ╚════██║██╔═██╗ ██║██║     ██║     ╚════██║
██║     ██║  ██║███████║██║  ██║╚██████╔╝ ╚████╔╝      ███████║██║  ██╗██║███████╗███████╗███████║
╚═╝     ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚═════╝   ╚═══╝       ╚══════╝╚═╝  ╚═╝╚═╝╚══════╝╚══════╝╚══════╝

```

Powered by [pashov/skills](https://github.com/pashov/skills) · pashov AI Auditor

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | ALL (170 vectors, 4 parallel scan agents)              |
| **Files reviewed**               | `UniversalGateway.sol` · `UniversalGatewayPC.sol`<br>`Vault.sol` · `VaultPC.sol`<br>`libraries/Types.sol` · `libraries/TypesUG.sol`<br>`libraries/TypesUGPC.sol` · `libraries/Errors.sol` |
| **Confidence threshold (1-100)** | 75                                                     |
| **Date**                         | 2026-03-15                                             |

---

## Findings

[80] **1. Non-Atomic Proxy Initialization Allows Front-Run Ownership Takeover**

`UniversalGateway.initialize` · Confidence: 80

**Description**
If the proxy is deployed with empty calldata (separate `initialize()` call), a mempool observer can call `initialize()` before the legitimate deployer, installing themselves as `DEFAULT_ADMIN_ROLE` and `TSS_ADDRESS` — gaining full control over inbound ETH routing, token support, and rate-limit configuration.

**Fix**

```diff
- new TransparentUpgradeableProxy(impl, proxyAdmin, "")
- // separate tx: proxy.initialize(admin, tss, ...)
+ new TransparentUpgradeableProxy(
+     impl,
+     proxyAdmin,
+     abi.encodeCall(UniversalGateway.initialize, (admin, tss, vault, minCap, maxCap, factory, router, weth))
+ )
```

---

[75] **2. Fee-on-Transfer Token in Revert/Rescue Flow Permanently Locks User Funds**

`Vault.revertUniversalTx` / `Vault.rescueFunds` · Confidence: 75

**Description**
When a supported ERC20 with a transfer fee is used, `Vault.revertUniversalTx` transfers `amount` tokens to the gateway (gateway receives `amount - fee`) then immediately calls `gateway.revertUniversalTx(…, amount, …)`; the gateway attempts to forward the original `amount` to `revertRecipient`, reverts because it holds less than `amount`, and the user's refund is permanently blocked with funds stuck in the Vault.

**Fix**

```diff
- IERC20(token).safeTransfer(address(gateway), amount);
- gateway.revertUniversalTx(subTxId, universalTxId, token, amount, revertInstruction);
+ uint256 balBefore = IERC20(token).balanceOf(address(gateway));
+ IERC20(token).safeTransfer(address(gateway), amount);
+ uint256 received = IERC20(token).balanceOf(address(gateway)) - balBefore;
+ gateway.revertUniversalTx(subTxId, universalTxId, token, received, revertInstruction);
```

---

### Below Confidence Threshold

[65] **3. Blacklisted revertRecipient Permanently DoS-es TSS Revert Path**

`Vault.revertUniversalTx` → `UniversalGateway.revertUniversalTx` · Confidence: 65

**Description**
A user can supply a USDC-blacklisted address as `revertRecipient` at deposit time; when TSS later calls `Vault.revertUniversalTx`, the token transfer chain (`Vault → gateway → revertRecipient`) reverts at the final transfer, and TSS retries always fail, permanently locking the tokens in the Vault with no on-chain recovery path.

---

[65] **4. Swap Deadline Always Satisfied When Caller Passes Zero**

`UniversalGateway.swapToNative` · Confidence: 65

**Description**
When `deadline == 0`, the gateway substitutes `block.timestamp + defaultSwapDeadlineSec` at execution time; a stale transaction held in the mempool for any duration will always pass the deadline check on inclusion, leaving the user's token-to-native swap exposed to sandwich attacks bounded only by their `amountOutMinETH` tolerance.

---

[60] **5. Rebasing Token Balance Divergence Causes Finalization DoS**

`Vault._finalizeUniversalTx` · Confidence: 60

**Description**
`_finalizeUniversalTx` reads `IERC20(token).balanceOf(address(this)) >= amount` as a guard and then calls `safeTransfer(cea, amount)`; a negative rebase occurring between these two operations reduces the Vault's actual balance below `amount`, causing the transfer to revert and permanently DoS-ing outbound fund delivery for that universal transaction until the Vault balance recovers.

---

[55] **6. Delisted Token Blocks All Vault Operations — Pending Reversals Become Permanently Unprocessable**

`Vault._enforceSupported` (called from `revertUniversalTx`, `rescueFunds`, `_validateParams`) · Confidence: 55

**Description**
`_enforceSupported(token)` is called unconditionally on all ERC20 Vault paths (forward execution, revert, and rescue); if an admin delists a token from the gateway after deposits have been accepted but before TSS processes pending reversals, every `revertUniversalTx` and `rescueFunds` call for that token reverts, making those user deposits unrecoverable without a contract upgrade.

Composability note: if this condition occurs simultaneously with Finding 3 (blacklisted revertRecipient), no recovery path exists even after re-listing the token.

---

[55] **7. Zero-Amount ERC20 Transfer to CEA Fails for Tokens That Reject Zero-Value Transfers**

`Vault._finalizeUniversalTx` · Confidence: 55

**Description**
When TSS calls `finalizeUniversalTx` with `amount = 0` and a non-zero ERC20 token address (valid per the CEA execution-only model), `_finalizeUniversalTx` passes the `balanceOf < amount` check (since `0 < 0` is false) and calls `IERC20(token).safeTransfer(cea, 0)`; tokens that revert on zero-amount transfers (e.g., early BNB) will cause this call to revert, making that specific sub-transaction permanently unexecutable.

---

## Analysis Summary by Vector Group (170 vectors total)

### Vectors 1–42 (Agent 1)

| Group | Disposition |
|---|---|
| Signature / NFT / ERC1155 / AA / LayerZero | Skip — constructs absent |
| Block timestamp epoch manipulation | Drop — epoch window (hours/days) makes 15s miner drift irrelevant |
| ERC777 reentrancy | Drop — `nonReentrant` on all entry points |
| Beacon proxy SPOF | Drop — TransparentUpgradeableProxy used |
| Precision loss (division before multiply) | Drop — `quoteEthAmountInUsd1e18` multiplies first |
| Cross-chain supply accounting | Drop — all withdrawal paths are TSS-only; on-chain invariant maintained by TSS |
| Blacklisted revertRecipient | CONFIRM [65] — see Finding 3 |
| Delisted token lock | CONFIRM [55] — see Finding 6 |
| Zero-amount ERC20 to CEA | CONFIRM [55] — see Finding 7 |

### Vectors 43–84 (Agent 2)

| Group | Disposition |
|---|---|
| Integer overflow (0.8+) | Drop — `uint192` cast occurs after `uint256`-width `newUsed > threshold` check |
| Single-function reentrancy | Drop — `nonReentrant` on `Vault.revertUniversalTx`; state changes before external calls |
| Cross-chain address ownership | Drop — CEAFactory set by admin; `req.recipient == mappedUEA` anti-spoof enforced |
| Chainlink staleness | Drop — `chainlinkStalePeriod` + L2 sequencer feed + grace period all present |
| Fee-on-transfer token | CONFIRM [75] — see Finding 2 |
| Rebasing token | CONFIRM [60] — see Finding 5 |
| ERC777 reentrancy | Drop — `nonReentrant` present; no ERC1820 registration by gateway |
| Force-feeding ETH to VaultPC | Drop — only allows MANAGER_ROLE to withdraw more; not user-facing |

### Vectors 85–126 (Agent 3)

| Group | Disposition |
|---|---|
| Assembly arithmetic overflow | Drop — `if (dec > 18) revert` guard present inside unchecked block |
| Upgrade race / front-run | CONFIRM [80] — see Finding 1 |
| Proxy admin key compromise | Drop — centralization concern, no concrete permissionless exploit |
| Uninitialized implementation | Drop — TransparentProxy; attacker initializing implementation cannot affect proxy state or trigger upgrades |
| Arbitrary external call injection | Drop — `revertRecipient` is value-only (no calldata); Vault calls are TSS-gated |
| Swap deadline bypass | CONFIRM [65] — see Finding 4 |
| Deployer privilege retention | Drop — centralization concern |
| Batch array duplicate items | Drop — privileged admin path; last-write-wins is idempotent |
| Cross-function reentrancy via Vault→Gateway | Drop — both contracts independently `nonReentrant`; CEI followed within each |

### Vectors 127–170 (Agent 4)

| Group | Disposition |
|---|---|
| Cross-chain subTxId replay | Drop — `chainNamespace` encodes destination chain; TSS is trusted relay |
| Unchecked `transferFrom` in `_burnPRC20` | Drop — failed transfer causes `burn()` to return false, which is explicitly checked |
| Uninitialized implementation (V139) | Drop — same as Agent 3 analysis |
| Missing oracle price bounds | Drop — near-zero price bypasses instant-route min cap but causes no fund theft |
| CEA CREATE2 salt binding | Drop — salt = `pushAccount`; pre-deploying someone else's CEA provides no advantage |
| Cross-function reentrancy (V153) | Drop — `nonReentrant` on both Vault and Gateway; CEI followed |
| `abi.encodePacked` hash collision | Drop — `abi.encode` used throughout; no collision possible |
| Metamorphic contracts via CREATE2 | Drop — EIP-6780 (Dencun): `selfdestruct` no longer destroys code except in same-tx |
| Storage layout collision on upgrade | Drop — all upgradeable additions appear appended (safe); no confirmed collision |
| All other V127–V170 | Skip — absent constructs (Diamond, ERC4626, LayerZero OFT, ERC1155, staking, lending, assembly, TWAP, Merkle) |

---

## Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [80] | Non-Atomic Proxy Initialization Allows Front-Run Ownership Takeover |
| 2 | [75] | Fee-on-Transfer Token in Revert/Rescue Flow Permanently Locks User Funds |
| | | **Below Confidence Threshold** |
| 3 | [65] | Blacklisted revertRecipient Permanently DoS-es TSS Revert Path |
| 4 | [65] | Swap Deadline Always Satisfied When Caller Passes Zero |
| 5 | [60] | Rebasing Token Balance Divergence Causes Finalization DoS |
| 6 | [55] | Delisted Token Blocks All Vault Operations |
| 7 | [55] | Zero-Amount ERC20 Transfer to CEA Fails for Tokens That Reject Zero-Value Transfers |

---

> This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
