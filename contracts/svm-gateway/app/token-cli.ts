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
import {
    createCreateMetadataAccountV3Instruction,
    PROGRAM_ID as TOKEN_METADATA_PROGRAM_ID,
} from "@metaplex-foundation/mpl-token-metadata";
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

// Helper function to create SPL token with metadata
async function createSPLToken(
    provider: anchor.AnchorProvider,
    wallet: Keypair,
    tokenName: string,
    tokenSymbol: string,
    tokenDescription: string,
    decimals: number = 6
): Promise<{ mint: Keypair; tokenAccount: PublicKey; metadataAccount: PublicKey }> {
    console.log(`🪙 Creating new SPL token: ${tokenName} (${tokenSymbol})...`);

    const mint = Keypair.generate();
    const mintRent = await spl.getMinimumBalanceForRentExemptMint(provider.connection as any);

    // Create metadata account PDA
    const [metadataAccount] = PublicKey.findProgramAddressSync(
        [
            Buffer.from("metadata"),
            TOKEN_METADATA_PROGRAM_ID.toBuffer(),
            mint.publicKey.toBuffer(),
        ],
        TOKEN_METADATA_PROGRAM_ID
    );

    const tokenTransaction = new anchor.web3.Transaction();

    // Create mint account
    tokenTransaction.add(
        anchor.web3.SystemProgram.createAccount({
            fromPubkey: wallet.publicKey,
            newAccountPubkey: mint.publicKey,
            lamports: mintRent,
            space: spl.MINT_SIZE,
            programId: spl.TOKEN_PROGRAM_ID,
        }),
        spl.createInitializeMintInstruction(
            mint.publicKey,
            decimals,
            wallet.publicKey,
            null
        )
    );

    // Create metadata account
    const createMetadataInstruction = createCreateMetadataAccountV3Instruction(
        {
            metadata: metadataAccount,
            mint: mint.publicKey,
            mintAuthority: wallet.publicKey,
            payer: wallet.publicKey,
            updateAuthority: wallet.publicKey,
        },
        {
            createMetadataAccountArgsV3: {
                data: {
                    name: tokenName,
                    symbol: tokenSymbol,
                    uri: "", // No URI for now, can be added later
                    sellerFeeBasisPoints: 0,
                    creators: null,
                    collection: null,
                    uses: null,
                },
                isMutable: true,
                collectionDetails: null,
            },
        }
    );

    tokenTransaction.add(createMetadataInstruction);

    await anchor.web3.sendAndConfirmTransaction(
        provider.connection as any,
        tokenTransaction,
        [wallet, mint]
    );

    // Create associated token account for the wallet
    const tokenAccount = await spl.getOrCreateAssociatedTokenAccount(
        provider.connection as any,
        wallet,
        mint.publicKey,
        wallet.publicKey
    );

    // Mint some tokens to the account
    const mintToTransaction = new anchor.web3.Transaction().add(
        spl.createMintToInstruction(
            mint.publicKey,
            tokenAccount.address,
            wallet.publicKey,
            1_000_000 * Math.pow(10, decimals) // 1M tokens
        )
    );

    await anchor.web3.sendAndConfirmTransaction(
        provider.connection as any,
        mintToTransaction,
        [wallet]
    );

    console.log(`✅ SPL Token created with metadata:`);
    console.log(`   Name: ${tokenName}`);
    console.log(`   Symbol: ${tokenSymbol}`);
    console.log(`   Description: ${tokenDescription}`);
    console.log(`   Mint: ${mint.publicKey.toString()}`);
    console.log(`   Metadata Account: ${metadataAccount.toString()}`);
    console.log(`   Token Account: ${tokenAccount.address.toString()}`);
    console.log(`   Decimals: ${decimals}`);
    console.log(`   Initial Supply: 1,000,000 tokens\n`);

    return { mint, tokenAccount: tokenAccount.address, metadataAccount };
}

// Helper function to mint tokens to any address
async function mintTokensToAddress(
    provider: anchor.AnchorProvider,
    mintAuthority: Keypair,
    mintAddress: string,
    recipientAddress: string,
    amount: number,
    decimals: number = 6
): Promise<void> {
    console.log(`🪙 Minting ${amount} tokens to ${recipientAddress}...`);

    const mint = new PublicKey(mintAddress);
    const recipient = new PublicKey(recipientAddress);

    // Get or create associated token account for recipient
    const recipientTokenAccount = await spl.getOrCreateAssociatedTokenAccount(
        provider.connection as any,
        mintAuthority,
        mint,
        recipient
    );

    // Convert amount to proper units (considering decimals)
    const mintAmount = amount * Math.pow(10, decimals);

    // Mint tokens
    const mintToTransaction = new anchor.web3.Transaction().add(
        spl.createMintToInstruction(
            mint,
            recipientTokenAccount.address,
            mintAuthority.publicKey,
            mintAmount
        )
    );

    const signature = await anchor.web3.sendAndConfirmTransaction(
        provider.connection as any,
        mintToTransaction,
        [mintAuthority]
    );

    console.log(`✅ Successfully minted ${amount} tokens to ${recipientAddress}`);
    console.log(`   Recipient Token Account: ${recipientTokenAccount.address.toString()}`);
    console.log(`   Transaction Signature: ${signature}\n`);
}

