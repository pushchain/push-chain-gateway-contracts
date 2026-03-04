/**
 * Push Chain → Solana: Outbound Transaction Initiator
 *
 * This script calls `sendUniversalTxOutbound` on UniversalGatewayPC (UGPC)
 * deployed on Push Chain. The UGPC burns the user's PRC20 tokens, emits
 * a `UniversalTxOutbound` event, and the TSS + relayer network finalizes
 * the transaction on the Solana side.
 *
 * ─── Cases covered ───────────────────────────────────────────────────────────
 *
 *   Case 1 – Withdraw SOL       amount > 0, token = PRC20(SOL), payload empty
 *   Case 2 – Withdraw SPL       amount > 0, token = PRC20 addr, payload empty
 *   Case 3 – Execute (SOL CPI)  amount = 0 or > 0, payload = encoded CPI ix
 *   Case 4 – CEA → UEA          amount = 0, target = gateway, payload = send_universal_tx_to_uea ix
 *
 * ─── Flow ────────────────────────────────────────────────────────────────────
 *
 *   User calls sendUniversalTxOutbound on Push Chain (this script)
 *       ↓
 *   UGPC burns PRC20 / charges gas fee, emits UniversalTxOutbound event
 *       ↓
 *   TSS committee signs, relayer submits finalizeUniversalTx on Solana
 *       ↓
 *   Solana gateway verifies sig, moves funds, emits UniversalTxFinalized
 *
 * ─── What to configure ───────────────────────────────────────────────────────
 *
 *   ETH_PRIVATE_KEY / PRIVATE_KEY  – signer on Push Chain (user or relayer)
 *   For SPL/execute you also need:
 *     - The PRC20 token address on Push Chain for the SPL mint
 *     - ERC20 approval for UGPC before calling (approve first)
 *
 * ─── Quick commands ──────────────────────────────────────────────────────────
 *
 *   Show help:
 *     npx ts-node app/push-chain-outbound.ts --help
 *
 *   Withdraw SOL to a Solana wallet:
 *     npx ts-node app/push-chain-outbound.ts withdraw-sol
 *
 *   Withdraw SPL token to a Solana wallet:
 *     npx ts-node app/push-chain-outbound.ts withdraw-spl
 *
 *   Execute a Solana CPI (current example: counter.increment(n)):
 *     npx ts-node app/push-chain-outbound.ts execute-sol
 *
 *   Trigger CEA → UEA self-call for SOL:
 *     npx ts-node app/push-chain-outbound.ts cea-to-uea-sol
 *
 *   Trigger CEA → UEA self-call for SPL:
 *     npx ts-node app/push-chain-outbound.ts cea-to-uea-spl
 *
 *   Run every case in sequence:
 *     npx ts-node app/push-chain-outbound.ts all
 *
 * ─── Important env vars ──────────────────────────────────────────────────────
 *
 *   WITHDRAW_SOL_AMOUNT            Amount for withdraw-sol (default "0.01", 9 decimals)
 *   WITHDRAW_SPL_AMOUNT            Amount for withdraw-spl (default "10", 6 decimals)
 *   EXECUTE_SOL_AMOUNT             Bridged amount for execute-sol (default "0.1", 9 decimals)
 *   EXECUTE_INCREMENT_BY           Counter increment for execute-sol (default "1")
 *   EXECUTE_RENT_FEE              Solana rent top-up inside execute payload (default "1500000")
 *   CEA_TO_UEA_SOL_AMOUNT          Amount drained from CEA on Solana (default "50000000")
 *   CEA_TO_UEA_SOL_TOPUP_AMOUNT    Extra amount burned on Push before CEA→UEA self-call (default "0")
 *   CEA_TO_UEA_SPL_AMOUNT          SPL amount drained from CEA ATA (default "10000000")
 *   CEA_TO_UEA_SPL_TOPUP_AMOUNT    Extra SPL amount burned on Push before CEA→UEA self-call (default "0")
 *   GAS_LIMIT                      Optional UGPC gasLimit override (default 0 = protocol base gas)
 *
 * ─── Calling via UEA (comment-only guide) ───────────────────────────────────
 *
 *   This script currently calls UGPC directly from the signer EOA:
 *     signer EOA -> UGPC.sendUniversalTxOutbound(req)
 *
 *   If you want the outbound to originate from a Push-side UEA instead:
 *     1. Fund the UEA with the required PRC20 balances.
 *     2. From the UEA, approve UGPC for:
 *          - gasFee
 *          - plus amount, if req.amount > 0
 *     3. From the UEA, execute a call to UGPC.sendUniversalTxOutbound(req).
 *
 *   In that model:
 *     - msg.sender at UGPC becomes the UEA contract
 *     - UniversalTxOutbound.sender becomes the UEA address
 *     - UGPC pulls fees/burns tokens from the UEA, not from the EOA
 *
 *   Minimal pseudo-flow:
 *     const ugpcCall = ugpc.interface.encodeFunctionData("sendUniversalTxOutbound", [req]);
 *     // First: UEA executes token.approve(UGPC, requiredAmount)
 *     // Then:  UEA executes { to: UGPC_ADDRESS, value: 0, data: ugpcCall }
 *
 *   This file does NOT implement the UEA wrapper path yet; this section is only
 *   here so SDK integrators understand how the same outbound request is routed
 *   when the caller is a UEA contract instead of a direct EOA.
 */

