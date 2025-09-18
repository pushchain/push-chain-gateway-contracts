#!/usr/bin/env node

import * as anchor from "@coral-xyz/anchor";
import * as dotenv from "dotenv";
import {
    PublicKey,
    LAMPORTS_PER_SOL,
    Keypair,
    SystemProgram,
} from "@solana/web3.js";
import fs from "fs";
import { Program } from "@coral-xyz/anchor";
import type { Pushsolanagateway } from "../target/types/pushsolanagateway";
import * as spl from "@solana/spl-token";
import { Command } from "commander";

const PROGRAM_ID = new PublicKey("CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS");
const CONFIG_SEED = "config";
const VAULT_SEED = "vault";
const WHITELIST_SEED = "whitelist";

// Load keypairs
const adminKeypair = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync("./upgrade-keypair.json", "utf8")))
);
const userKeypair = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync("./clean-user-keypair.json", "utf8")))
);

// Set up connection and provider
const connection = new anchor.web3.Connection("https://api.devnet.solana.com", "confirmed");
const adminProvider = new anchor.AnchorProvider(connection, new anchor.Wallet(adminKeypair), {
    commitment: "confirmed",
});
const userProvider = new anchor.AnchorProvider(connection, new anchor.Wallet(userKeypair), {
    commitment: "confirmed",
});

anchor.setProvider(adminProvider);

// Load IDL
const idl = JSON.parse(fs.readFileSync("./target/idl/pushsolanagateway.json", "utf8"));
const program = new Program(idl as Pushsolanagateway, adminProvider);
const userProgram = new Program(idl as Pushsolanagateway, userProvider);

// Helper function to load token info from file
function loadTokenInfo(tokenSymbol: string): any {
    const filename = `./tokens/${tokenSymbol.toLowerCase()}-token.json`;

    if (!fs.existsSync(filename)) {
        throw new Error(`Token file not found: ${filename}. Please create the token first using 'npm run token:create'`);
    }

    return JSON.parse(fs.readFileSync(filename, "utf8"));
}

// Helper function to whitelist a token
async function whitelistToken(mintAddress: string): Promise<void> {
    console.log(`🔒 Whitelisting token: ${mintAddress}...`);

    // Derive PDAs
    const [configPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(CONFIG_SEED)],
        PROGRAM_ID
    );
    const [whitelistPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(WHITELIST_SEED)],
        PROGRAM_ID
    );

    const admin = adminKeypair.publicKey;
    const mint = new PublicKey(mintAddress);

    try {
        const whitelistTx = await program.methods
            .whitelistToken(mint)
            .accounts({
                config: configPda,
                whitelist: whitelistPda,
                admin: admin,
                systemProgram: SystemProgram.programId,
            })
            .rpc();
        console.log(`✅ Token whitelisted successfully: ${whitelistTx}\n`);
    } catch (error) {
        if (error.message.includes("TokenAlreadyWhitelisted")) {
            console.log(`✅ Token already whitelisted (skipping)\n`);
        } else {
            throw error;
        }
    }
}

// Helper function to test SPL token deposit
async function testDeposit(mintAddress: string, amount: number): Promise<void> {
    console.log(`🧪 Testing SPL token deposit...`);

    // Derive PDAs
    const [configPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(CONFIG_SEED)],
        PROGRAM_ID
    );
    const [vaultPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(VAULT_SEED)],
        PROGRAM_ID
    );
    const [whitelistPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(WHITELIST_SEED)],
        PROGRAM_ID
    );

    const admin = adminKeypair.publicKey;
    const user = userKeypair.publicKey;
    const mint = new PublicKey(mintAddress);

    console.log(`Program ID: ${PROGRAM_ID.toString()}`);
    console.log(`Admin: ${admin.toString()}`);
    console.log(`User: ${user.toString()}`);
    console.log(`Mint: ${mint.toString()}`);
    console.log(`Config PDA: ${configPda.toString()}`);
    console.log(`Vault PDA: ${vaultPda.toString()}`);
    console.log(`Whitelist PDA: ${whitelistPda.toString()}\n`);

    // Step 1: Get vault ATA (should already exist from whitelisting)
    console.log("1. Getting vault ATA...");
    const vaultAta = await spl.getAssociatedTokenAddress(
        mint,
        vaultPda,
        true
    );
    console.log(`✅ Vault ATA: ${vaultAta.toString()}\n`);

    // Step 2: Get or create user token account
    console.log("2. Getting user token account...");
    const userTokenAccount = await spl.getOrCreateAssociatedTokenAccount(
        userProvider.connection as any,
        userKeypair,
        mint,
        user
    );
    console.log(`✅ User token account: ${userTokenAccount.address.toString()}\n`);

    // Step 3: Test SPL token deposit
    console.log("3. Testing SPL token deposit...");

    const depositAmount = new anchor.BN(amount * Math.pow(10, 6)); // Convert to proper units (assuming 6 decimals)
    const recipient = Keypair.generate().publicKey;

    const revertSettings = {
        fundRecipient: user,
        revertMsg: Buffer.from("test revert message"),
    };

    // Get balances before
    const userTokenBalanceBefore = (await spl.getAccount(userProvider.connection as any, userTokenAccount.address)).amount;
    const vaultTokenBalanceBefore = (await spl.getAccount(userProvider.connection as any, vaultAta)).amount;

    console.log(`📊 User SPL balance BEFORE: ${userTokenBalanceBefore.toString()} tokens`);
    console.log(`📊 Vault SPL balance BEFORE: ${vaultTokenBalanceBefore.toString()} tokens`);
    console.log(`📤 Depositing ${amount} tokens to ${recipient.toString()}`);

    // Perform the deposit
    const depositTx = await userProgram.methods
        .sendFunds(recipient, mint, depositAmount, revertSettings)
        .accounts({
            config: configPda,
            vault: vaultPda,
            user: user,
            tokenWhitelist: whitelistPda,
            userTokenAccount: userTokenAccount.address,
            gatewayTokenAccount: vaultAta,
            bridgeToken: mint,
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`✅ SPL deposit transaction: ${depositTx}`);

    // Get balances after
    const userTokenBalanceAfter = (await spl.getAccount(userProvider.connection as any, userTokenAccount.address)).amount;
    const vaultTokenBalanceAfter = (await spl.getAccount(userProvider.connection as any, vaultAta)).amount;

    console.log(`📊 User SPL balance AFTER: ${userTokenBalanceAfter.toString()} tokens`);
    console.log(`📊 Vault SPL balance AFTER: ${vaultTokenBalanceAfter.toString()} tokens`);

    // Verify the deposit worked
    const userBalanceDiff = userTokenBalanceBefore - userTokenBalanceAfter;
    const vaultBalanceDiff = vaultTokenBalanceAfter - vaultTokenBalanceBefore;

    console.log(`\n📈 Balance Changes:`);
    console.log(`   User lost: ${userBalanceDiff.toString()} tokens`);
    console.log(`   Vault gained: ${vaultBalanceDiff.toString()} tokens`);

    if (userBalanceDiff.toString() === depositAmount.toString() &&
        vaultBalanceDiff.toString() === depositAmount.toString()) {
        console.log(`✅ Deposit successful! Amounts match exactly.`);
    } else {
        console.log(`❌ Deposit amounts don't match. Expected: ${depositAmount.toString()}`);
    }

    console.log("\n=== Deposit test completed successfully! ===");
}

