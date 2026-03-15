// Load environment variables FIRST before any other imports that might use them
import * as dotenv from "dotenv";
dotenv.config({ path: "../.env" });
dotenv.config();

import * as anchor from "@coral-xyz/anchor";
import {
  PublicKey,
  LAMPORTS_PER_SOL,
  Keypair,
  SystemProgram,
  TransactionMessage,
  VersionedTransaction,
  Transaction,
} from "@solana/web3.js";
import fs from "fs";
import { Program } from "@coral-xyz/anchor";
import {
  TOKEN_PROGRAM_ID,
  ASSOCIATED_TOKEN_PROGRAM_ID,
  getAssociatedTokenAddressSync,
} from "@solana/spl-token";
import { assert } from "chai";
import { AltHelper } from "./alt-helper";
import { signTssMessage, buildWithdrawAdditionalData, TssInstruction, generateUniversalTxId } from "../tests/helpers/tss";

/**
 * ALT Integration Test Script
 *
 * This script demonstrates and validates ALT usage for withdraw_and_execute on devnet.
 *
 * Prerequisites:
 * - ALTs must be created via scripts/create-protocol-alt.ts and scripts/create-token-alt.ts
 * - Config files: alt-config-protocol.json and alt-config-tokens.json
 * - Programs already deployed on devnet
 *
 * What this tests:
 * 1. Loading ALTs from config files
 * 2. Verifying ALT account contents
 * 3. Comparing transaction sizes (with vs without ALTs)
 * 4. Using AltHelper for simplified ALT management
 */

// Devnet program IDs (update these if redeployed)
const PROGRAM_ID = new PublicKey("DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp");

const CONFIG_SEED = Buffer.from("config");
const TSS_SEED = Buffer.from("tsspda");
const VAULT_SEED = Buffer.from("vault");
const CEA_SEED = Buffer.from("push_identity");
const EXECUTED_TX_SEED = Buffer.from("executed_tx");

// Load keypairs
const adminKeypair = Keypair.fromSecretKey(
  Uint8Array.from(JSON.parse(fs.readFileSync("./upgrade-keypair.json", "utf8")))
);
const userKeypair = Keypair.fromSecretKey(
  Uint8Array.from(JSON.parse(fs.readFileSync("./clean-user-keypair.json", "utf8")))
);

// Set up connection and provider (devnet)
const connection = new anchor.web3.Connection("https://api.devnet.solana.com", "confirmed");
const provider = new anchor.AnchorProvider(connection, new anchor.Wallet(adminKeypair), {
  commitment: "confirmed",
});
anchor.setProvider(provider);

// Load ALT config files
interface ProtocolAltConfig {
  protocolStaticALT: string;
  accounts: string[];
  network: string;
  createdAt: string;
}

interface TokenAltConfig {
  network: string;
  tokens: Array<{
    symbol: string;
    mint: string;
    altAddress: string;
    accounts: string[];
  }>;
  createdAt: string;
}

let protocolAltConfig: ProtocolAltConfig;
let tokenAltConfig: TokenAltConfig;

try {
  protocolAltConfig = JSON.parse(fs.readFileSync("./alt-config-protocol.json", "utf8"));
  console.log("✅ Loaded Protocol ALT config:", protocolAltConfig.protocolStaticALT);
} catch (error) {
  console.error("❌ Failed to load alt-config-protocol.json");
  console.error("   Run: npx ts-node scripts/create-protocol-alt.ts");
  process.exit(1);
}

try {
  tokenAltConfig = JSON.parse(fs.readFileSync("./alt-config-tokens.json", "utf8"));
  console.log(`✅ Loaded Token ALT config: ${tokenAltConfig.tokens.length} tokens`);
} catch (error) {
  console.error("❌ Failed to load alt-config-tokens.json");
  console.error("   Run: npx ts-node scripts/create-token-alt.ts");
  process.exit(1);
}

const protocolAltAddress = new PublicKey(protocolAltConfig.protocolStaticALT);
const tokenAlts = new Map<string, PublicKey>();

for (const token of tokenAltConfig.tokens) {
  tokenAlts.set(token.mint, new PublicKey(token.altAddress));
}