import * as dotenv from "dotenv";
dotenv.config({ path: "../.env" });
dotenv.config();

import { ethers, BigNumberish } from "ethers";
import { Keypair, PublicKey } from "@solana/web3.js";
import { encodeExecutePayload, GatewayAccountMeta } from "./execute-payload";
import { createHash } from "crypto";
import * as fs from "fs";
import * as path from "path";

// ═══════════════════════════════════════════════════════════════════════════════
// NETWORK CONFIG
// ═══════════════════════════════════════════════════════════════════════════════

const PUSH_CHAIN_RPC  = "https://evm.rpc-testnet-donut-node1.push.org";
const PUSH_CHAIN_ID   = 42101;
const UGPC_ADDRESS    = "0x00000000000000000000000000000000000000C1";
const DEFAULT_GATEWAY_PROGRAM_ID = "DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp";
const DEFAULT_COUNTER_PROGRAM_ID = "4mpHkerNsaJPp35fyT5bkoXxuEBczGq6HUKTtrzFcptx";
const DEFAULT_SOL_RECIPIENT = "2EEYH6e1PtCdWzZaag9buJmDDS79gvrm1aQm9yEcgWdR";

const DEFAULT_PRC20 = {
    pSOL: "0x5D525Df2bD99a6e7ec58b76aF2fd95F39874EBed",
    USDC: "0x04B8F634ABC7C879763F623e0f0550a4b5c4426F",
    USDT: "0x4f1A3D22d170a2F4Bddb37845a962322e24f4e34",
    DAI:  "0x5861f56A556c990358cc9cccd8B5baa3767982A8",
} as const;

const COMMAND_HELP = `
Push Chain -> Solana outbound helper

Usage:
  npx ts-node app/push-chain-outbound.ts <case>

Cases:
  withdraw-sol
    Burns pSOL on Push, emits a FUNDS outbound, and targets a Solana wallet.

  withdraw-spl
    Burns a PRC20 token mapped to an SPL mint, emits a FUNDS outbound, and targets a Solana wallet.

  execute-sol
    Burns pSOL, encodes a Solana execute payload, and emits FUNDS_AND_PAYLOAD.
    Current example payload is: counter.increment(EXECUTE_INCREMENT_BY).

  cea-to-uea-sol
    Encodes a gateway self-call to send_universal_tx_to_uea for native SOL.
    CEA_TO_UEA_SOL_AMOUNT is the amount drained from the CEA on Solana.
    CEA_TO_UEA_SOL_TOPUP_AMOUNT is optional extra pSOL burned on Push before the self-call.

  cea-to-uea-spl
    Encodes a gateway self-call to send_universal_tx_to_uea for an SPL mint.
    CEA_TO_UEA_SPL_AMOUNT is the amount drained from the CEA ATA on Solana.
    CEA_TO_UEA_SPL_TOPUP_AMOUNT is optional extra PRC20 burned on Push before the self-call.

  all
    Runs every case sequentially using current env/default values.

Examples:
  npx ts-node app/push-chain-outbound.ts withdraw-sol
  npx ts-node app/push-chain-outbound.ts execute-sol
  CEA_TO_UEA_SOL_TOPUP_AMOUNT=1000000 npx ts-node app/push-chain-outbound.ts cea-to-uea-sol
  EXECUTE_INCREMENT_BY=5 npx ts-node app/push-chain-outbound.ts execute-sol

Key env vars:
  ETH_PRIVATE_KEY or PRIVATE_KEY   Push signer private key
  REVERT_RECIPIENT                 EVM address used for revert refunds (default: signer)
  SOL_RECIPIENT / SPL_RECIPIENT    Solana destination wallet(s)
  PRC20_PSOL / PRC20_USDC / PRC20_USDT
                                   Push-side PRC20 token addresses
  GATEWAY_PROGRAM_ID               Solana universal-gateway program ID
  COUNTER_PROGRAM_ID               Solana test-counter program ID
  COUNTER_AUTHORITY                Counter authority pubkey for execute-sol
  SPL_MINT                         Solana SPL mint used by cea-to-uea-spl
  GAS_LIMIT                        Optional UGPC gasLimit override (0 uses base gas)

Notes:
  - This script only initiates outbound on Push Chain.
  - Solana finalization happens later via TSS + relayer.
  - execute-sol and CEA -> UEA cases show how ixData and account metadata are encoded.
  - To call through a Push UEA instead of an EOA, the UEA must hold the PRC20s,
    approve UGPC, and then execute the encoded UGPC call. The outbound sender
    becomes the UEA address.
`;

// ═══════════════════════════════════════════════════════════════════════════════
// UGPC ABI — only what we need
// ═══════════════════════════════════════════════════════════════════════════════

const UGPC_ABI = [
    // sendUniversalTxOutbound(UniversalOutboundTxRequest req)
    {
        type: "function",
        name: "sendUniversalTxOutbound",
        stateMutability: "nonpayable",
        inputs: [
            {
                name: "req",
                type: "tuple",
                components: [
                    { name: "target",          type: "bytes"   }, // raw dest address on Solana (32 bytes)
                    { name: "token",           type: "address" }, // PRC20 token on Push Chain (must be non-zero)
                    { name: "amount",          type: "uint256" }, // token amount (0 for gas-only)
                    { name: "gasLimit",        type: "uint256" }, // 0 = use BASE_GAS_LIMIT
                    { name: "payload",         type: "bytes"   }, // empty = withdraw only; see encodePayload* below
                    { name: "revertRecipient", type: "address" }, // where funds land on revert
                ],
            },
        ],
        outputs: [],
    },
    {
        type: "function",
        name: "UNIVERSAL_CORE",
        stateMutability: "view",
        inputs: [],
        outputs: [{ type: "address" }],
    },
    {
        type: "event",
        name: "UniversalTxOutbound",
        inputs: [
            { name: "txID",            type: "bytes32", indexed: true  },
            { name: "sender",          type: "address", indexed: true  },
            { name: "chainNamespace",  type: "string",  indexed: false },
            { name: "token",           type: "address", indexed: true  },
            { name: "target",          type: "bytes",   indexed: false },
            { name: "amount",          type: "uint256", indexed: false },
            { name: "gasToken",        type: "address", indexed: false },
            { name: "gasFee",          type: "uint256", indexed: false },
            { name: "gasLimit",        type: "uint256", indexed: false },
            { name: "payload",         type: "bytes",   indexed: false },
            { name: "protocolFee",     type: "uint256", indexed: false },
            { name: "revertRecipient", type: "address", indexed: false },
            { name: "txType",          type: "uint8",   indexed: false },
        ],
    },
];

const ERC20_ABI = [
    "function approve(address spender, uint256 amount) external returns (bool)",
    "function allowance(address owner, address spender) external view returns (uint256)",
];

const UNIVERSAL_CORE_ABI = [
    "function BASE_GAS_LIMIT() external view returns (uint256)",
    "function withdrawGasFeeWithGasLimit(address _prc20, uint256 gasLimit) external view returns (address gasToken, uint256 gasFee)",
];

// ═══════════════════════════════════════════════════════════════════════════════
// PROVIDER + SIGNER
// ═══════════════════════════════════════════════════════════════════════════════

function getProvider(): ethers.JsonRpcProvider {
    return new ethers.JsonRpcProvider(PUSH_CHAIN_RPC, {
        chainId: PUSH_CHAIN_ID,
        name: "push-testnet",
    });
}

function getSigner(provider: ethers.JsonRpcProvider): ethers.Wallet {
    const raw = process.env.ETH_PRIVATE_KEY ?? process.env.PRIVATE_KEY;
    if (!raw) throw new Error("Set ETH_PRIVATE_KEY (or PRIVATE_KEY) env var");
    const privateKey = raw.startsWith("0x") ? raw : `0x${raw}`;
    return new ethers.Wallet(privateKey, provider);
}

function getUgpc(signer: ethers.Signer): ethers.Contract {
    return new ethers.Contract(UGPC_ADDRESS, UGPC_ABI, signer);
}

// ═══════════════════════════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Solana PublicKey → bytes for the `target` field.
 * UGPC passes this raw to the relayer; the relayer decodes it as a 32-byte pubkey.
 */
function solanaAddressToBytes(pubkey: PublicKey | string): Uint8Array {
    const pk = typeof pubkey === "string" ? new PublicKey(pubkey) : pubkey;
    return pk.toBuffer();
}

/** Anchor discriminator: first 8 bytes of SHA-256("global:<name>") */
function discriminator(name: string): Buffer {
    return createHash("sha256").update(`global:${name}`).digest().slice(0, 8);
}

function toBigInt(v: BigNumberish): bigint {
    return BigInt(v.toString());
}

function resolveCandidatePath(relativePath: string): string | null {
    const candidates = [
        path.resolve(process.cwd(), relativePath),
        path.resolve(process.cwd(), "contracts/svm-gateway", relativePath),
    ];
    for (const candidate of candidates) {
        if (fs.existsSync(candidate)) return candidate;
    }
    return null;
}

function loadSplMintFromTokenFile(tokenFileName: string): PublicKey | null {
    const tokenPath = resolveCandidatePath(path.join("tokens", tokenFileName));
    if (!tokenPath) return null;
    const parsed = JSON.parse(fs.readFileSync(tokenPath, "utf8"));
    if (!parsed.mint) return null;
    return new PublicKey(parsed.mint);
}

function loadPubkeyFromKeypairFile(fileName: string): PublicKey | null {
    const keyPath = resolveCandidatePath(fileName);
    if (!keyPath) return null;
    const secret = Uint8Array.from(JSON.parse(fs.readFileSync(keyPath, "utf8")));
    return Keypair.fromSecretKey(secret).publicKey;
}

function resolveCounterAuthority(): PublicKey | null {
    if (process.env.COUNTER_AUTHORITY) return new PublicKey(process.env.COUNTER_AUTHORITY);
    return loadPubkeyFromKeypairFile("upgrade-keypair.json");
}

type OutboundCase =
    | "withdraw-sol"
    | "withdraw-spl"
    | "execute-sol"
    | "cea-to-uea-sol"
    | "cea-to-uea-spl"
    | "all";

function printUsage(): void {
    console.log(COMMAND_HELP.trim());
}

function getRequestedCase(): OutboundCase {
    const argCase = process.argv[2]?.toLowerCase();
    const envCase = process.env.OUTBOUND_CASE?.toLowerCase();
    const requestedRaw = envCase ?? argCase ?? "withdraw-sol";
    if (requestedRaw === "help" || requestedRaw === "--help" || requestedRaw === "-h") {
        printUsage();
        process.exit(0);
    }
    const requested = requestedRaw as OutboundCase;
    const allowed = new Set<OutboundCase>([
        "withdraw-sol",
        "withdraw-spl",
        "execute-sol",
        "cea-to-uea-sol",
        "cea-to-uea-spl",
        "all",
    ]);
    if (!allowed.has(requested)) {
        throw new Error(
            `Invalid case "${requested}". Use one of: withdraw-sol, withdraw-spl, execute-sol, cea-to-uea-sol, cea-to-uea-spl, all. Run with --help for examples.`
        );
    }
    return requested;
}

async function getGasQuote(
    ugpc: ethers.Contract,
    token: string,
    gasLimit: BigNumberish,
): Promise<{ gasToken: string; gasFee: bigint; gasLimitUsed: bigint }> {
    const coreAddress: string = await ugpc.UNIVERSAL_CORE();
    const core = new ethers.Contract(coreAddress, UNIVERSAL_CORE_ABI, ugpc.runner);

    const gasLimitUsed = toBigInt(gasLimit) === BigInt(0)
        ? toBigInt(await core.BASE_GAS_LIMIT())
        : toBigInt(gasLimit);

    const [gasToken, gasFeeRaw] = await core.withdrawGasFeeWithGasLimit(token, gasLimitUsed);
    return { gasToken, gasFee: toBigInt(gasFeeRaw), gasLimitUsed };
}

async function ensureAllowance(
    signer: ethers.Wallet,
    token: string,
    spender: string,
    required: bigint,
): Promise<void> {
    if (required === BigInt(0)) return;
    const erc20 = new ethers.Contract(token, ERC20_ABI, signer);
    const owner = await signer.getAddress();
    const current = toBigInt(await erc20.allowance(owner, spender));
    if (current >= required) return;
    const tx = await erc20.approve(spender, required);
    await tx.wait();
}

/** Log the UniversalTxOutbound event from a tx receipt */
async function logOutboundEvent(
    receipt: ethers.TransactionReceipt,
    ugpc: ethers.Contract,
): Promise<void> {
    const iface = ugpc.interface;
    for (const log of receipt.logs) {
        try {
            const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
            if (parsed?.name === "UniversalTxOutbound") {
                const TX_TYPES = ["GAS", "GAS_AND_PAYLOAD", "FUNDS", "FUNDS_AND_PAYLOAD"];
                console.log("\nUniversalTxOutbound event:");
                console.log("  txID:         ", parsed.args.txID);
                console.log("  txType:       ", TX_TYPES[Number(parsed.args.txType)] ?? parsed.args.txType);
                console.log("  target:       ", Buffer.from(parsed.args.target.slice(2), "hex").toString("hex"));
                console.log("  token:        ", parsed.args.token);
                console.log("  amount:       ", parsed.args.amount.toString());
                console.log("  gasFee:       ", parsed.args.gasFee.toString());
                console.log("  payload len:  ", ((parsed.args.payload.length - 2) / 2).toString(), "bytes");
            }
        } catch { /* not our event */ }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// CASE 1 — WITHDRAW SOL
//
// Bridges native SOL to a Solana recipient.
// TX_TYPE = FUNDS (amount > 0, payload empty)
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Withdraw SOL from Push Chain to a Solana address.
 *
 * @param solRecipient  - Destination Solana address (base58 string or PublicKey)
 * @param prc20SolToken - PRC20 address on Push Chain that represents SOL
 * @param amount        - Amount in token units (PRC20 decimals match the bridged asset)
 * @param revertRecipient - Push Chain address to receive funds if Solana tx fails
 */
export async function withdrawSol(
    solRecipient: PublicKey | string,
    prc20SolToken: string,
    amount: BigNumberish,
    revertRecipient: string,
    gasLimit: BigNumberish = 0,
): Promise<ethers.TransactionReceipt> {
    const provider = getProvider();
    const signer   = getSigner(provider);
    const ugpc     = getUgpc(signer);

    const target = solanaAddressToBytes(solRecipient);
    const amountBI = toBigInt(amount);

    const { gasToken, gasFee, gasLimitUsed } = await getGasQuote(ugpc, prc20SolToken, gasLimit);

    // Approvals: fee token and burn token (if same token, approve combined amount).
    if (gasToken.toLowerCase() === prc20SolToken.toLowerCase()) {
        await ensureAllowance(signer, prc20SolToken, UGPC_ADDRESS, gasFee + amountBI);
    } else {
        await ensureAllowance(signer, gasToken, UGPC_ADDRESS, gasFee);
        await ensureAllowance(signer, prc20SolToken, UGPC_ADDRESS, amountBI);
    }

    console.log(`[Case 1] Withdraw SOL → ${typeof solRecipient === "string" ? solRecipient : solRecipient.toBase58()}`);
    console.log(`  token: ${prc20SolToken}, amount: ${amount}`);
    console.log(`  gasToken: ${gasToken}, gasFee: ${gasFee}, gasLimitUsed: ${gasLimitUsed}`);

    const tx = await ugpc.sendUniversalTxOutbound({
        target,
        token:           prc20SolToken,
        amount,
        gasLimit:        gasLimit,
        payload:         "0x",                // empty = withdraw only → TX_TYPE = FUNDS
        revertRecipient,
    });

    console.log("  tx hash:", tx.hash);
    const receipt = await tx.wait();
    await logOutboundEvent(receipt, ugpc);
    return receipt;
}

// ═══════════════════════════════════════════════════════════════════════════════
// CASE 2 — WITHDRAW SPL
//
// Bridges a PRC20 token on Push Chain to its SPL equivalent on Solana.
// TX_TYPE = FUNDS (amount > 0, payload empty)
//
// The user must ERC20-approve UGPC for `amount` before calling.
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Withdraw SPL token from Push Chain to a Solana address.
 *
 * @param solRecipient  - Destination Solana address
 * @param prc20Token    - PRC20 token address on Push Chain (maps to the SPL mint)
 * @param amount        - Token amount (in the PRC20's decimals)
 * @param revertRecipient
 */
export async function withdrawSpl(
    solRecipient: PublicKey | string,
    prc20Token: string,
    amount: BigNumberish,
    revertRecipient: string,
    gasLimit: BigNumberish = 0,
): Promise<ethers.TransactionReceipt> {
    const provider = getProvider();
    const signer   = getSigner(provider);
    const ugpc     = getUgpc(signer);

    const amountBI = toBigInt(amount);
    const { gasToken, gasFee, gasLimitUsed } = await getGasQuote(ugpc, prc20Token, gasLimit);

    if (gasToken.toLowerCase() === prc20Token.toLowerCase()) {
        await ensureAllowance(signer, prc20Token, UGPC_ADDRESS, gasFee + amountBI);
    } else {
        await ensureAllowance(signer, gasToken, UGPC_ADDRESS, gasFee);
        await ensureAllowance(signer, prc20Token, UGPC_ADDRESS, amountBI);
    }

    const target = solanaAddressToBytes(solRecipient);

    console.log(`[Case 2] Withdraw SPL → ${typeof solRecipient === "string" ? solRecipient : solRecipient.toBase58()}`);
    console.log(`  token: ${prc20Token}, amount: ${amount}`);
    console.log(`  gasToken: ${gasToken}, gasFee: ${gasFee}, gasLimitUsed: ${gasLimitUsed}`);

    const tx = await ugpc.sendUniversalTxOutbound({
        target,
        token:           prc20Token,   // PRC20 on Push Chain
        amount,
        gasLimit:        gasLimit,
        payload:         "0x",         // empty = withdraw only → TX_TYPE = FUNDS
        revertRecipient,
    });

    console.log("  tx hash:", tx.hash);
    const receipt = await tx.wait();
    await logOutboundEvent(receipt, ugpc);
    return receipt;
}

// ═══════════════════════════════════════════════════════════════════════════════
// CASE 3 — EXECUTE (CPI on Solana)
//
// Calls a Solana program via CPI after bridging funds (or gas-only).
// Payload is encoded using encodeExecutePayload from execute-payload.ts.
//
// TX_TYPE = GAS_AND_PAYLOAD (amount=0) or FUNDS_AND_PAYLOAD (amount>0)
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Execute a CPI on a Solana target program, optionally with funds.
 *
 * @param targetProgram   - Solana program to CPI into
 * @param solanaIxData    - Raw instruction data bytes for the target program.
 *                          This is the exact `instruction.data` that program expects.
 * @param cpiAccounts     - Accounts the CPI instruction needs, in exact on-chain order.
 *                          `encodeExecutePayload()` converts this ordered list into:
 *                          `accounts_count + [pubkey + writable_flag]...`.
 * @param token           - PRC20 address on Push Chain (must be non-zero)
 * @param amount          - Amount to transfer with execution (0 = gas-only)
 * @param rentFee         - Lamports the CEA needs to cover target account creation
 * @param revertRecipient
 */
export async function executeOnSolana(
    targetProgram: PublicKey | string,
    solanaIxData: Uint8Array,
    cpiAccounts: GatewayAccountMeta[],
    token: string,
    amount: BigNumberish,
    rentFee: bigint,
    revertRecipient: string,
    gasLimit: BigNumberish = 0,
): Promise<ethers.TransactionReceipt> {
    const provider = getProvider();
    const signer   = getSigner(provider);
    const ugpc     = getUgpc(signer);

    const targetPk = typeof targetProgram === "string"
        ? new PublicKey(targetProgram)
        : targetProgram;

    // Encode the Solana CPI payload — relayer decodes this to reconstruct the ix
    const payload = encodeExecutePayload({
        targetProgram: targetPk,
        accounts:      cpiAccounts,
        ixData:        solanaIxData,
        rentFee,
        instructionId: 2, // Execute
    });

    if (token === ethers.ZeroAddress) {
        throw new Error("UGPC req.token cannot be address(0). Pass the PRC20 token address.");
    }

    const amountBI = toBigInt(amount);
    const { gasToken, gasFee, gasLimitUsed } = await getGasQuote(ugpc, token, gasLimit);

    if (gasToken.toLowerCase() === token.toLowerCase()) {
        await ensureAllowance(signer, token, UGPC_ADDRESS, gasFee + amountBI);
    } else {
        await ensureAllowance(signer, gasToken, UGPC_ADDRESS, gasFee);
        if (amountBI > BigInt(0)) await ensureAllowance(signer, token, UGPC_ADDRESS, amountBI);
    }

    // target = the Solana target program address
    const target = targetPk.toBuffer();

    console.log(`[Case 3] Execute on Solana → program: ${targetPk.toBase58()}`);
    console.log(`  amount: ${amount}, payload: ${payload.length} bytes`);
    console.log(`  gasToken: ${gasToken}, gasFee: ${gasFee}, gasLimitUsed: ${gasLimitUsed}`);

    const tx = await ugpc.sendUniversalTxOutbound({
        target,
        token,
        amount,
        gasLimit: gasLimit,
        payload:  "0x" + payload.toString("hex"),
        revertRecipient,
    });

    console.log("  tx hash:", tx.hash);
    const receipt = await tx.wait();
    await logOutboundEvent(receipt, ugpc);
    return receipt;
}

// ═══════════════════════════════════════════════════════════════════════════════
// CASE 4 — CEA → UEA (Push Chain credits the user's UEA from their CEA balance)
//
// This is a self-call to the Solana gateway program.
// The gateway's send_universal_tx_to_uea instruction is called via CPI,
// which emits a UniversalTx event that Push Chain uses to credit the UEA.
//
// Steps:
//   1. User/CEA already has SOL or SPL on the Solana side (funded by a prior execute)
//   2. This call triggers the relayer to issue a gateway self-call
//   3. Gateway emits UniversalTx → Push Chain credits the UEA
//
// TX_TYPE = GAS_AND_PAYLOAD (topUpAmount=0) or FUNDS_AND_PAYLOAD (topUpAmount>0)
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Trigger a CEA → UEA transfer for SOL.
 *
 * @param gatewayProgramId   - Solana universal-gateway program ID
 * @param ceaDrainAmount     - Lamports to withdraw from CEA (set to full CEA balance)
 * @param payload            - Optional cross-chain payload (empty = FUNDS, non-empty = FUNDS_AND_PAYLOAD)
 * @param topUpAmount        - Optional extra amount to top up from vault before the self-call
 * @param revertRecipient
 */
export async function ceaToUeaSol(
    gatewayProgramId: PublicKey | string,
    prc20SolToken: string,
    ceaDrainAmount: bigint,
    revertRecipient: string,
    extraPayload: Uint8Array = new Uint8Array(0),
    gasLimit: BigNumberish = 0,
    topUpAmount: BigNumberish = 0,
): Promise<ethers.TransactionReceipt> {
    const provider = getProvider();
    const signer   = getSigner(provider);
    const ugpc     = getUgpc(signer);

    const gatewayPk = typeof gatewayProgramId === "string"
        ? new PublicKey(gatewayProgramId)
        : gatewayProgramId;

    // Build send_universal_tx_to_uea instruction data (Borsh-encoded):
    //   [discriminator (8)] [token (32)] [amount (u64 LE)] [payload (Vec<u8>: u32LE len + bytes)]
    const amountBuf = Buffer.alloc(8);
    amountBuf.writeBigUInt64LE(ceaDrainAmount);
    const payloadLenBuf = Buffer.alloc(4);
    payloadLenBuf.writeUInt32LE(extraPayload.length);

    const solanaIxData = Buffer.concat([
        discriminator("send_universal_tx_to_uea"),
        Buffer.alloc(32, 0),           // token = PublicKey::default() (native SOL)
        amountBuf,
        payloadLenBuf,
        Buffer.from(extraPayload),
    ]);

    // Encode as execute payload targeting the gateway itself (self-call)
    const payload = encodeExecutePayload({
        targetProgram: gatewayPk,
        accounts:      [],             // no remaining_accounts for gateway self-call
        ixData:        solanaIxData,
        rentFee:       BigInt(0),      // self-call doesn't need rent_fee
        instructionId: 2,
    });

    const target = gatewayPk.toBuffer(); // target = gateway program address
    const topUpAmountBI = toBigInt(topUpAmount);
    const { gasToken, gasFee, gasLimitUsed } = await getGasQuote(ugpc, prc20SolToken, gasLimit);
    if (gasToken.toLowerCase() === prc20SolToken.toLowerCase()) {
        await ensureAllowance(signer, prc20SolToken, UGPC_ADDRESS, gasFee + topUpAmountBI);
    } else {
        await ensureAllowance(signer, gasToken, UGPC_ADDRESS, gasFee);
        if (topUpAmountBI > BigInt(0)) {
            await ensureAllowance(signer, prc20SolToken, UGPC_ADDRESS, topUpAmountBI);
        }
    }

    console.log(`[Case 4] CEA → UEA SOL, drain: ${ceaDrainAmount} lamports`);
    console.log(`  topUpAmount: ${topUpAmountBI}`);
    console.log(`  gasToken: ${gasToken}, gasFee: ${gasFee}, gasLimitUsed: ${gasLimitUsed}`);

    const tx = await ugpc.sendUniversalTxOutbound({
        target,
        token:           prc20SolToken,
        amount:          topUpAmountBI,             // 0 => GAS_AND_PAYLOAD, >0 => FUNDS_AND_PAYLOAD
        gasLimit:        gasLimit,
        payload:         "0x" + payload.toString("hex"),
        revertRecipient,
    });

    console.log("  tx hash:", tx.hash);
    const receipt = await tx.wait();
    await logOutboundEvent(receipt, ugpc);
    return receipt;
}

/**
 * Trigger a CEA → UEA transfer for SPL tokens.
 *
 * @param gatewayProgramId   - Solana universal-gateway program ID
 * @param splMint            - SPL mint address on Solana
 * @param drainAmount        - Token units to withdraw from CEA ATA
 * @param prc20Token         - PRC20 address on Push Chain (for UGPC routing)
 * @param topUpAmount        - Optional extra amount to top up from vault before the self-call
 * @param revertRecipient
 */
export async function ceaToUeaSpl(
    gatewayProgramId: PublicKey | string,
    splMint: PublicKey | string,
    drainAmount: bigint,
    prc20Token: string,
    revertRecipient: string,
    extraPayload: Uint8Array = new Uint8Array(0),
    gasLimit: BigNumberish = 0,
    topUpAmount: BigNumberish = 0,
): Promise<ethers.TransactionReceipt> {
    const provider = getProvider();
    const signer   = getSigner(provider);
    const ugpc     = getUgpc(signer);

    const gatewayPk = typeof gatewayProgramId === "string"
        ? new PublicKey(gatewayProgramId)
        : gatewayProgramId;
    const mintPk = typeof splMint === "string"
        ? new PublicKey(splMint)
        : splMint;

    // Build send_universal_tx_to_uea instruction data with SPL mint
    const amountBuf = Buffer.alloc(8);
    amountBuf.writeBigUInt64LE(drainAmount);
    const payloadLenBuf = Buffer.alloc(4);
    payloadLenBuf.writeUInt32LE(extraPayload.length);

    const solanaIxData = Buffer.concat([
        discriminator("send_universal_tx_to_uea"),
        mintPk.toBuffer(),             // token = SPL mint address
        amountBuf,
        payloadLenBuf,
        Buffer.from(extraPayload),
    ]);

    const payload = encodeExecutePayload({
        targetProgram: gatewayPk,
        accounts:      [],
        ixData:        solanaIxData,
        rentFee:       BigInt(0),
        instructionId: 2,
    });

    const target = gatewayPk.toBuffer();
    const topUpAmountBI = toBigInt(topUpAmount);
    const { gasToken, gasFee, gasLimitUsed } = await getGasQuote(ugpc, prc20Token, gasLimit);
    if (gasToken.toLowerCase() === prc20Token.toLowerCase()) {
        await ensureAllowance(signer, prc20Token, UGPC_ADDRESS, gasFee + topUpAmountBI);
    } else {
        await ensureAllowance(signer, gasToken, UGPC_ADDRESS, gasFee);
        if (topUpAmountBI > BigInt(0)) {
            await ensureAllowance(signer, prc20Token, UGPC_ADDRESS, topUpAmountBI);
        }
    }

    console.log(`[Case 4] CEA → UEA SPL mint:${mintPk.toBase58()}, drain:${drainAmount}`);
    console.log(`  topUpAmount: ${topUpAmountBI}`);
    console.log(`  gasToken: ${gasToken}, gasFee: ${gasFee}, gasLimitUsed: ${gasLimitUsed}`);

    const tx = await ugpc.sendUniversalTxOutbound({
        target,
        token:           prc20Token,    // PRC20 of the SPL token
        amount:          topUpAmountBI, // 0 => GAS_AND_PAYLOAD, >0 => FUNDS_AND_PAYLOAD
        gasLimit:        gasLimit,
        payload:         "0x" + payload.toString("hex"),
        revertRecipient,
    });

    console.log("  tx hash:", tx.hash);
    const receipt = await tx.wait();
    await logOutboundEvent(receipt, ugpc);
    return receipt;
}

// ═══════════════════════════════════════════════════════════════════════════════
// MAIN — example usage
// Run: npx ts-node app/push-chain-outbound.ts withdraw-sol
// ═══════════════════════════════════════════════════════════════════════════════

async function main() {
    const requestedCase = getRequestedCase();
    const provider = getProvider();
    const signer = getSigner(provider);
    const signerAddress = await signer.getAddress();

    const REVERT_RECIPIENT = process.env.REVERT_RECIPIENT ?? signerAddress;
    const PRC20_PSOL = process.env.PRC20_PSOL ?? process.env.PRC20_SOL_TOKEN ?? DEFAULT_PRC20.pSOL;
    const PRC20_USDC = process.env.PRC20_USDC ?? DEFAULT_PRC20.USDC;
    const PRC20_USDT = process.env.PRC20_USDT ?? DEFAULT_PRC20.USDT;

    const GATEWAY_PROGRAM_ID = new PublicKey(process.env.GATEWAY_PROGRAM_ID ?? DEFAULT_GATEWAY_PROGRAM_ID);
    const COUNTER_PROGRAM = new PublicKey(process.env.COUNTER_PROGRAM_ID ?? DEFAULT_COUNTER_PROGRAM_ID);
    const [COUNTER_PDA] = PublicKey.findProgramAddressSync([Buffer.from("counter")], COUNTER_PROGRAM);
    const COUNTER_AUTH = resolveCounterAuthority();
    const SPL_MINT = process.env.SPL_MINT
        ? new PublicKey(process.env.SPL_MINT)
        : loadSplMintFromTokenFile("usdt-token.json");

    const SOL_RECIPIENT = process.env.SOL_RECIPIENT ?? DEFAULT_SOL_RECIPIENT;
    const SPL_RECIPIENT = process.env.SPL_RECIPIENT ?? SOL_RECIPIENT;

    console.log("\nPush outbound config:");
    console.log(`  sender:            ${signerAddress}`);
    console.log(`  revertRecipient:   ${REVERT_RECIPIENT}`);
    console.log(`  requestedCase:     ${requestedCase}`);
    console.log(`  UGPC:              ${UGPC_ADDRESS}`);
    console.log(`  pSOL PRC20:        ${PRC20_PSOL}`);
    console.log(`  USDC PRC20:        ${PRC20_USDC}`);
    console.log(`  USDT PRC20:        ${PRC20_USDT}`);
    console.log(`  Gateway Program:   ${GATEWAY_PROGRAM_ID.toBase58()}`);
    console.log(`  Counter Program:   ${COUNTER_PROGRAM.toBase58()}`);
    console.log(`  Counter PDA:       ${COUNTER_PDA.toBase58()}`);
    console.log(`  Counter Authority: ${COUNTER_AUTH?.toBase58() ?? "missing (set COUNTER_AUTHORITY or upgrade-keypair.json)"}`);
    console.log(`  SPL Mint:          ${SPL_MINT?.toBase58() ?? "missing (set SPL_MINT or tokens/usdt-token.json)"}`);

    const runWithdrawSol = async () => {
        await withdrawSol(
            SOL_RECIPIENT,
            PRC20_PSOL,
            ethers.parseUnits(process.env.WITHDRAW_SOL_AMOUNT ?? "0.01", 9),
            REVERT_RECIPIENT,
            process.env.GAS_LIMIT ?? 0,
        );
    };

    const runWithdrawSpl = async () => {
        await withdrawSpl(
            SPL_RECIPIENT,
            PRC20_USDC,
            ethers.parseUnits(process.env.WITHDRAW_SPL_AMOUNT ?? "10", 6),
            REVERT_RECIPIENT,
            process.env.GAS_LIMIT ?? 0,
        );
    };

    const runExecuteSol = async () => {
        if (!COUNTER_AUTH) {
            throw new Error("Counter authority missing. Set COUNTER_AUTHORITY or keep upgrade-keypair.json in repo root.");
        }

        // The target program receives these accounts as `remaining_accounts` on Solana.
        // Order matters. `isWritable` is what becomes the writable bitmap in the payload.
        const cpiAccounts: GatewayAccountMeta[] = [
            { pubkey: COUNTER_PDA,  isWritable: true  },
            { pubkey: COUNTER_AUTH, isWritable: false },
        ];
        const incrementBy = BigInt(process.env.EXECUTE_INCREMENT_BY ?? "1");
        const incrementDiscr = createHash("sha256").update("global:increment").digest().slice(0, 8);
        const incrementArg   = Buffer.alloc(8);
        incrementArg.writeBigUInt64LE(incrementBy);
        const cpiIxData = Buffer.concat([incrementDiscr, incrementArg]);

        console.log(`  execute.incrementBy: ${incrementBy}`);

        await executeOnSolana(
            COUNTER_PROGRAM,
            cpiIxData,
            cpiAccounts,
            PRC20_PSOL,
            ethers.parseUnits(process.env.EXECUTE_SOL_AMOUNT ?? "0.1", 9),
            BigInt(process.env.EXECUTE_RENT_FEE ?? "1500000"),
            REVERT_RECIPIENT,
            process.env.GAS_LIMIT ?? 0,
        );
    };

    const runCeaToUeaSol = async () => {
        await ceaToUeaSol(
            GATEWAY_PROGRAM_ID,
            PRC20_PSOL,
            BigInt(process.env.CEA_TO_UEA_SOL_AMOUNT ?? "50000000"),
            REVERT_RECIPIENT,
            new Uint8Array(0),
            process.env.GAS_LIMIT ?? 0,
            process.env.CEA_TO_UEA_SOL_TOPUP_AMOUNT ?? 0,
        );
    };

    const runCeaToUeaSpl = async () => {
        if (!SPL_MINT) {
            throw new Error("SPL mint missing. Set SPL_MINT or keep tokens/usdt-token.json.");
        }

        await ceaToUeaSpl(
            GATEWAY_PROGRAM_ID,
            SPL_MINT,
            BigInt(process.env.CEA_TO_UEA_SPL_AMOUNT ?? "10000000"),
            PRC20_USDT,
            REVERT_RECIPIENT,
            new Uint8Array(0),
            process.env.GAS_LIMIT ?? 0,
            process.env.CEA_TO_UEA_SPL_TOPUP_AMOUNT ?? 0,
        );
    };

    switch (requestedCase) {
    case "withdraw-sol":
        await runWithdrawSol();
        break;
    case "withdraw-spl":
        await runWithdrawSpl();
        break;
    case "execute-sol":
        await runExecuteSol();
        break;
    case "cea-to-uea-sol":
        await runCeaToUeaSol();
        break;
    case "cea-to-uea-spl":
        await runCeaToUeaSpl();
        break;
    case "all":
        await runWithdrawSol();
        await runWithdrawSpl();
        await runExecuteSol();
        await runCeaToUeaSol();
        await runCeaToUeaSpl();
        break;
    default:
        throw new Error(`Unhandled case ${requestedCase}`);
    }
}

if (require.main === module) {
    main().catch(console.error);
}
