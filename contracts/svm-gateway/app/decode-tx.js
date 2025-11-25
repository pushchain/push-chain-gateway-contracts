const anchor = require("@coral-xyz/anchor");
const { Connection, PublicKey } = require("@solana/web3.js");
const fs = require("fs");

async function decodeTx(sig, label) {
    try {
        const PROGRAM_ID = new PublicKey("CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS");
        const connection = new Connection("https://api.devnet.solana.com", { commitment: "confirmed" });
        const idl = JSON.parse(fs.readFileSync("./target/idl/universal_gateway.json", "utf8"));
        const coder = new anchor.BorshEventCoder(idl);

        const tx = await connection.getTransaction(sig, { commitment: "confirmed", maxSupportedTransactionVersion: 0 });
        if (!tx || !tx.meta || !tx.meta.logMessages) {
            console.log(`${label}: No logs found`);
            return;
        }
        const dataLogs = tx.meta.logMessages.filter(l => l.startsWith("Program data: "));
        if (dataLogs.length === 0) {
            console.log(`${label}: No Anchor event logs in tx`);
            return;
        }

        function readU64LE(buf, off) { return Number(buf.readBigUInt64LE(off)); }
        function readI64LE(buf, off) { return Number(buf.readBigInt64LE(off)); }
        function readVecU8(buf, off) { const len = buf.readUInt32LE(off); const start = off + 4; const end = start + len; return { bytes: buf.slice(start, end), next: end }; }
        function decodeVerificationType(buf, off) { const d = buf.readUInt8(off); if (d === 0) return { value: "SignedVerification", next: off + 1 }; if (d === 1) return { value: "UniversalTxVerification", next: off + 1 }; return { value: "Unknown", next: off + 1 }; }
        function decodeUniversalPayload(buf) { let off = 0; const to = buf.slice(off, off + 20); off += 20; const value = readU64LE(buf, off); off += 8; const dataRes = readVecU8(buf, off); const data = dataRes.bytes; off = dataRes.next; const gasLimit = readU64LE(buf, off); off += 8; const maxFeePerGas = readU64LE(buf, off); off += 8; const maxPriorityFeePerGas = readU64LE(buf, off); off += 8; const nonce = readU64LE(buf, off); off += 8; const deadline = readI64LE(buf, off); off += 8; const vTypeRes = decodeVerificationType(buf, off); const vType = vTypeRes.value; off = vTypeRes.next; return { to: "0x" + to.toString("hex"), value, data: "0x" + data.toString("hex"), gasLimit, maxFeePerGas, maxPriorityFeePerGas, nonce, deadline, vType }; }

        const decoded = [];
        for (const log of dataLogs) {
            const b64 = log.replace("Program data: ", "");
            const ev = coder.decode(b64);
            if (ev) decoded.push(ev);
        }

        const uni = decoded.find(e => e && e.name === "UniversalTx");
        if (!uni) {
            console.log(`${label}: UniversalTx event not found. Events found:`, decoded.map(d => d.name));
            return;
        }

        const e = uni.data;
        const payloadBytes = Buffer.from(e.payload);
        const payload = decodeUniversalPayload(payloadBytes);

        console.log(`\n${label}:`);
        console.log(JSON.stringify({
            payload
        }, null, 2));
    } catch (err) {
        console.error(`${label} Error:`, err?.message || String(err));
    }
}

const [, , ...sigs] = process.argv;
if (sigs.length === 0) {
    (async () => {
        await decodeTx("FHWFkN7AEKFvLsXHfP5h67mFbcKgFeThDZnBVsJ23uBpruRxZ4R4tsnkKQhj3aht3oVs9Gr4NtF8yEKakEPh4tC", "Latest sendTxWithGas");
    })();
} else {
    (async () => {
        for (const sig of sigs) {
            await decodeTx(sig, sig);
        }
    })();
}

