import {
  Connection,
  Keypair,
  PublicKey,
  AddressLookupTableProgram,
  Transaction,
} from "@solana/web3.js";
import {
  TOKEN_PROGRAM_ID,
  ASSOCIATED_TOKEN_PROGRAM_ID,
  getAssociatedTokenAddressSync,
} from "@solana/spl-token";
import { AnchorProvider, Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import idl from "../target/idl/universal_gateway.json";
import fs from "fs";

/**
 * Create Token-Specific ALT for withdraw_and_execute
 *
 * This ALT contains ONLY token-specific accounts:
 * - mint (unique per token)
 * - vault_ata (gateway's ATA for this token, unique per token)
 *
 * Note: token_program, ata_program, and rent are in Protocol ALT (shared)
 *
 * Net savings: 2 accounts → (2×32) - (32+2) = 64 - 34 = 30 bytes per SPL tx
 */

const PROGRAM_ID = new PublicKey(idl.address);
const VAULT_SEED = Buffer.from("vault");

interface TokenConfig {
  symbol: string;
  mint: string;
  decimals: number;
}

// Popular tokens on Solana
const SUPPORTED_TOKENS: TokenConfig[] = [
  {
    symbol: "USDC",
    mint: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", // Mainnet
    decimals: 6,
  },
  {
    symbol: "USDT",
    mint: "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB", // Mainnet
    decimals: 6,
  },
  // Add more tokens as needed
];

// Devnet test tokens
const DEVNET_TOKENS: TokenConfig[] = [
  {
    symbol: "USDC-DEV",
    mint: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU", // Devnet USDC
    decimals: 6,
  },
];

async function createTokenALT(
  connection: Connection,
  wallet: Keypair,
  tokenConfig: TokenConfig
) {
  console.log(`\n🔧 Creating Token ALT for ${tokenConfig.symbol}...`);

  const mintPubkey = new PublicKey(tokenConfig.mint);

  // Derive vault SOL PDA to get vault ATA
  const [vaultSol] = PublicKey.findProgramAddressSync(
    [VAULT_SEED],
    PROGRAM_ID
  );

  // Derive vault ATA for this token
  const vaultAta = getAssociatedTokenAddressSync(
    mintPubkey,
    vaultSol,
    true // allowOwnerOffCurve = true for PDA
  );

  // Token-specific accounts ONLY (program IDs are in Protocol ALT)
  const tokenAccounts = [
    mintPubkey,
    vaultAta,
  ];

  console.log("📋 Token-Specific Accounts:");
  console.log("  mint:", mintPubkey.toBase58());
  console.log("  vault_ata:", vaultAta.toBase58());
  console.log();
  console.log("ℹ️  Note: token_program, ata_program, and rent are in Protocol ALT (shared)");

  // Get confirmed slot for ALT creation (stays valid longer than current slot)
  const slot = await connection.getSlot("confirmed");

  // Create ALT
  let [lookupTableInstruction, lookupTableAddress] =
    AddressLookupTableProgram.createLookupTable({
      authority: wallet.publicKey,
      payer: wallet.publicKey,
      recentSlot: slot,
    });

  console.log("📍 Creating ALT at address:", lookupTableAddress.toBase58());

  // Retry loop to handle stale slots
  let sig: string | undefined;
  let created = false;
  const maxAttempts = 5;

  for (let attempt = 1; attempt <= maxAttempts && !created; attempt++) {
    try {
      // Get confirmed slot for this attempt (stays valid longer)
      const attemptSlot = attempt === 1 ? slot : await connection.getSlot("confirmed");
      const [attemptCreateIx, attemptAltAddress] = AddressLookupTableProgram.createLookupTable({
        authority: wallet.publicKey,
        payer: wallet.publicKey,
        recentSlot: attemptSlot,
      });

      const attemptExtendIx = AddressLookupTableProgram.extendLookupTable({
        lookupTable: attemptAltAddress,
        authority: wallet.publicKey,
        payer: wallet.publicKey,
        addresses: tokenAccounts,
      });

      const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash();

      const tx = new Transaction().add(attemptCreateIx, attemptExtendIx);
      tx.recentBlockhash = blockhash;
      tx.feePayer = wallet.publicKey;

      sig = await connection.sendTransaction(tx, [wallet]);
      await connection.confirmTransaction({
        signature: sig,
        blockhash,
        lastValidBlockHeight,
      });

      lookupTableAddress = attemptAltAddress;
      created = true;

      if (attempt > 1) {
        console.log(`✅ Succeeded on attempt ${attempt}`);
        console.log("📍 Final ALT address:", lookupTableAddress.toBase58());
      }
    } catch (error: any) {
      if (error.message?.includes("not a recent slot") && attempt < maxAttempts) {
        console.log(`⚠️  Slot became stale (attempt ${attempt}/${maxAttempts}), retrying...`);
        await new Promise(resolve => setTimeout(resolve, 100));
      } else if (attempt === maxAttempts) {
        throw new Error(`Failed to create ALT after ${maxAttempts} attempts: ${error.message}`);
      } else {
        throw error;
      }
    }
  }

  console.log("✅ Token ALT created!");
  console.log("   Signature:", sig);

  // Wait for ALT to be active (poll up to 10 seconds)
  console.log("⏳ Waiting for ALT to become active...");
  let altAccount;
  for (let i = 0; i < 20; i++) {
    await new Promise(resolve => setTimeout(resolve, 500));
    const result = await connection.getAddressLookupTable(lookupTableAddress);
    if (result.value && result.value.state.addresses.length > 0) {
      altAccount = result;
      console.log(`✅ ALT active after ${(i + 1) * 500}ms`);
      break;
    }
    if (i === 19) {
      console.warn("⚠️  ALT not active after 10 seconds. May need more time.");
    }
  }

  // Verify ALT
  if (altAccount?.value) {
    console.log("✅ ALT verified:");
    console.log("   Addresses:", altAccount.value.state.addresses.length);
    console.log("   Authority:", altAccount.value.state.authority?.toBase58());
  } else {
    console.error("❌ Failed to verify ALT. Check manually:");
    console.error(`   solana address-lookup-table ${lookupTableAddress.toBase58()}`);
  }

  return {
    symbol: tokenConfig.symbol,
    mint: tokenConfig.mint,
    altAddress: lookupTableAddress.toBase58(),
    accounts: tokenAccounts.map(acc => acc.toBase58()),
  };
}

async function main() {
  const connection = new Connection(
    process.env.ANCHOR_PROVIDER_URL || "https://api.devnet.solana.com",
    "confirmed"
  );

  const wallet = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync("./upgrade-keypair.json", "utf8")))
  );

  const isDevnet = process.env.ANCHOR_PROVIDER_URL?.includes("devnet");
  const tokens = isDevnet ? DEVNET_TOKENS : SUPPORTED_TOKENS;

  console.log("🔧 Creating Token-Specific ALTs for withdraw_and_execute");
  console.log(`Network: ${isDevnet ? "Devnet" : "Mainnet"}`);
  console.log(`Tokens to process: ${tokens.length}`);

  const altConfigs = [];

  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    try {
      const config = await createTokenALT(connection, wallet, token);
      altConfigs.push(config);

      // Add delay between ALT creations to avoid slot staleness
      if (i < tokens.length - 1) {
        console.log("\n⏳ Waiting 2 seconds before creating next ALT...\n");
        await new Promise(resolve => setTimeout(resolve, 2000));
      }
    } catch (error) {
      console.error(`❌ Failed to create ALT for ${token.symbol}:`, error);
    }
  }

  // Save to file
  const outputPath = "./alt-config-tokens.json";
  fs.writeFileSync(
    outputPath,
    JSON.stringify(
      {
        network: isDevnet ? "devnet" : "mainnet",
        tokens: altConfigs,
        createdAt: new Date().toISOString(),
      },
      null,
      2
    )
  );

  console.log("\n💾 Token ALT configs saved to:", outputPath);
  console.log("\n🎉 Done! Created", altConfigs.length, "token ALTs");
  console.log("   Each token ALT has 2 accounts (mint + vault_ata)");
  console.log("   Savings per token ALT: 30 bytes");
  console.log("   Total SPL tx savings (Protocol ALT + Token ALT): 215 bytes");
  console.log("   - Protocol ALT (7 accounts): 185 bytes");
  console.log("   - Token ALT (2 accounts): 30 bytes");
}

main().catch(console.error);
