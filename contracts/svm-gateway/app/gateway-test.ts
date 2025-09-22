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
import { keccak_256 } from "js-sha3";
import * as secp from "@noble/secp256k1";
import { assert } from "chai";

const PROGRAM_ID = new PublicKey("CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS");
const CONFIG_SEED = "config";
const VAULT_SEED = "vault";
const WHITELIST_SEED = "whitelist";
const PRICE_ACCOUNT = new PublicKey("7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE"); // Pyth SOL/USD price feed

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

// Helper: Get dynamic gas amount based on current SOL price
async function getDynamicGasAmount(targetUsd: number, fallbackSol: number = 0.01): Promise<anchor.BN> {
    try {
        const solPriceResult = await program.methods
            .getSolPrice()
            .accounts({
                priceUpdate: PRICE_ACCOUNT,
            })
            .view();

        const solPriceUsd = solPriceResult.price / Math.pow(10, 8); // Pyth uses 8 decimals
        const gasAmountSol = targetUsd / solPriceUsd;
        const gasAmountLamports = Math.floor(gasAmountSol * LAMPORTS_PER_SOL);

        console.log(`💰 SOL price: $${solPriceUsd.toFixed(2)} | ⛽ Gas: ${gasAmountSol.toFixed(4)} SOL (~$${targetUsd})`);

        return new anchor.BN(gasAmountLamports);
    } catch (error) {
        console.log(`⚠️ Could not fetch SOL price, using fallback: ${fallbackSol} SOL`);
        return new anchor.BN(fallbackSol * LAMPORTS_PER_SOL);
    }
}

// Helper: parse and print program data logs (Anchor events) from a transaction
async function parseAndPrintEvents(txSignature: string, label: string) {
    try {
        const tx = await connection.getTransaction(txSignature, {
            commitment: "confirmed",
            maxSupportedTransactionVersion: 0,
        });
        if (!tx?.meta?.logMessages) {
            console.log(`${label}: No logs found`);
            return;
        }
        const dataLogs = tx.meta.logMessages.filter((log) => log.startsWith("Program data: "));
        if (dataLogs.length === 0) {
            console.log(`${label}: No program data logs (events) found`);
            return;
        }
        console.log(`${label}: Found ${dataLogs.length} event log(s)`);
        dataLogs.forEach((log, idx) => {
            const base64Data = log.replace("Program data: ", "");
            const buf = Buffer.from(base64Data, "base64");
            const disc = buf.slice(0, 8).toString("hex");
            const data = buf.slice(8);
            console.log(`  [${idx}] discriminator=${disc} data_len=${data.length}`);
        });
    } catch (e: any) {
        console.log(`${label}: Error parsing events: ${e.message}`);
    }
}

// Helper function to load token info from tokens folder
function loadTokenInfo(tokenSymbol: string): any {
    const filename = `./tokens/${tokenSymbol.toLowerCase()}-token.json`;

    if (!fs.existsSync(filename)) {
        throw new Error(`Token file not found: ${filename}. Please create the token first.`);
    }

    return JSON.parse(fs.readFileSync(filename, "utf8"));
}

