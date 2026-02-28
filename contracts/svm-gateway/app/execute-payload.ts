import { PublicKey, TransactionInstruction } from "@solana/web3.js";

export interface GatewayAccountMeta {
    pubkey: PublicKey;
    isWritable: boolean;
}

/**
 * execution-specific data:
 * - targetProgram: Canonical destination program (source of truth) - REQUIRED
 * - accounts: Required for CPI execution
 * - ixData: Required for target program execution
 * - rentFee: Solana-specific, not in Push Chain event
 */
export interface ExecutePayloadFields {
    targetProgram: PublicKey; // REQUIRED - canonical destination (source of truth)
    accounts: GatewayAccountMeta[];
    ixData: Uint8Array;
    rentFee: bigint;
    instructionId: number; // NEW (u8)
  }
  

const SENDER_LEN = 20;

/**
 * Encode optimized execute payload
 *
 * Format (new - with targetProgram):
 * [accounts_count: 4 bytes (u32 BE)]
 * [account[0].pubkey: 32 bytes]
 * [account[0].is_writable: 1 byte]
 * ... (repeat for all accounts)
 * [ix_data_length: 4 bytes (u32 BE)]
 * [ix_data: N bytes]
 * [rent_fee: 8 bytes (u64 BE)]
 * [instruction_id: 1 byte (u8)]
 * [target_program: 32 bytes] ← REQUIRED: Canonical destination
 * Total size (new): 4 + (33 * accounts_count) + 4 + ix_data_length + 8 + 1 + 32
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
    const instructionIdBuf = Buffer.from([payload.instructionId ?? 2]);

    return Buffer.concat([
        accountsLen,                      // accounts_count (4 bytes)
        ...accountBuffers,                // accounts (33 bytes each)
        ixLen,                            // ix_data_length (4 bytes)
        Buffer.from(payload.ixData),      // ix_data (variable)
        rentFeeBuf,                       // rent_fee (8 bytes)
        instructionIdBuf,                 // instruction_id (1 byte)
        payload.targetProgram.toBuffer(), // target_program (32 bytes) - REQUIRED
    ]);
}

/**
 * Decode optimized execute payload
 *
 * Format (all fields required):
 * [accounts_count: 4 bytes (u32 BE)]
 * [account[i].pubkey: 32 bytes] [account[i].is_writable: 1 byte] (for each account)
 * [ix_data_length: 4 bytes (u32 BE)]
 * [ix_data: N bytes]
 * [rent_fee: 8 bytes (u64 BE)]
 * [instruction_id: 1 byte (u8)]
 * [target_program: 32 bytes] ← REQUIRED - canonical destination
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

    const instructionId = buf.readUInt8(offset);
    offset += 1;

    // Decode targetProgram (REQUIRED - 32 bytes)
    const remainingBytes = buf.length - offset;
    if (remainingBytes !== 32) {
        throw new Error(
            `Payload decode error: expected 32 bytes for targetProgram, ` +
            `but found ${remainingBytes} bytes (offset: ${offset}, buffer length: ${buf.length})`
        );
    }

    let targetProgram: PublicKey;
    try {
        targetProgram = new PublicKey(buf.slice(offset, offset + 32));
        offset += 32;
    } catch (err) {
        throw new Error(`Payload decode error: invalid targetProgram pubkey at offset ${offset}: ${err}`);
    }

    // Validate we consumed all bytes
    if (offset !== buf.length) {
        throw new Error(`Payload decode error: consumed ${offset} bytes but buffer has ${buf.length} bytes`);
    }

    return {
        targetProgram,
        accounts,
        ixData: new Uint8Array(ixData),
        rentFee,
        instructionId
    };
}

/**
 * Helper to convert accounts to writable flags for Solana transaction
 * This is used by the backend to prepare parameters for execute function
 * Bitpacked approach: writable flags as bitpacked Vec<u8> (1 bit per account, MSB first)
 * Accounts are mapped by position: remaining_accounts[i] maps to bit i in writable_flags
 */
export function accountsToWritableFlags(accounts: GatewayAccountMeta[]): Buffer {
    // Bitpack writable flags (MSB first)
    const writableBitsetLen = Math.ceil(accounts.length / 8);
    const writableFlags = Buffer.alloc(writableBitsetLen, 0);
    for (let i = 0; i < accounts.length; i++) {
        if (accounts[i].isWritable) {
            const byteIdx = Math.floor(i / 8);
            const bitIdx = 7 - (i % 8); // MSB first
            writableFlags[byteIdx] |= (1 << bitIdx);
        }
    }
    return writableFlags;
}

/**
 * Helper to build payload fields from a Solana instruction
 */
export interface InstructionBuildParams {
    instruction: TransactionInstruction;
    targetProgram: PublicKey; // REQUIRED - canonical destination program (source of truth)
    rentFee?: bigint; // Optional: rentFee to include in payload (Solana-specific)
    instructionId?: number;
}

export function instructionToPayloadFields(params: InstructionBuildParams): ExecutePayloadFields {
    const accounts: GatewayAccountMeta[] = params.instruction.keys.map((key) => ({
        pubkey: key.pubkey,
        isWritable: key.isWritable,
    }));

    return {
        targetProgram: params.targetProgram, // REQUIRED - canonical destination
        accounts,
        ixData: params.instruction.data,
        rentFee: params.rentFee ?? BigInt(0), // Default to 0 if not provided
        instructionId: params.instructionId ?? 2,
    };
}
