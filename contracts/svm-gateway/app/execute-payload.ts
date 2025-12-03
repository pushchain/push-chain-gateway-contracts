import { PublicKey, TransactionInstruction } from "@solana/web3.js";

export interface GatewayAccountMeta {
    pubkey: PublicKey;
    isWritable: boolean;
}

export interface ExecutePayloadFields {
    instructionId: number;
    chainId: string;
    nonce: number;
    amount: bigint;
    txId: Uint8Array; // 32 bytes
    targetProgram: PublicKey;
    sender: Uint8Array; // 20 bytes
    accounts: GatewayAccountMeta[];
    ixData: Uint8Array;
}

const TX_ID_LEN = 32;
const SENDER_LEN = 20;

export function encodeExecutePayload(payload: ExecutePayloadFields): Buffer {
    if (payload.txId.length !== TX_ID_LEN) {
        throw new Error(`txId must be ${TX_ID_LEN} bytes`);
    }
    if (payload.sender.length !== SENDER_LEN) {
        throw new Error(`sender must be ${SENDER_LEN} bytes`);
    }

    const chainBytes = Buffer.from(payload.chainId, "utf8");
    const chainLen = Buffer.alloc(4);
    chainLen.writeUInt32BE(chainBytes.length, 0);

    const nonceBuf = Buffer.alloc(8);
    nonceBuf.writeBigUInt64BE(BigInt(payload.nonce), 0);

    const amountBuf = Buffer.alloc(8);
    amountBuf.writeBigUInt64BE(payload.amount, 0);

    const accountsLen = Buffer.alloc(4);
    accountsLen.writeUInt32BE(payload.accounts.length, 0);
    const accountBuffers = payload.accounts.map((meta) =>
        Buffer.concat([meta.pubkey.toBuffer(), Buffer.from([meta.isWritable ? 1 : 0])]),
    );

    const ixLen = Buffer.alloc(4);
    ixLen.writeUInt32BE(payload.ixData.length, 0);

    return Buffer.concat([
        Buffer.from([payload.instructionId]),
        chainLen,
        chainBytes,
        nonceBuf,
        amountBuf,
        Buffer.from(payload.txId),
        payload.targetProgram.toBuffer(),
        Buffer.from(payload.sender),
        accountsLen,
        ...accountBuffers,
        ixLen,
        Buffer.from(payload.ixData),
    ]);
}

export function decodeExecutePayload(buf: Buffer): ExecutePayloadFields {
    let offset = 0;

    const instructionId = buf.readUInt8(offset);
    offset += 1;

    const chainLen = buf.readUInt32BE(offset);
    offset += 4;
    const chainId = buf.slice(offset, offset + chainLen).toString("utf8");
    offset += chainLen;

    const nonce = Number(buf.readBigUInt64BE(offset));
    offset += 8;

    const amount = buf.readBigUInt64BE(offset);
    offset += 8;

    const txId = buf.slice(offset, offset + TX_ID_LEN);
    offset += TX_ID_LEN;

    const targetProgram = new PublicKey(buf.slice(offset, offset + 32));
    offset += 32;

    const sender = buf.slice(offset, offset + SENDER_LEN);
    offset += SENDER_LEN;

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

    const ixDataLen = buf.readUInt32BE(offset);
    offset += 4;
    const ixData = buf.slice(offset, offset + ixDataLen);

    return {
        instructionId,
        chainId,
        nonce,
        amount: BigInt(amount.toString()),
        txId: new Uint8Array(txId),
        targetProgram,
        sender: new Uint8Array(sender),
        accounts,
        ixData: new Uint8Array(ixData),
    };
}

export interface InstructionBuildParams {
    instruction: TransactionInstruction;
    instructionId: number;
    chainId: string;
    nonce: number;
    amount: bigint;
    txId: Uint8Array;
    sender: Uint8Array;
}

export function instructionToPayloadFields(params: InstructionBuildParams): ExecutePayloadFields {
    const accounts: GatewayAccountMeta[] = params.instruction.keys.map((key) => ({
        pubkey: key.pubkey,
        isWritable: key.isWritable,
    }));

    return {
        instructionId: params.instructionId,
        chainId: params.chainId,
        nonce: params.nonce,
        amount: params.amount,
        txId: params.txId,
        targetProgram: params.instruction.programId,
        sender: params.sender,
        accounts,
        ixData: params.instruction.data,
    };
}