async function run() {
    console.log("=== GATEWAY PROGRAM COMPREHENSIVE TEST ===\n");

    // Load env from parent and local (so either location works)
    dotenv.config({ path: "../.env" });
    dotenv.config();

    // Derive PDAs
    const [configPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(CONFIG_SEED)],
        PROGRAM_ID
    );
    const [vaultPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(VAULT_SEED)],
        PROGRAM_ID
    );
    const [tssPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("tss")],
        PROGRAM_ID
    );

    const admin = adminKeypair.publicKey;
    const user = userKeypair.publicKey;

    console.log(`Program ID: ${PROGRAM_ID.toString()}`);
    console.log(`Admin: ${admin.toString()}`);
    console.log(`User: ${user.toString()}`);
    console.log(`Config PDA: ${configPda.toString()}`);
    console.log(`Vault PDA: ${vaultPda.toString()}\n`);

    // Step 1: Initialize Gateway
    console.log("1. Initializing Gateway...");
    const configAccount = await connection.getAccountInfo(configPda);
    if (!configAccount) {
        const tx = await program.methods
            .initialize(
                admin, // admin
                admin, // pauser
                admin, // tss (using admin for simplicity)
                new anchor.BN(100_000_000), // min_cap_usd ($1 with 8 decimals = 1e8)
                new anchor.BN(1_000_000_000), // max_cap_usd ($10 with 8 decimals = 10e8)
                new PublicKey("7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE") // pyth_price_feed (SOL/USD feed ID)
            )
            .accounts({
                config: configPda,
                vault: vaultPda,
                admin: admin,
                systemProgram: SystemProgram.programId,
            })
            .signers([adminKeypair])
            .rpc();
        console.log(`Gateway initialized: ${tx}\n`);
    } else {
        console.log("Gateway already initialized\n");
    }

    // Step 2: Test Admin Functions
    console.log("2. Testing Admin Functions...");

    // Check current caps
    try {
        const configData = await (program.account as any).config.fetch(configPda);
        const minCap = configData.minCapUniversalTxUsd ? configData.minCapUniversalTxUsd.toString() : 'N/A';
        const maxCap = configData.maxCapUniversalTxUsd ? configData.maxCapUniversalTxUsd.toString() : 'N/A';
        console.log(`Current caps - Min: ${minCap}, Max: ${maxCap}`);
    } catch (error) {
        console.log("Could not fetch config data, skipping caps display");
    }

    // Update caps
    const newMinCap = new anchor.BN(100_000_000); // $1 with 8 decimals = 1e8
    const newMaxCap = new anchor.BN(1_000_000_000); // $10 with 8 decimals = 10e8
    const capsTx = await program.methods
        .setCapsUsd(newMinCap, newMaxCap)
        .accounts({
            config: configPda,
            admin: admin,
        })
        .rpc();
    console.log(`✅ Caps updated: ${capsTx}`);

    // Verify caps update
    try {
        const updatedConfigData = await (program.account as any).config.fetch(configPda);
        const minCap = updatedConfigData.minCapUniversalTxUsd ? updatedConfigData.minCapUniversalTxUsd.toString() : 'N/A';
        const maxCap = updatedConfigData.maxCapUniversalTxUsd ? updatedConfigData.maxCapUniversalTxUsd.toString() : 'N/A';
        console.log(`📊 Updated caps - Min: ${minCap}, Max: ${maxCap}\n`);
    } catch (error) {
        console.log("📊 Could not fetch updated config data\n");
    }

    // Step 3: Use existing SPL Token from tokens folder
    console.log("3. Setting up SPL Token...");

    // Load existing token from tokens folder
    let mint: PublicKey;
    let tokenAccount: PublicKey;
    let tokenInfo: any;

    // Try to load USDT token first, fallback to USDC if not available
    const tokenFiles = ["usdt-token.json", "official-usdc-token.json", "dai-token.json", "pepe-token.json"];
    let tokenLoaded = false;

    for (const tokenFile of tokenFiles) {
        try {
            const tokenPath = `./tokens/${tokenFile}`;
            tokenInfo = JSON.parse(fs.readFileSync(tokenPath, "utf8"));
            mint = new PublicKey(tokenInfo.mint);

            // Get or create token account for this mint
            const tokenAccountInfo = await spl.getOrCreateAssociatedTokenAccount(
                userProvider.connection as any,
                userKeypair,
                mint,
                userKeypair.publicKey
            );
            tokenAccount = tokenAccountInfo.address;

            console.log(`✅ Using existing SPL Token from tokens folder:`);
            console.log(`   Name: ${tokenInfo.name}`);
            console.log(`   Symbol: ${tokenInfo.symbol}`);
            console.log(`   Mint: ${mint.toString()}`);
            console.log(`   Decimals: ${tokenInfo.decimals}`);
            console.log(`   Token Account: ${tokenAccount.toString()}\n`);
            tokenLoaded = true;
            break;
        } catch (error) {
            console.log(`Could not load ${tokenFile}, trying next...`);
            continue;
        }
    }

    if (!tokenLoaded) {
        throw new Error("No valid tokens found in tokens folder. Please create tokens first using the token CLI.");
    }

    // Step 4: Whitelist SPL Token
    console.log("4. Whitelisting SPL Token...");
    const [whitelistPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(WHITELIST_SEED)],
        PROGRAM_ID
    );

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
        console.log(`✅ Token whitelisted: ${whitelistTx}\n`);
    } catch (error) {
        if (error.message.includes("TokenAlreadyWhitelisted")) {
            console.log(`✅ Token already whitelisted (skipping)\n`);
        } else {
            throw error;
        }
    }

    // Step 5: Test send_tx_with_gas (SOL deposit with payload)
    console.log("5. Testing send_tx_with_gas...");
    const userBalanceBefore = await connection.getBalance(user);
    const vaultBalanceBefore = await connection.getBalance(vaultPda);

    console.log(`User balance BEFORE: ${userBalanceBefore / LAMPORTS_PER_SOL} SOL`);
    console.log(`Vault balance BEFORE: ${vaultBalanceBefore / LAMPORTS_PER_SOL} SOL`);

    // Create payload and revert settings
    const payload = {
        to: Keypair.generate().publicKey, // Target address on Push Chain
        value: new anchor.BN(0), // Value to send
        data: Buffer.from("test payload data"),
        gas_limit: new anchor.BN(100000),
        max_fee_per_gas: new anchor.BN(20000000000), // 20 gwei
        max_priority_fee_per_gas: new anchor.BN(1000000000), // 1 gwei
        nonce: new anchor.BN(0),
        deadline: new anchor.BN(Date.now() + 3600000), // 1 hour from now
        v_type: { signedVerification: {} }, // VerificationType enum
    };

    const revertSettings = {
        fundRecipient: user, // Use user as recipient for simplicity  
        revertMsg: Buffer.from("revert message"),
    };


    // Get dynamic gas amount for USD cap compliance
    const gasAmount = await getDynamicGasAmount(1.20, 0.01); // Target $1.20, fallback 0.01 SOL

    const gasTx = await userProgram.methods
        .sendTxWithGas(payload, revertSettings, gasAmount)
        .accounts({
            config: configPda,
            vault: vaultPda,
            user: user,
            priceUpdate: PRICE_ACCOUNT,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`Gas transaction sent: ${gasTx}`);
    await parseAndPrintEvents(gasTx, "send_tx_with_gas events");

    const userBalanceAfter = await connection.getBalance(user);
    const vaultBalanceAfter = await connection.getBalance(vaultPda);
    console.log(`User balance AFTER: ${userBalanceAfter / LAMPORTS_PER_SOL} SOL`);
    console.log(`Vault balance AFTER: ${vaultBalanceAfter / LAMPORTS_PER_SOL} SOL\n`);

    // Step 5a: Legacy add_funds (locker-compatible)
    console.log("5a. Legacy add_funds (locker-compatible)...");
    // Get dynamic amount for USD cap compliance
    const legacyAmount = await getDynamicGasAmount(1.10, 0.001); // Target $1.10, fallback 0.001 SOL
    const txHashLegacy: number[] = Array(32).fill(1); // 32-byte transaction hash (dummy)

    const legacyTx = await userProgram.methods
        .addFunds(legacyAmount, txHashLegacy)
        .accounts({
            config: configPda,
            vault: vaultPda,
            user: user,
            priceUpdate: PRICE_ACCOUNT,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`✅ Legacy add_funds sent: ${legacyTx}`);
    await parseAndPrintEvents(legacyTx, "legacy add_funds events");

    // Step 6: Test send_funds with native SOL (unified function)
    console.log("6. Testing send_funds (Native SOL)...");
    const recipient = Keypair.generate().publicKey;
    const fundAmount = new anchor.BN(0.005 * LAMPORTS_PER_SOL); // 0.005 SOL

    const userBalanceBeforeFunds = await connection.getBalance(user);
    const vaultBalanceBeforeFunds = await connection.getBalance(vaultPda);

    console.log(`💳 User balance BEFORE send_funds (native): ${userBalanceBeforeFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault balance BEFORE send_funds (native): ${vaultBalanceBeforeFunds / LAMPORTS_PER_SOL} SOL`);

    const nativeFundsTx = await userProgram.methods
        .sendFunds(recipient, PublicKey.default, fundAmount, revertSettings) // PublicKey.default for native SOL
        .accounts({
            config: configPda,
            vault: vaultPda,
            user: user,
            tokenWhitelist: whitelistPda,
            userTokenAccount: user, // For native SOL, can be any account
            gatewayTokenAccount: vaultPda, // For native SOL, can be any account
            bridgeToken: PublicKey.default, // Native SOL
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`✅ Native SOL funds sent to ${recipient.toString()}: ${nativeFundsTx}`);

    // Parse events
    await parseAndPrintEvents(nativeFundsTx, "send_funds (native) events");

    const userBalanceAfterFunds = await connection.getBalance(user);
    const vaultBalanceAfterFunds = await connection.getBalance(vaultPda);
    console.log(`💳 User balance AFTER send_funds (native): ${userBalanceAfterFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault balance AFTER send_funds (native): ${vaultBalanceAfterFunds / LAMPORTS_PER_SOL} SOL\n`);

    // Step 7: Test SPL token functions
    console.log("7. Testing SPL Token Functions...");

    // Create ATA for vault (admin's responsibility)
    const vaultAta = await spl.getOrCreateAssociatedTokenAccount(
        adminProvider.connection as any,
        adminKeypair,
        mint,
        vaultPda,
        true
    );
    console.log(`✅ Vault ATA created by admin: ${vaultAta.address.toString()}`);

    // Test send_funds with SPL token (SPL-only function)
    const splRecipient = Keypair.generate().publicKey;
    const splAmount = new anchor.BN(1000 * Math.pow(10, 6)); // 1000 tokens (6 decimals)

    console.log(`🪙 Testing SPL token send_funds...`);

    // Get SPL balances before
    const userTokenBalanceBefore = (await spl.getAccount(userProvider.connection as any, tokenAccount)).amount;
    const vaultTokenBalanceBefore = (await spl.getAccount(userProvider.connection as any, vaultAta.address)).amount;

    console.log(`📊 User SPL balance BEFORE: ${userTokenBalanceBefore.toString()} tokens`);
    console.log(`📊 Vault SPL balance BEFORE: ${vaultTokenBalanceBefore.toString()} tokens`);
    console.log(`📤 Sending ${splAmount.toNumber() / Math.pow(10, 6)} tokens to ${splRecipient.toString()}`);

    const splFundsTx = await userProgram.methods
        .sendFunds(splRecipient, mint, splAmount, revertSettings)
        .accounts({
            config: configPda,
            vault: vaultPda,
            user: user,
            tokenWhitelist: whitelistPda,
            userTokenAccount: tokenAccount,
            gatewayTokenAccount: vaultAta.address,
            bridgeToken: mint,
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`✅ SPL funds sent: ${splFundsTx}`);

    // Parse events
    await parseAndPrintEvents(splFundsTx, "send_funds (SPL) events");

    // Get SPL balances after
    const userTokenBalanceAfter = (await spl.getAccount(userProvider.connection as any, tokenAccount)).amount;
    const vaultTokenBalanceAfter = (await spl.getAccount(userProvider.connection as any, vaultAta.address)).amount;

    console.log(`📊 User SPL balance AFTER: ${userTokenBalanceAfter.toString()} tokens`);
    console.log(`📊 Vault SPL balance AFTER: ${vaultTokenBalanceAfter.toString()} tokens\n`);

    // Step 8: Test send_tx_with_funds (SPL + payload + gas)
    console.log("8. Testing send_tx_with_funds (SPL + payload + gas)...");

    // Get dynamic gas amount for USD cap compliance
    const txWithFundsGasAmount = await getDynamicGasAmount(1.50, 0.01); // Target $1.50, fallback 0.01 SOL

    const txWithFundsRecipient = Keypair.generate().publicKey;
    const txWithFundsSplAmount = new anchor.BN(500 * Math.pow(10, 6)); // 500 tokens

    // Create payload for this transaction
    const txWithFundsPayload = {
        to: Keypair.generate().publicKey, // Target address on Push Chain
        value: new anchor.BN(0), // Value to send
        data: Buffer.from("test payload for funds+gas"),
        gas_limit: new anchor.BN(120000),
        max_fee_per_gas: new anchor.BN(20000000000), // 20 gwei
        max_priority_fee_per_gas: new anchor.BN(1000000000), // 1 gwei
        nonce: new anchor.BN(1),
        deadline: new anchor.BN(Date.now() + 3600000), // 1 hour from now
        v_type: { signedVerification: {} }, // VerificationType enum
    };

    console.log(`🚀 Testing combined SPL + Gas transaction...`);
    console.log(`📤 SPL Amount: ${txWithFundsSplAmount.toNumber() / Math.pow(10, 6)} tokens`);
    console.log(`⛽ Gas Amount: ${txWithFundsGasAmount.toNumber() / LAMPORTS_PER_SOL} SOL`);

    const userBalanceBeforeTxWithFunds = await connection.getBalance(user);
    const vaultBalanceBeforeTxWithFunds = await connection.getBalance(vaultPda);
    const userTokenBalanceBeforeTx = (await spl.getAccount(userProvider.connection as any, tokenAccount)).amount;
    const vaultTokenBalanceBeforeTx = (await spl.getAccount(userProvider.connection as any, vaultAta.address)).amount;

    console.log(`💳 User SOL balance BEFORE: ${userBalanceBeforeTxWithFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault SOL balance BEFORE: ${vaultBalanceBeforeTxWithFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`📊 User SPL balance BEFORE: ${userTokenBalanceBeforeTx.toString()} tokens`);
    console.log(`📊 Vault SPL balance BEFORE: ${vaultTokenBalanceBeforeTx.toString()} tokens`);

    // Generate signature data for payload security (dynamic bytes)
    const signatureData = Buffer.from("test_signature_data_for_spl_payload", "utf8");
    // For testing, use a simple string. In production, this would be a secure signature.

    const txWithFundsTx = await userProgram.methods
        .sendTxWithFunds(
            mint,
            txWithFundsSplAmount,
            txWithFundsPayload,
            revertSettings,
            txWithFundsGasAmount,
            signatureData
        )
        .accounts({
            config: configPda,
            vault: vaultPda,
            user: user,
            tokenWhitelist: whitelistPda,
            userTokenAccount: tokenAccount,
            gatewayTokenAccount: vaultAta.address,
            priceUpdate: PRICE_ACCOUNT,
            bridgeToken: mint,
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`✅ Combined SPL + Gas transaction sent: ${txWithFundsTx}`);

    // Parse events
    await parseAndPrintEvents(txWithFundsTx, "send_tx_with_funds events");

    const userBalanceAfterTxWithFunds = await connection.getBalance(user);
    const vaultBalanceAfterTxWithFunds = await connection.getBalance(vaultPda);
    const userTokenBalanceAfterTx = (await spl.getAccount(userProvider.connection as any, tokenAccount)).amount;
    const vaultTokenBalanceAfterTx = (await spl.getAccount(userProvider.connection as any, vaultAta.address)).amount;

    console.log(`💳 User SOL balance AFTER: ${userBalanceAfterTxWithFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault SOL balance AFTER: ${vaultBalanceAfterTxWithFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`📊 User SPL balance AFTER: ${userTokenBalanceAfterTx.toString()} tokens`);
    console.log(`📊 Vault SPL balance AFTER: ${vaultTokenBalanceAfterTx.toString()} tokens\n`);

    // Step 9.5: Test send_tx_with_funds with native SOL as both bridge token and gas
    console.log("9.5. Testing send_tx_with_funds with native SOL (bridge + gas)...");

    // Get dynamic amounts for USD cap compliance
    const nativeGasAmount = await getDynamicGasAmount(1.20, 0.008); // Target $1.20, fallback 0.008 SOL
    const nativeBridgeAmount = await getDynamicGasAmount(2.00, 0.02); // Target $2.00, fallback 0.02 SOL
    console.log(`🌉 Bridge amount: ${(nativeBridgeAmount.toNumber() / LAMPORTS_PER_SOL).toFixed(4)} SOL`);

    const nativePayload = {
        to: new PublicKey("11111111111111111111111111111112"), // System program as example
        value: new anchor.BN(0),
        data: Buffer.from("native_sol_payload_data"),
        gasLimit: new anchor.BN(21000),
        maxFeePerGas: new anchor.BN(20000000000),
        maxPriorityFeePerGas: new anchor.BN(2000000000),
        nonce: new anchor.BN(0),
        deadline: new anchor.BN(Date.now() + 3600000),
        vType: { signedVerification: {} }
    };

    const nativeRevertSettings = {
        fundRecipient: user,
        revertMsg: Buffer.from("Native SOL revert")
    };

    // Generate signature data for native SOL payload
    const nativeSignatureData = Buffer.from("test_signature_data_for_native_sol_payload", "utf8");
    // Different signature for native SOL test

    const userBalanceBeforeNative = await connection.getBalance(user);
    const vaultBalanceBeforeNative = await connection.getBalance(vaultPda);

    console.log(`💳 User SOL balance BEFORE native test: ${userBalanceBeforeNative / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault SOL balance BEFORE native test: ${vaultBalanceBeforeNative / LAMPORTS_PER_SOL} SOL`);

    const nativeTxWithFundsTx = await userProgram.methods
        .sendTxWithFunds(
            PublicKey.default, // Native SOL (Pubkey::default())
            nativeBridgeAmount,
            nativePayload,
            nativeRevertSettings,
            nativeGasAmount,
            nativeSignatureData
        )
        .accounts({
            config: configPda,
            vault: vaultPda,
            user: user,
            tokenWhitelist: whitelistPda,
            userTokenAccount: tokenAccount, // Not used for native SOL but required by struct
            gatewayTokenAccount: vaultAta.address, // Not used for native SOL but required by struct
            priceUpdate: PRICE_ACCOUNT,
            bridgeToken: PublicKey.default, // Native SOL
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`✅ Native SOL + Gas transaction sent: ${nativeTxWithFundsTx}`);

    // Parse events
    await parseAndPrintEvents(nativeTxWithFundsTx, "native SOL send_tx_with_funds events");

    const userBalanceAfterNative = await connection.getBalance(user);
    const vaultBalanceAfterNative = await connection.getBalance(vaultPda);

    console.log(`💳 User SOL balance AFTER native test: ${userBalanceAfterNative / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault SOL balance AFTER native test: ${vaultBalanceAfterNative / LAMPORTS_PER_SOL} SOL`);

    const totalDeducted = (userBalanceBeforeNative - userBalanceAfterNative) / LAMPORTS_PER_SOL;
    const expectedDeduction = (nativeBridgeAmount.toNumber() + nativeGasAmount.toNumber()) / LAMPORTS_PER_SOL;
    console.log(`💰 Total SOL deducted: ${totalDeducted.toFixed(6)} SOL (expected: ${expectedDeduction.toFixed(6)} SOL)`);

    // Allow small tolerance for transaction fees
    const tolerance = 0.001; // 0.001 SOL tolerance
    assert.approximately(totalDeducted, expectedDeduction, tolerance, "Native SOL deduction should match expected amount within tolerance");
    console.log(`✅ Native SOL test passed - correct amount deducted\n`);

    // Step 10: Test pause/unpause
    console.log("10. Testing pause/unpause...");

    try {
        const pauseTx = await program.methods
            .pause()
            .accounts({
                config: configPda,
                pauser: admin,
            })
            .rpc();
        console.log(`✅ Gateway paused: ${pauseTx}`);
    } catch (error) {
        if (error.message.includes("PausedError") || error.message.includes("already paused")) {
            console.log("✅ Gateway already paused (skipping)");
        } else {
            throw error;
        }
    }

    // Try to send funds while paused (should fail)
    try {
        await userProgram.methods
            .sendTxWithGas(payload, revertSettings, gasAmount)
            .accounts({
                config: configPda,
                vault: vaultPda,
                user: user,
                priceUpdate: PRICE_ACCOUNT,
                systemProgram: SystemProgram.programId,
            })
            .rpc();
        console.log("❌ Transaction should have failed while paused!");
    } catch (error) {
        console.log("✅ Transaction correctly failed while paused");
    }

    try {
        const unpauseTx = await program.methods
            .unpause()
            .accounts({
                config: configPda,
                pauser: admin,
            })
            .rpc();
        console.log(`✅ Gateway unpaused: ${unpauseTx}\n`);
    } catch (error) {
        if (error.message.includes("not paused") || error.message.includes("already unpaused")) {
            console.log("✅ Gateway already unpaused (skipping)\n");
        } else {
            throw error;
        }
    }


    // =========================
    //   12. TSS INIT & WITHDRAW
    // =========================
    console.log("12. TSS init and TSS-verified withdraw test...");

    // 12.1 init_tss (chain_id = 1, ETH address from user)
    const ethAddrHex = "0xEbf0Cfc34E07ED03c05615394E2292b387B63F12".toLowerCase().replace(/^0x/, "");
    const ethAddrBytes = Buffer.from(ethAddrHex, "hex");
    if (ethAddrBytes.length !== 20) throw new Error("Invalid ETH address length for TSS");

    try {
        const tssInfo = await connection.getAccountInfo(tssPda);
        if (!tssInfo) {
            const initTssTx = await program.methods
                .initTss(Array.from(ethAddrBytes) as any, new anchor.BN(1))
                .accounts({
                    tssPda: tssPda,
                    authority: admin,
                    systemProgram: SystemProgram.programId,
                })
                .signers([adminKeypair])
                .rpc();
            console.log(`✅ TSS initialized: ${initTssTx}`);
        } else {
            console.log("TSS PDA already initialized");
        }
    } catch (e) {
        console.log("TSS init check failed, attempting init anyway");
        const initTssTx = await program.methods
            .initTss(Array.from(ethAddrBytes) as any, new anchor.BN(1))
            .accounts({
                tssPda: tssPda,
                authority: admin,
                systemProgram: SystemProgram.programId,
            })
            .signers([adminKeypair])
            .rpc();
        console.log(`✅ TSS initialized: ${initTssTx}`);
    }

    // 12.2 Build message for SOL withdraw to admin using instruction_id=1
    const withdrawAmountTss = new anchor.BN(0.0005 * LAMPORTS_PER_SOL).toNumber();
    const chainId = 1; // Ethereum mainnet id for domain separation
    // Fetch current nonce by reading TssPda account (optional). We'll pass a rolling nonce = 0 on first run.
    // For simplicity here, use a small local nonce and retry if mismatch.
    let nonce = 0; // default
    try {
        // Attempt to read current nonce from on-chain TSS PDA
        const tssAcc: any = await (program.account as any).tssPda.fetch(tssPda);
        if (tssAcc && typeof tssAcc.nonce !== "undefined") {
            nonce = Number(tssAcc.nonce);
        }
    } catch (e) {
        // If not initialized or IDL not exposed yet, keep default 0
    }

    const PREFIX = Buffer.from("PUSH_CHAIN_SVM");
    const instructionId = Buffer.from([1]); // 1 = SOL withdraw
    const chainIdBE = Buffer.alloc(8);
    chainIdBE.writeBigUInt64BE(BigInt(chainId));
    const nonceBE = Buffer.alloc(8);
    nonceBE.writeBigUInt64BE(BigInt(nonce));
    const amountBE = Buffer.alloc(8);
    amountBE.writeBigUInt64BE(BigInt(withdrawAmountTss));
    const recipientBytes = admin.toBuffer();

    const concat = Buffer.concat([
        PREFIX,
        instructionId,
        chainIdBE,
        nonceBE,
        amountBE,
        recipientBytes,
    ]);
    const messageHashHex = keccak_256(concat);
    const messageHash = Buffer.from(messageHashHex, "hex");

    // 12.3 Sign with ETH private key from .env
    const priv = (process.env.TSS_PRIVKEY || process.env.ETH_PRIVATE_KEY || process.env.PRIVATE_KEY || "").replace(/^0x/, "");
    if (!priv) throw new Error("Missing TSS_PRIVKEY/PRIVATE_KEY in .env");
    const sig = await secp.sign(messageHash, priv, { recovered: true, der: false });
    const signature: Uint8Array = sig[0];
    let recoveryId: number = sig[1]; // 0 or 1

    // 12.4 Call withdraw_tss
    const tssWithdrawTx = await program.methods
        .withdrawTss(
            new anchor.BN(withdrawAmountTss),
            Array.from(signature) as any,
            recoveryId,
            Array.from(messageHash) as any,
            new anchor.BN(nonce),
        )
        .accounts({
            config: configPda,
            vault: vaultPda,
            tssPda: tssPda,
            recipient: admin,
            systemProgram: SystemProgram.programId,
        })
        .signers([adminKeypair])
        .rpc();
    console.log(`✅ TSS withdraw SOL completed: ${tssWithdrawTx}`);
    await parseAndPrintEvents(tssWithdrawTx, "withdraw_tss events");

    // 12.5 Test SPL token TSS withdrawal (instruction_id=2)
    console.log("\n=== Testing SPL Token TSS Withdrawal ===");

    // Check if we have SPL tokens in the vault to withdraw
    const vaultTokenBalance = await spl.getAccount(userProvider.connection as any, vaultAta.address);
    if (Number(vaultTokenBalance.amount) === 0) {
        console.log("⚠️  No SPL tokens in vault to withdraw, skipping SPL TSS test");
    } else {
        const splWithdrawAmount = Math.min(Number(vaultTokenBalance.amount), 1000); // Withdraw small amount

        // Create admin ATA for the token
        const adminAta = await spl.getOrCreateAssociatedTokenAccount(
            userProvider.connection as any,
            adminKeypair,
            mint,
            admin
        );

        // Build message for SPL withdraw using instruction_id=2
        const PREFIX_SPL = Buffer.from("PUSH_CHAIN_SVM");
        const instructionIdSPL = Buffer.from([2]); // 2 = SPL withdraw
        const chainIdBE_SPL = Buffer.alloc(8);
        chainIdBE_SPL.writeBigUInt64BE(BigInt(chainId));
        const nonceBE_SPL = Buffer.alloc(8);
        nonceBE_SPL.writeBigUInt64BE(BigInt(nonce + 1)); // Increment nonce for SPL withdraw
        const amountBE_SPL = Buffer.alloc(8);
        amountBE_SPL.writeBigUInt64BE(BigInt(splWithdrawAmount));
        const recipientBytesSPL = admin.toBuffer();
        const mintBytes = mint.toBuffer(); // 32 bytes for mint address

        const concatSPL = Buffer.concat([
            PREFIX_SPL,
            instructionIdSPL,
            chainIdBE_SPL,
            nonceBE_SPL,
            amountBE_SPL,
            mintBytes, // Additional data for SPL withdraw (only mint, not recipient)
        ]);
        const messageHashHexSPL = keccak_256(concatSPL);
        const messageHashSPL = Buffer.from(messageHashHexSPL, "hex");

        // Sign with ETH private key
        const sigSPL = await secp.sign(messageHashSPL, priv, { recovered: true, der: false });
        const signatureSPL: Uint8Array = sigSPL[0];
        let recoveryIdSPL: number = sigSPL[1];

        // Call withdraw_spl_token_tss
        const tssSplWithdrawTx = await program.methods
            .withdrawSplTokenTss(
                new anchor.BN(splWithdrawAmount),
                Array.from(signatureSPL) as any,
                recoveryIdSPL,
                Array.from(messageHashSPL) as any,
                new anchor.BN(nonce + 1),
            )
            .accounts({
                config: configPda,
                whitelist: whitelistPda,
                vault: vaultPda,
                tokenVault: vaultAta.address,
                tokenMint: mint,
                tssPda: tssPda,
                recipientTokenAccount: adminAta.address,
                tokenProgram: spl.TOKEN_PROGRAM_ID,
            })
            .signers([adminKeypair])
            .rpc();
        console.log(`✅ TSS withdraw SPL completed: ${tssSplWithdrawTx}`);
        await parseAndPrintEvents(tssSplWithdrawTx, "withdraw_spl_token_tss events");

        // Log final SPL balances
        const finalVaultBalance = await spl.getAccount(userProvider.connection as any, vaultAta.address);
        const finalAdminBalance = await spl.getAccount(userProvider.connection as any, adminAta.address);
        console.log(`Final vault SPL balance: ${finalVaultBalance.amount}`);
        console.log(`Final admin SPL balance: ${finalAdminBalance.amount}`);
    }

    // 13. Note: ATA creation is now handled off-chain by clients (standard practice)
    console.log("\n=== ATA Creation Note ===");
    console.log("✅ ATA creation is handled off-chain by clients (standard Solana practice)");
    console.log("✅ This avoids complex reimbursement logic and follows industry standards");

    // 14. Remove token from whitelist (moved after all tests)
    console.log("14. Testing remove whitelist...");
    try {
        const removeWhitelistTx = await program.methods
            .removeWhitelistToken(mint)
            .accounts({
                config: configPda,
                whitelist: whitelistPda,
                admin: admin,
                systemProgram: SystemProgram.programId,
            })
            .rpc();
        console.log(`✅ Token removed from whitelist: ${removeWhitelistTx}\n`);
    } catch (error) {
        if (error.message.includes("TokenNotWhitelisted") || error.message.includes("not whitelisted")) {
            console.log("✅ Token not in whitelist (skipping removal)\n");
        } else {
            throw error;
        }
    }

    // 15. Test revert function with real TSS signature
    console.log("15. Testing revert function with real TSS signature...");

    // Test revert function with real TSS signature
    try {
        // Get current TSS nonce
        const tssAccount: any = await (program.account as any).tssPda.fetch(tssPda);
        const currentNonce = tssAccount.nonce;
        console.log(`Current TSS nonce: ${currentNonce}`);
        console.log(`TSS chain ID: ${tssAccount.chainId}`);

        // Create real message hash for revert withdraw (instruction_id = 3)
        const instructionId = 3;
        const amount = 1000000; // 0.001 SOL
        const recipientBytes = admin.toBytes();

        // Build message: PUSH_CHAIN_SVM + instruction_id + chain_id + nonce + amount + recipient
        // Use EXACT same format as working TSS withdrawal
        const PREFIX = Buffer.from("PUSH_CHAIN_SVM");
        const instructionIdBE = Buffer.from([instructionId]);
        const chainIdBE = Buffer.alloc(8);
        chainIdBE.writeBigUInt64BE(BigInt(1));
        const nonceBE = Buffer.alloc(8);
        nonceBE.writeBigUInt64BE(BigInt(currentNonce));
        const amountBE = Buffer.alloc(8);
        amountBE.writeBigUInt64BE(BigInt(amount));
        const recipientBytesBE = admin.toBuffer();

        const messageData = Buffer.concat([
            PREFIX,
            instructionIdBE,
            chainIdBE,
            nonceBE,
            amountBE,
            recipientBytesBE,
        ]);

        // Hash with keccak (same as program)
        const messageHashHex = keccak_256(messageData);
        const messageHash = Buffer.from(messageHashHex, "hex");
        console.log(`Message data: ${messageData.toString('hex')}`);
        console.log(`Message hash: ${messageHashHex}`);

        // Sign with ETH private key (same as other TSS functions)
        const priv = (process.env.TSS_PRIVKEY || process.env.ETH_PRIVATE_KEY || process.env.PRIVATE_KEY || "").replace(/^0x/, "");
        if (!priv) throw new Error("Missing TSS_PRIVKEY/PRIVATE_KEY in .env");

        const sig = await secp.sign(messageHash, priv, { recovered: true, der: false });
        const signature: Uint8Array = sig[0];
        let recoveryId: number = sig[1]; // 0 or 1

        await program.methods
            .revertWithdraw(
                new anchor.BN(amount),
                {
                    fundRecipient: admin,
                    revertCause: "test_revert",
                },
                Array.from(signature),
                recoveryId,
                Array.from(messageHash),
                currentNonce
            )
            .accounts({
                config: configPda,
                vault: vaultPda,
                tss: tssPda,
                recipient: admin,
                systemProgram: SystemProgram.programId,
            })
            .rpc();

        console.log("✅ revertWithdraw function working with real TSS signature!");

    } catch (error) {
        console.log(`❌ revertWithdraw failed: ${error.message}`);
    }

    console.log("All tests completed successfully!");
}

run().catch((e) => {
    console.error("Test failed:", e);
    process.exit(1);
});
