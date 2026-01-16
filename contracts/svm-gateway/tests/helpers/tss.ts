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
    ExecuteSol = 5,
    ExecuteSpl = 6,
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
    universalTxId?: Uint8Array; // Universal Transaction ID (32 bytes) - required for withdraw/revert/execute
    txId?: Uint8Array; // Transaction ID (32 bytes) - required for withdraw/revert
    originCaller?: Uint8Array; // Origin caller EVM address (20 bytes) - required for withdraw only
}

export async function signTssMessage({ instruction, nonce, amount, additional, chainId, universalTxId, txId, originCaller }: SignParams): Promise<TssSignature> {
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

    // For withdraw/revert functions: include universal_tx_id, tx_id, and origin_caller (withdraw only)
    // Order MUST match Rust: universal_tx_id BEFORE tx_id and origin_caller
    if (universalTxId) {
        segments.push(Buffer.from(universalTxId));
    }
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

/**
 * Generate a universal transaction ID (32 bytes) for testing
 * In production, this comes from the source chain (EVM/Push Chain)
 */
export function generateUniversalTxId(): Uint8Array {
    return Buffer.from(Array.from({ length: 32 }, () => Math.floor(Math.random() * 256)));
}

// =========================
// EXECUTE MESSAGE HELPERS
// =========================

export interface GatewayAccountMeta {
    pubkey: PublicKey;
    isWritable: boolean;
}

/**
 * Build execute message additional_data buffers (accounts and ix_data with length prefixes)
 * SECURITY CRITICAL: Accounts passed here MUST exactly match accounts in remaining_accounts.
 * - Same order (as passed to .remainingAccounts())
 * - Same pubkeys
 * - Same isWritable flags
 * Matches Rust execute.rs lines 110-117
 */
export function buildExecuteAdditionalData(
    universalTxId: Uint8Array,
    txId: Uint8Array,
    targetProgram: PublicKey,
    sender: Uint8Array,
    accounts: GatewayAccountMeta[],
    ixData: Uint8Array,
    gasFee: bigint = BigInt(0),
    rentFee: bigint = BigInt(0)
): Uint8Array[] {
    // Build accounts buffer with length prefix (u32 BE) - matches Rust line 113-117
    // Format: [u32 BE: count] + [32 bytes: pubkey, 1 byte: is_writable] * count
    const accountsCount = Buffer.alloc(4);
    accountsCount.writeUInt32BE(accounts.length, 0);
    const accountsBuf = Buffer.concat([
        accountsCount,
        ...accounts.map(acc => Buffer.concat([
            acc.pubkey.toBuffer(),
            Buffer.from([acc.isWritable ? 1 : 0])
        ]))
    ]);

    // Build ix_data buffer with length prefix (u32 BE) - matches Rust line 101-104
    const ixDataLength = Buffer.alloc(4);
    ixDataLength.writeUInt32BE(ixData.length, 0);
    const ixDataBuf = Buffer.concat([ixDataLength, Buffer.from(ixData)]);

    // Build gas_fee and rent_fee buffers (u64 BE)
    // Ensure BigInt conversion with safe defaults
    const gasFeeBigInt = (gasFee !== undefined && gasFee !== null)
        ? (typeof gasFee === 'bigint' ? gasFee : BigInt(gasFee))
        : BigInt(0);
    const rentFeeBigInt = (rentFee !== undefined && rentFee !== null)
        ? (typeof rentFee === 'bigint' ? rentFee : BigInt(rentFee))
        : BigInt(0);
    const gasFeeBuf = Buffer.alloc(8);
    gasFeeBuf.writeBigUInt64BE(gasFeeBigInt, 0);
    const rentFeeBuf = Buffer.alloc(8);
    rentFeeBuf.writeBigUInt64BE(rentFeeBigInt, 0);

    // Matches Rust execute.rs: [universal_tx_id, tx_id, target_program, sender, accounts_buf, ix_data_buf, gas_fee, rent_fee]
    return [
        universalTxId,           // universal_tx_id (32 bytes)
        txId,                    // tx_id (32 bytes)
        targetProgram.toBuffer(), // target_program (32 bytes)
        sender,                  // sender (20 bytes)
        accountsBuf,              // accounts with length prefix
        ixDataBuf,               // ix_data with length prefix
        gasFeeBuf,               // gas_fee (8 bytes, u64 BE)
        rentFeeBuf,              // rent_fee (8 bytes, u64 BE)
    ];
}