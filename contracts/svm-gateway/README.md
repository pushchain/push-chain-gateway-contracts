# Solana Universal Gateway

Production-ready Solana program for cross-chain asset bridging to Push Chain with complete Pyth oracle integration.

## Program Details

**Program ID:** `CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS`  
**Network:** Solana Devnet  
**Pyth Oracle:** SOL/USD feed `7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE`

## Core Functions

### Deposit Functions
- **`send_tx_with_gas`** - Native SOL gas deposits with USD caps ($1-$10)
- **`send_funds`** - SPL token bridging (whitelisted tokens only)
- **`send_funds_native`** - Native SOL bridging (high value, no caps)
- **`send_tx_with_funds`** - Combined SPL tokens + gas with payload execution

### Admin & TSS Functions
- **`initialize`** - Deploy gateway with admin/pauser/caps and set Pyth feed
- **`pause/unpause`** - Emergency controls
- **`set_caps_usd`** - Update USD caps (8 decimal precision)
- **`whitelist_token/remove_token`** - Manage supported SPL tokens
- **`init_tss` / `withdraw_tss`** - TSS-verified withdrawals (ECDSA secp256k1)

## Account Structure

### PDAs (Program Derived Addresses)
- **Config:** `[b"config"]` - Gateway state, caps, authorities, Pyth config
- **Vault:** `[b"vault"]` - Native SOL storage, authority for SPL token vault ATAs
- **Whitelist:** `[b"whitelist"]` - SPL token registry (max 50 tokens)
- **TSS:** `[b"tss"]` - TSS ETH address (20 bytes), chain id, nonce, authority

### ATAs (Associated Token Accounts)
- **User Token ATA:** User's SPL token account (created by user)
- **Vault Token ATA:** Gateway's SPL token account (created by admin, owned by vault PDA)
- **Admin Token ATA:** Admin's SPL token account (created by admin for withdrawals)

## 🚀 Command Line Tools

### Token Management Commands

#### Create New Tokens
```bash
# Create a USDC-like token
npm run token:create -- -n "USD Coin" -s "USDC" -d "A fully-backed U.S. dollar stablecoin"

# Create any custom token
npm run token:create -- -n "My Token" -s "MTK" -d "My custom token" --decimals 8
```

#### Mint Tokens to Any Address
```bash
# Mint using token symbol
npm run token:mint -- -m USDC -r 9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM -a 1000

# Mint using mint address
npm run token:mint -- -m 4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU -r ADDRESS -a 500
```

#### Whitelist Tokens
```bash
# Whitelist using token symbol
npm run token:whitelist -- -m USDC

# Whitelist using mint address
npm run token:whitelist -- -m 4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU
```

#### List All Tokens
```bash
npm run token:list
```

### Gateway Testing Commands

#### Test Deposit Functionality
```bash
# Test deposit using token symbol
npm run test:deposit -- -m USDC -a 1000

# Test deposit using mint address
npm run test:deposit -- -m 4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU -a 500
```

#### Full Test (Whitelist + Deposit)
```bash
# Run complete test
npm run test:full -- -m USDC -a 1000
```

## Complete Workflow Example

```bash
# 1. Create a new token
npm run token:create -- -n "Test Token" -s "TEST" -d "A test token for gateway"

# 2. Mint some tokens
npm run token:mint -- -m TEST -r YOUR_ADDRESS -a 10000

# 3. Test gateway integration
npm run test:full -- -m TEST -a 1000
```

## Integration Guide

### 1. Initialize Gateway
```typescript
await program.methods
  .initialize(adminPubkey, pauserPubkey, tssPubkey, minCapUsd, maxCapUsd, pythFeedId)
  .accounts({ config: configPda, vault: vaultPda, admin: adminPubkey })
  .rpc();
```

### 2. Create Vault ATA & Whitelist SPL Token
```typescript
// Admin creates vault ATA first
const vaultAta = await spl.getOrCreateAssociatedTokenAccount(
  connection, adminKeypair, tokenMint, vaultPda, true
);

// Then whitelist the token
await program.methods
  .whitelistToken(tokenMint)
  .accounts({ 
    config: configPda, whitelist: whitelistPda, admin: adminPubkey,
    systemProgram: SystemProgram.programId 
  })
  .rpc();
```

