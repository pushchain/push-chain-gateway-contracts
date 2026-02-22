#!/usr/bin/env node

import * as anchor from "@coral-xyz/anchor";
import * as dotenv from "dotenv";
import {
    PublicKey,
    Keypair,
    SystemProgram,
} from "@solana/web3.js";
import fs from "fs";
import { Program } from "@coral-xyz/anchor";
import type { UniversalGateway } from "../target/types/universal_gateway";
import { Command } from "commander";

// Program ID from gateway-test.ts
const PROGRAM_ID = new PublicKey("DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp");

// PDA Seeds
const CONFIG_SEED = "config";
const TSS_SEED = "tsspda_v2";
const VAULT_SEED = "vault";
const RATE_LIMIT_CONFIG_SEED = "rate_limit_config";
const RATE_LIMIT_SEED = "rate_limit";

// Load keypairs (same style as token-cli.ts)
const adminKeypair = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync("./upgrade-keypair.json", "utf8")))
);
const pauserKeypair = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync("./upgrade-keypair.json", "utf8")))
);

// Set up connection and provider
const connection = new anchor.web3.Connection("https://api.devnet.solana.com", "confirmed");
const adminProvider = new anchor.AnchorProvider(connection, new anchor.Wallet(adminKeypair), {
    commitment: "confirmed",
});

anchor.setProvider(adminProvider);

// Load IDL
const idl = JSON.parse(fs.readFileSync("./target/idl/universal_gateway.json", "utf8"));
const program = new Program(idl as UniversalGateway, adminProvider);

// Helper: Derive PDAs
function deriveConfigPda(): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync([Buffer.from(CONFIG_SEED)], PROGRAM_ID);
    return pda;
}

function deriveTssPda(): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync([Buffer.from(TSS_SEED)], PROGRAM_ID);
    return pda;
}

function deriveVaultPda(): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync([Buffer.from(VAULT_SEED)], PROGRAM_ID);
    return pda;
}

function deriveRateLimitConfigPda(): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync([Buffer.from(RATE_LIMIT_CONFIG_SEED)], PROGRAM_ID);
    return pda;
}

function deriveTokenRateLimitPda(mint: PublicKey): PublicKey {
    const [pda] = PublicKey.findProgramAddressSync(
        [Buffer.from(RATE_LIMIT_SEED), mint.toBuffer()],
        PROGRAM_ID
    );
    return pda;
}

// Helper: Parse hex address (20 bytes for ETH address)
function parseEthAddress(hex: string): number[] {
    const cleaned = hex.startsWith("0x") ? hex.slice(2) : hex;
    if (cleaned.length !== 40) {
        throw new Error("ETH address must be 40 hex chars (20 bytes)");
    }
    const bytes = Buffer.from(cleaned, "hex");
    return Array.from(bytes);
}

// Helper: Format account display
function formatAccount(label: string, data: any, indent = "   ") {
    console.log(`${indent}${label}:`);
    for (const [key, value] of Object.entries(data)) {
        if (value instanceof PublicKey) {
            console.log(`${indent}  ${key}: ${value.toBase58()}`);
        } else if (Array.isArray(value) && value.length === 20) {
            // ETH address
            console.log(`${indent}  ${key}: 0x${Buffer.from(value).toString("hex")}`);
        } else if (typeof value === "object" && value !== null && "toNumber" in value) {
            // BN or similar
            console.log(`${indent}  ${key}: ${value.toString()}`);
        } else if (typeof value === "boolean") {
            console.log(`${indent}  ${key}: ${value ? "✅ true" : "❌ false"}`);
        } else {
            console.log(`${indent}  ${key}: ${JSON.stringify(value)}`);
        }
    }
}

// Initialize the CLI
const program_cli = new Command();

program_cli
    .name("config-cli")
    .description("CLI tool for managing gateway admin/config/TSS actions")
    .version("1.0.0");

// ============================================
//               TSS COMMANDS
// ============================================

