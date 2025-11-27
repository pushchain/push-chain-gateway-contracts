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

// Default to Devnet cluster pubkey if not specified
export const TSS_CHAIN_ID = process.env.TSS_CHAIN_ID ?? "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG";

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
    chainId?: string; // Use chain_id from TSS account (Solana cluster pubkey string), fallback to TSS_CHAIN_ID
    txId?: Uint8Array; // Transaction ID (32 bytes) - required for withdraw/revert
    originCaller?: Uint8Array; // Origin caller EVM address (20 bytes) - required for withdraw only
}

export async function signTssMessage({ instruction, nonce, amount, additional, chainId, txId, originCaller }: SignParams): Promise<TssSignature> {
    // Build message EXACTLY like Rust program
    // Use chain_id from TSS account (Solana cluster pubkey string) or fallback to TSS_CHAIN_ID
    const chainIdToUse = chainId ?? TSS_CHAIN_ID;
    const PREFIX = Buffer.from("PUSH_CHAIN_SVM");
    const instructionId = Buffer.from([instruction]);
    const chainIdBytes = Buffer.from(chainIdToUse, 'utf8'); // UTF-8 bytes of cluster pubkey string
    const nonceBE = Buffer.alloc(8);
    nonceBE.writeBigUInt64BE(BigInt(nonce));

    const segments: Buffer[] = [PREFIX, instructionId, chainIdBytes, nonceBE];

    if (typeof amount === "bigint") {
        const amountBE = Buffer.alloc(8);
        amountBE.writeBigUInt64BE(amount);
        segments.push(amountBE);
    }

    // For withdraw functions: include tx_id and origin_caller
    // For revert functions: include tx_id only
    if (txId) {
        segments.push(Buffer.from(txId));
    }
    if (originCaller && (instruction === TssInstruction.WithdrawSol || instruction === TssInstruction.WithdrawSpl)) {
        segments.push(Buffer.from(originCaller));
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