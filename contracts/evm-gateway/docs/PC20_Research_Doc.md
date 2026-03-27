# PC20 Feature Research: Push Chain Native Token Interoperability

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Current Architecture Recap](#2-current-architecture-recap)
3. [PC20 Feature Requirements](#3-pc20-feature-requirements)
4. [Industry Reference Analysis](#4-industry-reference-analysis)
5. [Solution Architecture: Proposed Approaches](#5-solution-architecture-proposed-approaches)
6. [Recommended Approach: Detailed Design](#6-recommended-approach-detailed-design)
7. [EVM Gateway Modifications](#7-evm-gateway-modifications)
8. [SVM Gateway Modifications](#8-svm-gateway-modifications)
9. [Push Chain Core Contract Modifications](#9-push-chain-core-contract-modifications)
10. [Blockers and Mitigations](#10-blockers-and-mitigations)
11. [Solution Ranking](#11-solution-ranking)
12. [Appendix: Full Contract Interface Specifications](#12-appendix-full-contract-interface-specifications)

---

## 1. Executive Summary

**PC20** is Push Chain's native fungible token standard. Today, the Push Chain gateway infrastructure supports moving external tokens (ETH, USDC, etc.) onto Push Chain as PRC20 wrapped representations, and back out via burn/unlock. The PC20 feature extends this in the **reverse direction**: tokens *originating* on Push Chain need wrapped representations deployed and managed on external chains (Ethereum, Base, Arbitrum, Solana, etc.).

**Core challenge**: The current architecture is asymmetric. Inbound flows lock tokens in a Vault on external chains and mint PRC20 on Push Chain. Outbound flows burn PRC20 and release from Vault. For PC20, we need the inverse: lock on Push Chain, deploy + mint wrapped tokens on external chains; burn wrapped tokens on external chains, unlock on Push Chain.

**Recommended approach**: A **PC20 Registry + Wrapped Token Factory** pattern, where Push Chain acts as the hub and external chains are spokes. The hub locks PC20 tokens; spokes deploy deterministic wrapped ERC20/SPL tokens via a factory controlled by the TSS authority. This mirrors the battle-tested hub-and-spoke model used by Wormhole NTT and Axelar ITS.

---

## 2. Current Architecture Recap

### 2.1 Token Flow: External -> Push Chain (Existing)

```
External Chain                          Push Chain
+------------------+                   +------------------+
| User sends ETH   |                   | UEA receives     |
| via Gateway      | --- Validators -> | PRC20 (pETH)     |
| ETH locked in    |                   | minted by        |
| Vault            |                   | UniversalCore    |
+------------------+                   +------------------+
```

- `UniversalGateway.sendUniversalTx()` locks tokens in Vault (ERC20) or forwards native to TSS
- Validators observe `UniversalTx` event, credit PRC20 to UEA on Push Chain
- PRC20 is the wrapped representation of the external token on Push Chain

### 2.2 Token Flow: Push Chain -> External (Existing)

```
Push Chain                              External Chain
+------------------+                   +------------------+
| User burns pETH  |                   | Vault releases   |
| via GatewayPC    | --- TSS --------> | original ETH     |
| Gas fees swapped |                   | via CEA to       |
| and burned       |                   | recipient        |
+------------------+                   +------------------+
```

- `UniversalGatewayPC.sendUniversalTxOutbound()` burns PRC20
- TSS calls `Vault.finalizeUniversalTx()` to release original tokens from Vault
- CEA executes multicall payload if present

### 2.3 Key Contracts

| Contract | Chain | Role |
|----------|-------|------|
| `UniversalGateway` | External EVM | Inbound entry point |
| `Vault` | External EVM | ERC20 custody (outbound release) |
| `CEA` / `CEAFactory` | External EVM | Per-user execution accounts |
| `UniversalGatewayPC` | Push Chain | Outbound entry point (burns PRC20) |
| `VaultPC` | Push Chain | Fee collection |
| `UniversalCore` | Push Chain | PRC20 management, gas pricing, swaps |
| SVM Gateway | Solana | Inbound/outbound for Solana |

### 2.4 What's Missing for PC20

The current system has **no mechanism to**:
1. Lock a Push Chain native token (PC20) and emit a cross-chain deployment event
2. Deploy a new wrapped ERC20/SPL token on an external chain in response to a PC20 export
3. Mint wrapped tokens on external chains controlled by the TSS
4. Burn wrapped tokens on external chains and emit a burn event back to Push Chain
5. Unlock the original PC20 on Push Chain upon receiving a verified burn proof

---

## 3. PC20 Feature Requirements

### 3.1 Export Flow (Push Chain -> External Chain X)

1. User locks PC20 token in a custody contract on Push Chain (new `PC20Vault` or extended `UniversalGatewayPC`)
2. Gateway emits a committed export event with unique `txId` and a magic marker identifying it as PC20
3. Universal Validators (TSS quorum) relay + sign proof
4. On destination chain: if wrapped token doesn't exist yet, deploy it deterministically
5. Mint wrapped tokens to destination receiver (specified by caller, or default to CEA)

### 3.2 Return Flow (External Chain X -> Push Chain)

1. User calls external chain gateway to initiate return
2. External chain gateway **burns** wrapped tokens
3. Emits a committed burn event with `burnId`
4. Validators relay + sign burn proof back to Push Chain
5. Push Chain verifies burn proof
6. Push Chain unlocks original PC20 to receiver

### 3.3 Invariants

- **Supply conservation**: `locked_on_push + sum(minted_on_all_external_chains) = total_supply`
- **Mint authority**: Only TSS (via Vault) can mint wrapped tokens on external chains
- **Burn authority**: Any holder can burn wrapped tokens to initiate return
- **Deterministic deployment**: Same PC20 token must map to predictable wrapped token addresses on each external chain
- **Idempotent deployment**: Deploying a wrapped token that already exists must not fail

---

## 4. Industry Reference Analysis

### 4.1 LayerZero OFT

**Pattern**: Token IS the bridge contract. `OFT` extends `ERC20` and overrides `_debit` (burn) and `_credit` (mint). For existing tokens, `OFTAdapter` locks/unlocks.

**Relevance to PC20**:
- The adapter pattern maps to our Vault model (lock on origin, mint on destination)
- The "OFT as the token" pattern is clean but requires deploying a specific contract type, not a generic ERC20
- Shared decimals (6) for cross-chain precision is a good safety pattern

**Limitation**: No automated remote deployment. Relies on manual `setPeer()` configuration.

### 4.2 Wormhole NTT

**Pattern**: Hub-and-spoke with separate `NttManager` per token per chain. Hub chain uses LOCKING mode, spoke chains use BURNING mode.

**Relevance to PC20**:
- The hub (Push Chain) locks tokens; spokes (external chains) mint/burn -- this is exactly our PC20 model
- **Global Accountant** tracks supply per chain and prevents minting more than was locked -- strong integrity guarantee
- Rate limiting on both inbound and outbound per chain
- Separate manager + token contracts (vs. merged OFT) -- more modular

**Limitation**: No automated cross-chain deployment. Still requires manual NttManager deployment per chain.

### 4.3 Axelar ITS

**Pattern**: `InterchainTokenService` + `InterchainTokenFactory` + `TokenManager`. Uses CREATE3 for deterministic addresses. Can trigger remote deployment via cross-chain GMP message.

**Relevance to PC20**:
- **CREATE3 for deterministic addresses** is directly applicable. Same PC20 token gets the same wrapped address on every EVM chain regardless of constructor args
- **Remote deployment via cross-chain message**: Factory on destination chain receives a deploy instruction and creates the token. This is the most automated pattern
- **Interchain Token ID** (`keccak256(deployer, salt)`) maps well to a PC20 registry where `tokenId = keccak256(pc20Address, chainNamespace)`
- **Flow limits** per token per chain provide rate limiting

**Most relevant model for PC20** due to automated deployment + deterministic addresses.

### 4.4 Hyperlane Warp Routes

**Pattern**: `HypERC20Collateral` (lock/unlock on origin) + `HypERC20` (mint/burn on destination). The synthetic token IS the contract.

**Relevance to PC20**:
- Clean separation between collateral and synthetic chains
- Token router pattern for multi-chain routing

**Limitation**: CLI-driven deployment, no on-chain factory, no deterministic addresses.

### 4.5 Key Takeaways

| Feature | Best Reference |
|---------|---------------|
| Hub-and-spoke lock/mint model | Wormhole NTT |
| Deterministic cross-chain addresses | Axelar ITS (CREATE3) |
| Automated remote deployment | Axelar ITS (GMP-triggered deploy) |
| Supply conservation accounting | Wormhole Global Accountant |
| Rate limiting per token per chain | Axelar ITS + Wormhole NTT |
| Mint authority control | All four (TSS/Guardian/Validator gated) |

---

## 5. Solution Architecture: Proposed Approaches

### Approach A: CEA-Based Multicall Deployment (Minimal Infrastructure Change)

**Concept**: Use the existing Vault + CEA infrastructure. When a PC20 export is triggered, TSS constructs a multicall payload that deploys (if needed) and mints a wrapped ERC20 via the user's CEA.

**Export Flow**:
1. User locks PC20 in a new `PC20Vault` on Push Chain
2. `UniversalGatewayPC` emits `PC20Export` event with token metadata (name, symbol, decimals, amount, recipient)
3. TSS constructs a multicall payload:
   ```solidity
   Multicall[2] = [
       // Step 1: Deploy wrapped token if not exists (via factory)
       Multicall(wrappedTokenFactory, 0, abi.encodeCall(deployIfNeeded, (pc20TokenId, name, symbol, decimals))),
       // Step 2: Mint tokens to recipient
       Multicall(wrappedTokenAddress, 0, abi.encodeCall(mint, (recipient, amount)))
   ];
   ```
4. TSS calls `Vault.finalizeUniversalTx()` with this multicall payload
5. CEA executes: deploys wrapped token (if needed) + mints to recipient

**Return Flow**:
1. User approves wrapped token to gateway, calls `sendUniversalTx` with the wrapped token
2. Gateway burns wrapped tokens (new capability needed)
3. Emits `UniversalTx` with a PC20 burn marker
4. TSS relays burn proof to Push Chain
5. Push Chain unlocks original PC20

**Pros**:
- Minimal new infrastructure -- reuses existing Vault + CEA execution model
- No new contracts on external chains beyond the wrapped token factory
- CEA multicall is already battle-tested

**Cons**:
- Mint authority on wrapped tokens must be granted to EVERY CEA that might interact -- this is a **fundamental security problem**. If any CEA can mint, a compromised UEA could mint unlimited tokens.
- CEA execution is per-user, but token deployment/minting is a protocol-level operation. Mixing these concerns is architecturally wrong.
- No deterministic token addresses (deployment depends on CEA address)
- Return flow requires Gateway to have burn authority on wrapped tokens, which conflicts with the current design where Gateway only locks in Vault

**Verdict**: **Rejected**. The mint authority problem makes this insecure.

### Approach B: Vault-Direct Mint/Burn (Recommended)

**Concept**: Extend the `Vault` contract on external chains with a `WrappedTokenFactory` and grant the Vault (via TSS) exclusive mint authority over PC20 wrapped tokens. The Vault becomes the single point of control for both existing bridge tokens (lock/unlock) AND PC20 wrapped tokens (mint/burn).

**Export Flow**:
1. User locks PC20 in `PC20Vault` on Push Chain
2. `UniversalGatewayPC` emits `PC20Export` event
3. TSS calls a new `Vault.mintPC20()` function:
   - Deploys wrapped token via `WrappedTokenFactory.deployIfNeeded()` (CREATE2 deterministic)
   - Mints wrapped tokens directly to recipient
4. No CEA involvement for the mint operation

**Return Flow**:
1. User calls a new `UniversalGateway.burnPC20()` function
2. Gateway calls `burn()` on the wrapped token
3. Emits `PC20Burn` event
4. TSS relays to Push Chain
5. Push Chain unlocks original PC20

**Pros**:
- **Single mint authority**: Only Vault (via TSS) can mint. No CEA mint authority needed.
- **Deterministic addresses**: CREATE2 factory guarantees predictable wrapped token addresses per PC20
- **Clean separation**: PC20 mint/burn path is distinct from existing lock/unlock path
- **Vault already has TSS access control** -- extends naturally
- **Rate limiting** can be applied per-PC20 token

**Cons**:
- Requires Vault contract upgrade (new functions)
- Requires new WrappedTokenFactory contract
- Requires new WrappedPC20 token contract template
- New entry point on UniversalGateway for burn

**Verdict**: **Recommended**. Best balance of security, simplicity, and alignment with current architecture.

### Approach C: Standalone PC20 Bridge Contracts (Maximum Isolation)

**Concept**: Deploy entirely separate contracts (`PC20Gateway`, `PC20Vault`) on both Push Chain and external chains, completely independent of the existing gateway infrastructure.

**Pros**:
- Zero risk to existing bridge operations
- Clean-sheet design optimized for PC20
- Can be audited independently

**Cons**:
- Massive development effort (duplicate the entire gateway stack)
- Code duplication with existing Vault/Gateway
- Users need to interact with different contracts for different token types
- TSS needs to monitor additional event sources
- Doubles the attack surface

**Verdict**: **Not recommended** unless the existing gateway is too rigid to extend. The engineering cost far outweighs the isolation benefit.

---

## 6. Recommended Approach: Detailed Design

### 6.1 Architecture Overview

```
PUSH CHAIN                                    EXTERNAL CHAIN (EVM)
+--------------------+                        +----------------------+
| PC20 Token (ABC)   |                        | WrappedPC20 (wABC)   |
| (ERC20 on PC)      |                        | (ERC20 on ext chain) |
+--------------------+                        +----------------------+
         |                                              ^
         v                                              |
+--------------------+   TSS Relay    +----------------------+
| PC20Vault          | ------------> | Vault                |
| (locks PC20)       |               | .mintPC20()          |
|                    |               | .burnPC20()          |
+--------------------+               +----------------------+
         ^                                      |
         |                                      v
+--------------------+               +----------------------+
| UniversalGatewayPC |               | WrappedTokenFactory  |
| .exportPC20()      |               | .deploy()            |
+--------------------+               | .getAddress()        |
                                     +----------------------+

RETURN FLOW:

EXTERNAL CHAIN (EVM)                          PUSH CHAIN
+--------------------+                        +--------------------+
| User burns wABC    |                        | PC20Vault          |
| via Gateway        |                        | unlocks ABC        |
| .returnPC20()      | --- TSS Relay -------> | to recipient       |
+--------------------+                        +--------------------+
```

### 6.2 New Contracts Required

#### 6.2.1 WrappedPC20 (External Chains -- EVM)

A minimal ERC20 with controlled mint/burn, deployed per PC20 token per external chain.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title WrappedPC20
/// @notice Wrapped representation of a Push Chain native token
///         on an external EVM chain. Only the authorized minter
///         (Vault) can mint/burn.
contract WrappedPC20 is ERC20 {
    /// @notice Address of the Push Chain token this wraps
    address public immutable PC20_TOKEN;

    /// @notice Chain namespace of Push Chain
    string public PC20_CHAIN_NAMESPACE;

    /// @notice Sole address authorized to mint and burn
    address public immutable MINTER;

    /// @notice Token decimals (mirrors Push Chain token)
    uint8 private immutable _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address pc20Token,
        string memory chainNamespace,
        address minter
    ) ERC20(name_, symbol_) {
        if (minter == address(0)) revert Errors.ZeroAddress();
        if (pc20Token == address(0)) revert Errors.ZeroAddress();

        PC20_TOKEN = pc20Token;
        PC20_CHAIN_NAMESPACE = chainNamespace;
        MINTER = minter;
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(
        address to,
        uint256 amount
    ) external onlyMinter {
        _mint(to, amount);
    }

    function burn(
        address from,
        uint256 amount
    ) external onlyMinter {
        _burn(from, amount);
    }

    modifier onlyMinter() {
        if (msg.sender != MINTER) revert Errors.Unauthorized();
        _;
    }
}
```

**Design decisions**:
- `MINTER` is immutable and set to the Vault address at deployment. No admin can change it.
- No upgradeability -- wrapped tokens are simple, immutable ERC20s. If the contract needs changing, a new version is deployed.
- No governance, no owner, no admin. Mint/burn is purely TSS-controlled via Vault.
- Decimals mirror the Push Chain token decimals to avoid precision issues.

#### 6.2.2 WrappedTokenFactory (External Chains -- EVM)

Deterministic deployer for WrappedPC20 tokens using CREATE2.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WrappedPC20} from "./WrappedPC20.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title WrappedTokenFactory
/// @notice Deterministic deployer for WrappedPC20 tokens.
///         Uses CREATE2 so the wrapped token address is
///         predictable from the PC20 token address alone.
contract WrappedTokenFactory {
    /// @notice The Vault that will be set as MINTER on
    ///         all deployed WrappedPC20 tokens
    address public immutable VAULT;

    /// @notice Push Chain namespace (e.g., "pushchain:1")
    string public PC_CHAIN_NAMESPACE;

    /// @notice pc20Token => wrappedToken address
    mapping(address => address) public wrappedTokens;

    event WrappedTokenDeployed(
        address indexed pc20Token,
        address indexed wrappedToken,
        string name,
        string symbol,
        uint8 decimals
    );

    constructor(address vault, string memory pcChainNamespace) {
        if (vault == address(0)) revert Errors.ZeroAddress();
        VAULT = vault;
        PC_CHAIN_NAMESPACE = pcChainNamespace;
    }

    /// @notice Deploy a WrappedPC20 for the given PC20 token.
    ///         Idempotent: returns existing address if already
    ///         deployed.
    /// @param pc20Token Address of the token on Push Chain
    /// @param name Token name (e.g., "Wrapped ABC")
    /// @param symbol Token symbol (e.g., "wABC")
    /// @param decimals_ Token decimals
    /// @return wrapped Address of the deployed WrappedPC20
    function deploy(
        address pc20Token,
        string calldata name,
        string calldata symbol,
        uint8 decimals_
    ) external returns (address wrapped) {
        if (pc20Token == address(0)) revert Errors.ZeroAddress();

        // Return existing if already deployed
        wrapped = wrappedTokens[pc20Token];
        if (wrapped != address(0)) return wrapped;

        // Only Vault can trigger deployment
        if (msg.sender != VAULT) revert Errors.Unauthorized();

        bytes32 salt = _salt(pc20Token);

        wrapped = address(
            new WrappedPC20{salt: salt}(
                name,
                symbol,
                decimals_,
                pc20Token,
                PC_CHAIN_NAMESPACE,
                VAULT
            )
        );

        wrappedTokens[pc20Token] = wrapped;

        emit WrappedTokenDeployed(
            pc20Token,
            wrapped,
            name,
            symbol,
            decimals_
        );
    }

    /// @notice Predict the address of a WrappedPC20 before
    ///         deployment.
    /// @param pc20Token Address of the token on Push Chain
    /// @param name Token name
    /// @param symbol Token symbol
    /// @param decimals_ Token decimals
    /// @return predicted The deterministic address
    function getAddress(
        address pc20Token,
        string calldata name,
        string calldata symbol,
        uint8 decimals_
    ) external view returns (address predicted) {
        bytes32 salt = _salt(pc20Token);
        bytes memory bytecode = abi.encodePacked(
            type(WrappedPC20).creationCode,
            abi.encode(
                name,
                symbol,
                decimals_,
                pc20Token,
                PC_CHAIN_NAMESPACE,
                VAULT
            )
        );
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(bytecode)
            )
        );
        predicted = address(uint160(uint256(hash)));
    }

    /// @notice Check if a wrapped token exists for a
    ///         PC20 token.
    function isWrappedToken(
        address token
    ) external view returns (bool) {
        return wrappedTokens[token] != address(0);
    }

    /// @notice Get the PC20 token for a wrapped token.
    function getPC20ForWrapped(
        address wrapped
    ) external view returns (address) {
        return WrappedPC20(wrapped).PC20_TOKEN();
    }

    function _salt(
        address pc20Token
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(pc20Token));
    }
}
```

**Design decisions**:
- Only Vault can trigger deployment (prevents griefing with wrong metadata)
- Salt is derived purely from `pc20Token` address, making it deterministic
- `getAddress()` allows off-chain prediction of wrapped token addresses
- Idempotent: calling `deploy()` for an existing token returns the existing address
- No admin, no upgradeability -- immutable factory
- **Note on CREATE2 vs CREATE3**: CREATE2 is used here because the bytecode is deterministic given the same constructor args. If we needed the same address regardless of constructor args (e.g., different names on different chains), CREATE3 would be needed. Since we control the constructor args via TSS and they should be identical across chains, CREATE2 suffices.

#### 6.2.3 PC20Vault (Push Chain)

Custody contract for PC20 tokens being exported to external chains.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from
    "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title PC20Vault
/// @notice Holds PC20 tokens locked during export to
///         external chains. Releases tokens when burn
///         proofs are verified from external chains.
contract PC20Vault is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant TSS_ROLE = keccak256("TSS_ROLE");
    bytes32 public constant PAUSER_ROLE =
        keccak256("PAUSER_ROLE");

    /// @notice Tracks locked balance per PC20 token
    mapping(address => uint256) public lockedBalance;

    /// @notice Tracks total minted on each external chain
    ///         per PC20 token.
    ///         pc20Token => chainNamespace => mintedAmount
    mapping(address => mapping(string => uint256))
        public mintedOnChain;

    /// @notice Replay protection for unlock operations
    mapping(bytes32 => bool) public isProcessed;

    /// @notice Registry of approved PC20 tokens
    mapping(address => bool) public isRegisteredPC20;

    /// @notice PC20 token metadata for deployment
    struct PC20Metadata {
        string name;
        string symbol;
        uint8 decimals;
    }
    mapping(address => PC20Metadata) public pc20Metadata;

    // --- Events ---

    event PC20Registered(
        address indexed pc20Token,
        string name,
        string symbol,
        uint8 decimals
    );

    event PC20Locked(
        bytes32 indexed exportId,
        address indexed pc20Token,
        address indexed sender,
        string chainNamespace,
        bytes recipient,
        uint256 amount,
        string name,
        string symbol,
        uint8 decimals
    );

    event PC20Unlocked(
        bytes32 indexed burnId,
        address indexed pc20Token,
        address indexed recipient,
        string chainNamespace,
        uint256 amount
    );

    // --- Initialization ---

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address pauser,
        address tss
    ) external initializer {
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(TSS_ROLE, tss);
    }

    // --- Admin ---

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Register a PC20 token for cross-chain
    ///         export.
    /// @param pc20Token The token address on Push Chain
    /// @param name Wrapped token name
    /// @param symbol Wrapped token symbol
    /// @param decimals_ Token decimals
    function registerPC20(
        address pc20Token,
        string calldata name,
        string calldata symbol,
        uint8 decimals_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pc20Token == address(0)) revert Errors.ZeroAddress();
        isRegisteredPC20[pc20Token] = true;
        pc20Metadata[pc20Token] = PC20Metadata(
            name, symbol, decimals_
        );
        emit PC20Registered(pc20Token, name, symbol, decimals_);
    }

    // --- Export (Lock) ---

    /// @notice Lock PC20 tokens for export to an external
    ///         chain. Emits event for TSS to deploy + mint
    ///         wrapped tokens on the destination.
    /// @param pc20Token The PC20 token to export
    /// @param amount Amount to export
    /// @param chainNamespace Destination chain
    ///        (e.g., "eip155:1")
    /// @param recipient Destination address (bytes for
    ///        SVM compatibility)
    function lockForExport(
        address pc20Token,
        uint256 amount,
        string calldata chainNamespace,
        bytes calldata recipient
    ) external payable nonReentrant whenNotPaused {
        if (!isRegisteredPC20[pc20Token]) {
            revert Errors.NotSupported();
        }
        if (amount == 0) revert Errors.ZeroAmount();
        if (recipient.length == 0) {
            revert Errors.InvalidRecipient();
        }

        // Lock tokens
        IERC20(pc20Token).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
        lockedBalance[pc20Token] += amount;

        // Generate export ID
        bytes32 exportId = keccak256(
            abi.encode(
                msg.sender,
                pc20Token,
                amount,
                chainNamespace,
                recipient,
                block.timestamp
            )
        );

        PC20Metadata memory meta = pc20Metadata[pc20Token];

        emit PC20Locked(
            exportId,
            pc20Token,
            msg.sender,
            chainNamespace,
            recipient,
            amount,
            meta.name,
            meta.symbol,
            meta.decimals
        );
    }

    // --- Return (Unlock) ---

    /// @notice Unlock PC20 tokens after burn proof is
    ///         verified from an external chain. Only TSS.
    /// @param burnId Unique identifier from the burn event
    /// @param pc20Token The PC20 token to unlock
    /// @param recipient Recipient on Push Chain
    /// @param chainNamespace Source chain of the burn
    /// @param amount Amount to unlock
    function unlockFromBurn(
        bytes32 burnId,
        address pc20Token,
        address recipient,
        string calldata chainNamespace,
        uint256 amount
    ) external nonReentrant whenNotPaused onlyRole(TSS_ROLE) {
        if (isProcessed[burnId]) {
            revert Errors.PayloadExecuted();
        }
        if (recipient == address(0)) {
            revert Errors.ZeroAddress();
        }
        if (amount == 0) revert Errors.ZeroAmount();
        if (lockedBalance[pc20Token] < amount) {
            revert Errors.InsufficientBalance();
        }

        isProcessed[burnId] = true;
        lockedBalance[pc20Token] -= amount;
        mintedOnChain[pc20Token][chainNamespace] -= amount;

        IERC20(pc20Token).safeTransfer(recipient, amount);

        emit PC20Unlocked(
            burnId,
            pc20Token,
            recipient,
            chainNamespace,
            amount
        );
    }

    /// @notice Called by TSS after successful mint on
    ///         external chain to update accounting.
    function confirmMint(
        address pc20Token,
        string calldata chainNamespace,
        uint256 amount
    ) external onlyRole(TSS_ROLE) {
        mintedOnChain[pc20Token][chainNamespace] += amount;
    }
}
```

### 6.3 Modifications to Existing Contracts

#### 6.3.1 Vault.sol Modifications (External EVM Chain)

Add two new functions for PC20 wrapped token operations:

```solidity
/// @notice Mint wrapped PC20 tokens on this external
///         chain. Deploys the wrapped token via factory
///         if it doesn't exist yet.
/// @param subTxId Sub-transaction ID (replay protection)
/// @param universalTxId Universal transaction ID
/// @param pc20Token Address of the token on Push Chain
/// @param recipient Recipient of minted tokens
/// @param amount Amount to mint
/// @param name Token name (used only for first deploy)
/// @param symbol Token symbol (used only for first deploy)
/// @param decimals_ Token decimals
function mintPC20(
    bytes32 subTxId,
    bytes32 universalTxId,
    address pc20Token,
    address recipient,
    uint256 amount,
    string calldata name,
    string calldata symbol,
    uint8 decimals_
) external nonReentrant whenNotPaused onlyRole(TSS_ROLE) {
    if (recipient == address(0)) revert Errors.ZeroAddress();
    if (amount == 0) revert Errors.ZeroAmount();
    if (pc20Token == address(0)) revert Errors.ZeroAddress();

    // Deploy wrapped token if needed
    address wrapped = IWrappedTokenFactory(
        WRAPPED_TOKEN_FACTORY
    ).deploy(pc20Token, name, symbol, decimals_);

    // Mint to recipient
    IWrappedPC20(wrapped).mint(recipient, amount);

    emit PC20Minted(
        subTxId,
        universalTxId,
        pc20Token,
        wrapped,
        recipient,
        amount
    );
}

/// @notice Burn wrapped PC20 tokens as part of a return
///         flow. Called by UniversalGateway when user
///         initiates a PC20 return.
/// @param subTxId Sub-transaction ID
/// @param universalTxId Universal transaction ID
/// @param wrappedToken Address of the wrapped token
/// @param from Address to burn from
/// @param amount Amount to burn
function burnPC20(
    bytes32 subTxId,
    bytes32 universalTxId,
    address wrappedToken,
    address from,
    uint256 amount
) external nonReentrant whenNotPaused onlyRole(GATEWAY_ROLE) {
    if (amount == 0) revert Errors.ZeroAmount();

    // Burn the wrapped tokens
    IWrappedPC20(wrappedToken).burn(from, amount);

    address pc20Token = IWrappedPC20(wrappedToken).PC20_TOKEN();

    emit PC20Burned(
        subTxId,
        universalTxId,
        pc20Token,
        wrappedToken,
        from,
        amount
    );
}
```

**New state variables**:
```solidity
address public WRAPPED_TOKEN_FACTORY;
bytes32 public constant GATEWAY_ROLE =
    keccak256("GATEWAY_ROLE");
```

**New events**:
```solidity
event PC20Minted(
    bytes32 indexed subTxId,
    bytes32 indexed universalTxId,
    address indexed pc20Token,
    address wrappedToken,
    address recipient,
    uint256 amount
);

event PC20Burned(
    bytes32 indexed subTxId,
    bytes32 indexed universalTxId,
    address indexed pc20Token,
    address wrappedToken,
    address from,
    uint256 amount
);
```

#### 6.3.2 UniversalGateway.sol Modifications (External EVM Chain)

Add a new entry point for PC20 return flow:

```solidity
/// @notice Burn wrapped PC20 tokens and emit event for
///         TSS to unlock on Push Chain.
/// @param wrappedToken Address of the wrapped PC20 token
/// @param amount Amount to burn and return to Push Chain
/// @param pushRecipient Recipient address on Push Chain
/// @param revertRecipient Fallback recipient on this chain
function returnPC20(
    address wrappedToken,
    uint256 amount,
    address pushRecipient,
    address revertRecipient
) external payable nonReentrant whenNotPaused {
    if (amount == 0) revert Errors.ZeroAmount();
    if (pushRecipient == address(0)) {
        revert Errors.ZeroAddress();
    }
    if (revertRecipient == address(0)) {
        revert Errors.ZeroAddress();
    }

    // Validate it's a real wrapped PC20
    IWrappedTokenFactory factory = IWrappedTokenFactory(
        IVault(VAULT).WRAPPED_TOKEN_FACTORY()
    );
    address pc20Token = IWrappedPC20(wrappedToken)
        .PC20_TOKEN();
    if (factory.wrappedTokens(pc20Token) != wrappedToken) {
        revert Errors.NotSupported();
    }

    // Collect protocol fee
    uint256 nativeValue = msg.value;
    if (INBOUND_FEE > 0) {
        if (nativeValue < INBOUND_FEE) {
            revert Errors.InsufficientProtocolFee();
        }
        nativeValue -= INBOUND_FEE;
        (bool feeSuccess, ) = TSS_ADDRESS.call{
            value: INBOUND_FEE
        }("");
        if (!feeSuccess) revert Errors.DepositFailed();
        totalProtocolFeesCollected += INBOUND_FEE;
    }

    // Transfer wrapped tokens from user to Vault
    IERC20(wrappedToken).safeTransferFrom(
        msg.sender,
        VAULT,
        amount
    );

    // Vault burns the wrapped tokens
    bytes32 burnId = keccak256(
        abi.encode(
            msg.sender,
            wrappedToken,
            pc20Token,
            amount,
            pushRecipient,
            block.number
        )
    );

    IVault(VAULT).burnPC20(
        burnId,
        bytes32(0), // universalTxId generated by TSS
        wrappedToken,
        VAULT,      // burn from Vault (tokens transferred there)
        amount
    );

    emit PC20Return(
        burnId,
        pc20Token,
        wrappedToken,
        msg.sender,
        pushRecipient,
        revertRecipient,
        amount
    );
}
```

**New event**:
```solidity
event PC20Return(
    bytes32 indexed burnId,
    address indexed pc20Token,
    address wrappedToken,
    address indexed sender,
    address pushRecipient,
    address revertRecipient,
    uint256 amount
);
```

---

## 7. EVM Gateway Modifications

### 7.1 Summary of Changes

| Contract | Change Type | Description |
|----------|-------------|-------------|
| `Vault.sol` | **Modify** | Add `mintPC20()`, `burnPC20()`, `setWrappedTokenFactory()`, `GATEWAY_ROLE` |
| `UniversalGateway.sol` | **Modify** | Add `returnPC20()` entry point |
| `WrappedPC20.sol` | **New** | Minimal ERC20 with controlled mint/burn |
| `WrappedTokenFactory.sol` | **New** | CREATE2 deployer for WrappedPC20 |
| `IWrappedPC20.sol` | **New** | Interface for wrapped token |
| `IWrappedTokenFactory.sol` | **New** | Interface for factory |
| `Types.sol` | **Modify** | Add `TX_TYPE.PC20_EXPORT` (5), `TX_TYPE.PC20_RETURN` (6) |

### 7.2 Vault.sol Detailed Modifications

**New state variables to add**:
```solidity
/// @notice Factory for deploying wrapped PC20 tokens
address public WRAPPED_TOKEN_FACTORY;

/// @notice Role for UniversalGateway to call burnPC20
bytes32 public constant GATEWAY_ROLE =
    keccak256("GATEWAY_ROLE");
```

**New admin function**:
```solidity
function setWrappedTokenFactory(
    address factory
) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (factory == address(0)) revert Errors.ZeroAddress();
    address old = WRAPPED_TOKEN_FACTORY;
    WRAPPED_TOKEN_FACTORY = factory;
    emit WrappedTokenFactoryUpdated(old, factory);
}
```

**Storage layout consideration**: Since Vault is upgradeable (TransparentUpgradeableProxy), new state variables MUST be appended at the end of the storage layout. The `WRAPPED_TOKEN_FACTORY` and any new mappings must come after all existing state variables. A `__gap` slot reduction is needed if one exists.

### 7.3 UniversalGateway.sol Detailed Modifications

The `returnPC20()` function (specified in Section 6.3.2) needs the following supporting changes:

1. **Vault reference**: Already exists as `VAULT` state variable
2. **Factory access**: Via `IVault(VAULT).WRAPPED_TOKEN_FACTORY()`
3. **Protocol fee**: Reuses existing `INBOUND_FEE` mechanism
4. **Rate limiting**: PC20 return should be subject to epoch-based rate limiting. The `wrappedToken` address can be registered in `tokenToLimitThreshold` for rate limiting.

**CEA interaction**: CEAs can also return PC20 tokens via their multicall. The `returnPC20()` function should NOT block CEA callers since the CEA might hold wrapped PC20 tokens from a previous execution. However, the `sendUniversalTxFromCEA` path is separate and should remain unchanged.

### 7.4 Event Flow Diagram

**Export (Push -> EVM)**:
```
1. User calls PC20Vault.lockForExport() on Push Chain
   -> Emits PC20Locked(exportId, pc20Token, chainNamespace, recipient, amount, name, symbol, decimals)

2. TSS observes PC20Locked event
   -> Calls Vault.mintPC20(subTxId, universalTxId, pc20Token, recipient, amount, name, symbol, decimals) on external chain
   -> If first time: WrappedTokenFactory.deploy() called internally
   -> WrappedPC20.mint(recipient, amount) called

3. Vault emits PC20Minted(subTxId, universalTxId, pc20Token, wrappedToken, recipient, amount)

4. TSS confirms mint on Push Chain
   -> PC20Vault.confirmMint(pc20Token, chainNamespace, amount)
```

**Return (EVM -> Push)**:
```
1. User approves wrappedToken to UniversalGateway
2. User calls UniversalGateway.returnPC20(wrappedToken, amount, pushRecipient, revertRecipient)
   -> Transfers wrappedToken from user to Vault
   -> Vault.burnPC20() burns the tokens
   -> Emits PC20Return(burnId, pc20Token, wrappedToken, sender, pushRecipient, revertRecipient, amount)

3. TSS observes PC20Return event
   -> Calls PC20Vault.unlockFromBurn(burnId, pc20Token, recipient, chainNamespace, amount) on Push Chain
   -> Original PC20 tokens released to recipient
```

---

## 8. SVM Gateway Modifications

### 8.1 Architecture Differences from EVM

Solana's programming model differs fundamentally:
- **No CREATE2**: Token deployment uses the SPL Token program, not custom factory contracts
- **PDAs**: Token mint authorities are PDAs, not EOAs
- **Associated Token Accounts (ATAs)**: Each user needs an ATA per token mint
- **CPI**: Cross-program invocations replace internal contract calls

### 8.2 New Components for SVM

#### 8.2.1 Wrapped SPL Token Deployment

Instead of a factory contract, wrapped PC20 tokens on Solana are SPL Token mints with the **Vault PDA as the mint authority**.

```rust
/// PDA seeds for the wrapped token mint
/// seeds = [b"wrapped_pc20", pc20_token_address[20]]
///
/// The Vault PDA holds mint authority over this mint.
/// TSS triggers minting via invoke_signed using Vault seeds.

pub struct WrappedPC20Mint {
    /// Push Chain token address (20 bytes)
    pub pc20_token: [u8; 20],
    /// Whether this mint has been initialized
    pub initialized: bool,
    /// The SPL token mint address
    pub mint: Pubkey,
    /// Bump for the PDA
    pub bump: u8,
}
```

**Deployment instruction**:
```rust
pub fn deploy_wrapped_pc20(
    ctx: Context<DeployWrappedPC20>,
    pc20_token: [u8; 20],
    name: String,
    symbol: String,
    decimals: u8,
) -> Result<()> {
    // 1. Derive mint PDA
    // 2. Create mint account via CPI to Token Program
    // 3. Set mint authority to Vault PDA
    // 4. Create metadata via CPI to Token Metadata Program
    // 5. Store mapping in WrappedPC20Mint PDA
}
```

**Account structure**:
```rust
#[derive(Accounts)]
#[instruction(pc20_token: [u8; 20])]
pub struct DeployWrappedPC20<'info> {
    #[account(mut)]
    pub caller: Signer<'info>,

    #[account(
        init,
        payer = caller,
        space = WrappedPC20Mint::LEN,
        seeds = [b"wrapped_pc20", &pc20_token],
        bump
    )]
    pub wrapped_pc20_config: Account<'info, WrappedPC20Mint>,

    /// The SPL token mint (created via CPI)
    /// CHECK: Initialized by Token Program CPI
    #[account(mut)]
    pub mint: UncheckedAccount<'info>,

    /// Vault PDA as mint authority
    #[account(
        seeds = [b"vault"],
        bump
    )]
    pub vault: SystemAccount<'info>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
}
```

#### 8.2.2 Mint Instruction (TSS-Authorized)

```rust
pub fn mint_wrapped_pc20(
    ctx: Context<MintWrappedPC20>,
    sub_tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    pc20_token: [u8; 20],
    amount: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
) -> Result<()> {
    // 1. Verify TSS signature (same pattern as finalize)
    // 2. Replay protection via ExecutedSubTx PDA
    // 3. Resolve mint from WrappedPC20Mint PDA
    // 4. Deploy mint if not initialized
    // 5. Create recipient ATA if needed
    // 6. Mint tokens via CPI with Vault PDA as signer
    //    invoke_signed(
    //        &spl_token::instruction::mint_to(
    //            token_program, mint, recipient_ata,
    //            vault, &[], amount
    //        )?,
    //        accounts,
    //        &[vault_seeds]
    //    )?;
    // 7. Emit event
}
```

#### 8.2.3 Burn Instruction (User-Initiated)

```rust
pub fn burn_wrapped_pc20(
    ctx: Context<BurnWrappedPC20>,
    pc20_token: [u8; 20],
    amount: u64,
    push_recipient: [u8; 20],
    revert_recipient: Pubkey,
) -> Result<()> {
    // 1. Validate wrapped token exists
    // 2. Burn tokens from user's ATA via CPI
    //    invoke(
    //        &spl_token::instruction::burn(
    //            token_program, user_ata, mint,
    //            user, &[], amount
    //        )?,
    //        accounts
    //    )?;
    // 3. Emit PC20Burn event for TSS to observe
}
```

### 8.3 TSS Message Format for SVM PC20

**New instruction IDs**:
```
instruction_id = 5: mint_wrapped_pc20
instruction_id = 6: burn_wrapped_pc20 (return flow, TSS confirmation)
```

**Mint message**:
```
PREFIX || instruction_id(5) || chain_id || amount (8 BE) ||
sub_tx_id (32) || universal_tx_id (32) ||
pc20_token (20) || recipient (32) ||
name_hash (32) || symbol_hash (32) || decimals (1)
```

### 8.4 Summary of SVM Changes

| Component | Change Type | Description |
|-----------|-------------|-------------|
| `state.rs` | **Modify** | Add `WrappedPC20Mint` account struct |
| `instructions/` | **New files** | `pc20_deploy.rs`, `pc20_mint.rs`, `pc20_burn.rs` |
| `lib.rs` | **Modify** | Add new instruction handlers |
| `tss.rs` | **Modify** | Add instruction_id 5, 6 message formats |
| `errors.rs` | **Modify** | Add PC20-specific error codes |
| CLI tools | **New** | `pc20:{deploy,mint,status}` commands |

### 8.5 Rate Limiting for SVM PC20

PC20 wrapped tokens should be subject to the same epoch-based rate limiting as regular SPL tokens:

- Each wrapped PC20 mint needs a `TokenRateLimit` PDA: `seeds = [b"rate_limit", wrapped_mint]`
- Admin sets limit thresholds via existing `set_token_rate_limit` instruction
- `consume_rate_limit` called during burn (return flow) to prevent rapid drain

---

## 9. Push Chain Core Contract Modifications

### 9.1 UniversalCore Changes

UniversalCore needs awareness of PC20 tokens vs PRC20 tokens:

```solidity
/// @notice Registry of PC20 tokens approved for
///         cross-chain export
mapping(address => bool) public isPC20Token;

/// @notice Chain namespaces where each PC20 token has
///         been deployed
mapping(address => string[])
    public pc20DeployedChains;

/// @notice Register a PC20 token for cross-chain export
function registerPC20Token(
    address pc20Token
) external onlyRole(MANAGER_ROLE) {
    isPC20Token[pc20Token] = true;
}

/// @notice Get gas and fee quote for PC20 export
function getPC20ExportGasAndFees(
    address pc20Token,
    string calldata chainNamespace,
    uint256 gasLimit
) external view returns (
    address gasToken,
    uint256 gasFee,
    uint256 protocolFee,
    uint256 gasPrice
) {
    // Same logic as getOutboundTxGasAndFees
    // but resolves chain from the target namespace
    // directly (not from PRC20 mapping)
}
```

### 9.2 UniversalGatewayPC Changes

The outbound gateway needs a new function for PC20 exports:

```solidity
/// @notice Export a PC20 token to an external chain.
///         Locks the token in PC20Vault and emits event
///         for TSS to mint on the destination.
/// @param req Export request containing token, amount,
///            destination chain, and recipient
function exportPC20(
    PC20ExportRequest calldata req
) external payable whenNotPaused nonReentrant {
    // 1. Validate token is registered PC20
    // 2. Validate recipient and chainNamespace
    // 3. Quote gas fees for destination chain
    // 4. Transfer PC20 from user to PC20Vault
    // 5. Swap and collect gas fees (same as sendUniversalTxOutbound)
    // 6. Emit PC20Export event for TSS
}
```

**New struct**:
```solidity
struct PC20ExportRequest {
    address token;              // PC20 token on Push Chain
    uint256 amount;             // Amount to export
    string chainNamespace;      // Destination chain
    bytes recipient;            // Destination address
    uint256 gasLimit;           // Gas limit for fee quote
    address revertRecipient;    // Fallback on Push Chain
}
```

**New event**:
```solidity
event PC20Export(
    bytes32 indexed exportId,
    address indexed pc20Token,
    address indexed sender,
    string chainNamespace,
    bytes recipient,
    uint256 amount,
    address gasToken,
    uint256 gasFee,
    uint256 gasLimit,
    uint256 protocolFee,
    address revertRecipient,
    string name,
    string symbol,
    uint8 decimals
);
```

### 9.3 UEA/CEA Implications

**UEA**: No changes needed. UEAs on Push Chain interact with PC20 tokens as regular ERC20s. The export flow is initiated by the user through `UniversalGatewayPC.exportPC20()`.

**CEA (External Chains)**:
- CEAs CAN hold wrapped PC20 tokens received via multicall execution
- CEAs can call `UniversalGateway.returnPC20()` to burn wrapped tokens and return them to Push Chain
- No special CEA modifications needed -- the existing multicall pattern handles this

**CEA (Push Chain)**:
- CEAs on Push Chain can call `UniversalGatewayPC.exportPC20()` to export PC20 tokens they hold
- No special modifications needed

---

## 10. Blockers and Mitigations

### 10.1 EVM-Specific Blockers

#### Blocker 1: Vault Storage Layout Compatibility

**Problem**: Vault is deployed behind a TransparentUpgradeableProxy. Adding new state variables (`WRAPPED_TOKEN_FACTORY`, `GATEWAY_ROLE`) must preserve storage layout.

**Mitigation**:
- Append new variables AFTER all existing state variables
- If a `__gap` exists, reduce it by the number of new slots
- Run `forge inspect Vault storageLayout` before and after to verify no collisions
- Write a storage layout compatibility test

#### Blocker 2: Vault Needs GATEWAY_ROLE

**Problem**: Currently, Vault only has `TSS_ROLE` and `PAUSER_ROLE`. The `burnPC20()` function needs to be called by UniversalGateway, which requires a new `GATEWAY_ROLE`.

**Mitigation**: Add `GATEWAY_ROLE` and grant it to the UniversalGateway address during initialization (or via admin after upgrade). This is a one-time admin action.

#### Blocker 3: WrappedPC20 Mint Authority Immutability

**Problem**: The `MINTER` on WrappedPC20 is immutable (set to Vault). If Vault is upgraded to a new proxy address, all existing wrapped tokens become unmintable.

**Mitigation**:
- Vault address should NOT change across upgrades (it's behind a proxy, so the proxy address is stable)
- Document that Vault proxy address is permanent
- Alternative: Use a mutable minter with a two-step transfer pattern (adds complexity, not recommended initially)

#### Blocker 4: CREATE2 Address Depends on Bytecode

**Problem**: If WrappedPC20 contract code changes in a future version, CREATE2 will produce a different address for the same PC20 token, breaking the mapping.

**Mitigation**:
- Version the factory: `WrappedTokenFactoryV1`, `WrappedTokenFactoryV2`
- New versions deploy to new addresses but old tokens remain at old addresses
- Alternatively, use CREATE3 (Axelar pattern) where address depends only on salt, not bytecode. This requires an additional proxy layer.

#### Blocker 5: Gas Costs for Token Deployment

**Problem**: Deploying a WrappedPC20 via CREATE2 on Ethereum mainnet is expensive (~500K-1M gas). The TSS needs to cover this cost.

**Mitigation**:
- Gas cost is covered by the gas fee paid by the user during export
- `gasLimit` in the export request should account for deployment gas
- After first deployment, subsequent mints are cheap (~50K gas)
- Consider a higher gas limit for "first export" vs "subsequent export"

### 10.2 SVM-Specific Blockers

#### Blocker 6: SPL Token Mint Authority Model

**Problem**: On Solana, mint authority is a single Pubkey. Unlike EVM where Vault calls `WrappedPC20.mint()`, on SVM the Vault PDA must be the mint authority and use `invoke_signed`.

**Mitigation**: The Vault PDA is already used as authority for vault token accounts. The same pattern extends to wrapped PC20 mints. The PDA seeds for signing are `[b"vault", bump]`.

#### Blocker 7: ATA Creation for Recipients

**Problem**: On Solana, recipients need an Associated Token Account (ATA) for each SPL token. If the recipient doesn't have an ATA for the wrapped PC20 token, the mint fails.

**Mitigation**:
- Create ATA during the mint instruction if it doesn't exist (caller pays rent)
- Use `create_associated_token_account` CPI from the gateway program
- Gas fee should cover rent costs
- This is the same pattern already used in the existing `finalize_universal_tx` instruction

#### Blocker 8: Token Metadata on SVM

**Problem**: SPL tokens don't have built-in name/symbol fields. The Metaplex Token Metadata program is needed for human-readable token info.

**Mitigation**:
- Use the Token Metadata program CPI during deployment
- Pass name, symbol, and URI (optional) from the export event
- The metadata program is standard and well-supported

#### Blocker 9: No CREATE2 Equivalent on Solana

**Problem**: Cannot guarantee deterministic token addresses on Solana like EVM. Token mint addresses depend on PDA derivation.

**Mitigation**:
- Use PDA derivation: `seeds = [b"wrapped_pc20", pc20_token_address[20]]` for the config PDA
- The actual mint can be a keypair generated deterministically from seeds, or use `find_program_address` for PDA mints
- Store the mapping `pc20_token -> mint_address` in the config PDA
- TSS can predict the mint address before deployment using `find_program_address`

### 10.3 Push Chain-Specific Blockers

#### Blocker 10: UniversalCore Token Registry

**Problem**: UniversalCore manages PRC20 tokens (external-to-Push mapping). PC20 is the reverse (Push-to-external mapping). The registry needs to distinguish between these.

**Mitigation**:
- Add `isPC20Token` mapping to UniversalCore (or a separate PC20Registry contract)
- PC20 tokens are registered by admin with metadata (name, symbol, decimals, approved chains)
- UniversalCore already has `isSupportedToken` for PRC20 -- keep this separate from PC20 registration

#### Blocker 11: Gas Fee Quoting for PC20 Export

**Problem**: `getOutboundTxGasAndFees()` resolves chain from the PRC20 token address. For PC20 export, the chain is specified directly (since the PC20 token is on Push Chain, not linked to a specific external chain).

**Mitigation**:
- Add `getPC20ExportGasAndFees(pc20Token, chainNamespace, gasLimit)` to UniversalCore
- This function resolves gas pricing from `chainNamespace` directly (using `gasPriceByChainNamespace` mapping)
- Protocol fee can be per-PC20 or a flat rate

#### Blocker 12: PC20 Return Flow -- Unlocking on Push Chain

**Problem**: When TSS receives a burn proof from an external chain, it needs to call `PC20Vault.unlockFromBurn()` on Push Chain. The current TSS infrastructure monitors `UniversalTx` events but not `PC20Return` events.

**Mitigation**:
- TSS needs to monitor two new event types: `PC20Locked` (from Push Chain) and `PC20Return` (from external chains)
- This is an off-chain (validator/relayer) modification, not a smart contract blocker
- Event structure should be similar to existing events for easy integration

### 10.4 Cross-Chain Blockers

#### Blocker 13: Supply Accounting Integrity

**Problem**: If TSS mints on an external chain but the Push Chain `confirmMint()` call fails or is delayed, the `mintedOnChain` accounting is wrong. This could allow more tokens to be unlocked than were minted.

**Mitigation**:
- The `lockedBalance` on Push Chain is the source of truth. Unlocking can never exceed `lockedBalance` regardless of `mintedOnChain` accounting.
- `confirmMint()` is an accounting optimization, not a security gate
- For stronger guarantees, implement a Global Accountant pattern (Wormhole-style) where validators track `locked - minted` invariant off-chain and refuse to sign if negative

#### Blocker 14: Revert Flow for PC20 Export

**Problem**: If TSS fails to mint on the external chain (e.g., gas issues, chain downtime), the PC20 tokens remain locked in PC20Vault with no way to recover.

**Mitigation**:
- Implement a `revertPC20Export()` function on PC20Vault callable by TSS_ROLE
- Takes the `exportId` and returns locked tokens to the original sender
- Uses `revertRecipient` from the export request
- Replay protection via `isProcessed[exportId]` mapping
- This mirrors the existing `Vault.revertUniversalTx()` pattern

```solidity
function revertPC20Export(
    bytes32 exportId,
    address pc20Token,
    address revertRecipient,
    uint256 amount
) external nonReentrant whenNotPaused onlyRole(TSS_ROLE) {
    if (isProcessed[exportId]) {
        revert Errors.PayloadExecuted();
    }
    isProcessed[exportId] = true;

    lockedBalance[pc20Token] -= amount;
    IERC20(pc20Token).safeTransfer(
        revertRecipient,
        amount
    );

    emit PC20ExportReverted(
        exportId,
        pc20Token,
        revertRecipient,
        amount
    );
}
```

---

## 11. Solution Ranking

### Ranking Criteria

| Criterion | Weight | Description |
|-----------|--------|-------------|
| Security | 35% | Mint authority control, supply integrity, attack surface |
| Feasibility | 25% | Development effort, compatibility with current infra |
| Effectiveness | 20% | Covers all requirements, clean UX |
| Maintainability | 10% | Code complexity, upgrade paths |
| Performance | 10% | Gas costs, latency |

### Approach Comparison

#### Approach A: CEA-Based Multicall Deployment

| Criterion | Score (1-10) | Notes |
|-----------|-------------|-------|
| Security | 2 | Fatal flaw: CEA mint authority grants every user mint control |
| Feasibility | 7 | Reuses existing infrastructure |
| Effectiveness | 5 | Works but architecturally wrong |
| Maintainability | 4 | Mixing per-user and protocol operations |
| Performance | 6 | Multicall overhead |
| **Weighted** | **3.85** | |

#### Approach B: Vault-Direct Mint/Burn (RECOMMENDED)

| Criterion | Score (1-10) | Notes |
|-----------|-------------|-------|
| Security | 9 | Single mint authority (Vault/TSS), no CEA involvement in minting |
| Feasibility | 7 | Moderate effort: new contracts + Vault upgrade |
| Effectiveness | 9 | Clean separation, deterministic addresses, covers all flows |
| Maintainability | 8 | Modular design, clear interfaces |
| Performance | 8 | Direct mint (no multicall), CREATE2 is cheap after first deploy |
| **Weighted** | **8.25** | |

#### Approach C: Standalone PC20 Bridge

| Criterion | Score (1-10) | Notes |
|-----------|-------------|-------|
| Security | 8 | Isolated from existing bridge (no blast radius) |
| Feasibility | 3 | Massive development effort, code duplication |
| Effectiveness | 8 | Purpose-built |
| Maintainability | 4 | Two separate bridge systems to maintain |
| Performance | 7 | No legacy overhead |
| **Weighted** | **5.85** | |

### Final Ranking

| Rank | Approach | Score | Recommendation |
|------|----------|-------|----------------|
| 1 | **B: Vault-Direct Mint/Burn** | **8.25** | **Recommended** |
| 2 | C: Standalone PC20 Bridge | 5.85 | Only if Vault upgrade is impossible |
| 3 | A: CEA-Based Multicall | 3.85 | Rejected (security flaw) |

---

## 12. Appendix: Full Contract Interface Specifications

### 12.1 IWrappedPC20

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IWrappedPC20 {
    /// @notice The Push Chain token this wraps
    function PC20_TOKEN() external view returns (address);

    /// @notice Push Chain namespace
    function PC20_CHAIN_NAMESPACE()
        external view returns (string memory);

    /// @notice Authorized minter (Vault)
    function MINTER() external view returns (address);

    /// @notice Mint tokens. Only callable by MINTER.
    function mint(address to, uint256 amount) external;

    /// @notice Burn tokens. Only callable by MINTER.
    function burn(address from, uint256 amount) external;
}
```

### 12.2 IWrappedTokenFactory

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IWrappedTokenFactory {
    /// @notice Deploy a WrappedPC20 for the given PC20
    ///         token. Idempotent.
    function deploy(
        address pc20Token,
        string calldata name,
        string calldata symbol,
        uint8 decimals_
    ) external returns (address wrapped);

    /// @notice Predict deployed address before deployment
    function getAddress(
        address pc20Token,
        string calldata name,
        string calldata symbol,
        uint8 decimals_
    ) external view returns (address predicted);

    /// @notice Lookup mapping
    function wrappedTokens(
        address pc20Token
    ) external view returns (address);

    /// @notice Check if a token is a wrapped PC20
    function isWrappedToken(
        address token
    ) external view returns (bool);

    /// @notice Vault address (set as MINTER on all tokens)
    function VAULT() external view returns (address);

    /// @notice Push Chain namespace
    function PC_CHAIN_NAMESPACE()
        external view returns (string memory);
}
```

### 12.3 IPC20Vault

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IPC20Vault {
    // --- Events ---
    event PC20Registered(
        address indexed pc20Token,
        string name,
        string symbol,
        uint8 decimals
    );
    event PC20Locked(
        bytes32 indexed exportId,
        address indexed pc20Token,
        address indexed sender,
        string chainNamespace,
        bytes recipient,
        uint256 amount,
        string name,
        string symbol,
        uint8 decimals
    );
    event PC20Unlocked(
        bytes32 indexed burnId,
        address indexed pc20Token,
        address indexed recipient,
        string chainNamespace,
        uint256 amount
    );
    event PC20ExportReverted(
        bytes32 indexed exportId,
        address indexed pc20Token,
        address indexed revertRecipient,
        uint256 amount
    );

    // --- Admin ---
    function registerPC20(
        address pc20Token,
        string calldata name,
        string calldata symbol,
        uint8 decimals_
    ) external;

    // --- Export (Lock) ---
    function lockForExport(
        address pc20Token,
        uint256 amount,
        string calldata chainNamespace,
        bytes calldata recipient
    ) external payable;

    // --- Return (Unlock) ---
    function unlockFromBurn(
        bytes32 burnId,
        address pc20Token,
        address recipient,
        string calldata chainNamespace,
        uint256 amount
    ) external;

    // --- Revert ---
    function revertPC20Export(
        bytes32 exportId,
        address pc20Token,
        address revertRecipient,
        uint256 amount
    ) external;

    // --- Accounting ---
    function confirmMint(
        address pc20Token,
        string calldata chainNamespace,
        uint256 amount
    ) external;

    // --- Views ---
    function lockedBalance(
        address pc20Token
    ) external view returns (uint256);
    function mintedOnChain(
        address pc20Token,
        string calldata chainNamespace
    ) external view returns (uint256);
    function isRegisteredPC20(
        address pc20Token
    ) external view returns (bool);
    function isProcessed(
        bytes32 id
    ) external view returns (bool);
}
```

### 12.4 Updated Vault Interface (Additions)

```solidity
// Add to IVault.sol:

event PC20Minted(
    bytes32 indexed subTxId,
    bytes32 indexed universalTxId,
    address indexed pc20Token,
    address wrappedToken,
    address recipient,
    uint256 amount
);

event PC20Burned(
    bytes32 indexed subTxId,
    bytes32 indexed universalTxId,
    address indexed pc20Token,
    address wrappedToken,
    address from,
    uint256 amount
);

event WrappedTokenFactoryUpdated(
    address indexed oldFactory,
    address indexed newFactory
);

function mintPC20(
    bytes32 subTxId,
    bytes32 universalTxId,
    address pc20Token,
    address recipient,
    uint256 amount,
    string calldata name,
    string calldata symbol,
    uint8 decimals_
) external;

function burnPC20(
    bytes32 subTxId,
    bytes32 universalTxId,
    address wrappedToken,
    address from,
    uint256 amount
) external;

function WRAPPED_TOKEN_FACTORY()
    external view returns (address);

function setWrappedTokenFactory(
    address factory
) external;
```

### 12.5 Updated UniversalGateway Interface (Additions)

```solidity
// Add to IUniversalGateway.sol:

event PC20Return(
    bytes32 indexed burnId,
    address indexed pc20Token,
    address wrappedToken,
    address indexed sender,
    address pushRecipient,
    address revertRecipient,
    uint256 amount
);

function returnPC20(
    address wrappedToken,
    uint256 amount,
    address pushRecipient,
    address revertRecipient
) external payable;
```

### 12.6 Complete Modification Checklist

#### EVM External Chain Contracts

| # | Contract | Action | Function/Variable | Notes |
|---|----------|--------|-------------------|-------|
| 1 | `WrappedPC20.sol` | NEW | Full contract | Minimal ERC20 with controlled mint/burn |
| 2 | `WrappedTokenFactory.sol` | NEW | Full contract | CREATE2 deployer |
| 3 | `IWrappedPC20.sol` | NEW | Interface | |
| 4 | `IWrappedTokenFactory.sol` | NEW | Interface | |
| 5 | `Vault.sol` | MODIFY | Add `mintPC20()` | TSS mints wrapped tokens |
| 6 | `Vault.sol` | MODIFY | Add `burnPC20()` | Gateway triggers burn |
| 7 | `Vault.sol` | MODIFY | Add `WRAPPED_TOKEN_FACTORY` | State variable |
| 8 | `Vault.sol` | MODIFY | Add `GATEWAY_ROLE` | New role for Gateway |
| 9 | `Vault.sol` | MODIFY | Add `setWrappedTokenFactory()` | Admin setter |
| 10 | `IVault.sol` | MODIFY | Add new function signatures + events | |
| 11 | `UniversalGateway.sol` | MODIFY | Add `returnPC20()` | User entry point for return |
| 12 | `IUniversalGateway.sol` | MODIFY | Add new function signature + event | |
| 13 | `Types.sol` | MODIFY | Add `TX_TYPE.PC20_EXPORT`, `TX_TYPE.PC20_RETURN` | New TX types |

#### Push Chain Contracts

| # | Contract | Action | Function/Variable | Notes |
|---|----------|--------|-------------------|-------|
| 14 | `PC20Vault.sol` | NEW | Full contract | Lock/unlock PC20 tokens |
| 15 | `IPC20Vault.sol` | NEW | Interface | |
| 16 | `UniversalGatewayPC.sol` | MODIFY | Add `exportPC20()` | User entry point for export |
| 17 | `UniversalCore.sol` | MODIFY | Add `isPC20Token` mapping | Token registry |
| 18 | `UniversalCore.sol` | MODIFY | Add `getPC20ExportGasAndFees()` | Gas quoting |
| 19 | `TypesUGPC.sol` | MODIFY | Add `PC20ExportRequest` struct | |
| 20 | `IUniversalGatewayPC.sol` | MODIFY | Add new function signature + event | |

#### SVM Gateway (Solana)

| # | Component | Action | Description |
|---|-----------|--------|-------------|
| 21 | `state.rs` | MODIFY | Add `WrappedPC20Mint` account struct |
| 22 | `instructions/pc20_deploy.rs` | NEW | Deploy wrapped SPL token |
| 23 | `instructions/pc20_mint.rs` | NEW | TSS-authorized mint |
| 24 | `instructions/pc20_burn.rs` | NEW | User-initiated burn |
| 25 | `lib.rs` | MODIFY | Register new instructions |
| 26 | `tss.rs` | MODIFY | instruction_id 5, 6 |
| 27 | `errors.rs` | MODIFY | PC20-specific errors |
| 28 | CLI tools | NEW | `pc20:{deploy,mint,status}` |

#### Off-Chain / Infrastructure

| # | Component | Action | Description |
|---|-----------|--------|-------------|
| 29 | TSS Relayer | MODIFY | Monitor `PC20Locked` and `PC20Return` events |
| 30 | TSS Relayer | MODIFY | Call `Vault.mintPC20()` on export |
| 31 | TSS Relayer | MODIFY | Call `PC20Vault.unlockFromBurn()` on return |
| 32 | TSS Relayer | MODIFY | Call `PC20Vault.confirmMint()` after successful mint |
| 33 | TSS Relayer | MODIFY | Handle PC20 revert flows |

### 12.7 Security Considerations Summary

| Risk | Severity | Mitigation |
|------|----------|------------|
| Unauthorized minting | Critical | Only Vault (TSS_ROLE) can call `mintPC20()`. WrappedPC20 has immutable MINTER. |
| Supply inflation | Critical | `lockedBalance` on PC20Vault is source of truth. Unlock never exceeds locked. |
| Replay attacks | High | `isProcessed` mapping on both PC20Vault and Vault prevents double-mint/unlock. |
| Wrapped token impersonation | High | `returnPC20()` validates token via WrappedTokenFactory registry. |
| Factory griefing | Medium | Only Vault can deploy via factory (prevents deploying with wrong metadata). |
| Storage slot collision (upgrade) | Medium | Append-only storage layout. Run `forge inspect` before/after. |
| Stuck funds (failed export) | Medium | `revertPC20Export()` returns locked tokens. |
| Gas cost spike (first deploy) | Low | User-paid gas covers deployment. Subsequent mints are cheap. |

### 12.8 Testing Strategy

#### Unit Tests (EVM)

```
test/pc20/
  1_WrappedPC20.t.sol          -- mint, burn, access control, decimals
  2_WrappedTokenFactory.t.sol  -- deploy, idempotency, address prediction, access control
  3_PC20Vault.t.sol            -- register, lock, unlock, revert, accounting
  4_VaultMintPC20.t.sol        -- mintPC20, burnPC20, factory integration
  5_GatewayReturnPC20.t.sol    -- returnPC20 flow, fee collection, validation
  6_PC20EndToEnd.t.sol         -- Full export + return cycle
```

#### Integration Tests (SVM)

```
tests/
  pc20-deploy.test.ts          -- Deploy wrapped SPL token
  pc20-mint.test.ts            -- TSS-authorized mint
  pc20-burn.test.ts            -- User-initiated burn + event
  pc20-e2e.test.ts             -- Full export + return cycle
```

#### Invariant Tests

```
- lockedBalance[token] >= sum(mintedOnChain[token][*]) at all times
- wrappedToken.totalSupply() <= PC20Vault.lockedBalance[pc20Token]
- No WrappedPC20 can be minted without corresponding lock on PC20Vault
- isProcessed prevents double-unlock and double-mint
```

---

*End of Research Document*