program_cli
    .command("tss:init")
    .description("Initialize TSS with ETH address and chain ID")
    .requiredOption("--eth <address>", "TSS ETH address (hex, 20 bytes)")
    .requiredOption("--chain-id <id>", "Chain ID string (e.g., Solana cluster pubkey)")
    .action(async (options) => {
        try {
            console.log("=== INITIALIZING TSS ===\n");

            const ethAddress = parseEthAddress(options.eth);
            const chainId = options.chainId;

            const configPda = deriveConfigPda();
            const tssPda = deriveTssPda();

            console.log(`TSS ETH Address: 0x${Buffer.from(ethAddress).toString("hex")}`);
            console.log(`Chain ID: ${chainId}`);
            console.log(`TSS PDA: ${tssPda.toBase58()}\n`);

            const tx = await program.methods
                .initTss(ethAddress, chainId)
                .accounts({
                    tssPda: tssPda,
                    config: configPda,
                    authority: adminKeypair.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([adminKeypair])
                .rpc();

            console.log(`✅ TSS initialized successfully!`);
            console.log(`   Transaction: ${tx}\n`);
        } catch (error: any) {
            console.error(`❌ Error initializing TSS: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("tss:update")
    .description("Update TSS ETH address and/or chain ID")
    .requiredOption("--eth <address>", "New TSS ETH address (hex, 20 bytes)")
    .requiredOption("--chain-id <id>", "New chain ID string")
    .action(async (options) => {
        try {
            console.log("=== UPDATING TSS ===\n");

            const ethAddress = parseEthAddress(options.eth);
            const chainId = options.chainId;

            const tssPda = deriveTssPda();

            console.log(`New TSS ETH Address: 0x${Buffer.from(ethAddress).toString("hex")}`);
            console.log(`New Chain ID: ${chainId}`);
            console.log(`TSS PDA: ${tssPda.toBase58()}\n`);

            const tx = await program.methods
                .updateTss(ethAddress, chainId)
                .accounts({
                    tssPda: tssPda,
                    authority: adminKeypair.publicKey,
                })
                .signers([adminKeypair])
                .rpc();

            console.log(`✅ TSS updated successfully!`);
            console.log(`   Transaction: ${tx}\n`);
        } catch (error: any) {
            console.error(`❌ Error updating TSS: ${error.message}`);
            process.exit(1);
        }
    });

// ============================================
//             PAUSE COMMANDS
// ============================================

program_cli
    .command("pause")
    .description("Pause the gateway (emergency stop)")
    .action(async () => {
        try {
            console.log("=== PAUSING GATEWAY ===\n");

            const configPda = deriveConfigPda();

            const tx = await program.methods
                .pause()
                .accounts({
                    config: configPda,
                    pauser: pauserKeypair.publicKey,
                })
                .signers([pauserKeypair])
                .rpc();

            console.log(`✅ Gateway paused successfully!`);
            console.log(`   Transaction: ${tx}\n`);
        } catch (error: any) {
            console.error(`❌ Error pausing gateway: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("unpause")
    .description("Unpause the gateway")
    .action(async () => {
        try {
            console.log("=== UNPAUSING GATEWAY ===\n");

            const configPda = deriveConfigPda();

            const tx = await program.methods
                .unpause()
                .accounts({
                    config: configPda,
                    pauser: pauserKeypair.publicKey,
                })
                .signers([pauserKeypair])
                .rpc();

            console.log(`✅ Gateway unpaused successfully!`);
            console.log(`   Transaction: ${tx}\n`);
        } catch (error: any) {
            console.error(`❌ Error unpausing gateway: ${error.message}`);
            process.exit(1);
        }
    });

// ============================================
//             CAPS COMMANDS
// ============================================

program_cli
    .command("caps:set")
    .description("Set min/max USD caps for universal transactions")
    .requiredOption("--min <value>", "Min cap in USD (u128, Pyth format: 1e8 = $1)")
    .requiredOption("--max <value>", "Max cap in USD (u128, Pyth format: 1e8 = $1)")
    .action(async (options) => {
        try {
            console.log("=== SETTING USD CAPS ===\n");

            const minCap = BigInt(options.min);
            const maxCap = BigInt(options.max);

            if (minCap >= maxCap) {
                throw new Error("Min cap must be less than max cap");
            }

            const configPda = deriveConfigPda();

            console.log(`Min Cap: ${minCap} (${Number(minCap) / 1e8} USD)`);
            console.log(`Max Cap: ${maxCap} (${Number(maxCap) / 1e8} USD)\n`);

            const tx = await program.methods
                .setCapsUsd(
                    new anchor.BN(minCap.toString()),
                    new anchor.BN(maxCap.toString())
                )
                .accounts({
                    config: configPda,
                    admin: adminKeypair.publicKey,
                })
                .signers([adminKeypair])
                .rpc();

            console.log(`✅ USD caps set successfully!`);
            console.log(`   Transaction: ${tx}\n`);
        } catch (error: any) {
            console.error(`❌ Error setting caps: ${error.message}`);
            process.exit(1);
        }
    });

// ============================================
//             PYTH COMMANDS
// ============================================

program_cli
    .command("pyth:set-feed")
    .description("Set Pyth price feed address")
    .requiredOption("--feed <pubkey>", "Pyth price feed public key")
    .action(async (options) => {
        try {
            console.log("=== SETTING PYTH PRICE FEED ===\n");

            const feed = new PublicKey(options.feed);
            const configPda = deriveConfigPda();

            console.log(`Pyth Feed: ${feed.toBase58()}\n`);

            const tx = await program.methods
                .setPythPriceFeed(feed)
                .accounts({
                    config: configPda,
                    admin: adminKeypair.publicKey,
                })
                .signers([adminKeypair])
                .rpc();

            console.log(`✅ Pyth price feed set successfully!`);
            console.log(`   Transaction: ${tx}\n`);
        } catch (error: any) {
            console.error(`❌ Error setting Pyth feed: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("pyth:set-conf")
    .description("Set Pyth confidence threshold")
    .requiredOption("--threshold <value>", "Confidence threshold (u64)")
    .action(async (options) => {
        try {
            console.log("=== SETTING PYTH CONFIDENCE THRESHOLD ===\n");

            const threshold = BigInt(options.threshold);
            const configPda = deriveConfigPda();

            console.log(`Confidence Threshold: ${threshold}\n`);

            const tx = await program.methods
                .setPythConfidenceThreshold(new anchor.BN(threshold.toString()))
                .accounts({
                    config: configPda,
                    admin: adminKeypair.publicKey,
                })
                .signers([adminKeypair])
                .rpc();

            console.log(`✅ Pyth confidence threshold set successfully!`);
            console.log(`   Transaction: ${tx}\n`);
        } catch (error: any) {
            console.error(`❌ Error setting Pyth confidence: ${error.message}`);
            process.exit(1);
        }
    });

// ============================================
//          RATE LIMIT COMMANDS
// ============================================

program_cli
    .command("rate:set-block-usd-cap")
    .description("Set block-level USD cap for rate limiting")
    .requiredOption("--cap <value>", "Block USD cap (u128, 8 decimals)")
    .action(async (options) => {
        try {
            console.log("=== SETTING BLOCK USD CAP ===\n");

            const cap = BigInt(options.cap);
            const configPda = deriveConfigPda();
            const rateLimitConfigPda = deriveRateLimitConfigPda();

            console.log(`Block USD Cap: ${cap} (${Number(cap) / 1e8} USD)\n`);

            const tx = await program.methods
                .setBlockUsdCap(new anchor.BN(cap.toString()))
                .accounts({
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    admin: adminKeypair.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([adminKeypair])
                .rpc();

            console.log(`✅ Block USD cap set successfully!`);
            console.log(`   Transaction: ${tx}\n`);
        } catch (error: any) {
            console.error(`❌ Error setting block USD cap: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("rate:set-epoch")
    .description("Set epoch duration for rate limiting")
    .requiredOption("--seconds <value>", "Epoch duration in seconds (u64)")
    .action(async (options) => {
        try {
            console.log("=== SETTING EPOCH DURATION ===\n");

            const seconds = BigInt(options.seconds);
            const configPda = deriveConfigPda();
            const rateLimitConfigPda = deriveRateLimitConfigPda();

            console.log(`Epoch Duration: ${seconds} seconds (${Number(seconds) / 60} minutes)\n`);

            const tx = await program.methods
                .updateEpochDuration(new anchor.BN(seconds.toString()))
                .accounts({
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    admin: adminKeypair.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([adminKeypair])
                .rpc();

            console.log(`✅ Epoch duration set successfully!`);
            console.log(`   Transaction: ${tx}\n`);
        } catch (error: any) {
            console.error(`❌ Error setting epoch duration: ${error.message}`);
            process.exit(1);
        }
    });

program_cli
    .command("rate:set-token")
    .description("Set rate limit threshold for a specific token")
    .requiredOption("--mint <pubkey>", "Token mint address (use Pubkey::default() for SOL)")
    .requiredOption("--threshold <value>", "Rate limit threshold (u128, token natural units)")
    .action(async (options) => {
        try {
            console.log("=== SETTING TOKEN RATE LIMIT ===\n");

            const mint = options.mint === "default" || options.mint === "11111111111111111111111111111111"
                ? PublicKey.default
                : new PublicKey(options.mint);
            const threshold = BigInt(options.threshold);

            const configPda = deriveConfigPda();
            const tokenRateLimitPda = deriveTokenRateLimitPda(mint);

            console.log(`Token Mint: ${mint.toBase58()}`);
            console.log(`Threshold: ${threshold}`);
            console.log(`Token Rate Limit PDA: ${tokenRateLimitPda.toBase58()}\n`);

            const tx = await program.methods
                .setTokenRateLimit(new anchor.BN(threshold.toString()))
                .accounts({
                    config: configPda,
                    tokenRateLimit: tokenRateLimitPda,
                    tokenMint: mint,
                    admin: adminKeypair.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([adminKeypair])
                .rpc();

            console.log(`✅ Token rate limit set successfully!`);
            console.log(`   Transaction: ${tx}\n`);
        } catch (error: any) {
            console.error(`❌ Error setting token rate limit: ${error.message}`);
            process.exit(1);
        }
    });

// ============================================
//          CONFIG SHOW COMMAND
// ============================================

program_cli
    .command("config:show")
    .description("Show current gateway configuration (config + tss + rate_limit)")
    .action(async () => {
        try {
            console.log("=== GATEWAY CONFIGURATION ===\n");

            const configPda = deriveConfigPda();
            const tssPda = deriveTssPda();
            const rateLimitConfigPda = deriveRateLimitConfigPda();

            // Fetch Config
            console.log("📋 Config Account");
            console.log(`   PDA: ${configPda.toBase58()}`);
            try {
                const config = await (program.account as any).config.fetch(configPda);
                formatAccount("Data", config);
            } catch (error: any) {
                console.log(`   ❌ Not initialized: ${error.message}`);
            }
            console.log();

            // Fetch TSS
            console.log("🔐 TSS Account");
            console.log(`   PDA: ${tssPda.toBase58()}`);
            try {
                const tss = await (program.account as any).tssPda.fetch(tssPda);
                formatAccount("Data", tss);
            } catch (error: any) {
                console.log(`   ❌ Not initialized: ${error.message}`);
            }
            console.log();

            // Fetch Rate Limit Config
            console.log("⏱️  Rate Limit Config");
            console.log(`   PDA: ${rateLimitConfigPda.toBase58()}`);
            try {
                const rateLimitConfig = await (program.account as any).rateLimitConfig.fetch(rateLimitConfigPda);
                formatAccount("Data", rateLimitConfig);
            } catch (error: any) {
                console.log(`   ❌ Not initialized: ${error.message}`);
            }
            console.log();

            console.log("✅ Configuration displayed successfully!\n");
        } catch (error: any) {
            console.error(`❌ Error fetching configuration: ${error.message}`);
            process.exit(1);
        }
    });

// Load environment variables
dotenv.config({ path: "../.env" });
dotenv.config();

// Parse command line arguments
program_cli.parse();
