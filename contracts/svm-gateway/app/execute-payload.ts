import { PublicKey, TransactionInstruction } from "@solana/web3.js";

export interface GatewayAccountMeta {
    pubkey: PublicKey;
    isWritable: boolean;
}

/**
 * execution-specific data:
 * - accounts: Required for CPI execution
 * - ixData: Required for target program execution
 * - rentFee: Solana-specific, not in Push Chain event
 */
export interface ExecutePayloadFields {
    accounts: GatewayAccountMeta[];
    ixData: Uint8Array;
    rentFee: bigint; // Rent fee (u64, 8 bytes) - Solana-specific, not in Push Chain event
}

const TX_ID_LEN = 32;
const SENDER_LEN = 20;

/**
 * Encode optimized execute payload
 * 
 * Format:
 * [accounts_count: 4 bytes (u32 BE)]
 * [account[0].pubkey: 32 bytes]
 * [account[0].is_writable: 1 byte]
 * ... (repeat for all accounts)
 * [ix_data_length: 4 bytes (u32 BE)]
 * [ix_data: N bytes]
 * [rent_fee: 8 bytes (u64 BE)]
 * 
 * Total size: 4 + (33 * accounts_count) + 4 + ix_data_length + 8
 * 
 * Note: Payload still contains full accounts (for Push Chain and backend).
 * Indices are used only in the Solana transaction (not in payload).
 */
export function encodeExecutePayload(payload: ExecutePayloadFields): Buffer {
    // Encode accounts
    const accountsLen = Buffer.alloc(4);
    accountsLen.writeUInt32BE(payload.accounts.length, 0);
    const accountBuffers = payload.accounts.map((meta) =>
        Buffer.concat([meta.pubkey.toBuffer(), Buffer.from([meta.isWritable ? 1 : 0])]),
    );

    // Encode ix_data
    const ixLen = Buffer.alloc(4);
    ixLen.writeUInt32BE(payload.ixData.length, 0);

    // Encode rentFee (u64 BE, 8 bytes)
    const rentFeeBuf = Buffer.alloc(8);
    rentFeeBuf.writeBigUInt64BE(payload.rentFee ?? BigInt(0), 0);

    return Buffer.concat([
        accountsLen,              // accounts_count (4 bytes)
        ...accountBuffers,        // accounts (33 bytes each)
        ixLen,                    // ix_data_length (4 bytes)
        Buffer.from(payload.ixData), // ix_data (variable)
        rentFeeBuf,               // rent_fee (8 bytes)
    ]);
}

/**
 * Decode optimized execute payload
 * 
 * Format:
 * [accounts_count: 4 bytes (u32 BE)]
 * [account[0].pubkey: 32 bytes]
 * [account[0].is_writable: 1 byte]
 * ... (repeat for all accounts)
 * [ix_data_length: 4 bytes (u32 BE)]
 * [ix_data: N bytes]
 * [rent_fee: 8 bytes (u64 BE)]
 */
export function decodeExecutePayload(buf: Buffer): ExecutePayloadFields {
    let offset = 0;

    // Decode accounts
    const accountsLen = buf.readUInt32BE(offset);
    offset += 4;

    const accounts: GatewayAccountMeta[] = [];
    for (let i = 0; i < accountsLen; i++) {
        const pubkey = new PublicKey(buf.slice(offset, offset + 32));
        offset += 32;
        const isWritable = buf.readUInt8(offset) === 1;
        offset += 1;
        accounts.push({ pubkey, isWritable });
    }

    // Decode ix_data
    const ixDataLen = buf.readUInt32BE(offset);
    offset += 4;
    const ixData = buf.slice(offset, offset + ixDataLen);
    offset += ixDataLen;

    // Decode rentFee (u64 BE, 8 bytes)
    const rentFee = buf.readBigUInt64BE(offset);
    offset += 8;

    // Validate we consumed all bytes
    if (offset !== buf.length) {
        throw new Error(`Payload decode error: consumed ${offset} bytes but buffer has ${buf.length} bytes`);
    }

    return {
        accounts,
        ixData: new Uint8Array(ixData),
        rentFee,
    };
}

/**
 * Helper to convert accounts to indices and writable flags for Solana transaction
 * This is used by the backend to prepare parameters for execute function
 * Bitpacked approach: indices as Vec<u8>, writable flags as bitpacked Vec<u8> (1 bit per account, MSB first)
 */
export function accountsToIndicesAndFlags(accounts: GatewayAccountMeta[]): {
    indices: Buffer;
    writableFlags: Buffer;
} {
    // Sequential indices (0, 1, 2, ...) as Buffer
    const indices = Buffer.from(accounts.map((_, i) => i));

    // Bitpack writable flags
    const writableBitsetLen = Math.ceil(accounts.length / 8);
    const writableFlags = Buffer.alloc(writableBitsetLen, 0);
    for (let i = 0; i < accounts.length; i++) {
        if (accounts[i].isWritable) {
            const byteIdx = Math.floor(i / 8);
            const bitIdx = 7 - (i % 8); // MSB first
            writableFlags[byteIdx] |= (1 << bitIdx);
        }
    }

    return { indices, writableFlags };
}

/**
 * Helper to build payload fields from a Solana instruction
 */
export interface InstructionBuildParams {
    instruction: TransactionInstruction;
    rentFee?: bigint; // Optional: rentFee to include in payload (Solana-specific)
}

export function instructionToPayloadFields(params: InstructionBuildParams): ExecutePayloadFields {
    const accounts: GatewayAccountMeta[] = params.instruction.keys.map((key) => ({
        pubkey: key.pubkey,
        isWritable: key.isWritable,
    }));

    return {
        accounts,
        ixData: params.instruction.data,
        rentFee: params.rentFee ?? BigInt(0), // Default to 0 if not provided
    };
}