// PDA helpers
function getCeaAuthorityPda(sender: Uint8Array | number[]): PublicKey {
  return PublicKey.findProgramAddressSync(
    [CEA_SEED, Buffer.from(sender)],
    PROGRAM_ID
  )[0];
}

function getExecutedTxPda(txIdBytes: Uint8Array): PublicKey {
  return PublicKey.findProgramAddressSync(
    [EXECUTED_TX_SEED, Buffer.from(txIdBytes)],
    PROGRAM_ID
  )[0];
}

async function main() {
  console.log("\n🔍 ALT Integration Test - Devnet\n");
  console.log("=" .repeat(60));

  // Test 1: Verify Protocol ALT
  console.log("\n📋 Test 1: Verify Protocol ALT");
  console.log("-".repeat(60));
  const deactivationSentinel = 18446744073709551615n; // u64::MAX => active

  const protocolAlt = await connection.getAddressLookupTable(protocolAltAddress);

  if (!protocolAlt.value) {
    console.error("❌ Protocol ALT not found on-chain:", protocolAltAddress.toBase58());
    console.error("   Run: npx ts-node scripts/create-protocol-alt.ts");
    process.exit(1);
  }

  if (protocolAlt.value.state.deactivationSlot !== deactivationSentinel) {
    console.error(`❌ Protocol ALT is DEACTIVATED at slot ${protocolAlt.value.state.deactivationSlot}!`);
    console.error("   Create a new ALT and update alt-config-protocol.json");
    process.exit(1);
  }

  console.log("✅ Protocol ALT verified:");
  console.log(`   Address: ${protocolAltAddress.toBase58()}`);
  console.log(`   Accounts: ${protocolAlt.value.state.addresses.length}`);
  console.log(`   Authority: ${protocolAlt.value.state.authority?.toBase58()}`);

  // Verify expected accounts
  const [configPda] = PublicKey.findProgramAddressSync([CONFIG_SEED], PROGRAM_ID);
  const [tssPda] = PublicKey.findProgramAddressSync([TSS_SEED], PROGRAM_ID);
  const [vaultSol] = PublicKey.findProgramAddressSync([VAULT_SEED], PROGRAM_ID);

  const expectedProtocolAccounts = [
    configPda,
    tssPda,
    vaultSol,
    SystemProgram.programId,
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID,
    anchor.web3.SYSVAR_RENT_PUBKEY,
  ];

  console.log("\n   Expected accounts:");
  for (let i = 0; i < expectedProtocolAccounts.length; i++) {
    const expected = expectedProtocolAccounts[i].toBase58();
    const actual = protocolAlt.value.state.addresses[i]?.toBase58();
    const match = expected === actual;
    console.log(`   ${i}. ${match ? "✅" : "❌"} ${expected}`);
    if (!match && actual) {
      console.log(`      (actual: ${actual})`);
    }
  }

  // Test 2: Verify Token ALTs
  console.log("\n📋 Test 2: Verify Token ALTs");
  console.log("-".repeat(60));

  for (const [mintStr, altAddress] of tokenAlts.entries()) {
    const tokenInfo = tokenAltConfig.tokens.find(t => t.mint === mintStr);
    if (!tokenInfo) continue;

    console.log(`\n   Token: ${tokenInfo.symbol}`);
    console.log(`   Mint: ${mintStr}`);
    console.log(`   ALT: ${altAddress.toBase58()}`);

    const tokenAlt = await connection.getAddressLookupTable(altAddress);

    if (!tokenAlt.value) {
      console.error(`   ❌ Token ALT not found on-chain`);
      continue;
    }

    if (tokenAlt.value.state.deactivationSlot !== deactivationSentinel) {
      console.error(`   ❌ Token ALT is DEACTIVATED at slot ${tokenAlt.value.state.deactivationSlot}`);
      continue;
    }

    console.log(`   ✅ ALT verified: ${tokenAlt.value.state.addresses.length} accounts`);

    // Verify expected accounts (mint + vault_ata)
    const mintPubkey = new PublicKey(mintStr);
    const vaultAta = getAssociatedTokenAddressSync(mintPubkey, vaultSol, true);

    const expectedTokenAccounts = [mintPubkey, vaultAta];

    for (let i = 0; i < expectedTokenAccounts.length; i++) {
      const expected = expectedTokenAccounts[i].toBase58();
      const actual = tokenAlt.value.state.addresses[i]?.toBase58();
      const match = expected === actual;
      console.log(`   ${i}. ${match ? "✅" : "❌"} ${expected}`);
      if (!match && actual) {
        console.log(`      (actual: ${actual})`);
      }
    }
  }

  // Test 3: Compare Transaction Sizes
  console.log("\n📋 Test 3: Compare Transaction Sizes (SOL Withdraw)");
  console.log("-".repeat(60));

  const sender: number[] = Array(20).fill(1); // Mock EVM address
  const txId = Array.from(Keypair.generate().publicKey.toBytes());
  const universalTxId = Array.from(Keypair.generate().publicKey.toBytes());
  const amountBn = new anchor.BN(0.1 * LAMPORTS_PER_SOL);
  const gasFeeBn = new anchor.BN(0.001 * LAMPORTS_PER_SOL);
  const amountBig = BigInt(amountBn.toString());
  const gasFeeBig = BigInt(gasFeeBn.toString());

  const [ceaAuthority] = PublicKey.findProgramAddressSync(
    [CEA_SEED, Buffer.from(sender)],
    PROGRAM_ID
  );

  const [executedTx] = PublicKey.findProgramAddressSync(
    [EXECUTED_TX_SEED, Buffer.from(txId)],
    PROGRAM_ID
  );

  const recipient = Keypair.generate().publicKey;

  // Load program
  const idl = JSON.parse(fs.readFileSync("./target/idl/universal_gateway.json", "utf8"));
  const program = new Program(idl as anchor.Idl, provider);

  // Build instruction (will be used for both tests)
  let tssNonce: number | undefined;
  let tssChainId: string | undefined;
  const buildInstruction = async () => {
    // Fetch TSS nonce
    const tssAccount = await (program.account as any).tssPda.fetch(tssPda);
    const nonce = typeof tssAccount.nonce === "number"
      ? tssAccount.nonce
      : tssAccount.nonce.toNumber();
    const chainId = tssAccount.chainId;
    tssNonce = nonce;
    tssChainId = chainId;

    // Sign message
    const additional = buildWithdrawAdditionalData(
      Buffer.from(universalTxId),
      Buffer.from(txId),
      Buffer.from(sender),
      PublicKey.default, // SOL (token = zero pubkey)
      recipient,
      gasFeeBig
    );

    const { signature, recoveryId, messageHash } = await signTssMessage({
      instruction: TssInstruction.Withdraw,
      nonce: nonce,
      amount: amountBig,
      additional,
      chainId,
    });

    return program.methods
      .withdrawAndExecute(
        1, // instruction_id (withdraw)
        Array.from(txId),
        Array.from(universalTxId),
        amountBn,
        sender,
        Buffer.alloc(0), // writable_flags (empty for withdraw)
        Buffer.alloc(0), // ix_data (empty for withdraw)
        gasFeeBn,
        new anchor.BN(0), // rent_fee
        Array.from(signature),
        recoveryId,
        Array.from(messageHash),
        new anchor.BN(nonce),
      )
      .accounts({
        caller: provider.wallet.publicKey,
        config: configPda,
        vaultSol,
        ceaAuthority,
        tssPda,
        executedTx,
        systemProgram: SystemProgram.programId,
        destinationProgram: SystemProgram.programId,
        recipient,
        vaultAta: null,
        ceaAta: null,
        mint: null,
        tokenProgram: null,
        rent: null,
        associatedTokenProgram: null,
        recipientAta: null,
      })
      .instruction();
  };

  const instruction = await buildInstruction();
  let legacySize = 0;
  let legacyAccounts = 0;

  // Test WITHOUT ALTs (legacy transaction)
  {
    const { blockhash } = await connection.getLatestBlockhash();

    const legacyTx = new Transaction({
      recentBlockhash: blockhash,
      feePayer: provider.wallet.publicKey,
    }).add(instruction);

    const serialized = legacyTx.serialize({
      requireAllSignatures: false,
      verifySignatures: false,
    });

    legacySize = serialized.length;
    legacyAccounts = legacyTx.instructions[0].keys.length;
    console.log("\n📊 Transaction WITHOUT ALTs (legacy):");
    console.log(`   Size: ${legacySize} bytes`);
    console.log(`   Accounts: ${legacyAccounts}`);
  }

  // Test WITH Protocol ALT (versioned transaction)
  {
    const { blockhash } = await connection.getLatestBlockhash();

    const messageV0 = new TransactionMessage({
      payerKey: provider.wallet.publicKey,
      recentBlockhash: blockhash,
      instructions: [instruction],
    }).compileToV0Message([protocolAlt.value]);

    const versionedTx = new VersionedTransaction(messageV0);

    const serialized = versionedTx.serialize();

    console.log("\n📊 Transaction WITH Protocol ALT (v0):");
    console.log(`   Size: ${serialized.length} bytes`);
    console.log(`   ALTs used: 1`);
    console.log(`   Accounts in ALT: ${protocolAlt.value.state.addresses.length}`);

    const savings = legacySize - serialized.length;
    console.log(`   Savings: ${savings} bytes (${((savings / legacySize) * 100).toFixed(1)}%)`);
  }

  // Test 3b: Compare Transaction Sizes (SPL Withdraw)
  if (tokenAltConfig.tokens.length > 0) {
    if (tssNonce === undefined || tssChainId === undefined) {
      throw new Error("Missing TSS nonce/chainId for SPL test");
    }
    console.log("\n📋 Test 3b: Compare Transaction Sizes (SPL Withdraw)");
    console.log("-".repeat(60));

    const tokenInfo = tokenAltConfig.tokens[0];
    const mintPubkey = new PublicKey(tokenInfo.mint);
    const vaultAta = getAssociatedTokenAddressSync(mintPubkey, vaultSol, true);
    const ceaAta = getAssociatedTokenAddressSync(mintPubkey, ceaAuthority, true);
    const recipientAta = getAssociatedTokenAddressSync(mintPubkey, recipient, true);

    const splTxId = Array.from(Keypair.generate().publicKey.toBytes());
    const splUniversalTxId = Array.from(Keypair.generate().publicKey.toBytes());
    const splExecutedTx = getExecutedTxPda(Buffer.from(splTxId));

    const splAdditional = buildWithdrawAdditionalData(
      Buffer.from(splUniversalTxId),
      Buffer.from(splTxId),
      Buffer.from(sender),
      mintPubkey,
      recipient,
      gasFeeBig
    );

    const splSig = await signTssMessage({
      instruction: TssInstruction.Withdraw,
      nonce: tssNonce,
      amount: amountBig,
      additional: splAdditional,
      chainId: tssChainId,
    });

    const splInstruction = await program.methods
      .withdrawAndExecute(
        1, // instruction_id (withdraw)
        Array.from(splTxId),
        Array.from(splUniversalTxId),
        amountBn,
        sender,
        Buffer.alloc(0),
        Buffer.alloc(0),
        gasFeeBn,
        new anchor.BN(0),
        Array.from(splSig.signature),
        splSig.recoveryId,
        Array.from(splSig.messageHash),
        new anchor.BN(tssNonce),
      )
      .accounts({
        caller: provider.wallet.publicKey,
        config: configPda,
        vaultSol,
        ceaAuthority,
        tssPda,
        executedTx: splExecutedTx,
        systemProgram: SystemProgram.programId,
        destinationProgram: SystemProgram.programId,
        recipient,
        vaultAta,
        ceaAta,
        mint: mintPubkey,
        tokenProgram: TOKEN_PROGRAM_ID,
        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
        recipientAta,
      })
      .instruction();

    // Legacy SPL tx size
    {
      const { blockhash } = await connection.getLatestBlockhash();
      const legacyTx = new Transaction({
        recentBlockhash: blockhash,
        feePayer: provider.wallet.publicKey,
      }).add(splInstruction);

      const serialized = legacyTx.serialize({
        requireAllSignatures: false,
        verifySignatures: false,
      });

      console.log("\n📊 SPL Transaction WITHOUT ALTs (legacy):");
      console.log(`   Size: ${serialized.length} bytes`);
      console.log(`   Accounts: ${legacyTx.instructions[0].keys.length}`);
    }

    // v0 SPL tx size with Protocol ALT + Token ALT
    {
      const { blockhash } = await connection.getLatestBlockhash();
      const tokenAltAddress = tokenAlts.get(tokenInfo.mint);
      const tokenAlt = tokenAltAddress
        ? await connection.getAddressLookupTable(tokenAltAddress)
        : null;

      const alts = [protocolAlt.value];
      if (tokenAlt?.value) {
        alts.push(tokenAlt.value);
      }

      const messageV0 = new TransactionMessage({
        payerKey: provider.wallet.publicKey,
        recentBlockhash: blockhash,
        instructions: [splInstruction],
      }).compileToV0Message(alts);

      const versionedTx = new VersionedTransaction(messageV0);
      const serialized = versionedTx.serialize();

      console.log("\n📊 SPL Transaction WITH ALTs (v0):");
      console.log(`   Size: ${serialized.length} bytes`);
      console.log(`   ALTs used: ${alts.length}`);
      console.log(`   Accounts in Protocol ALT: ${protocolAlt.value.state.addresses.length}`);
      if (tokenAlt?.value) {
        console.log(`   Accounts in Token ALT: ${tokenAlt.value.state.addresses.length}`);
      }
    }
  }

  // Test 4: AltHelper Usage
  console.log("\n📋 Test 4: Test AltHelper");
  console.log("-".repeat(60));

  const altHelper = new AltHelper(connection);

  // Load ALTs from config files
  altHelper.loadFromConfigFiles("./alt-config-protocol.json", "./alt-config-tokens.json");

  console.log("✅ ALTs loaded into AltHelper");

  // Fetch ALT accounts
  await altHelper.fetchAltAccounts();

  console.log("✅ ALT accounts fetched");

  // Get ALTs for SOL transaction
  const solAlts = altHelper.getAltsForTransaction(null);
  console.log(`\n   SOL transaction: ${solAlts.length} ALT(s)`);

  // Get ALTs for SPL transaction (if we have token ALTs)
  if (tokenAltConfig.tokens.length > 0) {
    const firstToken = tokenAltConfig.tokens[0];
    const splAlts = altHelper.getAltsForTransaction(new PublicKey(firstToken.mint));
    console.log(`   SPL transaction (${firstToken.symbol}): ${splAlts.length} ALT(s)`);
  }

  // Estimate savings
  const solSavings = altHelper.estimateSavings(null);
  console.log(`\n   Estimated savings:`);
  console.log(`   - SOL: ${solSavings} bytes`);

  if (tokenAltConfig.tokens.length > 0) {
    const firstToken = tokenAltConfig.tokens[0];
    const splSavings = altHelper.estimateSavings(new PublicKey(firstToken.mint));
    console.log(`   - SPL (${firstToken.symbol}): ${splSavings} bytes`);
  }

  // Summary
  console.log("\n" + "=".repeat(60));
  console.log("✅ ALT Integration Test Complete\n");
  console.log("Summary:");
  console.log(`  - Protocol ALT: ${protocolAlt.value.state.addresses.length} accounts`);
  console.log(`  - Token ALTs: ${tokenAltConfig.tokens.length} tokens`);
  console.log(`  - SOL savings: ${solSavings} bytes per transaction`);
  console.log("\nNext steps:");
  console.log("  1. Use AltHelper in your backend service");
  console.log("  2. Load ALTs once at startup: altHelper.loadFromConfigFiles(...)");
  console.log("  3. Fetch ALT accounts: await altHelper.fetchAltAccounts()");
  console.log("  4. Get ALTs per transaction: altHelper.getAltsForTransaction(mint)");
  console.log("  5. Build versioned transactions with ALTs");
  console.log();
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Test failed:", error);
    process.exit(1);
  });
