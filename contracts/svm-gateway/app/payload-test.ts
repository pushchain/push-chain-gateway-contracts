import * as anchor from "@coral-xyz/anchor";
import {
    Connection,
    Keypair,
    PublicKey,
    SystemProgram,
    LAMPORTS_PER_SOL,
} from "@solana/web3.js";
import { Program } from "@coral-xyz/anchor";
import fs from "fs";
import * as spl from "@solana/spl-token";

type PayloadStruct = {
    to: number[];
    value: anchor.BN;
    data: Buffer;
    gasLimit: anchor.BN;
    maxFeePerGas: anchor.BN;
    maxPriorityFeePerGas: anchor.BN;
    nonce: anchor.BN;
    deadline: anchor.BN;
    vType: { signedVerification: Record<string, never> };
};

const PROGRAM_ID = new PublicKey("CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS");
const CONFIG_SEED = "config";
const VAULT_SEED = "vault";
const WHITELIST_SEED = "whitelist";
const PRICE_ACCOUNT = new PublicKey("7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE");

function loadKeypair(path: string): Keypair {
    const secret = JSON.parse(fs.readFileSync(path, "utf8"));
    return Keypair.fromSecretKey(Uint8Array.from(secret));
}

async function main() {
    const adminKeypair = loadKeypair("./upgrade-keypair.json");
    const userKeypair = loadKeypair("./clean-user-keypair.json");

    const connection = new Connection("https://api.devnet.solana.com", "confirmed");
    const adminProvider = new anchor.AnchorProvider(
        connection,
        new anchor.Wallet(adminKeypair),
        { commitment: "confirmed" },
    );
    anchor.setProvider(adminProvider);

    const userProvider = new anchor.AnchorProvider(
        connection,
        new anchor.Wallet(userKeypair),
        { commitment: "confirmed" },
    );

    const idl = JSON.parse(fs.readFileSync("./target/idl/universal_gateway.json", "utf8"));
    const userProgram = new Program(idl, userProvider);

    const [configPda] = PublicKey.findProgramAddressSync([Buffer.from(CONFIG_SEED)], PROGRAM_ID);
    const [vaultPda] = PublicKey.findProgramAddressSync([Buffer.from(VAULT_SEED)], PROGRAM_ID);
    const [whitelistPda] = PublicKey.findProgramAddressSync([Buffer.from(WHITELIST_SEED)], PROGRAM_ID);

    const commonPayload: PayloadStruct = {
        to: Array.from(Buffer.from("1234567890123456789012345678901234567890", "hex").subarray(0, 20)),
        value: new anchor.BN(0),
        data: Buffer.from("test payload data"),
        gasLimit: new anchor.BN(12230_000),
        maxFeePerGas: new anchor.BN(223230_000_000_000),
        maxPriorityFeePerGas: new anchor.BN(1_0677_000_000),
        nonce: new anchor.BN(4982),
        deadline: new anchor.BN(Date.now() + 60 * 60 * 1000),
        vType: { signedVerification: {} },
    };

    const revertInstructions = {
        fundRecipient: userKeypair.publicKey,
        revertMsg: Buffer.from("payload revert test"),
    };

    const gasAmount = new anchor.BN(Math.floor(0.01 * LAMPORTS_PER_SOL));
    const bridgeAmount = new anchor.BN(Math.floor(0.015 * LAMPORTS_PER_SOL));
    const gasSignatureData = Buffer.from("sig-sendTxWithGas");
    const fundsSignatureData = Buffer.from("sig-sendTxWithFunds");

    console.log("-> sendTxWithGas");
    const gasTx = await userProgram.methods
        .sendTxWithGas(commonPayload as any, revertInstructions, gasAmount, gasSignatureData)
        .accounts({
            config: configPda,
            vault: vaultPda,
            user: userKeypair.publicKey,
            priceUpdate: PRICE_ACCOUNT,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`   tx: ${gasTx}`);

    console.log("-> sendTxWithFunds (native)");
    const fundsTx = await userProgram.methods
        .sendTxWithFunds(
            PublicKey.default,
            bridgeAmount,
            commonPayload as any,
            revertInstructions,
            gasAmount,
            fundsSignatureData,
        )
        .accounts({
            config: configPda,
            vault: vaultPda,
            user: userKeypair.publicKey,
            tokenWhitelist: whitelistPda,
            userTokenAccount: userKeypair.publicKey,
            gatewayTokenAccount: vaultPda,
            priceUpdate: PRICE_ACCOUNT,
            bridgeToken: PublicKey.default,
            tokenProgram: spl.TOKEN_PROGRAM_ID,
            systemProgram: SystemProgram.programId,
        })
        .rpc();

    console.log(`   tx: ${fundsTx}`);
}

main().catch((err) => {
    console.error("Script failed:", err);
    process.exit(1);
});