### 3. SPL Token Bridge
```typescript
// User creates their own ATA first
const userAta = await spl.getOrCreateAssociatedTokenAccount(
  connection, userKeypair, tokenMint, userPubkey
);

await program.methods
  .sendFunds(recipient, tokenMint, amount, revertSettings)
  .accounts({
    config: configPda, vault: vaultPda, user: userPubkey,
    tokenWhitelist: whitelistPda, 
    userTokenAccount: userAta.address,
    gatewayTokenAccount: vaultAta.address,
    bridgeToken: tokenMint, 
    tokenProgram: TOKEN_PROGRAM_ID,
    systemProgram: SystemProgram.programId
  })
  .rpc();
```

### 4. TSS Configuration & Verified Withdrawals
```typescript
// Initialize TSS
const ethAddress = "0xEbf0Cfc34E07ED03c05615394E2292b387B63F12";
const ethAddressBytes = Buffer.from(ethAddress.slice(2), 'hex');

await program.methods
  .initTss(Array.from(ethAddressBytes), new anchor.BN(1))
  .accounts({ 
    tssPda, authority: admin, systemProgram: SystemProgram.programId 
  })
  .rpc();

// TSS Message Construction
const messageData = Buffer.concat([
  Buffer.from("PUSH_CHAIN_SVM"),
  Buffer.from([1]), // instruction_id (1=SOL, 2=SPL, 3=revert)
  Buffer.from(chainId.toArray("be", 8)),
  Buffer.from(nonce.toArray("be", 8)),
  Buffer.from(amount.toArray("be", 8)),
  recipient.toBuffer()
]);
const messageHash = keccak_256(messageData);

// Sign with ETH private key
const sig = await secp.sign(messageHash, ethPrivateKey, { recovered: true, der: false });
const signature = sig[0];
const recoveryId = sig[1];

// Withdraw
await program.methods
  .withdrawTss(new anchor.BN(amount), Array.from(signature), recoveryId, 
               Array.from(messageHash), new anchor.BN(nonce))
  .accounts({ 
    config: configPda, vault: vaultPda, tssPda, recipient, 
    systemProgram: SystemProgram.programId 
  })
  .rpc();
```

## Security Features

- **Pause functionality** - Emergency stop for all user functions
- **USD caps** - Real-time Pyth oracle price validation (gas functions only)
- **Whitelist enforcement** - Only approved SPL tokens accepted
- **Authority separation** - Admin, pauser, TSS roles with distinct permissions
- **TSS verification** - Nonce check, canonical message hash, ECDSA secp256k1 recovery to ETH address
- **Balance validation** - Comprehensive user fund checks before operations
- **PDA-based vaults** - Secure custody using program-derived addresses

## Critical Integration Requirements

### Must Do Before Deposits:
1. **Admin creates vault ATAs** for all whitelisted SPL tokens
2. **Users create their own ATAs** for receiving SPL tokens
3. **Check token whitelist** before SPL deposits
4. **Include Pyth price feed** for gas functions (USD caps)

### Must Do Before Withdrawals:
1. **Create recipient ATAs** for SPL token withdrawals
2. **Generate valid TSS signatures** with correct nonce
3. **Construct TSS messages** with proper instruction IDs

### Common Errors:
- **"Account not found"**: ATA doesn't exist (create it)
- **"Token not whitelisted"**: Add token to whitelist first
- **"Insufficient balance"**: User doesn't have enough tokens
- **"Message hash mismatch"**: Wrong TSS message construction
- **"Nonce mismatch"**: Use correct nonce from TSS PDA

## Development

**Build:** `anchor build`  
**Deploy:** `anchor deploy --program-name pushsolanagateway`  
**Test:** Uses devnet SPL tokens and Pyth price feeds  
**Current Deployment:** `CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS`