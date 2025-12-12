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
        if (!tx) {
            console.log(`${label}: Transaction not found. Check if signature is correct and network matches.`);
            return;
        }
        if (!tx.meta || !tx.meta.logMessages) {
            console.log(`${label}: No logs found in transaction`);
            return;
        }
        if (tx.meta.err) {
            console.log(`${label}: Transaction failed with error:`, tx.meta.err);
            return;
        }
        const dataLogs = tx.meta.logMessages.filter(l => l.startsWith("Program data: "));
        if (dataLogs.length === 0) {
            console.log(`${label}: No Anchor event logs in tx`);
            return;
        }

        // Debug: Show all program logs and try to manually decode UniversalTx
        console.log(`${label}: Found ${dataLogs.length} event log(s)`);
        const UNIVERSAL_TX_DISCRIMINATOR = Buffer.from([0x6c, 0x9a, 0xd8, 0x29, 0xb5, 0xea, 0x1d, 0x7c]); // From the output
        dataLogs.forEach((log, idx) => {
            const b64 = log.replace("Program data: ", "");
            const buf = Buffer.from(b64, "base64");
            const disc = buf.slice(0, 8);
            const isUniversalTx = disc.equals(UNIVERSAL_TX_DISCRIMINATOR);
            console.log(`  [${idx}] discriminator=${disc.toString('hex')} data_len=${buf.length - 8} ${isUniversalTx ? '(UniversalTx)' : ''}`);
            if (isUniversalTx) {
                // Try to manually parse the event to see payload
                const eventData = buf.slice(8);
                console.log(`    Raw event data (first 100 bytes): ${eventData.slice(0, 100).toString('hex')}`);
            }
        });

        function readU64LE(buf, off) {
            if (off + 8 > buf.length) throw new Error(`Buffer overflow: trying to read u64 at offset ${off}, buffer length ${buf.length}`);
            return Number(buf.readBigUInt64LE(off));
        }
        function readI64LE(buf, off) {
            if (off + 8 > buf.length) throw new Error(`Buffer overflow: trying to read i64 at offset ${off}, buffer length ${buf.length}`);
            return Number(buf.readBigInt64LE(off));
        }
        function readVecU8(buf, off) {
            if (off + 4 > buf.length) throw new Error(`Buffer overflow: trying to read vec length at offset ${off}, buffer length ${buf.length}`);
            const len = buf.readUInt32LE(off);
            const start = off + 4;
            const end = start + len;
            if (end > buf.length) throw new Error(`Buffer overflow: trying to read vec of length ${len} at offset ${start}, buffer length ${buf.length}`);
            return { bytes: buf.slice(start, end), next: end };
        }
        function decodeVerificationType(buf, off) {
            if (off >= buf.length) throw new Error(`Buffer overflow: trying to read u8 at offset ${off}, buffer length ${buf.length}`);
            const d = buf.readUInt8(off);
            if (d === 0) return { value: "SignedVerification", next: off + 1 };
            if (d === 1) return { value: "UniversalTxVerification", next: off + 1 };
            return { value: "Unknown", next: off + 1 };
        }
        function decodeUniversalPayload(buf) {
            try {
                let off = 0;
                if (buf.length < 20) throw new Error(`Buffer too small for 'to' field: ${buf.length} bytes`);
                const to = buf.slice(off, off + 20);
                off += 20;

                const value = readU64LE(buf, off);
                off += 8;

                const dataRes = readVecU8(buf, off);
                const data = dataRes.bytes;
                off = dataRes.next;

                const gasLimit = readU64LE(buf, off);
                off += 8;

                const maxFeePerGas = readU64LE(buf, off);
                off += 8;

                const maxPriorityFeePerGas = readU64LE(buf, off);
                off += 8;

                const nonce = readU64LE(buf, off);
                off += 8;

                const deadline = readI64LE(buf, off);
                off += 8;

                const vTypeRes = decodeVerificationType(buf, off);
                const vType = vTypeRes.value;
                off = vTypeRes.next;

                return {
                    to: "0x" + to.toString("hex"),
                    value,
                    data: "0x" + data.toString("hex"),
                    gasLimit,
                    maxFeePerGas,
                    maxPriorityFeePerGas,
                    nonce,
                    deadline,
                    vType
                };
            } catch (err) {
                console.error(`Error decoding payload (buffer length: ${buf.length}):`, err.message);
                throw err;
            }
        }

        const decoded = [];
        for (const log of dataLogs) {
            const b64 = log.replace("Program data: ", "");
            const ev = coder.decode(b64);
            if (ev) decoded.push(ev);
        }

        // Find ALL UniversalTx events (there might be multiple)
        const uniEvents = decoded.filter(e => e && e.name === "UniversalTx");
        if (uniEvents.length === 0) {
            console.log(`${label}: UniversalTx event not found. Events found:`, decoded.map(d => d ? d.name : 'null'));
            return;
        }

        console.log(`${label}: Found ${uniEvents.length} UniversalTx event(s), processing the one with payload...`);

        // Find the event with a non-empty payload
        let uni = uniEvents.find(e => e.data.payload && (Array.isArray(e.data.payload) ? e.data.payload.length > 0 : Buffer.isBuffer(e.data.payload) ? e.data.payload.length > 0 : true));
        if (!uni) {
            // If none have payload, use the largest one (likely has the payload)
            uni = uniEvents.reduce((prev, curr) => {
                const prevSize = prev.data.payload ? (Array.isArray(prev.data.payload) ? prev.data.payload.length : Buffer.isBuffer(prev.data.payload) ? prev.data.payload.length : 0) : 0;
                const currSize = curr.data.payload ? (Array.isArray(curr.data.payload) ? curr.data.payload.length : Buffer.isBuffer(curr.data.payload) ? curr.data.payload.length : 0) : 0;
                return currSize > prevSize ? curr : prev;
            });
        }

        const e = uni.data;
        console.log(`${label}: Found UniversalTx event`);
        console.log(`  - sender: ${e.sender}`);
        console.log(`  - recipient: 0x${Buffer.from(e.recipient).toString('hex')}`);
        console.log(`  - token: ${e.token}`);
        console.log(`  - amount: ${e.amount}`);

        // Try both snake_case and camelCase for tx_type
        const txType = e.tx_type !== undefined ? e.tx_type : e.txType;
        if (txType !== undefined) {
            // Anchor deserializes enums as objects: { gas: {} }, { gasAndPayload: {} }, etc.
            let txTypeName = 'Unknown';
            if (typeof txType === 'object' && txType !== null) {
                // Get the first key (enum variant name)
                const keys = Object.keys(txType);
                if (keys.length > 0) {
                    // Convert camelCase to PascalCase for display
                    const variant = keys[0];
                    txTypeName = variant.charAt(0).toUpperCase() + variant.slice(1);
                }
            } else if (typeof txType === 'number') {
                // Fallback: if it's a number, map it
                const txTypeNames = ['Gas', 'GasAndPayload', 'Funds', 'FundsAndPayload'];
                txTypeName = txTypeNames[txType] || `Unknown(${txType})`;
            } else {
                txTypeName = String(txType);
            }
            console.log(`  - tx_type: ${txTypeName}`);
        } else {
            console.log(`  - tx_type: undefined (field not found in event data)`);
            console.log(`  - Available fields: ${Object.keys(e).join(', ')}`);
        }

        // Handle payload - it might be an array, buffer, or already deserialized
        let payloadBytes;
        if (Array.isArray(e.payload)) {
            payloadBytes = Buffer.from(e.payload);
        } else if (Buffer.isBuffer(e.payload)) {
            payloadBytes = e.payload;
        } else if (e.payload && typeof e.payload === 'object' && e.payload.data) {
            // Anchor might have already deserialized it
            payloadBytes = Buffer.from(e.payload.data);
        } else {
            payloadBytes = Buffer.from(e.payload || []);
        }

        console.log(`  - payload length: ${payloadBytes.length} bytes`);
        console.log(`  - payload (hex): ${payloadBytes.length > 0 ? payloadBytes.toString('hex').substring(0, 100) + '...' : 'empty'}`);

        if (payloadBytes.length === 0) {
            console.log(`${label}: No payload in event (empty payload)`);
            console.log(`  This might be a GAS-only route (TxType::Gas) or payload was not included.`);
            return;
        }

        // Check if payload is JSON (starts with '{') or Borsh
        const isJson = payloadBytes[0] === 0x7b; // '{' in ASCII
        if (isJson) {
            console.log(`  - Payload appears to be JSON (not Borsh). This is incorrect - should use Borsh serialization.`);
            try {
                const jsonPayload = JSON.parse(payloadBytes.toString('utf8'));
                console.log(`\n${label}: (JSON Payload - INCORRECT FORMAT):`);
                console.log(JSON.stringify({ payload: jsonPayload }, null, 2));
                console.log(`\n⚠️  WARNING: Payload is JSON but should be Borsh-serialized UniversalPayload!`);
                return;
            } catch (err) {
                console.log(`  - Failed to parse as JSON: ${err.message}`);
            }
        }

        console.log(`  - Attempting to decode payload as Borsh (${payloadBytes.length} bytes)...`);
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
    console.log("Usage: node app/decode-tx.js <transaction_signature> [signature2] ...");
    console.log("\nExample:");
    console.log("  node app/decode-tx.js xuV3B2KRBdUSPrP76uLp7dDPXjf4seiyW9Dqq5WARGghJUhvVirJqyYeUmJz8PaAFUhjaJhcp6wzzoNzCTLNnHW");
    console.log("\nThis script decodes UniversalTx events from Solana transactions.");
    process.exit(1);
} else {
    (async () => {
        for (const sig of sigs) {
            await decodeTx(sig, sig);
        }
    })();
}