// Helper function to save token info to file
function saveTokenInfo(mint: Keypair, tokenName: string, tokenSymbol: string) {
    const tokenInfo = {
        mint: mint.publicKey.toString(),
        mintSecretKey: Array.from(mint.secretKey),
        name: tokenName,
        symbol: tokenSymbol,
        createdAt: new Date().toISOString()
    };

    const filename = `../tokens/${tokenSymbol.toLowerCase()}-token.json`;

    // Create tokens directory if it doesn't exist
    if (!fs.existsSync("../tokens")) {
        fs.mkdirSync("../tokens");
    }

    fs.writeFileSync(filename, JSON.stringify(tokenInfo, null, 2));
    console.log(`💾 Token info saved to: ${filename}`);
}

// Helper function to load token info from file
function loadTokenInfo(tokenSymbol: string): any {
    const filename = `../tokens/${tokenSymbol.toLowerCase()}-token.json`;

    if (!fs.existsSync(filename)) {
        throw new Error(`Token file not found: ${filename}`);
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

// Initialize the CLI
const program_cli = new Command();

program_cli
    .name('token-cli')
    .description('CLI tool for managing SPL tokens with metadata')
    .version('1.0.0');

// Create token command
program_cli
    .command('create')
    .description('Create a new SPL token with metadata')
    .requiredOption('-n, --name <name>', 'Token name (e.g., "USD Coin")')
    .requiredOption('-s, --symbol <symbol>', 'Token symbol (e.g., "USDC")')
    .option('-d, --description <description>', 'Token description', 'A custom SPL token')
    .option('--decimals <decimals>', 'Number of decimals', '6')
    .action(async (options) => {
        try {
            console.log("=== CREATING NEW SPL TOKEN ===\n");

            const decimals = parseInt(options.decimals);
            const { mint, tokenAccount, metadataAccount } = await createSPLToken(
                userProvider,
                userKeypair,
                options.name,
                options.symbol,
                options.description,
                decimals
            );

            // Save token info
            saveTokenInfo(mint, options.name, options.symbol);

            console.log("🎉 Token creation completed successfully!");

        } catch (error) {
            console.error("❌ Error creating token:", error.message);
            process.exit(1);
        }
    });

// Mint tokens command
program_cli
    .command('mint')
    .description('Mint tokens to any address')
    .requiredOption('-m, --mint <mint>', 'Mint address or token symbol')
    .requiredOption('-r, --recipient <recipient>', 'Recipient address')
    .requiredOption('-a, --amount <amount>', 'Amount to mint')
    .option('--decimals <decimals>', 'Number of decimals (if using mint address)', '6')
    .action(async (options) => {
        try {
            console.log("=== MINTING TOKENS ===\n");

            let mintAddress: string;
            let decimals: number;

            // Check if it's a token symbol or mint address
            if (options.mint.length === 44) {
                // It's a mint address
                mintAddress = options.mint;
                decimals = parseInt(options.decimals);
            } else {
                // It's a token symbol, load from file
                const tokenInfo = loadTokenInfo(options.mint);
                mintAddress = tokenInfo.mint;
                decimals = 6; // Default, could be stored in token info
            }

            const amount = parseFloat(options.amount);

            await mintTokensToAddress(
                userProvider,
                userKeypair,
                mintAddress,
                options.recipient,
                amount,
                decimals
            );

            console.log("🎉 Token minting completed successfully!");

        } catch (error) {
            console.error("❌ Error minting tokens:", error.message);
            process.exit(1);
        }
    });

// Whitelist token command
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

// List tokens command
program_cli
    .command('list')
    .description('List all created tokens')
    .action(() => {
        try {
            console.log("=== CREATED TOKENS ===\n");

            if (!fs.existsSync("../tokens")) {
                console.log("No tokens created yet.");
                return;
            }

            const files = fs.readdirSync("../tokens");
            const tokenFiles = files.filter(file => file.endsWith('-token.json'));

            if (tokenFiles.length === 0) {
                console.log("No tokens created yet.");
                return;
            }

            tokenFiles.forEach(file => {
                const tokenInfo = JSON.parse(fs.readFileSync(`../tokens/${file}`, "utf8"));
                console.log(`📄 ${tokenInfo.symbol} (${tokenInfo.name})`);
                console.log(`   Mint: ${tokenInfo.mint}`);
                console.log(`   Created: ${tokenInfo.createdAt}`);
                console.log("");
            });

        } catch (error) {
            console.error("❌ Error listing tokens:", error.message);
            process.exit(1);
        }
    });

// Load environment variables
dotenv.config({ path: "../.env" });
dotenv.config();

// Parse command line arguments
program_cli.parse();
