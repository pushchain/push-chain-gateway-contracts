#!/usr/bin/env ts-node

import {
    AddressLookupTableProgram,
    Connection,
    Keypair,
    PublicKey,
    SystemProgram,
    Transaction,
} from "@solana/web3.js";
import fs from "fs";
import * as spl from "@solana/spl-token";

// This script:
// 1) Creates an Address Lookup Table (ALT) owned by the upgrade/admin key.
// 2) Extends it with the static accounts used by send_universal_tx so that
//    user transactions can spend more of the 1232‑byte budget on instruction
//    data (payload / revertInstruction / signatureData).
//
// It writes the created ALT address to ./universal-alt.json so other scripts
// (like the ALT send_universal_tx test) can load and use it.

const PROGRAM_ID = new PublicKey("CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS");
const CONFIG_SEED = "config";
const VAULT_SEED = "vault";
const RATE_LIMIT_CONFIG_SEED = "rate_limit_config";
const PRICE_ACCOUNT = new PublicKey("7UVimffxr9ow1uXYxsr4LHAcV58mLzhmwaeKvJ1pjLiE"); // Pyth SOL/USD

function loadKeypair(path: string): Keypair {
    const secret = JSON.parse(fs.readFileSync(path, "utf8"));
    return Keypair.fromSecretKey(Uint8Array.from(secret));
}

async function main() {
    const adminKeypair = loadKeypair("./upgrade-keypair.json");

    const connection = new Connection("https://api.devnet.solana.com", "confirmed");

    console.log("Admin:", adminKeypair.publicKey.toBase58());

    // Derive PDAs we want to pack into the ALT
    const [configPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(CONFIG_SEED)],
        PROGRAM_ID,
    );
    const [vaultPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(VAULT_SEED)],
        PROGRAM_ID,
    );
    const [rateLimitConfigPda] = PublicKey.findProgramAddressSync(
        [Buffer.from(RATE_LIMIT_CONFIG_SEED)],
        PROGRAM_ID,
    );

    console.log("Config PDA:", configPda.toBase58());
    console.log("Vault  PDA:", vaultPda.toBase58());
    console.log("RateLimitConfig PDA:", rateLimitConfigPda.toBase58());
    console.log("Price account:", PRICE_ACCOUNT.toBase58());

    // 1) Create the lookup table
    const slot = await connection.getSlot("finalized");
    const [createIx, altAddress] = AddressLookupTableProgram.createLookupTable({
        authority: adminKeypair.publicKey,
        payer: adminKeypair.publicKey,
        recentSlot: slot,
    });

    console.log("Creating ALT at address:", altAddress.toBase58());

    let tx = new Transaction().add(createIx);
    tx.feePayer = adminKeypair.publicKey;
    tx.recentBlockhash = (await connection.getLatestBlockhash()).blockhash;

    const createSig = await connection.sendTransaction(tx, [adminKeypair]);
    console.log(" ALT create tx:", createSig);
    await connection.confirmTransaction(createSig, "confirmed");

    // 2) Extend the table with static accounts used by send_universal_tx
    // We intentionally do NOT include token_rate_limit here to avoid having to
    // manage many per‑mint PDAs. We focus on global/static addresses instead.
    const addressesToAdd: PublicKey[] = [
        configPda,
        vaultPda,
        rateLimitConfigPda,
        PRICE_ACCOUNT,
        spl.TOKEN_PROGRAM_ID,
        SystemProgram.programId,
    ];

    const extendIx = AddressLookupTableProgram.extendLookupTable({
        payer: adminKeypair.publicKey,
        authority: adminKeypair.publicKey,
        lookupTable: altAddress,
        addresses: addressesToAdd,
    });

    tx = new Transaction().add(extendIx);
    tx.feePayer = adminKeypair.publicKey;
    tx.recentBlockhash = (await connection.getLatestBlockhash()).blockhash;

    const extendSig = await connection.sendTransaction(tx, [adminKeypair]);
    console.log(" ALT extend tx:", extendSig);
    await connection.confirmTransaction(extendSig, "confirmed");

    // Persist ALT address so the test script can load it.
    const out = {
        altAddress: altAddress.toBase58(),
        entries: addressesToAdd.map((a) => a.toBase58()),
    };
    fs.writeFileSync("./universal-alt.json", JSON.stringify(out, null, 2));
    console.log("Saved ALT metadata to ./universal-alt.json");

    console.log("\n✅ ALT created and extended successfully.");
}

main().catch((err) => {
    console.error("create-universal-alt failed:", err);
    process.exit(1);
});


