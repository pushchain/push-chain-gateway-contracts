# Solana Universal Gateway

Production-ready Solana program for cross-chain asset bridging to Push Chain. Mirrors Ethereum Universal Gateway functionality with complete Pyth oracle integration.

## Program Details

**Program ID:** `CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS`  
**Token Mint:** `8bzuac9NTZtkUHz8L1wC2k8fiBbuDrPaiFRV949SS5CH`
**Network:** Solana Devnet  
**Pyth Oracle:** SOL/USD feed `7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE`  
**Legacy Locker:** `3zrWaMknHTRQpZSxY4BvQxw9TStSXiHcmcp3NMPTFkke` (compatible)

## Core Functions

### Deposit Functions
1. **`send_tx_with_gas`** - Native SOL gas deposits with USD caps ($1-$10)
2. **`send_funds`** - SPL token bridging (whitelisted tokens only)
3. **`send_funds_native`** - Native SOL bridging (high value, no caps)
4. **`send_tx_with_funds`** - Combined SPL tokens + gas with payload execution + signature data

### Admin & TSS Functions
- **`initialize`** - Deploy gateway with admin/pauser/caps and set Pyth feed
- **`pause/unpause`** - Emergency controls
- **`set_caps_usd`** - Update USD caps (8 decimal precision)
- **`whitelist_token/remove_token`** - Manage supported SPL tokens
- **`init_tss` / `update_tss` / `reset_nonce`** - Configure Ethereum TSS address, chain id, and nonce
- **`withdraw_tss` / `withdraw_spl_token_tss`** - TSS-verified withdrawals (ECDSA secp256k1)

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

### System Accounts
- **Pyth Price Feed:** `7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE` (SOL/USD)
- **SPL Token Program:** `TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA`
- **System Program:** `11111111111111111111111111111111`

### Account Responsibilities
- **Admin:** Creates vault ATAs, whitelists tokens, manages gateway
- **Users:** Create their own ATAs, deposit funds to existing vault ATAs
- **TSS:** Signs withdrawal requests with ECDSA secp256k1 signatures

## Events
- **`TxWithGas`** - Gas deposits (maps to Ethereum event)
- **`TxWithFunds`** - Token/native bridging with signature data (maps to Ethereum event)
- **`WithdrawFunds`** - TSS withdrawals
- **`CapsUpdated`** - Admin cap changes

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

### 3. Gas Deposit (with USD caps)
```typescript
await program.methods
  .sendTxWithGas(payload, revertSettings, amount)
  .accounts({
    config: configPda, vault: vaultPda, user: userPubkey,
    priceUpdate: pythPriceAccount, systemProgram: SystemProgram.programId
  })
  .rpc();
```

### 4. SPL Token Bridge
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

### 5. Combined Funds + Payload with Signature Data
```typescript
// Create payload for execution on Push Chain
const payload = {
  to: targetAddress,
  value: new anchor.BN(0),
  data: Buffer.from("execution_data"),
  gasLimit: new anchor.BN(21000),
  maxFeePerGas: new anchor.BN(20000000000),
  maxPriorityFeePerGas: new anchor.BN(2000000000),
  nonce: new anchor.BN(0),
  deadline: new anchor.BN(Date.now() + 3600000),
  vType: { signedVerification: {} }
};

// Generate signature data for payload security
const signatureData = Buffer.alloc(32);
// In production, this would be computed from payload hash + private key
signatureData.fill(0x42); // Example pattern for testing

await program.methods
  .sendTxWithFunds(
    tokenMint, 
    bridgeAmount, 
    payload, 
    revertSettings, 
    gasAmount,
    Array.from(signatureData)
  )
  .accounts({
    config: configPda, vault: vaultPda, user: userPubkey,
    tokenWhitelist: whitelistPda,
    userTokenAccount: userAta.address,
    gatewayTokenAccount: vaultAta.address,
    priceUpdate: priceAccount,
    bridgeToken: tokenMint,
    tokenProgram: TOKEN_PROGRAM_ID,
    systemProgram: SystemProgram.programId
  })
  .rpc();
```

### 6. TSS Configuration & Verified Withdrawals
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

## Testing

Run comprehensive test suite:
```bash
cd app && ts-node gateway-test.ts
```

## Development

**Build:** `anchor build`  
**Deploy:** `anchor deploy --program-name pushsolanagateway`  
**Test:** Uses devnet SPL tokens and Pyth price feeds  
**Current Deployment:** `CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS`

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