// Initialize the CLI
const program_cli = new Command();

program_cli
    .name('gateway-test')
    .description('CLI tool for testing gateway functionality with SPL tokens')
    .version('1.0.0');

// Whitelist command
program_cli
    .command('whitelist')
    .description('Whitelist a token in the gateway program')
    .requiredOption('-m, --mint <mint>', 'Mint address or token symbol')
    .action(async (options) => {
        try {
            console.log("=== WHITELISTING TOKEN ===\n");

            let mintAddress: string;

            // Check if it's a token symbol or mint address
            if (options.mint.length === 44) {
                // It's a mint address
                mintAddress = options.mint;
            } else {
                // It's a token symbol, load from file
                const tokenInfo = loadTokenInfo(options.mint);
                mintAddress = tokenInfo.mint;
                console.log(`Found token: ${tokenInfo.name} (${tokenInfo.symbol})`);
            }

            await whitelistToken(mintAddress);

            console.log("🎉 Token whitelisting completed successfully!");

        } catch (error) {
            console.error("❌ Error whitelisting token:", error.message);
            process.exit(1);
        }
    });

// Test deposit command
program_cli
    .command('test-deposit')
    .description('Test SPL token deposit functionality')
    .requiredOption('-m, --mint <mint>', 'Mint address or token symbol')
    .requiredOption('-a, --amount <amount>', 'Amount to deposit (in human-readable units)')
    .action(async (options) => {
        try {
            console.log("=== TESTING SPL TOKEN DEPOSIT ===\n");

            let mintAddress: string;

            // Check if it's a token symbol or mint address
            if (options.mint.length === 44) {
                // It's a mint address
                mintAddress = options.mint;
            } else {
                // It's a token symbol, load from file
                const tokenInfo = loadTokenInfo(options.mint);
                mintAddress = tokenInfo.mint;
                console.log(`Found token: ${tokenInfo.name} (${tokenInfo.symbol})`);
            }

            const amount = parseFloat(options.amount);

            await testDeposit(mintAddress, amount);

            console.log("🎉 Deposit test completed successfully!");

        } catch (error) {
            console.error("❌ Error testing deposit:", error.message);
            process.exit(1);
        }
    });

// Full test command (whitelist + test deposit)
program_cli
    .command('full-test')
    .description('Run full test: whitelist token and test deposit')
    .requiredOption('-m, --mint <mint>', 'Mint address or token symbol')
    .requiredOption('-a, --amount <amount>', 'Amount to deposit (in human-readable units)')
    .action(async (options) => {
        try {
            console.log("=== FULL GATEWAY TEST ===\n");

            let mintAddress: string;
            let tokenInfo: any = null;

            // Check if it's a token symbol or mint address
            if (options.mint.length === 44) {
                // It's a mint address
                mintAddress = options.mint;
            } else {
                // It's a token symbol, load from file
                tokenInfo = loadTokenInfo(options.mint);
                mintAddress = tokenInfo.mint;
                console.log(`Found token: ${tokenInfo.name} (${tokenInfo.symbol})`);
            }

            // Step 1: Whitelist the token
            console.log("Step 1: Whitelisting token...");
            await whitelistToken(mintAddress);

            // Step 2: Test deposit
            console.log("Step 2: Testing deposit...");
            const amount = parseFloat(options.amount);
            await testDeposit(mintAddress, amount);

            console.log("🎉 Full test completed successfully!");

        } catch (error) {
            console.error("❌ Error in full test:", error.message);
            process.exit(1);
        }
    });

// Load environment variables
dotenv.config({ path: "../.env" });
dotenv.config();

// Parse command line arguments
program_cli.parse();
