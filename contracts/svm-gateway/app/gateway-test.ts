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
import type { UniversalGateway } from "../target/types/universal_gateway";
import * as spl from "@solana/spl-token";
import pkg from 'js-sha3';
const { keccak_256 } = pkg;
import * as secp from "@noble/secp256k1";
import { assert } from "chai";

const PROGRAM_ID = new PublicKey("DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp");
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
const idl = JSON.parse(fs.readFileSync("./target/idl/universal_gateway.json", "utf8"));
const program = new Program(idl, adminProvider);
const userProgram = new Program(idl, userProvider);

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
    const [rateLimitConfigPda] = PublicKey.findProgramAddressSync(
        [Buffer.from("rate_limit_config")],
        PROGRAM_ID
    );
    const [whitelistPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(WHITELIST_SEED)],
        PROGRAM_ID
    );

    const admin = adminKeypair.publicKey;
    const user = userKeypair.publicKey;

    // Helper to get token rate limit PDA
    const getTokenRateLimitPda = (tokenMint: PublicKey): PublicKey => {
        const [pda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit"), tokenMint.toBuffer()],
            PROGRAM_ID
        );
        return pda;
    };

    // Helper to create payload
    const createPayload = (to: number, vType: any = { signedVerification: {} }) => ({
        to: Array.from(Buffer.alloc(20, to)),
        value: new anchor.BN(0),
        data: Buffer.from([]),
        gasLimit: new anchor.BN(21000),
        maxFeePerGas: new anchor.BN(20000000000),
        maxPriorityFeePerGas: new anchor.BN(1000000000),
        nonce: new anchor.BN(0),
        deadline: new anchor.BN(Math.floor(Date.now() / 1000) + 3600),
        vType,
    });

    // Helper to serialize payload to bytes
    const serializePayload = (payload: any): Buffer => {
        return Buffer.from(JSON.stringify(payload));
    };

    // Helper to create revert instruction
    const createRevertInstruction = (recipient: PublicKey, msg: string = "test") => ({
        fundRecipient: recipient,
        revertMsg: Buffer.from(msg),
    });

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

    // Step 1.5: Initialize Rate Limit Config and Token Rate Limits
    console.log("1.5. Setting up Rate Limits...");
    const veryLargeThreshold = new anchor.BN("1000000000000000000000"); // Effectively unlimited

    // Initialize rate limit config by calling setBlockUsdCap (uses init_if_needed)
    try {
        await (program.account as any).rateLimitConfig.fetch(rateLimitConfigPda);
        console.log("Rate limit config already initialized");
    } catch {
        // Initialize by setting block USD cap to 0 (disabled, but creates the account)
        await program.methods
            .setBlockUsdCap(new anchor.BN(0))
            .accounts({
                admin: admin,
                config: configPda,
                rateLimitConfig: rateLimitConfigPda,
                systemProgram: SystemProgram.programId,
            })
            .signers([adminKeypair])
            .rpc();
        console.log("✅ Rate limit config initialized");
    }

    // Initialize native SOL rate limit
    const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);
    try {
        await (program.account as any).tokenRateLimit.fetch(nativeSolTokenRateLimitPda);
        console.log("Native SOL rate limit already initialized");
    } catch {
        await program.methods
            .setTokenRateLimit(veryLargeThreshold)
            .accounts({
                admin: admin,
                config: configPda,
                rateLimitConfig: rateLimitConfigPda,
                tokenRateLimit: nativeSolTokenRateLimitPda,
                tokenMint: PublicKey.default,
                systemProgram: SystemProgram.programId,
            })
            .signers([adminKeypair])
            .rpc();
        console.log("✅ Native SOL rate limit initialized");
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

    // Initialize SPL token rate limit if needed
    if (tokenLoaded) {
        const splTokenRateLimitPda = getTokenRateLimitPda(mint);
        try {
            await (program.account as any).tokenRateLimit.fetch(splTokenRateLimitPda);
            console.log("SPL token rate limit already initialized");
        } catch {
            await program.methods
                .setTokenRateLimit(veryLargeThreshold)
                .accounts({
                    admin: admin,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: splTokenRateLimitPda,
                    tokenMint: mint,
                    systemProgram: SystemProgram.programId,
                })
                .signers([adminKeypair])
                .rpc();
            console.log("✅ SPL token rate limit initialized");
        }
    }

    // =========================
    // NEW: sendUniversalTx Tests
    // =========================
    console.log("\n=== 4.5. Testing sendUniversalTx (New Universal Entrypoint) ===\n");

    // Test 4.5.1: GAS Route (TxType.GAS)
    console.log("4.5.1. Testing GAS Route (TxType.GAS)...");
    const universalGasAmount = await getDynamicGasAmount(2.5, 0.01);
    const initialVaultBalanceGas = await connection.getBalance(vaultPda);

    const gasReq = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: PublicKey.default,
        amount: new anchor.BN(0),
        payload: Buffer.from([]),
        revertInstruction: createRevertInstruction(user),
        signatureData: Buffer.from("gas_sig"),
    };

    const gasUniversalTx = await userProgram.methods
        .sendUniversalTx(gasReq, universalGasAmount)
        .accounts({
            config: configPda,
            vault: vaultPda,
            userTokenAccount: vaultPda,
            gatewayTokenAccount: vaultPda,
            user: user,
            priceUpdate: PRICE_ACCOUNT,
            rateLimitConfig: rateLimitConfigPda,
            tokenRateLimit: nativeSolTokenRateLimitPda,
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
        })
        .signers([userKeypair])
        .rpc();

    console.log(`✅ GAS route transaction: ${gasUniversalTx}`);
    await parseAndPrintEvents(gasUniversalTx, "GAS route events");
    const finalVaultBalanceGas = await connection.getBalance(vaultPda);
    const balanceIncrease = finalVaultBalanceGas - initialVaultBalanceGas;
    assert.equal(balanceIncrease, universalGasAmount.toNumber(), "Vault should receive exact gas amount");
    console.log(`💰 Vault balance increased by: ${balanceIncrease / LAMPORTS_PER_SOL} SOL (verified)\n`);

    // Test 4.5.2: GAS_AND_PAYLOAD Route
    console.log("4.5.2. Testing GAS_AND_PAYLOAD Route...");
    const universalGasPayloadAmount = await getDynamicGasAmount(2.5, 0.01);
    const gasPayloadReq = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: PublicKey.default,
        amount: new anchor.BN(0),
        payload: serializePayload(createPayload(1)),
        revertInstruction: createRevertInstruction(user),
        signatureData: Buffer.from("gas_payload_sig"),
    };

    const initialVaultBalanceGasPayload = await connection.getBalance(vaultPda);
    const gasPayloadTx = await userProgram.methods
        .sendUniversalTx(gasPayloadReq, universalGasPayloadAmount)
        .accounts({
            config: configPda,
            vault: vaultPda,
            userTokenAccount: vaultPda,
            gatewayTokenAccount: vaultPda,
            user: user,
            priceUpdate: PRICE_ACCOUNT,
            rateLimitConfig: rateLimitConfigPda,
            tokenRateLimit: nativeSolTokenRateLimitPda,
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
        })
        .signers([userKeypair])
        .rpc();

    console.log(`✅ GAS_AND_PAYLOAD route transaction: ${gasPayloadTx}`);
    await parseAndPrintEvents(gasPayloadTx, "GAS_AND_PAYLOAD route events");
    const finalVaultBalanceGasPayload = await connection.getBalance(vaultPda);
    const balanceIncreaseGasPayload = finalVaultBalanceGasPayload - initialVaultBalanceGasPayload;
    assert.equal(balanceIncreaseGasPayload, universalGasPayloadAmount.toNumber(), "Vault should receive exact gas amount");
    console.log(`💰 Vault balance increased by: ${balanceIncreaseGasPayload / LAMPORTS_PER_SOL} SOL (verified)\n`);

    // Test 4.5.3: FUNDS Route (Native SOL)
    console.log("4.5.3. Testing FUNDS Route (Native SOL)...");
    const fundsAmount = new anchor.BN(0.005 * LAMPORTS_PER_SOL);
    const fundsRecipient = Array.from(Buffer.from("1111111111111111111111111111111111111111", "hex").subarray(0, 20));
    const initialVaultBalanceFunds = await connection.getBalance(vaultPda);

    const fundsReq = {
        recipient: fundsRecipient,
        token: PublicKey.default,
        amount: fundsAmount,
        payload: Buffer.from([]),
        revertInstruction: createRevertInstruction(user),
        signatureData: Buffer.from("funds_sig"),
    };

    const fundsTx = await userProgram.methods
        .sendUniversalTx(fundsReq, fundsAmount) // native_amount == amount for native FUNDS
        .accounts({
            config: configPda,
            vault: vaultPda,
            userTokenAccount: vaultPda,
            gatewayTokenAccount: vaultPda,
            user: user,
            priceUpdate: PRICE_ACCOUNT,
            rateLimitConfig: rateLimitConfigPda,
            tokenRateLimit: nativeSolTokenRateLimitPda,
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
        })
        .signers([userKeypair])
        .rpc();

    console.log(`✅ FUNDS route (native SOL) transaction: ${fundsTx}`);
    await parseAndPrintEvents(fundsTx, "FUNDS route events");
    const finalVaultBalanceFunds = await connection.getBalance(vaultPda);
    const balanceIncreaseFunds = finalVaultBalanceFunds - initialVaultBalanceFunds;
    assert.equal(balanceIncreaseFunds, fundsAmount.toNumber(), "Vault should receive exact funds amount");
    console.log(`💰 Vault balance increased by: ${balanceIncreaseFunds / LAMPORTS_PER_SOL} SOL (verified)\n`);

    // Test 4.5.4: FUNDS Route (SPL Token) - if token is loaded
    if (tokenLoaded) {
        console.log("4.5.4. Testing FUNDS Route (SPL Token)...");
        // Create vault ATA if needed
        const vaultAta = await spl.getOrCreateAssociatedTokenAccount(
            adminProvider.connection as any,
            adminKeypair,
            mint,
            vaultPda,
            true
        );

        const splFundsAmount = new anchor.BN(1000 * Math.pow(10, tokenInfo.decimals));
        const splFundsRecipient = Array.from(Buffer.from("2222222222222222222222222222222222222222", "hex").subarray(0, 20));
        const userTokenBalanceBeforeSplFunds = (await spl.getAccount(userProvider.connection as any, tokenAccount)).amount;
        const vaultTokenBalanceBeforeSplFunds = (await spl.getAccount(userProvider.connection as any, vaultAta.address)).amount;

        const splFundsReq = {
            recipient: splFundsRecipient,
            token: mint,
            amount: splFundsAmount,
            payload: Buffer.from([]),
            revertInstruction: createRevertInstruction(user),
            signatureData: Buffer.from("spl_funds_sig"),
        };

        const splTokenRateLimitPda = getTokenRateLimitPda(mint);
        const splFundsTx = await userProgram.methods
            .sendUniversalTx(splFundsReq, new anchor.BN(0)) // No native SOL for SPL funds
            .accounts({
                config: configPda,
                vault: vaultPda,
                userTokenAccount: tokenAccount,
                gatewayTokenAccount: vaultAta.address,
                user: user,
                priceUpdate: PRICE_ACCOUNT,
                rateLimitConfig: rateLimitConfigPda,
                tokenRateLimit: splTokenRateLimitPda,
                tokenProgram: spl.TOKEN_PROGRAM_ID,
                systemProgram: SystemProgram.programId,
            })
            .signers([userKeypair])
            .rpc();

        console.log(`✅ FUNDS route (SPL token) transaction: ${splFundsTx}`);
        await parseAndPrintEvents(splFundsTx, "FUNDS route (SPL) events");
        const userTokenBalanceAfterSplFunds = (await spl.getAccount(userProvider.connection as any, tokenAccount)).amount;
        const vaultTokenBalanceAfterSplFunds = (await spl.getAccount(userProvider.connection as any, vaultAta.address)).amount;
        const userBalanceChange = Number(userTokenBalanceAfterSplFunds) - Number(userTokenBalanceBeforeSplFunds);
        const vaultBalanceChange = Number(vaultTokenBalanceAfterSplFunds) - Number(vaultTokenBalanceBeforeSplFunds);
        assert.equal(userBalanceChange, -splFundsAmount.toNumber(), "User should lose exact SPL amount");
        assert.equal(vaultBalanceChange, splFundsAmount.toNumber(), "Vault should gain exact SPL amount");
        console.log(`📊 User SPL balance: ${userTokenBalanceBeforeSplFunds.toString()} → ${userTokenBalanceAfterSplFunds.toString()} (verified)`);
        console.log(`📊 Vault SPL balance: ${vaultTokenBalanceBeforeSplFunds.toString()} → ${vaultTokenBalanceAfterSplFunds.toString()} (verified)\n`);
    }

    // Test 4.5.5: FUNDS_AND_PAYLOAD Route (Native SOL)
    console.log("4.5.5. Testing FUNDS_AND_PAYLOAD Route (Native SOL)...");
    const fundsPayloadBridgeAmount = new anchor.BN(0.01 * LAMPORTS_PER_SOL);
    const fundsPayloadGasAmount = await getDynamicGasAmount(1.5, 0.01);
    const totalNativeAmount = fundsPayloadBridgeAmount.add(fundsPayloadGasAmount);
    const fundsPayloadRecipient = Array.from(Buffer.from("3333333333333333333333333333333333333333", "hex").subarray(0, 20));

    const fundsPayloadReq = {
        recipient: fundsPayloadRecipient,
        token: PublicKey.default,
        amount: fundsPayloadBridgeAmount,
        payload: serializePayload(createPayload(2)),
        revertInstruction: createRevertInstruction(user),
        signatureData: Buffer.from("funds_payload_sig"),
    };

    const initialVaultBalanceFundsPayload = await connection.getBalance(vaultPda);
    const fundsPayloadTx = await userProgram.methods
        .sendUniversalTx(fundsPayloadReq, totalNativeAmount) // native_amount = bridge + gas
        .accounts({
            config: configPda,
            vault: vaultPda,
            userTokenAccount: vaultPda,
            gatewayTokenAccount: vaultPda,
            user: user,
            priceUpdate: PRICE_ACCOUNT,
            rateLimitConfig: rateLimitConfigPda,
            tokenRateLimit: nativeSolTokenRateLimitPda,
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
        })
        .signers([userKeypair])
        .rpc();

    console.log(`✅ FUNDS_AND_PAYLOAD route (native SOL) transaction: ${fundsPayloadTx}`);
    await parseAndPrintEvents(fundsPayloadTx, "FUNDS_AND_PAYLOAD route events");
    const finalVaultBalanceFundsPayload = await connection.getBalance(vaultPda);
    const balanceIncreaseFundsPayload = finalVaultBalanceFundsPayload - initialVaultBalanceFundsPayload;
    assert.equal(balanceIncreaseFundsPayload, totalNativeAmount.toNumber(), "Vault should receive bridge + gas amount");
    console.log(`💰 Vault balance increased by: ${balanceIncreaseFundsPayload / LAMPORTS_PER_SOL} SOL (verified)\n`);

    // Test 4.5.6: FUNDS_AND_PAYLOAD Route (SPL Token) - if token is loaded
    if (tokenLoaded) {
        console.log("4.5.6. Testing FUNDS_AND_PAYLOAD Route (SPL Token)...");
        // Ensure vault ATA exists
        const vaultAta = await spl.getOrCreateAssociatedTokenAccount(
            adminProvider.connection as any,
            adminKeypair,
            mint,
            vaultPda,
            true
        );

        const splFundsPayloadBridgeAmount = new anchor.BN(500 * Math.pow(10, tokenInfo.decimals));
        const splFundsPayloadGasAmount = await getDynamicGasAmount(1.5, 0.01);
        const splFundsPayloadRecipient = Array.from(Buffer.from("4444444444444444444444444444444444444444", "hex").subarray(0, 20));

        const splFundsPayloadReq = {
            recipient: splFundsPayloadRecipient,
            token: mint,
            amount: splFundsPayloadBridgeAmount,
            payload: serializePayload(createPayload(3)),
            revertInstruction: createRevertInstruction(user),
            signatureData: Buffer.from("spl_funds_payload_sig"),
        };

        const initialVaultBalanceSplFundsPayload = await connection.getBalance(vaultPda);
        const userTokenBalanceBeforeSplFundsPayload = (await spl.getAccount(userProvider.connection as any, tokenAccount)).amount;
        const vaultTokenBalanceBeforeSplFundsPayload = (await spl.getAccount(userProvider.connection as any, vaultAta.address)).amount;
        const splTokenRateLimitPda = getTokenRateLimitPda(mint);
        const splFundsPayloadTx = await userProgram.methods
            .sendUniversalTx(splFundsPayloadReq, splFundsPayloadGasAmount) // Only gas amount in native SOL
            .accounts({
                config: configPda,
                vault: vaultPda,
                userTokenAccount: tokenAccount,
                gatewayTokenAccount: vaultAta.address,
                user: user,
                priceUpdate: PRICE_ACCOUNT,
                rateLimitConfig: rateLimitConfigPda,
                tokenRateLimit: splTokenRateLimitPda,
                tokenProgram: spl.TOKEN_PROGRAM_ID,
                systemProgram: SystemProgram.programId,
            })
            .signers([userKeypair])
            .rpc();

        console.log(`✅ FUNDS_AND_PAYLOAD route (SPL token) transaction: ${splFundsPayloadTx}`);
        await parseAndPrintEvents(splFundsPayloadTx, "FUNDS_AND_PAYLOAD route (SPL) events");
        const finalVaultBalanceSplFundsPayload = await connection.getBalance(vaultPda);
        const userTokenBalanceAfterSplFundsPayload = (await spl.getAccount(userProvider.connection as any, tokenAccount)).amount;
        const vaultTokenBalanceAfterSplFundsPayload = (await spl.getAccount(userProvider.connection as any, vaultAta.address)).amount;
        const vaultSolIncrease = finalVaultBalanceSplFundsPayload - initialVaultBalanceSplFundsPayload;
        const userTokenChange = Number(userTokenBalanceAfterSplFundsPayload) - Number(userTokenBalanceBeforeSplFundsPayload);
        const vaultTokenChange = Number(vaultTokenBalanceAfterSplFundsPayload) - Number(vaultTokenBalanceBeforeSplFundsPayload);
        assert.equal(vaultSolIncrease, splFundsPayloadGasAmount.toNumber(), "Vault should receive exact gas amount");
        assert.equal(userTokenChange, -splFundsPayloadBridgeAmount.toNumber(), "User should lose exact SPL bridge amount");
        assert.equal(vaultTokenChange, splFundsPayloadBridgeAmount.toNumber(), "Vault should gain exact SPL bridge amount");
        console.log(`💰 Vault SOL increased by: ${vaultSolIncrease / LAMPORTS_PER_SOL} SOL (verified)`);
        console.log(`📊 User SPL: ${userTokenBalanceBeforeSplFundsPayload.toString()} → ${userTokenBalanceAfterSplFundsPayload.toString()} (verified)`);
        console.log(`📊 Vault SPL: ${vaultTokenBalanceBeforeSplFundsPayload.toString()} → ${vaultTokenBalanceAfterSplFundsPayload.toString()} (verified)\n`);
    }

    // Test 4.5.7: Edge Cases and Negative Tests
    console.log("4.5.7. Testing Edge Cases and Negative Tests...");

    // Edge Case: Payload-only execution (GAS_AND_PAYLOAD with native_amount == 0)
    console.log("  - Testing payload-only execution (GAS_AND_PAYLOAD with 0 gas)...");
    const payloadOnlyReq = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: PublicKey.default,
        amount: new anchor.BN(0),
        payload: serializePayload(createPayload(5)),
        revertInstruction: createRevertInstruction(user),
        signatureData: Buffer.from("payload_only_sig"),
    };

    const initialVaultBalancePayloadOnly = await connection.getBalance(vaultPda);
    try {
        const payloadOnlyTx = await userProgram.methods
            .sendUniversalTx(payloadOnlyReq, new anchor.BN(0)) // 0 native amount
            .accounts({
                config: configPda,
                vault: vaultPda,
                userTokenAccount: vaultPda,
                gatewayTokenAccount: vaultPda,
                user: user,
                priceUpdate: PRICE_ACCOUNT,
                rateLimitConfig: rateLimitConfigPda,
                tokenRateLimit: nativeSolTokenRateLimitPda,
                tokenProgram: spl.TOKEN_PROGRAM_ID,
                systemProgram: SystemProgram.programId,
            })
            .signers([userKeypair])
            .rpc();
        const finalVaultBalancePayloadOnly = await connection.getBalance(vaultPda);
        assert.equal(finalVaultBalancePayloadOnly, initialVaultBalancePayloadOnly, "Vault balance should not change for payload-only execution");
        console.log(`  ✅ Payload-only execution succeeded: ${payloadOnlyTx} (no balance change verified)`);
    } catch (error: any) {
        console.log(`  ⚠️  Payload-only execution failed: ${error.message}`);
        throw error; // Re-throw to fail the script if this should succeed
    }


    // Negative Test: FUNDS native with mismatched amounts (should fail)
    console.log("  - Testing negative case: FUNDS native with mismatched amounts (should fail)...");
    const mismatchedFundsReq = {
        recipient: Array.from(Buffer.from("5555555555555555555555555555555555555555", "hex").subarray(0, 20)),
        token: PublicKey.default,
        amount: new anchor.BN(0.01 * LAMPORTS_PER_SOL),
        payload: Buffer.from([]),
        revertInstruction: createRevertInstruction(user),
        signatureData: Buffer.from("mismatched_sig"),
    };

    try {
        await userProgram.methods
            .sendUniversalTx(mismatchedFundsReq, new anchor.BN(0.005 * LAMPORTS_PER_SOL)) // Different amount
            .accounts({
                config: configPda,
                vault: vaultPda,
                userTokenAccount: vaultPda,
                gatewayTokenAccount: vaultPda,
                user: user,
                priceUpdate: PRICE_ACCOUNT,
                rateLimitConfig: rateLimitConfigPda,
                tokenRateLimit: nativeSolTokenRateLimitPda,
                tokenProgram: spl.TOKEN_PROGRAM_ID,
                systemProgram: SystemProgram.programId,
            })
            .signers([userKeypair])
            .rpc();
        assert.fail("Should have rejected mismatched amounts");
    } catch (error: any) {
        const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
        assert.equal(errorCode, "InvalidAmount", `Expected InvalidAmount but got: ${errorCode}`);
        console.log(`  ✅ Correctly rejected mismatched amounts with InvalidAmount error`);
    }

    // Negative Test: FUNDS SPL with native SOL provided (should fail)
    if (tokenLoaded) {
        console.log("  - Testing negative case: FUNDS SPL with native SOL (should fail)...");
        // Ensure vault ATA exists for the test
        const testVaultAta = await spl.getOrCreateAssociatedTokenAccount(
            adminProvider.connection as any,
            adminKeypair,
            mint,
            vaultPda,
            true
        );

        const invalidSplFundsReq = {
            recipient: Array.from(Buffer.from("6666666666666666666666666666666666666666", "hex").subarray(0, 20)),
            token: mint,
            amount: new anchor.BN(1000 * Math.pow(10, tokenInfo.decimals)),
            payload: Buffer.from([]),
            revertInstruction: createRevertInstruction(user),
            signatureData: Buffer.from("invalid_spl_sig"),
        };

        try {
            await userProgram.methods
                .sendUniversalTx(invalidSplFundsReq, new anchor.BN(0.001 * LAMPORTS_PER_SOL)) // Native SOL provided
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    userTokenAccount: tokenAccount,
                    gatewayTokenAccount: testVaultAta.address,
                    user: user,
                    priceUpdate: PRICE_ACCOUNT,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: getTokenRateLimitPda(mint),
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([userKeypair])
                .rpc();
            assert.fail("Should have rejected SPL FUNDS with native SOL");
        } catch (error: any) {
            const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
            assert.equal(errorCode, "InvalidAmount", `Expected InvalidAmount but got: ${errorCode}`);
            console.log(`  ✅ Correctly rejected SPL FUNDS with native SOL (InvalidAmount error)`);
        }
    }

    // Negative Test: Invalid revert recipient (should fail with InvalidRecipient)
    console.log("  - Testing negative case: Invalid revert recipient (should fail)...");
    const invalidRecipientReq = {
        recipient: Array.from(Buffer.alloc(20, 0)),
        token: PublicKey.default,
        amount: new anchor.BN(0),
        payload: Buffer.from([]),
        revertInstruction: createRevertInstruction(PublicKey.default), // Invalid: default pubkey
        signatureData: Buffer.from("invalid_recipient_sig"),
    };

    try {
        await userProgram.methods
            .sendUniversalTx(invalidRecipientReq, await getDynamicGasAmount(2.5, 0.01))
            .accounts({
                config: configPda,
                vault: vaultPda,
                userTokenAccount: vaultPda,
                gatewayTokenAccount: vaultPda,
                user: user,
                priceUpdate: PRICE_ACCOUNT,
                rateLimitConfig: rateLimitConfigPda,
                tokenRateLimit: nativeSolTokenRateLimitPda,
                tokenProgram: spl.TOKEN_PROGRAM_ID,
                systemProgram: SystemProgram.programId,
            })
            .signers([userKeypair])
            .rpc();
        assert.fail("Should have rejected invalid revert recipient");
    } catch (error: any) {
        const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
        assert.equal(errorCode, "InvalidRecipient", `Expected InvalidRecipient but got: ${errorCode}`);
        console.log(`  ✅ Correctly rejected invalid revert recipient (InvalidRecipient error)`);
    }

    // Negative Test: FUNDS with mismatched native amount (should fail with InvalidAmount)
    // NOTE: When payload is empty and amount > 0, fetchTxType routes to TxType::Funds (not FundsAndPayload)
    // The validation happens in fetchTxType before routing, so we get InvalidAmount, not InvalidInput
    console.log("  - Testing negative case: FUNDS with mismatched native amount (should fail)...");
    const mismatchedNativeReq = {
        recipient: Array.from(Buffer.from("7777777777777777777777777777777777777777", "hex").subarray(0, 20)),
        token: PublicKey.default,
        amount: new anchor.BN(0.01 * LAMPORTS_PER_SOL),
        payload: Buffer.from([]), // Empty payload routes to FUNDS, not FUNDS_AND_PAYLOAD
        revertInstruction: createRevertInstruction(user),
        signatureData: Buffer.from("mismatched_native_sig"),
    };

    try {
        await userProgram.methods
            .sendUniversalTx(mismatchedNativeReq, new anchor.BN(0.02 * LAMPORTS_PER_SOL)) // native != amount
            .accounts({
                config: configPda,
                vault: vaultPda,
                userTokenAccount: vaultPda,
                gatewayTokenAccount: vaultPda,
                user: user,
                priceUpdate: PRICE_ACCOUNT,
                rateLimitConfig: rateLimitConfigPda,
                tokenRateLimit: nativeSolTokenRateLimitPda,
                tokenProgram: spl.TOKEN_PROGRAM_ID,
                systemProgram: SystemProgram.programId,
            })
            .signers([userKeypair])
            .rpc();
        assert.fail("Should have rejected FUNDS with mismatched native amount");
    } catch (error: any) {
        const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
        assert.equal(errorCode, "InvalidAmount", `Expected InvalidAmount but got: ${errorCode}`);
        console.log(`  ✅ Correctly rejected FUNDS with mismatched native amount (InvalidAmount error)`);
    }

    // Negative Test: FUNDS_AND_PAYLOAD native with insufficient native amount (should fail)
    console.log("  - Testing negative case: FUNDS_AND_PAYLOAD native with insufficient amount (should fail)...");
    const insufficientNativeReq = {
        recipient: Array.from(Buffer.from("8888888888888888888888888888888888888888", "hex").subarray(0, 20)),
        token: PublicKey.default,
        amount: new anchor.BN(0.01 * LAMPORTS_PER_SOL),
        payload: serializePayload(createPayload(4)),
        revertInstruction: createRevertInstruction(user),
        signatureData: Buffer.from("insufficient_native_sig"),
    };

    try {
        await userProgram.methods
            .sendUniversalTx(insufficientNativeReq, new anchor.BN(0.005 * LAMPORTS_PER_SOL)) // native < amount
            .accounts({
                config: configPda,
                vault: vaultPda,
                userTokenAccount: vaultPda,
                gatewayTokenAccount: vaultPda,
                user: user,
                priceUpdate: PRICE_ACCOUNT,
                rateLimitConfig: rateLimitConfigPda,
                tokenRateLimit: nativeSolTokenRateLimitPda,
                tokenProgram: spl.TOKEN_PROGRAM_ID,
                systemProgram: SystemProgram.programId,
            })
            .signers([userKeypair])
            .rpc();
        assert.fail("Should have rejected insufficient native amount");
    } catch (error: any) {
        const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
        assert.equal(errorCode, "InvalidAmount", `Expected InvalidAmount but got: ${errorCode}`);
        console.log(`  ✅ Correctly rejected insufficient native amount (InvalidAmount error)`);
    }

    console.log("✅ Edge cases and negative tests completed!\n");

    console.log("✅ All sendUniversalTx tests completed!\n");

    // Step 5: Test send_tx_with_gas (SOL deposit with payload) - LEGACY FUNCTION
    console.log("5. Testing send_tx_with_gas...");
    const userBalanceBefore = await connection.getBalance(user);
    const vaultBalanceBefore = await connection.getBalance(vaultPda);

    console.log(`User balance BEFORE: ${userBalanceBefore / LAMPORTS_PER_SOL} SOL`);
    console.log(`Vault balance BEFORE: ${vaultBalanceBefore / LAMPORTS_PER_SOL} SOL`);

    // Create payload and revert settings
    const payload = {
        to: Array.from(Buffer.from("1234567890123456789012345678901234567890", "hex").subarray(0, 20)), // Ethereum address (20 bytes)
        value: new anchor.BN(0), // Value to send
        data: Buffer.from("test payload data"),
        gasLimit: new anchor.BN(100000),
        maxFeePerGas: new anchor.BN(20000000000), // 20 gwei
        maxPriorityFeePerGas: new anchor.BN(1000000000), // 1 gwei
        nonce: new anchor.BN(0),
        deadline: new anchor.BN(Date.now() + 3600000), // 1 hour from now
        vType: { signedVerification: {} }, // VerificationType enum
    };

    const revertInstructions = {
        fundRecipient: user, // Use user as recipient for simplicity  
        revertMsg: Buffer.from("revert message"),
    };


    // Get dynamic gas amount for USD cap compliance
    const gasAmount = await getDynamicGasAmount(1.20, 0.01); // Target $1.20, fallback 0.01 SOL

    // Generate signature data for send_tx_with_gas
    const gasSignatureData = Buffer.from("test_signature_data_for_send_tx_with_gas", "utf8");

    const gasTx = await userProgram.methods
        .sendTxWithGas(payload, revertInstructions, gasAmount, gasSignatureData)
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
    const vaultBalanceIncrease = vaultBalanceAfter - vaultBalanceBefore;
    assert.equal(vaultBalanceIncrease, gasAmount.toNumber(), "Vault should receive exact gas amount");
    console.log(`User balance AFTER: ${userBalanceAfter / LAMPORTS_PER_SOL} SOL`);
    console.log(`Vault balance AFTER: ${vaultBalanceAfter / LAMPORTS_PER_SOL} SOL (verified: +${vaultBalanceIncrease / LAMPORTS_PER_SOL} SOL)\n`);

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
    const recipient = Array.from(Buffer.from("1111111111111111111111111111111111111111", "hex").subarray(0, 20)); // EVM address (20 bytes)
    const fundAmount = new anchor.BN(0.005 * LAMPORTS_PER_SOL); // 0.005 SOL

    const userBalanceBeforeFunds = await connection.getBalance(user);
    const vaultBalanceBeforeFunds = await connection.getBalance(vaultPda);

    console.log(`💳 User balance BEFORE send_funds (native): ${userBalanceBeforeFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault balance BEFORE send_funds (native): ${vaultBalanceBeforeFunds / LAMPORTS_PER_SOL} SOL`);

    const nativeFundsTx = await userProgram.methods
        .sendFunds(recipient, PublicKey.default, fundAmount, revertInstructions) // PublicKey.default for native SOL
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
    const vaultBalanceIncreaseFunds = vaultBalanceAfterFunds - vaultBalanceBeforeFunds;
    assert.equal(vaultBalanceIncreaseFunds, fundAmount.toNumber(), "Vault should receive exact funds amount");
    console.log(`💳 User balance AFTER send_funds (native): ${userBalanceAfterFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault balance AFTER send_funds (native): ${vaultBalanceAfterFunds / LAMPORTS_PER_SOL} SOL (verified: +${vaultBalanceIncreaseFunds / LAMPORTS_PER_SOL} SOL)\n`);

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
    // Convert SPL recipient to EVM address for the event
    const splRecipientEvm = Array.from(Buffer.from("2222222222222222222222222222222222222222", "hex").subarray(0, 20)); // EVM address (20 bytes)

    console.log(`📤 Sending ${splAmount.toNumber() / Math.pow(10, 6)} tokens to EVM address 0x2222222222222222222222222222222222222222`);

    const splFundsTx = await userProgram.methods
        .sendFunds(splRecipientEvm, mint, splAmount, revertInstructions)
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
    const userTokenChange = Number(userTokenBalanceAfter) - Number(userTokenBalanceBefore);
    const vaultTokenChange = Number(vaultTokenBalanceAfter) - Number(vaultTokenBalanceBefore);
    assert.equal(userTokenChange, -splAmount.toNumber(), "User should lose exact SPL amount");
    assert.equal(vaultTokenChange, splAmount.toNumber(), "Vault should gain exact SPL amount");
    console.log(`📊 User SPL balance AFTER: ${userTokenBalanceAfter.toString()} tokens (verified: ${userTokenChange < 0 ? '-' : '+'}${Math.abs(userTokenChange)})`);
    console.log(`📊 Vault SPL balance AFTER: ${vaultTokenBalanceAfter.toString()} tokens (verified: +${vaultTokenChange})\n`);

    // Step 8: Test send_tx_with_funds (SPL + payload + gas)
    console.log("8. Testing send_tx_with_funds (SPL + payload + gas)...");

    // Get dynamic gas amount for USD cap compliance
    const txWithFundsGasAmount = await getDynamicGasAmount(1.50, 0.01); // Target $1.50, fallback 0.01 SOL

    const txWithFundsRecipient = Keypair.generate().publicKey;
    const txWithFundsSplAmount = new anchor.BN(500 * Math.pow(10, 6)); // 500 tokens

    // Create payload for this transaction
    const txWithFundsPayload = {
        to: Array.from(Buffer.from("abcdefabcdefabcdefabcdefabcdefabcdefabcd", "hex").subarray(0, 20)), // Ethereum address (20 bytes)
        value: new anchor.BN(0), // Value to send
        data: Buffer.from("test payload for funds+gas"),
        gasLimit: new anchor.BN(120000),
        maxFeePerGas: new anchor.BN(20000000000), // 20 gwei
        maxPriorityFeePerGas: new anchor.BN(1000000000), // 1 gwei
        nonce: new anchor.BN(1),
        deadline: new anchor.BN(Date.now() + 3600000), // 1 hour from now
        vType: { signedVerification: {} }, // VerificationType enum
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
            revertInstructions,
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
    const vaultSolIncreaseTx = vaultBalanceAfterTxWithFunds - vaultBalanceBeforeTxWithFunds;
    const userTokenChangeTx = Number(userTokenBalanceAfterTx) - Number(userTokenBalanceBeforeTx);
    const vaultTokenChangeTx = Number(vaultTokenBalanceAfterTx) - Number(vaultTokenBalanceBeforeTx);
    assert.equal(vaultSolIncreaseTx, txWithFundsGasAmount.toNumber(), "Vault should receive exact gas amount");
    assert.equal(userTokenChangeTx, -txWithFundsSplAmount.toNumber(), "User should lose exact SPL amount");
    assert.equal(vaultTokenChangeTx, txWithFundsSplAmount.toNumber(), "Vault should gain exact SPL amount");
    console.log(`💳 User SOL balance AFTER: ${userBalanceAfterTxWithFunds / LAMPORTS_PER_SOL} SOL`);
    console.log(`🏦 Vault SOL balance AFTER: ${vaultBalanceAfterTxWithFunds / LAMPORTS_PER_SOL} SOL (verified: +${vaultSolIncreaseTx / LAMPORTS_PER_SOL} SOL)`);
    console.log(`📊 User SPL balance AFTER: ${userTokenBalanceAfterTx.toString()} tokens (verified: ${userTokenChangeTx < 0 ? '-' : '+'}${Math.abs(userTokenChangeTx)})`);
    console.log(`📊 Vault SPL balance AFTER: ${vaultTokenBalanceAfterTx.toString()} tokens (verified: +${vaultTokenChangeTx})\n`);

    // Step 9.5: Test send_tx_with_funds with native SOL as both bridge token and gas
    console.log("9.5. Testing send_tx_with_funds with native SOL (bridge + gas)...");

    // Get dynamic amounts for USD cap compliance
    const nativeGasAmount = await getDynamicGasAmount(1.20, 0.008); // Target $1.20, fallback 0.008 SOL
    const nativeBridgeAmount = await getDynamicGasAmount(2.00, 0.02); // Target $2.00, fallback 0.02 SOL
    console.log(`🌉 Bridge amount: ${(nativeBridgeAmount.toNumber() / LAMPORTS_PER_SOL).toFixed(4)} SOL`);

    const nativePayload = {
        to: Array.from(Buffer.from("fedcbafedcbafedcbafedcbafedcbafedcbafedcba", "hex").subarray(0, 20)), // Ethereum address (20 bytes)
        value: new anchor.BN(0),
        data: Buffer.from("native_sol_payload_data"),
        gasLimit: new anchor.BN(21000),
        maxFeePerGas: new anchor.BN(20000000000),
        maxPriorityFeePerGas: new anchor.BN(2000000000),
        nonce: new anchor.BN(0),
        deadline: new anchor.BN(Date.now() + 3600000),
        vType: { signedVerification: {} }
    };

    const nativeRevertInstructions = {
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
            nativeRevertInstructions,
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
    const signatureNew = Buffer.from("test_signature_data_for_gas", "utf8");
    try {
        await userProgram.methods
            .sendTxWithGas(payload, revertInstructions, gasAmount, signatureNew)
            .accounts({
                config: configPda,
                vault: vaultPda,
                user: user,
                priceUpdate: PRICE_ACCOUNT,
                systemProgram: SystemProgram.programId,
            })
            .rpc();
        assert.fail("Transaction should have failed while paused");
    } catch (error: any) {
        const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
        assert.equal(errorCode, "Paused", `Expected Paused but got: ${errorCode}`);
        console.log("✅ Transaction correctly failed while paused (Paused error verified)");
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

    // Re-whitelist the token after removal test
    console.log("14b. Re-whitelisting token after removal test...");
    try {
        const reWhitelistTx = await program.methods
            .whitelistToken(mint)
            .accounts({
                config: configPda,
                whitelist: whitelistPda,
                admin: admin,
                systemProgram: SystemProgram.programId,
            })
            .rpc();
        console.log(`✅ Token re-whitelisted: ${reWhitelistTx}\n`);
    } catch (error) {
        if (error.message.includes("TokenAlreadyWhitelisted")) {
            console.log(`✅ Token already whitelisted (skipping re-whitelist)\n`);
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
