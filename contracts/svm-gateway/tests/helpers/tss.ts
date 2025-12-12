import * as anchor from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import pkg from "js-sha3";
const { keccak_256 } = pkg;
import * as secp from "@noble/secp256k1";

export enum TssInstruction {
    WithdrawSol = 1,
    WithdrawSpl = 2,
    RevertWithdrawSol = 3,
    RevertWithdrawSpl = 4,
}

export const TSS_CHAIN_ID = Number(process.env.TSS_CHAIN_ID ?? "1");

function getTssPrivateKey(): string {
    const priv = (process.env.TSS_PRIVKEY || process.env.ETH_PRIVATE_KEY || process.env.PRIVATE_KEY || "f1c05d6c46a4a2b06c4d679f7f6ed15c93dffa50e1399c049b58289f6a1e33ad").replace(/^0x/, "");
    return priv;
}

// Compute ETH address from private key
const privateKeyHex = getTssPrivateKey();
const PRIVATE_KEY = Buffer.from(privateKeyHex, "hex");
const PUBLIC_KEY = secp.getPublicKey(PRIVATE_KEY, false).slice(1); // remove 0x04 prefix
const ETH_ADDRESS_HEX = keccak_256(PUBLIC_KEY).slice(-40);
const ETH_ADDRESS_BYTES = Buffer.from(ETH_ADDRESS_HEX, "hex");

export function getTssEthAddress(): number[] {
    return Array.from(ETH_ADDRESS_BYTES);
}

export interface TssSignature {
    signature: number[];
    recoveryId: number;
    messageHash: number[];
    nonce: anchor.BN;
}

interface SignParams {
    instruction: TssInstruction;
    nonce: number;
    amount?: bigint;
    additional: Uint8Array[];
    chainId?: number; // Use chain_id from TSS account, fallback to TSS_CHAIN_ID
}

export async function signTssMessage({ instruction, nonce, amount, additional, chainId }: SignParams): Promise<TssSignature> {
    // Build message EXACTLY like gateway-test.ts
    // Use chain_id from TSS account (like Rust does) or fallback to TSS_CHAIN_ID
    const chainIdToUse = chainId ?? TSS_CHAIN_ID;
    const PREFIX = Buffer.from("PUSH_CHAIN_SVM");
    const instructionId = Buffer.from([instruction]);
    const chainIdBE = Buffer.alloc(8);
    chainIdBE.writeBigUInt64BE(BigInt(chainIdToUse));
    const nonceBE = Buffer.alloc(8);
    nonceBE.writeBigUInt64BE(BigInt(nonce));

    const segments: Buffer[] = [PREFIX, instructionId, chainIdBE, nonceBE];

    if (typeof amount === "bigint") {
        const amountBE = Buffer.alloc(8);
        amountBE.writeBigUInt64BE(amount);
        segments.push(amountBE);
    }

    additional.forEach((item) => {
        segments.push(Buffer.from(item));
    });

    const concat = Buffer.concat(segments);
    const messageHashHex = keccak_256(concat);
    const messageHash = Buffer.from(messageHashHex, "hex");


    // Sign EXACTLY like gateway-test.ts
    const priv = privateKeyHex;
    const sig = await secp.sign(messageHash, priv, { recovered: true, der: false });
    const signature: Uint8Array = sig[0];
    let recoveryId: number = sig[1]; // 0 or 1

    return {
        signature: Array.from(signature),
        recoveryId,
        messageHash: Array.from(messageHash),
        nonce: new anchor.BN(nonce),
    };
}

export function pubkeyToBytes(pubkey: PublicKey): Uint8Array {
    return pubkey.toBuffer();
}