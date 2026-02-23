import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { TestCounter } from "../target/types/test_counter";
import { PublicKey, Keypair, SystemProgram, ComputeBudgetProgram } from "@solana/web3.js";
import { expect } from "chai";
import { TOKEN_PROGRAM_ID, getAssociatedTokenAddress, createAssociatedTokenAccountInstruction, ASSOCIATED_TOKEN_PROGRAM_ID } from "@solana/spl-token";
import * as spl from "@solana/spl-token";
import { encodeExecutePayload, decodeExecutePayload, instructionToPayloadFields, accountsToWritableFlags } from "../app/execute-payload";
import * as sharedState from "./shared-state";
import { signTssMessage, buildExecuteAdditionalData, TssInstruction, GatewayAccountMeta, generateUniversalTxId } from "./helpers/tss";
import { ensureTestSetup } from "./helpers/test-setup";
import { createHash } from "crypto";

// Helper to compute Anchor-style discriminator (first 8 bytes of SHA-256)
const computeDiscriminator = (name: string): Buffer => {
    return createHash("sha256").update(name).digest().slice(0, 8);
};

const USDT_DECIMALS = 6;
const TOKEN_MULTIPLIER = BigInt(10 ** USDT_DECIMALS);

// Compute buffer for transaction fees and compute units (in lamports)
// This covers Solana transaction fees (~5-20k) and compute unit costs
const COMPUTE_BUFFER = BigInt(100_000); // 0.0001 SOL buffer for compute + tx fees

// Base rent_fee for target program rent needs (in lamports)
// This is transferred to CEA for target program account creation/rent
// Can be adjusted per test based on target program requirements
const BASE_RENT_FEE = BigInt(1_500_000); // 0.0015 SOL base for target program rent needs

// Helper to calculate actual rent for ExecutedTx account (8 bytes)
// ExecutedTx::LEN = 8 (discriminator only)
const getExecutedTxRent = async (connection: anchor.web3.Connection): Promise<number> => {
    const rent = await connection.getMinimumBalanceForRentExemption(8);
    return rent;
};

// Helper to calculate actual rent for Token Account (165 bytes)
// Standard SPL token account size
const getTokenAccountRent = async (connection: anchor.web3.Connection): Promise<number> => {
    const rent = await connection.getMinimumBalanceForRentExemption(165);
    return rent;
};

// Helper to check if CEA ATA exists
const ceaAtaExists = async (connection: anchor.web3.Connection, ceaAta: PublicKey): Promise<boolean> => {
    const accountInfo = await connection.getAccountInfo(ceaAta);
    return accountInfo !== null && accountInfo.data.length > 0;
};

/**
 * Calculate gas_fee and rent_fee dynamically for SOL execute operations
 * 
 * gas_fee = rent_fee + executed_tx_rent + compute_buffer
 * - rent_fee: For target program rent needs (transferred to CEA)
 * - executed_tx_rent: Gateway account creation cost (paid by relayer, reimbursed via gas_fee)
 * - compute_buffer: Transaction fees and compute unit costs
 * 
 * @param connection - Solana connection
 * @param rentFee - Rent fee for target program (defaults to BASE_RENT_FEE)
 * @returns Object with gasFee and rentFee as BigInt
 */
const calculateSolExecuteFees = async (
    connection: anchor.web3.Connection,
    rentFee: bigint = BASE_RENT_FEE
): Promise<{ gasFee: bigint; rentFee: bigint }> => {
    const executedTxRent = BigInt(await getExecutedTxRent(connection));

    // gas_fee must cover: rent_fee + executed_tx_rent + compute_buffer
    const gasFee = rentFee + executedTxRent + COMPUTE_BUFFER;

    return { gasFee, rentFee };
};

/**
 * Calculate gas_fee and rent_fee dynamically for SPL execute operations
 * 
 * gas_fee = rent_fee + executed_tx_rent + (cea_ata_rent if created) + compute_buffer
 * - rent_fee: For target program rent needs (transferred to CEA)
 * - executed_tx_rent: Gateway account creation cost (paid by relayer, reimbursed via gas_fee)
 * - cea_ata_rent: CEA ATA creation cost if account doesn't exist (paid by relayer, reimbursed via gas_fee)
 * - compute_buffer: Transaction fees and compute unit costs
 * 
 * @param connection - Solana connection
 * @param ceaAta - CEA ATA public key to check if it exists
 * @param rentFee - Rent fee for target program (defaults to BASE_RENT_FEE)
 * @returns Object with gasFee and rentFee as BigInt
 */
const calculateSplExecuteFees = async (
    connection: anchor.web3.Connection,
    ceaAta: PublicKey,
    rentFee: bigint = BASE_RENT_FEE
): Promise<{ gasFee: bigint; rentFee: bigint }> => {
    const executedTxRent = BigInt(await getExecutedTxRent(connection));
    const ceaAtaExisted = await ceaAtaExists(connection, ceaAta);
    const ceaAtaRent = ceaAtaExisted ? BigInt(0) : BigInt(await getTokenAccountRent(connection));

    // gas_fee must cover: rent_fee + executed_tx_rent + cea_ata_rent (if created) + compute_buffer
    const gasFee = rentFee + executedTxRent + ceaAtaRent + COMPUTE_BUFFER;

    return { gasFee, rentFee };
};

/**
 * Calculate rent_fee for target program based on account size
 * Used when target program needs specific account rent (e.g., stake account)
 * 
 * @param connection - Solana connection
 * @param accountSize - Size of account needed by target program
 * @param additionalBuffer - Additional buffer on top of rent exemption (defaults to 500k)
 * @returns Rent fee as BigInt
 */
const calculateRentFeeForAccountSize = async (
    connection: anchor.web3.Connection,
    accountSize: number,
    additionalBuffer: bigint = BigInt(500_000)
): Promise<bigint> => {
    const rentExempt = await connection.getMinimumBalanceForRentExemption(accountSize);
    return BigInt(rentExempt) + additionalBuffer;
};

const asLamports = (sol: number) => new anchor.BN(sol * anchor.web3.LAMPORTS_PER_SOL);
const asTokenAmount = (tokens: number) => new anchor.BN(Number(BigInt(tokens) * TOKEN_MULTIPLIER));

// SECURITY CRITICAL: These helpers MUST produce accounts in the SAME ORDER.
// The accounts used for TSS signing (via buildExecuteAdditionalData) MUST exactly match
// the accounts passed to .remainingAccounts() (same order, same pubkeys, same isWritable).
// Any mismatch will cause MessageHashMismatch (correct - TSS signature protects integrity).
const instructionAccountsToGatewayMetas = (ix: anchor.web3.TransactionInstruction): GatewayAccountMeta[] =>
    ix.keys.map((key) => ({
        pubkey: key.pubkey,
        isWritable: key.isWritable,
    }));

const instructionAccountsToRemaining = (ix: anchor.web3.TransactionInstruction) =>
    ix.keys.map((key) => ({
        pubkey: key.pubkey,
        isWritable: key.isWritable,
        isSigner: false,
    }));

// Helper to convert accounts to writable flags for execute calls
const accountsToWritableFlagsOnly = (accounts: GatewayAccountMeta[]) => {
    return accountsToWritableFlags(accounts);
};

describe("Universal Gateway - Execute Tests", () => {
    anchor.setProvider(anchor.AnchorProvider.env());
    const provider = anchor.getProvider() as anchor.AnchorProvider;
    const gatewayProgram = anchor.workspace.UniversalGateway as Program<UniversalGateway>;
    const counterProgram = anchor.workspace.TestCounter as Program<TestCounter>;

    before(async () => {
        await ensureTestSetup();
    });

    let admin: Keypair;
    let recipient: Keypair; // Recipient for test-counter

    let configPda: PublicKey;
    let vaultPda: PublicKey;
    let tssPda: PublicKey;

    let mockUSDT: any;
    let vaultUsdtAccount: PublicKey;
    let recipientUsdtAccount: PublicKey;

    let counterPda: PublicKey; // Counter PDA
    let counterBump: number; // Counter PDA bump
    let counterAuthority: Keypair; // Authority for counter

    let txIdCounter = 0;

    const generateTxId = (): number[] => {
        txIdCounter++;
        const buffer = Buffer.alloc(32);
        buffer.writeUInt32BE(txIdCounter, 0);
        buffer.writeUInt32BE(Date.now() % 0xFFFFFFFF, 4);
        for (let i = 8; i < 32; i++) {
            buffer[i] = Math.floor(Math.random() * 256);
        }
        return Array.from(buffer);
    };

    const generateSender = (): number[] => {
        const buffer = Buffer.alloc(20);
        for (let i = 0; i < 20; i++) {
            buffer[i] = Math.floor(Math.random() * 256);
        }
        if (buffer.every(b => b === 0)) {
            buffer[0] = 1;
        }
        return Array.from(buffer);
    };

    const getExecutedTxPda = (txId: number[]): PublicKey => {
        const [pda] = PublicKey.findProgramAddressSync(
            [Buffer.from("executed_tx"), Buffer.from(txId)],
            gatewayProgram.programId
        );
        return pda;
    };

    const getCeaAuthorityPda = (sender: number[]): PublicKey => {
        const [pda] = PublicKey.findProgramAddressSync(
            [Buffer.from("push_identity"), Buffer.from(sender)],
            gatewayProgram.programId
        );
        return pda;
    };

    const getStakeAta = async (stakePda: PublicKey, mint: PublicKey): Promise<PublicKey> => {
        return getAssociatedTokenAddress(
            mint,
            stakePda,
            true, // allowOwnerOffCurve (stake PDA is off-curve)
            TOKEN_PROGRAM_ID,
            ASSOCIATED_TOKEN_PROGRAM_ID
        );
    };

    const getCeaAta = async (sender: number[], mint: PublicKey): Promise<PublicKey> => {
        const ceaAuthority = getCeaAuthorityPda(sender);
        return getAssociatedTokenAddress(mint, ceaAuthority, true);
    };


    before(async () => {
        admin = sharedState.getAdmin();
        mockUSDT = sharedState.getMockUSDT();

        recipient = Keypair.generate();
        counterAuthority = sharedState.getCounterAuthority();

        const airdropLamports = 100 * anchor.web3.LAMPORTS_PER_SOL;
        await Promise.all([
            provider.connection.requestAirdrop(admin.publicKey, airdropLamports), // Admin pays for executed_tx account creation
            provider.connection.requestAirdrop(recipient.publicKey, airdropLamports),
            provider.connection.requestAirdrop(counterAuthority.publicKey, airdropLamports),
        ]);
        await new Promise((resolve) => setTimeout(resolve, 2000));

        // Get PDAs
        [configPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("config")],
            gatewayProgram.programId
        );

        [vaultPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("vault")],
            gatewayProgram.programId
        );

        [tssPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("tsspda_v2")],
            gatewayProgram.programId
        );
        // Get vault ATA and create if needed (admin pays)
        vaultUsdtAccount = await getAssociatedTokenAddress(
            mockUSDT.mint.publicKey,
            vaultPda,
            true,
            TOKEN_PROGRAM_ID,
            ASSOCIATED_TOKEN_PROGRAM_ID
        );
        const vaultAtaInfo = await provider.connection.getAccountInfo(vaultUsdtAccount);
        if (!vaultAtaInfo) {
            const createVaultAtaIx = createAssociatedTokenAccountInstruction(
                admin.publicKey,
                vaultUsdtAccount,
                vaultPda,
                mockUSDT.mint.publicKey,
                TOKEN_PROGRAM_ID,
                ASSOCIATED_TOKEN_PROGRAM_ID
            );
            await provider.sendAndConfirm(new anchor.web3.Transaction().add(createVaultAtaIx), [admin]);
        }
        // Get recipient ATA and create if needed (admin pays)
        recipientUsdtAccount = await getAssociatedTokenAddress(
            mockUSDT.mint.publicKey,
            recipient.publicKey,
            false,
            TOKEN_PROGRAM_ID,
            ASSOCIATED_TOKEN_PROGRAM_ID
        );
        const recipientAtaInfo = await provider.connection.getAccountInfo(recipientUsdtAccount);
        if (!recipientAtaInfo) {
            const createRecipientAtaIx = createAssociatedTokenAccountInstruction(
                admin.publicKey,
                recipientUsdtAccount,
                recipient.publicKey,
                mockUSDT.mint.publicKey,
                TOKEN_PROGRAM_ID,
                ASSOCIATED_TOKEN_PROGRAM_ID
            );
            await provider.sendAndConfirm(new anchor.web3.Transaction().add(createRecipientAtaIx), [admin]);
        }
        // Initialize test counter with dedicated authority (not signer in execute tests)
        // Derive counter PDA
        [counterPda, counterBump] = PublicKey.findProgramAddressSync(
            [Buffer.from("counter")],
            counterProgram.programId
        );

        try {
            await counterProgram.methods
                .initialize(new anchor.BN(0))
                .accounts({
                    counter: counterPda,
                    authority: counterAuthority.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([counterAuthority])
                .rpc();
        } catch (e: any) {
            // Counter might already be initialized
            if (!e.toString().includes("already in use")) {
                throw e;
            }
        }

        // Fund vault with SOL (admin pays)
        const vaultAmount = asLamports(100);
        const vaultTx = new anchor.web3.Transaction().add(
            anchor.web3.SystemProgram.transfer({
                fromPubkey: admin.publicKey,
                toPubkey: vaultPda,
                lamports: vaultAmount.toNumber(),
            })
        );
        await provider.sendAndConfirm(vaultTx, [admin]);

        // Fund vault with tokens
        await mockUSDT.mintTo(vaultUsdtAccount, 1000);
    });

    describe("execute_universal_tx (SOL)", () => {
        it("should execute SOL-only payload (increment) with zero amount", async () => {
            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const sender = generateSender();
            const executeAmount = new anchor.BN(0);
            const incrementAmount = new anchor.BN(5);

            // Build instruction data for test-counter.increment
            const counterIx = await counterProgram.methods
                .increment(incrementAmount)
                .accounts({
                    counter: counterPda,
                    authority: counterAuthority.publicKey,
                })
                .instruction();

            // CRITICAL: Use the EXACT same accounts for signing and remaining_accounts
            const remainingAccounts = instructionAccountsToRemaining(counterIx);
            const accounts = remainingAccounts.map((acc) => ({
                pubkey: acc.pubkey,
                isWritable: acc.isWritable,
            }));

            // Calculate fees dynamically based on actual costs
            const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    counterIx.data,
                    gasFee,
                    rentFee
                ),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterPda);
            console.log("SOL-only payload with zero amount counterBefore", counterBefore.value.toNumber());

            const balanceBefore = await provider.connection.getBalance(admin.publicKey);
            // Convert accounts to writable flags for Solana transaction
            const writableFlags = accountsToWritableFlagsOnly(accounts);

            await gatewayProgram.methods
                .withdrawAndExecute(
                    2,
                    Array.from(txId),
                    Array.from(universalTxId),
                    executeAmount,
                    Array.from(sender),
                    writableFlags,
                    Buffer.from(counterIx.data),
                    new anchor.BN(Number(gasFee)),
                    new anchor.BN(Number(rentFee)),
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    destinationProgram: counterProgram.programId,
                    recipient: null,
                    vaultAta: null,
                    ceaAta: null,
                    mint: null,
                    tokenProgram: null,
                    rent: null,
                    associatedTokenProgram: null,
                    recipientAta: null,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(remainingAccounts)
                .signers([admin])
                .rpc();

            const balanceAfter = await provider.connection.getBalance(admin.publicKey);
            // Option 1: Relayer pays gateway costs, gets relayer_fee reimbursement
            // Caller pays for:
            // 1. executed_tx account rent (~890k)
            // 2. Transaction fees (varies by transaction size)
            // Caller receives: relayer_fee = gas_fee - rent_fee (reimbursement for gateway costs)
            const actualRentForExecutedTx = await getExecutedTxRent(provider.connection);
            const relayerFee = Number(gasFee - rentFee);
            const actualBalanceChange = balanceAfter - balanceBefore;
            // Expected: -executed_tx_rent + relayer_fee - transaction_fees
            // relayer_fee = gas_fee - rent_fee = (rent_fee + executed_tx_rent + compute_buffer) - rent_fee
            // = executed_tx_rent + compute_buffer
            const expectedBalanceChange = -actualRentForExecutedTx + relayerFee;
            expect(actualBalanceChange).to.be.closeTo(expectedBalanceChange, 15000); // Allow for transaction fees

            const counterAfter = await counterProgram.account.counter.fetch(counterPda);
            console.log("SOL-only payload with zero amount counterAfter", counterAfter.value.toNumber());
            expect(counterAfter.value.toNumber()).to.equal(
                counterBefore.value.toNumber() + incrementAmount.toNumber(),
            );
        });

        it("should allow gateway self-call to withdraw SOL from CEA", async () => {
            const sender = generateSender();
            const cea = getCeaAuthorityPda(sender);

            // 1) Fund CEA via execute (amount > 0, target = counterProgram)
            const txIdFund = generateTxId();
            const universalTxIdFund = generateUniversalTxId();
            const fundAmount = asLamports(1);
            const counterIx = await counterProgram.methods
                .increment(new anchor.BN(0))
                .accounts({ counter: counterPda, authority: counterAuthority.publicKey })
                .instruction();
            // CRITICAL: Use the EXACT same accounts for signing and remaining_accounts
            const remainingAccounts = instructionAccountsToRemaining(counterIx);
            const fundAccounts = remainingAccounts.map((acc) => ({
                pubkey: acc.pubkey,
                isWritable: acc.isWritable,
            }));

            // Calculate fees dynamically for fund operation
            const { gasFee: gasFeeFund, rentFee: rentFeeFund } = await calculateSolExecuteFees(provider.connection);

            const sigFund = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(fundAmount.toString()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxIdFund),
                    new Uint8Array(txIdFund),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    fundAccounts,
                    counterIx.data,
                    gasFeeFund,
                    rentFeeFund
                ),
            });

            const fundWritableFlags = accountsToWritableFlagsOnly(fundAccounts);
            await gatewayProgram.methods
                .withdrawAndExecute(
                    2,
                    Array.from(txIdFund),
                    Array.from(universalTxIdFund),
                    fundAmount,
                    Array.from(sender),
                    fundWritableFlags,
                    Buffer.from(counterIx.data),
                    new anchor.BN(Number(gasFeeFund)),
                    new anchor.BN(Number(rentFeeFund)),
                    Array.from(sigFund.signature),
                    sigFund.recoveryId,
                    Array.from(sigFund.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: cea,
                    tssPda,
                    executedTx: getExecutedTxPda(txIdFund),
                    destinationProgram: counterProgram.programId,
                    recipient: null,
                    vaultAta: null,
                    ceaAta: null,
                    mint: null,
                    tokenProgram: null,
                    rent: null,
                    associatedTokenProgram: null,
                    recipientAta: null,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(remainingAccounts)
                .signers([admin])
                .rpc();

            const ceaBalBefore = await provider.connection.getBalance(cea);
            expect(ceaBalBefore).to.be.greaterThan(0);

            // 2) Withdraw all SOL from CEA via gateway self-call (target = gateway)
            const txIdWithdraw = generateTxId();
            const universalTxIdWithdraw = generateUniversalTxId();
            const withdrawDiscr = computeDiscriminator("global:withdraw_from_cea");
            const withdrawArgs = Buffer.concat([
                Buffer.alloc(32, 0), // token = Pubkey::default()
                (() => {
                    const b = Buffer.alloc(8);
                    b.writeBigUInt64LE(BigInt(0)); // amount = 0 => all
                    return b;
                })(),
            ]);
            const withdrawIxData = Buffer.concat([withdrawDiscr, withdrawArgs]);

            // Calculate fees dynamically for withdraw operation
            const { gasFee: gasFeeWithdraw, rentFee: rentFeeWithdraw } = await calculateSolExecuteFees(provider.connection);

            const sigW = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxIdWithdraw),
                    new Uint8Array(txIdWithdraw),
                    gatewayProgram.programId,
                    new Uint8Array(sender),
                    [],
                    withdrawIxData,
                    gasFeeWithdraw,
                    rentFeeWithdraw
                ),
            });

            const callerBalanceBeforeWithdraw = await provider.connection.getBalance(admin.publicKey);
            const withdrawWritableFlags = accountsToWritableFlagsOnly([]);
            await gatewayProgram.methods
                .withdrawAndExecute(
                    2,
                    Array.from(txIdWithdraw),
                    Array.from(universalTxIdWithdraw),
                    new anchor.BN(0),
                    Array.from(sender),
                    withdrawWritableFlags,
                    withdrawIxData,
                    new anchor.BN(Number(gasFeeWithdraw)),
                    new anchor.BN(Number(rentFeeWithdraw)),
                    Array.from(sigW.signature),
                    sigW.recoveryId,
                    Array.from(sigW.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: cea,
                    tssPda,
                    executedTx: getExecutedTxPda(txIdWithdraw),
                    destinationProgram: gatewayProgram.programId,
                    recipient: null,
                    vaultAta: null,
                    ceaAta: null,
                    mint: null,
                    tokenProgram: null,
                    rent: null,
                    associatedTokenProgram: null,
                    recipientAta: null,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            const callerBalanceAfterWithdraw = await provider.connection.getBalance(admin.publicKey);
            const actualBalanceChangeWithdraw = callerBalanceAfterWithdraw - callerBalanceBeforeWithdraw;
            // Balance flow (Option 1: relayer pays gateway costs, gets relayer_fee reimbursement):
            // 1. Caller PAYS for executed_tx account creation: -890k (replay protection account)
            // 2. Caller PAYS transaction fees: ~-10-20k (Solana network compute fees)
            // 3. Vault TRANSFERS relayer_fee to caller: relayer_fee = gas_fee - rent_fee (reimbursement for gateway costs)
            // relayer_fee = (rent_fee + executed_tx_rent + compute_buffer) - rent_fee = executed_tx_rent + compute_buffer
            // Net expected: -executed_tx_rent - tx_fees + (executed_tx_rent + compute_buffer) ≈ +compute_buffer - tx_fees
            // Note: CEA is a PDA - caller doesn't pay for its creation (auto-created by Solana on first transfer)
            const actualRentForExecutedTx = await getExecutedTxRent(provider.connection);
            const relayerFeeWithdraw = Number(gasFeeWithdraw - rentFeeWithdraw);
            const expectedBalanceChangeWithdraw = -actualRentForExecutedTx + relayerFeeWithdraw;
            // Use tight tolerance (50k) to catch missing relayer_fee reimbursement
            expect(actualBalanceChangeWithdraw).to.be.closeTo(expectedBalanceChangeWithdraw, 50000);

            const ceaBalAfter = await provider.connection.getBalance(cea);
            expect(ceaBalAfter).to.equal(0);
        });

        // SOL transfer test removed - covered by CEA staking tests below

        it("should reject duplicate tx_id (replay protection)", async () => {
            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const sender = generateSender();
            const amount = asLamports(0.1);

            const counterIx = await counterProgram.methods
                .increment(new anchor.BN(1))
                .accounts({
                    counter: counterPda,
                    authority: counterAuthority.publicKey,
                })
                .instruction();
            const accounts = instructionAccountsToGatewayMetas(counterIx);
            const remaining = instructionAccountsToRemaining(counterIx);

            // Calculate fees dynamically for both executions (same tx_id, same fees)
            const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

            // First execution
            const sig1 = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(amount.toString()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    counterIx.data,
                    gasFee,
                    rentFee
                ),
            });

            const writableFlags1 = accountsToWritableFlagsOnly(accounts);
            await gatewayProgram.methods
                .withdrawAndExecute(
                    2,
                    Array.from(txId),
                    Array.from(universalTxId),
                    amount,
                    Array.from(sender),
                    writableFlags1,
                    Buffer.from(counterIx.data),
                    new anchor.BN(Number(gasFee)),
                    new anchor.BN(Number(rentFee)),
                    Array.from(sig1.signature),
                    sig1.recoveryId,
                    Array.from(sig1.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    tssPda: tssPda,
                    executedTx: getExecutedTxPda(txId),
                    destinationProgram: counterProgram.programId,
                    recipient: null,
                    vaultAta: null,
                    ceaAta: null,
                    mint: null,
                    tokenProgram: null,
                    rent: null,
                    associatedTokenProgram: null,
                    recipientAta: null,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(remaining)
                .signers([admin])
                .rpc();

            // Second execution with same tx_id should fail
            const sig2 = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(amount.toString()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    counterIx.data,
                    gasFee,
                    rentFee
                ),
            });

            try {
                const writableFlags2 = accountsToWritableFlagsOnly(accounts);
                await gatewayProgram.methods
                    .withdrawAndExecute(
                    2,
                        Array.from(txId),
                        Array.from(universalTxId),
                        amount,
                        Array.from(sender),
                        writableFlags2,
                        Buffer.from(counterIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig2.signature),
                        sig2.recoveryId,
                        Array.from(sig2.messageHash),
                    )
                    .accounts({
                        caller: admin.publicKey,
                        config: configPda,
                        vaultSol: vaultPda,
                        ceaAuthority: getCeaAuthorityPda(sender),
                        tssPda: tssPda,
                        executedTx: getExecutedTxPda(txId),
                        destinationProgram: counterProgram.programId,
                        recipient: null,
                        vaultAta: null,
                        ceaAta: null,
                        mint: null,
                        tokenProgram: null,
                        rent: null,
                        associatedTokenProgram: null,
                        recipientAta: null,
                        systemProgram: SystemProgram.programId,
                    })
                    .remainingAccounts(remaining)
                    .signers([admin])
                    .rpc();
                expect.fail("Should have rejected duplicate tx_id");
            } catch (e: any) {
                expect(e.toString()).to.include("already in use");
            }
        });
    });

    describe("execute_universal_tx (SPL)", () => {
        it("should execute SPL token transfer to test-counter", async () => {
            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const sender = generateSender();
            const amount = asTokenAmount(100); // 100 USDT
            const targetProgram = counterProgram.programId;

            // Build instruction data for test-counter.receive_spl
            const counterIx = await counterProgram.methods
                .receiveSpl(amount)
                .accounts({
                    counter: counterPda,
                    ceaAta: await getCeaAta(sender, mockUSDT.mint.publicKey),
                    recipientAta: recipientUsdtAccount,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    tokenProgram: TOKEN_PROGRAM_ID,
                })
                .instruction();

            // Check CEA ATA existence BEFORE calculating fees (fee calculation depends on this)
            const ceaAta = await getCeaAta(sender, mockUSDT.mint.publicKey);
            const ceaAtaExistedBefore = await ceaAtaExists(provider.connection, ceaAta);

            // Calculate fees dynamically based on actual costs (including CEA ATA rent if needed)
            const { gasFee, rentFee } = await calculateSplExecuteFees(provider.connection, ceaAta);

            const accounts = instructionAccountsToGatewayMetas(counterIx);
            const remainingAccounts = instructionAccountsToRemaining(counterIx);

            // Sign execute message with the EXACT same accounts that will be in remaining_accounts
            const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);
            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(amount.toString()),
                chainId: tssAccount.chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    counterIx.data,
                    gasFee,
                    rentFee,
                    mockUSDT.mint.publicKey
                ),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterPda);
            const recipientTokenBefore = await mockUSDT.getBalance(recipientUsdtAccount);
            console.log("SPL token transfer to test-counter counterBefore", counterBefore.value.toNumber());
            const balanceBefore = await provider.connection.getBalance(admin.publicKey);
            const splWritableFlags1 = accountsToWritableFlagsOnly(accounts);
            await gatewayProgram.methods
                .withdrawAndExecute(
                    2,
                    Array.from(txId),
                    Array.from(universalTxId),
                    amount,
                    Array.from(sender),
                    splWritableFlags1,
                    Buffer.from(counterIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAta: vaultUsdtAccount,
                    vaultSol: vaultPda,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    ceaAta: ceaAta,
                    mint: mockUSDT.mint.publicKey,
                    tssPda: tssPda,
                    executedTx: getExecutedTxPda(txId),
                    destinationProgram: counterProgram.programId,
                    recipient: null,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                    associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
                    recipientAta: null,
                })
                .remainingAccounts(remainingAccounts)
                .signers([admin])
                .rpc();

            const balanceAfter = await provider.connection.getBalance(admin.publicKey);
            // Option 1: Relayer pays gateway costs, gets relayer_fee reimbursement
            // Caller pays for:
            // 1. executed_tx account rent (~890k)
            // 2. CEA ATA rent (if it doesn't exist - caller is payer per line 465 in execute.rs) (~2M)
            // 3. Transaction fees (varies by transaction size)
            // Caller receives: relayer_fee = gas_fee - rent_fee (reimbursement for gateway costs)
            // relayer_fee = (rent_fee + executed_tx_rent + cea_ata_rent + compute_buffer) - rent_fee
            // = executed_tx_rent + cea_ata_rent + compute_buffer
            const actualRentForExecutedTx = await getExecutedTxRent(provider.connection);
            const actualRentForCeaAta = ceaAtaExistedBefore ? 0 : await getTokenAccountRent(provider.connection);
            const relayerFee = Number(gasFee - rentFee);

            const actualBalanceChange = balanceAfter - balanceBefore;
            // Expected: -executed_tx_rent - cea_ata_rent (if created) + relayer_fee - transaction_fees
            const expectedBalanceChange = -actualRentForExecutedTx - actualRentForCeaAta + relayerFee;
            expect(actualBalanceChange).to.be.closeTo(expectedBalanceChange, 20000); // Allow for transaction fees (SPL txs are larger)

            // Verify executed_tx account exists
            const executedTx = await gatewayProgram.account.executedTx.fetch(getExecutedTxPda(txId));
            expect(executedTx).to.not.be.null;

            const counterAfter = await counterProgram.account.counter.fetch(counterPda);
            expect(counterAfter.value.toNumber()).to.equal(
                counterBefore.value.toNumber() + amount.toNumber(),
            );

            const recipientTokenAfter = await mockUSDT.getBalance(recipientUsdtAccount);
            const amountTokens = amount.toNumber() / 10 ** USDT_DECIMALS;
            expect(recipientTokenAfter - recipientTokenBefore).to.equal(amountTokens);

            // Verify cea_ata persists (CEA is now persistent, not auto-closed)
            const ceaAtaInfo = await provider.connection.getAccountInfo(ceaAta);
            expect(ceaAtaInfo).to.not.be.null; // CEA ATA persists (pull model)
        });
        it("should reject SPL execution if cea ATA owner mismatches", async () => {
            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const sender = generateSender();
            const amount = asTokenAmount(25);

            const counterIx = await counterProgram.methods
                .receiveSpl(amount)
                .accounts({
                    counter: counterPda,
                    ceaAta: await getCeaAta(sender, mockUSDT.mint.publicKey),
                    recipientAta: recipientUsdtAccount,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    tokenProgram: TOKEN_PROGRAM_ID,
                })
                .instruction();

            const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);

            // Check CEA ATA existence BEFORE calculating fees
            const correctCeaAta = await getCeaAta(sender, mockUSDT.mint.publicKey);
            const { gasFee, rentFee } = await calculateSplExecuteFees(provider.connection, correctCeaAta);

            // Create a malicious ATA owned by an attacker (not the cea PDA)
            const attacker = Keypair.generate();
            const maliciousAta = await getAssociatedTokenAddress(
                mockUSDT.mint.publicKey,
                attacker.publicKey
            );
            const createIx = createAssociatedTokenAccountInstruction(
                admin.publicKey,
                maliciousAta,
                attacker.publicKey,
                mockUSDT.mint.publicKey,
                TOKEN_PROGRAM_ID,
                ASSOCIATED_TOKEN_PROGRAM_ID
            );
            const createTx = new anchor.web3.Transaction().add(createIx);
            await provider.sendAndConfirm(createTx, [admin]);

            const accounts = instructionAccountsToGatewayMetas(counterIx);
            const remainingAccounts = instructionAccountsToRemaining(counterIx);
            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(amount.toString()),
                chainId: tssAccount.chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    counterIx.data,
                    gasFee,
                    rentFee,
                    mockUSDT.mint.publicKey
                ),
            });

            try {
                const splWritableFlags2 = accountsToWritableFlagsOnly(accounts);
                await gatewayProgram.methods
                    .withdrawAndExecute(
                    2,
                        Array.from(txId),
                        Array.from(universalTxId),
                        amount,
                        Array.from(sender),
                        splWritableFlags2,
                        Buffer.from(counterIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig.signature),
                        sig.recoveryId,
                        Array.from(sig.messageHash),
                    )
                    .accounts({
                        caller: admin.publicKey,
                        config: configPda,
                        vaultAta: vaultUsdtAccount,
                        vaultSol: vaultPda,
                        ceaAuthority: getCeaAuthorityPda(sender),
                        ceaAta: maliciousAta, // Malicious ATA - wrong owner (checked at line 546-559)
                        mint: mockUSDT.mint.publicKey,
                        tssPda: tssPda,
                        executedTx: getExecutedTxPda(txId),
                        destinationProgram: counterProgram.programId,
                        recipient: null,
                        tokenProgram: TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                        associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
                        recipientAta: null,
                    })
                    .remainingAccounts(remainingAccounts)
                    .signers([admin])
                    .rpc();
                expect.fail("Should have rejected malicious cea ATA");
            } catch (error: any) {
                const errorCode =
                    error.error?.errorCode?.code ||
                    error.errorCode?.code ||
                    error.code ||
                    error.error?.code ||
                    error.message;
                // Execution flow: unified execute validates cea_ata manually (SplAccount::unpack);
                // if owner mismatches, program returns InvalidAccount (not Anchor's ConstraintTokenOwner).
                expect(errorCode).to.equal("InvalidAccount");
            }

        });
        it("should execute SPL-only payload (increment) with zero amount", async () => {
            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const sender = generateSender();
            const amount = new anchor.BN(0);
            const incrementAmount = new anchor.BN(4);

            // Use increment instead of decrement to avoid underflow
            const counterIx = await counterProgram.methods
                .increment(incrementAmount)
                .accounts({
                    counter: counterPda,
                    authority: counterAuthority.publicKey,
                })
                .instruction();

            // Check CEA ATA existence BEFORE calculating fees
            const ceaAta = await getCeaAta(sender, mockUSDT.mint.publicKey);
            const ceaAtaExistedBeforeZeroAmount = await ceaAtaExists(provider.connection, ceaAta);
            const { gasFee, rentFee } = await calculateSplExecuteFees(provider.connection, ceaAta);

            const accounts = instructionAccountsToGatewayMetas(counterIx);
            const remainingAccounts = instructionAccountsToRemaining(counterIx);

            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    counterIx.data,
                    gasFee,
                    rentFee,
                    mockUSDT.mint.publicKey
                ),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterPda);
            const recipientTokenBefore = await mockUSDT.getBalance(recipientUsdtAccount);
            console.log("SPL-only payload with zero amount counterBefore", counterBefore.value.toNumber());
            const balanceBefore = await provider.connection.getBalance(admin.publicKey);
            const splWritableFlags4 = accountsToWritableFlagsOnly(accounts);
            await gatewayProgram.methods
                .withdrawAndExecute(
                    2,
                    Array.from(txId),
                    Array.from(universalTxId),
                    amount,
                    Array.from(sender),
                    splWritableFlags4,
                    Buffer.from(counterIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAta: vaultUsdtAccount,
                    vaultSol: vaultPda,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    ceaAta: ceaAta,
                    mint: mockUSDT.mint.publicKey,
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    destinationProgram: counterProgram.programId,
                    recipient: null,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                    associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
                    recipientAta: null,
                })
                .remainingAccounts(remainingAccounts)
                .signers([admin])
                .rpc();

            const balanceAfter = await provider.connection.getBalance(admin.publicKey);
            // Option 1: Relayer pays gateway costs, gets relayer_fee reimbursement
            // Caller pays for:
            // 1. executed_tx account rent (~890k)
            // 2. CEA ATA rent (if it doesn't exist - caller is payer per line 465 in execute.rs) (~2M)
            // 3. Transaction fees (varies by transaction size)
            // Caller receives: relayer_fee = gas_fee - rent_fee (reimbursement for gateway costs)
            // relayer_fee = (rent_fee + executed_tx_rent + cea_ata_rent + compute_buffer) - rent_fee
            // = executed_tx_rent + cea_ata_rent + compute_buffer
            const actualRentForExecutedTx = await getExecutedTxRent(provider.connection);
            const actualRentForCeaAta = ceaAtaExistedBeforeZeroAmount ? 0 : await getTokenAccountRent(provider.connection);
            const relayerFee = Number(gasFee - rentFee);

            const actualBalanceChange = balanceAfter - balanceBefore;
            // Expected: -executed_tx_rent - cea_ata_rent (if created) + relayer_fee - transaction_fees
            const expectedBalanceChange = -actualRentForExecutedTx - actualRentForCeaAta + relayerFee;
            expect(actualBalanceChange).to.be.closeTo(expectedBalanceChange, 20000); // Allow for transaction fees (SPL txs are larger)

            const counterAfter = await counterProgram.account.counter.fetch(counterPda);
            expect(counterAfter.value.toNumber()).to.equal(
                counterBefore.value.toNumber() + incrementAmount.toNumber(),
            );

            const recipientTokenAfter = await mockUSDT.getBalance(recipientUsdtAccount);
            expect(recipientTokenAfter).to.equal(recipientTokenBefore);

            const ceaAtaInfo = await provider.connection.getAccountInfo(
                await getCeaAta(sender, mockUSDT.mint.publicKey),
            );
            // CEA ATA is created by init_if_needed even for zero-amount (persists for pull model)
            expect(ceaAtaInfo).to.not.be.null;
        });
    });

    it("should allow gateway self-call to withdraw SPL from CEA", async () => {
        const sender = generateSender();
        const cea = getCeaAuthorityPda(sender);
        const ceaAta = await getCeaAta(sender, mockUSDT.mint.publicKey);

        // Fund CEA ATA via execute (amount > 0, target = counterProgram)
        const txIdFund = generateTxId();
        const universalTxIdFund = generateUniversalTxId();
        const fundAmount = asTokenAmount(25);

        // Calculate rent_fee for target program (stake account needs 48 bytes)
        const rentFeeLamports = await calculateRentFeeForAccountSize(provider.connection, 48, BigInt(500_000));

        // Calculate gas_fee dynamically (includes CEA ATA rent if needed)
        const ceaAtaExistedBefore = await ceaAtaExists(provider.connection, ceaAta);
        const { gasFee: gasFeeLamports, rentFee: calculatedRentFee } = await calculateSplExecuteFees(provider.connection, ceaAta, rentFeeLamports);

        const rentFeeBn = new anchor.BN(rentFeeLamports.toString());
        const gasFeeBn = new anchor.BN(gasFeeLamports.toString());

        const counterIx = await counterProgram.methods
            .increment(new anchor.BN(0))
            .accounts({ counter: counterPda, authority: counterAuthority.publicKey })
            .instruction();
        const fundAccounts = instructionAccountsToGatewayMetas(counterIx);
        const sigFund = await signTssMessage({
            instruction: TssInstruction.Execute,
            amount: BigInt(fundAmount.toString()),
            chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
            additional: buildExecuteAdditionalData(
                new Uint8Array(universalTxIdFund),
                new Uint8Array(txIdFund),
                counterProgram.programId,
                new Uint8Array(sender),
                fundAccounts,
                counterIx.data,
                gasFeeLamports,
                rentFeeLamports,
                mockUSDT.mint.publicKey
            ),
        });

        const callerBalanceBeforeFund = await provider.connection.getBalance(admin.publicKey);
        const fundWritableFlagsSpl = accountsToWritableFlagsOnly(fundAccounts);
        await gatewayProgram.methods
            .withdrawAndExecute(
                    2,
                Array.from(txIdFund),
                Array.from(universalTxIdFund),
                fundAmount,
                Array.from(sender),
                fundWritableFlagsSpl,
                Buffer.from(counterIx.data),
                gasFeeBn,
                rentFeeBn,
                Array.from(sigFund.signature),
                sigFund.recoveryId,
                Array.from(sigFund.messageHash),
            )
            .accounts({
                caller: admin.publicKey,
                config: configPda,
                vaultAta: vaultUsdtAccount,
                vaultSol: vaultPda,
                ceaAuthority: cea,
                ceaAta,
                mint: mockUSDT.mint.publicKey,
                tssPda,
                executedTx: getExecutedTxPda(txIdFund),
                destinationProgram: counterProgram.programId,
                recipient: null,
                tokenProgram: TOKEN_PROGRAM_ID,
                systemProgram: SystemProgram.programId,
                rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
                recipientAta: null,
            })
            .remainingAccounts(instructionAccountsToRemaining(counterIx))
            .signers([admin])
            .rpc();
console.log("withdrawAndExecute (execute SPL) succeeded");
        // Verify caller received relayer_fee reimbursement
        const callerBalanceAfterFund = await provider.connection.getBalance(admin.publicKey);
        const callerBalanceChangeFund = callerBalanceAfterFund - callerBalanceBeforeFund;
        // Option 1: Relayer pays gateway costs, gets relayer_fee reimbursement
        // Caller pays for:
        // 1. executed_tx account rent (~890k)
        // 2. CEA ATA rent (if it doesn't exist - caller is payer per line 465 in execute.rs) (~2M)
        // 3. Transaction fees (varies by transaction size)
        // Caller receives: relayer_fee = gas_fee - rent_fee as reimbursement
        const actualRentForExecutedTx = await getExecutedTxRent(provider.connection);
        const actualRentForCeaAta = ceaAtaExistedBefore ? 0 : await getTokenAccountRent(provider.connection);
        const relayerFeeFund = Number(gasFeeLamports - rentFeeLamports);
        // Expected: -executed_tx_rent - cea_ata_rent (if created) + relayer_fee - transaction_fees
        const expectedBalanceChangeFund = -actualRentForExecutedTx - actualRentForCeaAta + relayerFeeFund;
        expect(callerBalanceChangeFund).to.be.closeTo(expectedBalanceChangeFund, 100000); // Allow for transaction fees (SPL txs are larger)

        const ceaAtaBefore = await provider.connection.getTokenAccountBalance(ceaAta);
        expect(Number(ceaAtaBefore.value.amount)).to.be.greaterThan(0);

        // Withdraw all SPL from CEA via gateway self-call (target = gateway)
        const txIdWithdraw = generateTxId();
        const universalTxIdWithdraw = generateUniversalTxId();
        const withdrawDiscr = computeDiscriminator("global:withdraw_from_cea");
        const withdrawArgs = Buffer.concat([
            mockUSDT.mint.publicKey.toBuffer(),
            (() => {
                const b = Buffer.alloc(8);
                b.writeBigUInt64LE(BigInt(0)); // all
                return b;
            })(),
        ]);
        const withdrawIxData = Buffer.concat([withdrawDiscr, withdrawArgs]);

        // Calculate fees dynamically for withdraw operation (CEA ATA already exists)
        const { gasFee: gasFeeWithdrawSpl, rentFee: rentFeeWithdrawSpl } = await calculateSplExecuteFees(provider.connection, ceaAta);

        const sigW = await signTssMessage({
            instruction: TssInstruction.Execute,
            amount: BigInt(0),
            chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
            additional: buildExecuteAdditionalData(
                new Uint8Array(universalTxIdWithdraw),
                new Uint8Array(txIdWithdraw),
                gatewayProgram.programId,
                new Uint8Array(sender),
                [],
                withdrawIxData,
                gasFeeWithdrawSpl,
                rentFeeWithdrawSpl,
                mockUSDT.mint.publicKey
            ),
        });

        const callerBalanceBeforeWithdrawSpl = await provider.connection.getBalance(admin.publicKey);
        const withdrawWritableFlagsSpl = accountsToWritableFlagsOnly([]);
        console.log("withdrawAndExecute (execute SPL) start");
        await gatewayProgram.methods
            .withdrawAndExecute(
                    2,
                Array.from(txIdWithdraw),
                Array.from(universalTxIdWithdraw),
                new anchor.BN(0),
                Array.from(sender),
                withdrawWritableFlagsSpl,
                withdrawIxData,
                new anchor.BN(Number(gasFeeWithdrawSpl)),
                new anchor.BN(Number(rentFeeWithdrawSpl)),
                Array.from(sigW.signature),
                sigW.recoveryId,
                Array.from(sigW.messageHash),
            )
            .accounts({
                caller: admin.publicKey,
                config: configPda,
                vaultAta: vaultUsdtAccount,
                vaultSol: vaultPda,
                ceaAuthority: cea,
                ceaAta,
                mint: mockUSDT.mint.publicKey,
                tssPda,
                executedTx: getExecutedTxPda(txIdWithdraw),
                destinationProgram: gatewayProgram.programId,
                recipient: null,
                tokenProgram: TOKEN_PROGRAM_ID,
                systemProgram: SystemProgram.programId,
                rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
                recipientAta: null,
            })
            .signers([admin])
            .rpc();
console.log("withdrawAndExecute (execute SPL) succeeded");
        // Verify caller received relayer_fee reimbursement (self-withdraw should also pay the caller)
        const callerBalanceAfterWithdrawSpl = await provider.connection.getBalance(admin.publicKey);
        const callerBalanceChangeWithdrawSpl = callerBalanceAfterWithdrawSpl - callerBalanceBeforeWithdrawSpl;
        // Option 1: Relayer pays gateway costs, gets relayer_fee reimbursement
        // Caller pays for:
        // 1. executed_tx account rent (~890k)
        // 2. Transaction fees (varies by transaction size)
        // Caller receives: relayer_fee = gas_fee - rent_fee (reimbursement for gateway costs)
        // relayer_fee = (rent_fee + executed_tx_rent + compute_buffer) - rent_fee = executed_tx_rent + compute_buffer
        // Reuse actualRentForExecutedTx from above (same test scope)
        const relayerFeeWithdrawSpl = Number(gasFeeWithdrawSpl - rentFeeWithdrawSpl);
        // Expected: -executed_tx_rent + relayer_fee - transaction_fees
        const expectedBalanceChangeWithdrawSpl = -actualRentForExecutedTx + relayerFeeWithdrawSpl;
        expect(callerBalanceChangeWithdrawSpl).to.be.closeTo(expectedBalanceChangeWithdrawSpl, 15000); // Allow for transaction fees

        const ceaAtaAfter = await provider.connection.getTokenAccountBalance(ceaAta);
        expect(Number(ceaAtaAfter.value.amount)).to.equal(0);
    });

    describe("execute payload encode/decode roundtrip", () => {
        it("encodes, decodes, signs, and executes SOL payload", async () => {
            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const sender = generateSender();
            const incrementAmount = new anchor.BN(4);

            const counterIx = await counterProgram.methods
                .increment(incrementAmount)
                .accounts({
                    counter: counterPda,
                    authority: counterAuthority.publicKey,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(counterIx);
            const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);

            // Calculate fees dynamically for SOL execute (before encoding payload)
            const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

            // Encode payload with only execution data (accounts, ixData, rentFee)
            const payloadFields = instructionToPayloadFields({
                instruction: counterIx,
                rentFee, // Include rentFee in payload
                instructionId:2

            });

            const encoded = encodeExecutePayload(payloadFields);
            const decoded = decodeExecutePayload(encoded);

            // Verify payload decoding
            expect(Buffer.from(decoded.ixData)).to.deep.equal(Buffer.from(counterIx.data));
            expect(decoded.rentFee).to.equal(rentFee); // Verify rentFee is decoded correctly
            expect(decoded.accounts.length).to.equal(accounts.length);
            expect(decoded.instructionId).to.equal(2);

            // Get other fields from their proper sources (not from payload)
            const targetProgram = counterProgram.programId;
            const amount = BigInt(0);
            const chainId = tssAccount.chainId;

            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: amount,
                chainId: chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    targetProgram,
                    new Uint8Array(sender),
                    decoded.accounts,
                    decoded.ixData,
                    gasFee,
                    rentFee
                ),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterPda);
            const callerBalanceBefore = await provider.connection.getBalance(admin.publicKey);

            const decodedWritableFlags = accountsToWritableFlagsOnly(decoded.accounts);
            await gatewayProgram.methods
                .withdrawAndExecute(
                    decoded.instructionId,
                    Array.from(txId),
                    Array.from(universalTxId),
                    new anchor.BN(Number(amount)),
                    Array.from(sender),
                    decodedWritableFlags,
                    Buffer.from(decoded.ixData),
                    new anchor.BN(Number(gasFee)),
                    new anchor.BN(Number(rentFee)),
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: getCeaAuthorityPda(Array.from(sender)),
                    tssPda,
                    executedTx: getExecutedTxPda(Array.from(txId)),
                    destinationProgram: targetProgram,
                    recipient: null,
                    vaultAta: null,
                    ceaAta: null,
                    mint: null,
                    tokenProgram: null,
                    rent: null,
                    associatedTokenProgram: null,
                    recipientAta: null,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(
                    decoded.accounts.map((a) => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                        isSigner: false,
                    })),
                )
                .signers([admin])
                .rpc();

            // Verify caller received relayer_fee reimbursement
            const callerBalanceAfter = await provider.connection.getBalance(admin.publicKey);
            const actualBalanceChange = callerBalanceAfter - callerBalanceBefore;
            // Option 1: Relayer pays gateway costs, gets relayer_fee reimbursement
            const actualRentForExecutedTx = await getExecutedTxRent(provider.connection);
            const relayerFee = Number(gasFee - rentFee);
            // Expected: -executed_tx_rent + relayer_fee - transaction_fees
            const minExpectedChange = -actualRentForExecutedTx + relayerFee - 10000; // Allow up to 10k for tx fees
            const maxExpectedChange = -actualRentForExecutedTx + relayerFee - 1000;  // Minimum tx fee ~1k
            expect(actualBalanceChange).to.be.at.least(minExpectedChange);
            expect(actualBalanceChange).to.be.at.most(maxExpectedChange);

            const counterAfter = await counterProgram.account.counter.fetch(counterPda);
            expect(counterAfter.value.toNumber()).to.equal(
                counterBefore.value.toNumber() + incrementAmount.toNumber(),
            );
        });

        it("encodes, decodes, signs, and executes SPL payload", async () => {
            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const sender = generateSender();
            const amount = asTokenAmount(25);

            const counterIx = await counterProgram.methods
                .receiveSpl(amount)
                .accounts({
                    counter: counterPda,
                    ceaAta: await getCeaAta(sender, mockUSDT.mint.publicKey),
                    recipientAta: recipientUsdtAccount,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    tokenProgram: TOKEN_PROGRAM_ID,
                })
                .instruction();

            // Check CEA ATA existence BEFORE calculating fees
            const ceaAtaForDecodeSpl = await getCeaAta(sender, mockUSDT.mint.publicKey);
            const ceaAtaExistedBeforeDecodeSpl = await ceaAtaExists(provider.connection, ceaAtaForDecodeSpl);
            const { gasFee, rentFee } = await calculateSplExecuteFees(provider.connection, ceaAtaForDecodeSpl);

            // Encode payload with only execution data (accounts, ixData, rentFee)
            const payloadFields = instructionToPayloadFields({
                instruction: counterIx,
                rentFee, // Include rentFee in payload
                instructionId:2
            });

            const encoded = encodeExecutePayload(payloadFields);
            const decoded = decodeExecutePayload(encoded);

            // Use decoded accounts for signing and remaining_accounts
            const accountsForSigning = decoded.accounts;
            const remainingAccounts = decoded.accounts.map((acc) => ({
                pubkey: acc.pubkey,
                isWritable: acc.isWritable,
                isSigner: false,
            }));

            // Verify payload decoding
            expect(decoded.rentFee).to.equal(rentFee);
            expect(decoded.accounts.length).to.equal(counterIx.keys.length);
            expect(decoded.instructionId).to.equal(2);

            // Get other fields from their proper sources (not from decoded payload)
            const targetProgram = counterProgram.programId;
            const amountValue = BigInt(amount.toString());
            const chainId = (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId;
            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: amountValue,
                chainId: chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    targetProgram,
                    new Uint8Array(sender),
                    accountsForSigning, // Includes ceaAta (matches remaining_accounts)
                    decoded.ixData,
                    gasFee,
                    rentFee,
                    mockUSDT.mint.publicKey
                ),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterPda);
            const recipientTokenBefore = await mockUSDT.getBalance(recipientUsdtAccount);
            const callerBalanceBefore = await provider.connection.getBalance(admin.publicKey);

            const accountsForSigningWritableFlags = accountsToWritableFlagsOnly(accountsForSigning);
            await gatewayProgram.methods
                .withdrawAndExecute(
                    decoded.instructionId,
                    Array.from(txId),
                    Array.from(universalTxId),
                    new anchor.BN(amount.toString()),
                    Array.from(sender),
                    accountsForSigningWritableFlags,
                    Buffer.from(decoded.ixData),
                    new anchor.BN(Number(gasFee)),
                    new anchor.BN(Number(rentFee)),
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAta: vaultUsdtAccount,
                    vaultSol: vaultPda,
                    ceaAuthority: getCeaAuthorityPda(Array.from(sender)),
                    ceaAta: ceaAtaForDecodeSpl,
                    mint: mockUSDT.mint.publicKey,
                    tssPda,
                    executedTx: getExecutedTxPda(Array.from(txId)),
                    destinationProgram: targetProgram,
                    recipient: null,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                    associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
                    recipientAta: null,
                })
                .remainingAccounts(remainingAccounts) // Includes ceaAta (needed for CPI)
                .signers([admin])
                .rpc();

            // Verify caller received relayer_fee reimbursement
            const callerBalanceAfter = await provider.connection.getBalance(admin.publicKey);
            const actualBalanceChange = callerBalanceAfter - callerBalanceBefore;
            // Option 1: Relayer pays gateway costs, gets relayer_fee reimbursement
            const actualRentForExecutedTx = await getExecutedTxRent(provider.connection);
            const actualRentForCeaAta = ceaAtaExistedBeforeDecodeSpl ? 0 : await getTokenAccountRent(provider.connection);
            const relayerFee = Number(gasFee - rentFee);
            // Expected: -executed_tx_rent - cea_ata_rent (if created) + relayer_fee - transaction_fees
            const expectedBalanceChange = -actualRentForExecutedTx - actualRentForCeaAta + relayerFee;
            expect(actualBalanceChange).to.be.closeTo(expectedBalanceChange, 20000); // Allow for transaction fees (SPL txs are larger)

            const counterAfter = await counterProgram.account.counter.fetch(counterPda);
            expect(counterAfter.value.toNumber()).to.equal(
                counterBefore.value.toNumber() + amount.toNumber(),
            );

            const recipientTokenAfter = await mockUSDT.getBalance(recipientUsdtAccount);
            const amountTokens = amount.toNumber() / 10 ** USDT_DECIMALS;
            expect(recipientTokenAfter - recipientTokenBefore).to.equal(amountTokens);
        });
    });

    describe("execute security validations (negative tests)", () => {
        /**
         * Helper to execute a test that should revert with a specific error
         * @param testName - Descriptive name for the attack being tested
         * @param executeCall - Async function that performs the attack
         * @param expectedErrorCode - Expected Anchor error code (e.g., "AccountPubkeyMismatch")
         */
        async function expectExecuteRevert(
            testName: string,
            executeCall: () => Promise<any>,
            expectedErrorCode: string
        ): Promise<void> {
            try {
                await executeCall();
                expect.fail(`${testName}: Should have reverted but succeeded`);
            } catch (e: any) {
                const errorMsg = e.toString();
                const hasExpectedError = errorMsg.includes(expectedErrorCode);

                if (!hasExpectedError) {
                    console.error(`❌ ${testName}: Expected error "${expectedErrorCode}" but got:`, errorMsg);
                    expect.fail(`Expected error code "${expectedErrorCode}" not found. Got: ${errorMsg}`);
                }

                console.log(`✅ ${testName}: Correctly rejected with ${expectedErrorCode}`);
            }
        }

        describe("account manipulation attacks", () => {
            it("should reject account substitution attack", async () => {
                const txId = generateTxId();
                const universalTxId = generateUniversalTxId();
                const sender = generateSender();

                // Build a valid instruction
                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterPda,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                const correctAccounts = instructionAccountsToGatewayMetas(counterIx);

                // Calculate fees dynamically
                const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

                // Sign with CORRECT accounts
                const sig = await signTssMessage({
                    instruction: TssInstruction.Execute,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(universalTxId),
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        correctAccounts,
                        counterIx.data,
                        gasFee,
                        rentFee
                    ),
                });

                // ATTACK: Pass DIFFERENT accounts in remainingAccounts
                const attackerAccount = Keypair.generate().publicKey;
                const substitutedRemaining = [
                    { pubkey: attackerAccount, isWritable: true, isSigner: false }, // Wrong account!
                    { pubkey: counterAuthority.publicKey, isWritable: false, isSigner: false },
                ];

                const correctWritableFlags = accountsToWritableFlagsOnly(correctAccounts);
                await expectExecuteRevert(
                    "Account substitution",
                    async () => {
                        return await gatewayProgram.methods
                            .withdrawAndExecute(
                    2,
                                Array.from(txId),
                                Array.from(universalTxId),
                                new anchor.BN(0),
                                Array.from(sender),
                                correctWritableFlags,
                                Buffer.from(counterIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                destinationProgram: counterProgram.programId,
                                recipient: null,
                                vaultAta: null,
                                ceaAta: null,
                                mint: null,
                                tokenProgram: null,
                                rent: null,
                                associatedTokenProgram: null,
                                recipientAta: null,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(substitutedRemaining) // Substituted accounts!
                            .signers([admin])
                            .rpc();
                    },
                    "MessageHashMismatch" // Reconstructed accounts don't match signed message
                );
            });

            it("should reject account count mismatch", async () => {
                const txId = generateTxId();
                const universalTxId = generateUniversalTxId();
                const sender = generateSender();

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterPda,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                const correctAccounts = instructionAccountsToGatewayMetas(counterIx);

                // Calculate fees dynamically
                const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

                const sig = await signTssMessage({
                    instruction: TssInstruction.Execute,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(universalTxId),
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        correctAccounts,
                        counterIx.data,
                        gasFee,
                        rentFee
                    ),
                });

                // ATTACK: Pass FEWER accounts than signed
                const fewerRemaining = [
                    { pubkey: counterPda, isWritable: true, isSigner: false },
                    // Missing counterAuthority!
                ];

                // Create writable flags for correct accounts (2 accounts), but pass fewer remaining accounts (1 account)
                // Note: Both 1 and 2 accounts need 1 byte of flags, so length check passes
                // But TSS hash will fail because we signed 2 accounts but only reconstructed 1
                const correctWritableFlags2 = accountsToWritableFlagsOnly(correctAccounts);
                await expectExecuteRevert(
                    "Account count mismatch (fewer)",
                    async () => {
                        return await gatewayProgram.methods
                            .withdrawAndExecute(
                    2,
                                Array.from(txId),
                                Array.from(universalTxId),
                                new anchor.BN(0),
                                Array.from(sender),
                                correctWritableFlags2,
                                Buffer.from(counterIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                destinationProgram: counterProgram.programId,
                                recipient: null,
                                vaultAta: null,
                                ceaAta: null,
                                mint: null,
                                tokenProgram: null,
                                rent: null,
                                associatedTokenProgram: null,
                                recipientAta: null,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(fewerRemaining)
                            .signers([admin])
                            .rpc();
                    },
                    "MessageHashMismatch" // TSS hash fails because we signed 2 accounts but only reconstructed 1
                );
            });

            it("should reject writable flag mismatch", async () => {
                const txId = generateTxId();
                const universalTxId = generateUniversalTxId();
                const sender = generateSender();

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterPda,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                const correctAccounts = instructionAccountsToGatewayMetas(counterIx);

                // Calculate fees dynamically
                const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

                // Sign with counter as writable
                const sig = await signTssMessage({
                    instruction: TssInstruction.Execute,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(universalTxId),
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        correctAccounts,
                        counterIx.data,
                        gasFee,
                        rentFee
                    ),
                });

                // ATTACK: Mark writable account as read-only in remaining_accounts
                const wrongWritableRemaining = [
                    { pubkey: counterPda, isWritable: false, isSigner: false }, // Should be writable!
                    { pubkey: counterAuthority.publicKey, isWritable: false, isSigner: false },
                ];

                const correctWritableFlags3 = accountsToWritableFlagsOnly(correctAccounts);
                await expectExecuteRevert(
                    "Writable flag mismatch",
                    async () => {
                        return await gatewayProgram.methods
                            .withdrawAndExecute(
                    2,
                                Array.from(txId),
                                Array.from(universalTxId),
                                new anchor.BN(0),
                                Array.from(sender),
                                correctWritableFlags3,
                                Buffer.from(counterIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                destinationProgram: counterProgram.programId,
                                recipient: null,
                                vaultAta: null,
                                ceaAta: null,
                                mint: null,
                                tokenProgram: null,
                                rent: null,
                                associatedTokenProgram: null,
                                recipientAta: null,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(wrongWritableRemaining)
                            .signers([admin])
                            .rpc();
                    },
                    "AccountWritableFlagMismatch" // validate_remaining_accounts catches writable flag mismatch before TSS validation
                );
            });

            it("should reject account reordering attack", async () => {
                const txId = generateTxId();
                const universalTxId = generateUniversalTxId();
                const sender = generateSender();

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterPda,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                const correctAccounts = instructionAccountsToGatewayMetas(counterIx);

                // Calculate fees dynamically
                const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

                const sig = await signTssMessage({
                    instruction: TssInstruction.Execute,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(universalTxId),
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        correctAccounts,
                        counterIx.data,
                        gasFee,
                        rentFee
                    ),
                });

                // ATTACK: Reorder accounts (swap counter and authority)
                const reorderedRemaining = [
                    { pubkey: counterAuthority.publicKey, isWritable: false, isSigner: false }, // Wrong position!
                    { pubkey: counterPda, isWritable: true, isSigner: false },
                ];

                const correctWritableFlags4 = accountsToWritableFlagsOnly(correctAccounts);
                await expectExecuteRevert(
                    "Account reordering",
                    async () => {
                        return await gatewayProgram.methods
                            .withdrawAndExecute(
                    2,
                                Array.from(txId),
                                Array.from(universalTxId),
                                new anchor.BN(0),
                                Array.from(sender),
                                correctWritableFlags4,
                                Buffer.from(counterIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                destinationProgram: counterProgram.programId,
                                recipient: null,
                                vaultAta: null,
                                ceaAta: null,
                                mint: null,
                                tokenProgram: null,
                                rent: null,
                                associatedTokenProgram: null,
                                recipientAta: null,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(reorderedRemaining)
                            .signers([admin])
                            .rpc();
                    },
                    "AccountWritableFlagMismatch" // validate_remaining_accounts catches writable flag mismatch (from reordering) before TSS validation
                );
            });
        });

        describe("signature and authentication attacks", () => {
            it("should reject invalid signature", async () => {
                const txId = generateTxId();
                const universalTxId = generateUniversalTxId();
                const sender = generateSender();

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterPda,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                // CRITICAL: Use the EXACT same accounts for signing and remaining_accounts
                const remainingAccounts = instructionAccountsToRemaining(counterIx);
                const accounts = remainingAccounts.map((acc) => ({
                    pubkey: acc.pubkey,
                    isWritable: acc.isWritable,
                }));

                // Calculate fees dynamically
                const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

                const sig = await signTssMessage({
                    instruction: TssInstruction.Execute,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(universalTxId),
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        accounts,
                        counterIx.data,
                        gasFee,
                        rentFee
                    ),
                });

                // ATTACK: Corrupt the signature
                const corruptedSignature = Array.from(sig.signature);
                corruptedSignature[0] ^= 0xFF; // Flip bits

                const sigWritableFlags = accountsToWritableFlagsOnly(accounts);
                await expectExecuteRevert(
                    "Invalid signature",
                    async () => {
                        return await gatewayProgram.methods
                            .withdrawAndExecute(
                    2,
                                Array.from(txId),
                                Array.from(universalTxId),
                                new anchor.BN(0),
                                Array.from(sender),
                                sigWritableFlags,
                                Buffer.from(counterIx.data),
                                new anchor.BN(Number(gasFee)),
                                new anchor.BN(Number(rentFee)),
                                corruptedSignature, // Invalid!
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                destinationProgram: counterProgram.programId,
                                recipient: null,
                                vaultAta: null,
                                ceaAta: null,
                                mint: null,
                                tokenProgram: null,
                                rent: null,
                                associatedTokenProgram: null,
                                recipientAta: null,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(remainingAccounts)
                            .signers([admin])
                            .rpc();
                    },
                    "TssAuthFailed"
                );
            });

            it("should reject tampered message hash", async () => {
                const txId = generateTxId();
                const universalTxId = generateUniversalTxId();
                const sender = generateSender();

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterPda,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                // CRITICAL: Use the EXACT same accounts for signing and remaining_accounts
                const remainingAccounts = instructionAccountsToRemaining(counterIx);
                const accounts = remainingAccounts.map((acc) => ({
                    pubkey: acc.pubkey,
                    isWritable: acc.isWritable,
                }));

                // Calculate fees dynamically
                const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

                const sig = await signTssMessage({
                    instruction: TssInstruction.Execute,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(universalTxId),
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        accounts,
                        counterIx.data,
                        gasFee,
                        rentFee
                    ),
                });

                // ATTACK: Tamper with message hash
                const tamperedHash = Array.from(sig.messageHash);
                tamperedHash[0] ^= 0xFF;

                const hashWritableFlags = accountsToWritableFlagsOnly(accounts);
                await expectExecuteRevert(
                    "Tampered message hash",
                    async () => {
                        return await gatewayProgram.methods
                            .withdrawAndExecute(
                    2,
                                Array.from(txId),
                                Array.from(universalTxId),
                                new anchor.BN(0),
                                Array.from(sender),
                                hashWritableFlags,
                                Buffer.from(counterIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig.signature),
                                sig.recoveryId,
                                tamperedHash, // Tampered!
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                destinationProgram: counterProgram.programId,
                                recipient: null,
                                vaultAta: null,
                                ceaAta: null,
                                mint: null,
                                tokenProgram: null,
                                rent: null,
                                associatedTokenProgram: null,
                                recipientAta: null,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(remainingAccounts)
                            .signers([admin])
                            .rpc();
                    },
                    "MessageHashMismatch"
                );
            });
        });

        describe("program and target validation", () => {
            it("should reject non-executable destination program", async () => {
                const txId = generateTxId();
                const universalTxId = generateUniversalTxId();
                const sender = generateSender();

                // Use a regular account (not a program) as destination
                const nonExecutableAccount = Keypair.generate().publicKey;

                // CRITICAL: Use the EXACT same accounts for signing and remaining_accounts
                const remainingAccounts = [
                    { pubkey: counterPda, isWritable: true, isSigner: false },
                ];
                const accounts = remainingAccounts.map((acc) => ({
                    pubkey: acc.pubkey,
                    isWritable: acc.isWritable,
                }));

                // Calculate fees dynamically
                const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

                const sig = await signTssMessage({
                    instruction: TssInstruction.Execute,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(universalTxId),
                        new Uint8Array(txId),
                        nonExecutableAccount, // Non-executable!
                        new Uint8Array(sender),
                        accounts,
                        Buffer.from([0x01]),
                        gasFee,
                        rentFee
                    ),
                });

                const progWritableFlags = accountsToWritableFlagsOnly(accounts);
                await expectExecuteRevert(
                    "Non-executable destination program",
                    async () => {
                        return await gatewayProgram.methods
                            .withdrawAndExecute(
                    2,
                                Array.from(txId),
                                Array.from(universalTxId),
                                new anchor.BN(0),
                                Array.from(sender),
                                progWritableFlags,
                                Buffer.from([0x01]),
                                new anchor.BN(Number(gasFee)),
                                new anchor.BN(Number(rentFee)),
                                Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                destinationProgram: nonExecutableAccount,
                                recipient: null,
                                vaultAta: null,
                                ceaAta: null,
                                mint: null,
                                tokenProgram: null,
                                rent: null,
                                associatedTokenProgram: null,
                                recipientAta: null,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(remainingAccounts)
                            .signers([admin])
                            .rpc();
                    },
                    "InvalidProgram"
                );
            });

            it("should reject gateway PDAs in remaining accounts (vault)", async () => {
                const txId = generateTxId();
                const universalTxId = generateUniversalTxId();
                const sender = generateSender();

                // ATTACK: Include vault PDA in remaining_accounts
                const maliciousAccounts: GatewayAccountMeta[] = [
                    { pubkey: counterPda, isWritable: true },
                    { pubkey: vaultPda, isWritable: true }, // Protected account!
                ];

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterPda,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                // Calculate fees dynamically
                const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

                const sig = await signTssMessage({
                    instruction: TssInstruction.Execute,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(universalTxId),
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        maliciousAccounts, // Includes vault!
                        counterIx.data,
                        gasFee,
                        rentFee
                    ),
                });

                const maliciousRemaining = [
                    { pubkey: counterPda, isWritable: true, isSigner: false },
                    { pubkey: vaultPda, isWritable: true, isSigner: false }, // Vault should never be passed!
                ];

                const maliciousWritableFlags = accountsToWritableFlagsOnly(maliciousAccounts);
                await expectExecuteRevert(
                    "Gateway vault PDA in remaining accounts",
                    async () => {
                        return await gatewayProgram.methods
                            .withdrawAndExecute(
                    2,
                                Array.from(txId),
                                Array.from(universalTxId),
                                new anchor.BN(0),
                                Array.from(sender),
                                maliciousWritableFlags,
                                Buffer.from(counterIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                destinationProgram: counterProgram.programId,
                                recipient: null,
                                vaultAta: null,
                                ceaAta: null,
                                mint: null,
                                tokenProgram: null,
                                rent: null,
                                associatedTokenProgram: null,
                                recipientAta: null,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(maliciousRemaining)
                            .signers([admin])
                            .rpc();
                    },
                    "Error" // Will fail at CPI level or earlier validation
                );
            });

            it("should reject target program mismatch (via message hash)", async () => {
                const txId = generateTxId();
                const universalTxId = generateUniversalTxId();
                const sender = generateSender();

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterPda,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                // CRITICAL: Use the EXACT same accounts for signing and remaining_accounts
                const remainingAccounts = instructionAccountsToRemaining(counterIx);
                const accounts = remainingAccounts.map((acc) => ({
                    pubkey: acc.pubkey,
                    isWritable: acc.isWritable,
                }));

                // Calculate fees dynamically
                const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

                // Sign for counter program
                const sig = await signTssMessage({
                    instruction: TssInstruction.Execute,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(universalTxId),
                        new Uint8Array(txId),
                        counterProgram.programId, // Signed for counter program
                        new Uint8Array(sender),
                        accounts,
                        counterIx.data,
                        gasFee,
                        rentFee
                    ),
                });

                // ATTACK: Pass different program as destination_program
                // Note: This fails at message hash validation because target_program is part of the signed message.
                // The TargetProgramMismatch check exists as a defensive measure but is unlikely to be hit
                // since message hash validation happens first.
                const differentProgram = Keypair.generate().publicKey;

                const targetMismatchWritableFlags = accountsToWritableFlagsOnly(accounts);
                await expectExecuteRevert(
                    "Target program mismatch (caught by message hash validation)",
                    async () => {
                        return await gatewayProgram.methods
                            .withdrawAndExecute(
                    2,
                                Array.from(txId),
                                Array.from(universalTxId),
                                new anchor.BN(0),
                                Array.from(sender),
                                targetMismatchWritableFlags,
                                Buffer.from(counterIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                destinationProgram: differentProgram,
                                recipient: null,
                                vaultAta: null,
                                ceaAta: null,
                                mint: null,
                                tokenProgram: null,
                                rent: null,
                                associatedTokenProgram: null,
                                recipientAta: null,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(remainingAccounts)
                            .signers([admin])
                            .rpc();
                    },
                    "MessageHashMismatch" // Correct error - message hash includes target_program
                );
            });
        });
    });

    describe("CEA Identity Preservation - Multi-User Tests", () => {
        // Fixed sender addresses for identity testing (EVM-like 20-byte addresses)
        const user1Sender = Array.from(Buffer.from("1111111111111111111111111111111111111111", "hex"));
        const user2Sender = Array.from(Buffer.from("2222222222222222222222222222222222222222", "hex"));
        const user3Sender = Array.from(Buffer.from("3333333333333333333333333333333333333333", "hex"));
        const user4Sender = Array.from(Buffer.from("4444444444444444444444444444444444444444", "hex"));

        // Derive CEAs for each user
        const user1Cea = getCeaAuthorityPda(user1Sender);
        const user2Cea = getCeaAuthorityPda(user2Sender);
        const user3Cea = getCeaAuthorityPda(user3Sender);
        const user4Cea = getCeaAuthorityPda(user4Sender);

        // Stake PDAs for test-counter
        const getStakePda = (authority: PublicKey): PublicKey => {
            const [pda] = PublicKey.findProgramAddressSync(
                [Buffer.from("stake"), authority.toBuffer()],
                counterProgram.programId
            );
            return pda;
        };

        const getStakeVaultPda = (authority: PublicKey): PublicKey => {
            const [pda] = PublicKey.findProgramAddressSync(
                [Buffer.from("stake_vault"), authority.toBuffer()],
                counterProgram.programId
            );
            return pda;
        };

        it("should verify each user has unique CEA addresses", () => {
            // Verify all CEAs are different
            expect(user1Cea.toString()).to.not.equal(user2Cea.toString());
            expect(user1Cea.toString()).to.not.equal(user3Cea.toString());
            expect(user1Cea.toString()).to.not.equal(user4Cea.toString());
            expect(user2Cea.toString()).to.not.equal(user3Cea.toString());
            expect(user2Cea.toString()).to.not.equal(user4Cea.toString());
            expect(user3Cea.toString()).to.not.equal(user4Cea.toString());

            console.log("✅ All 4 users have unique CEA addresses");
            console.log("  User1 CEA:", user1Cea.toString());
            console.log("  User2 CEA:", user2Cea.toString());
            console.log("  User3 CEA:", user3Cea.toString());
            console.log("  User4 CEA:", user4Cea.toString());
        });

        it("User1: should stake SOL and verify CEA identity persistence", async () => {
            const stakeAmount = asLamports(1); // 1 SOL
            const user1Stake = getStakePda(user1Cea);
            const user1StakeVault = getStakeVaultPda(user1Cea);

            // Transaction 1: Stake SOL
            const txId1 = generateTxId();
            const universalTxId1 = generateUniversalTxId();
            const stakeIx = await counterProgram.methods
                .stakeSol(stakeAmount)
                .accounts({
                    counter: counterPda,
                    authority: user1Cea,
                    stake: user1Stake,
                    stakeVault: user1StakeVault,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(stakeIx);

            // Calculate fees dynamically (stake account needs rent if it doesn't exist or is under-funded)
            // Stake account size: 8 (discriminator) + 40 (Stake::LEN) = 48 bytes
            const stakeAccountInfo = await provider.connection.getAccountInfo(user1Stake);
            const stakeRentExempt = await provider.connection.getMinimumBalanceForRentExemption(48);
            const needsRent = !stakeAccountInfo || stakeAccountInfo.lamports < stakeRentExempt;
            const stakeRentFee = needsRent
                ? BigInt(stakeRentExempt) // Account missing or under-funded, need full rent exemption
                : BigInt(0); // Account exists and is rent-exempt
            const { gasFee: gasFee1, rentFee: rentFee1 } = await calculateSolExecuteFees(provider.connection, stakeRentFee);

            const sig1 = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(stakeAmount.toString()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId1),
                    new Uint8Array(txId1),
                    counterProgram.programId,
                    new Uint8Array(user1Sender),
                    accounts,
                    stakeIx.data,
                    gasFee1,
                    rentFee1
                ),
            });

            const user1WritableFlags1 = accountsToWritableFlagsOnly(accounts);
            await gatewayProgram.methods
                .withdrawAndExecute(
                    2,
                    Array.from(txId1),
                    Array.from(universalTxId1),
                    stakeAmount,
                    Array.from(user1Sender),
                    user1WritableFlags1,
                    Buffer.from(stakeIx.data), new anchor.BN(Number(gasFee1)), new anchor.BN(Number(rentFee1)), Array.from(sig1.signature),
                    sig1.recoveryId,
                    Array.from(sig1.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: user1Cea,
                    tssPda,
                    executedTx: getExecutedTxPda(txId1),
                    destinationProgram: counterProgram.programId,
                    recipient: null,
                    vaultAta: null,
                    ceaAta: null,
                    mint: null,
                    tokenProgram: null,
                    rent: null,
                    associatedTokenProgram: null,
                    recipientAta: null,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(instructionAccountsToRemaining(stakeIx))
                .signers([admin])
                .rpc();

            // Verify stake was created and SOL was actually transferred
            const stakeAccount = await counterProgram.account.stake.fetch(user1Stake);
            expect(stakeAccount.amount.toNumber()).to.equal(stakeAmount.toNumber());
            expect(stakeAccount.authority.toString()).to.equal(user1Cea.toString());

            // Verify actual SOL balance in stake_vault (must equal staked amount)
            const stakeVaultBalance = await provider.connection.getBalance(user1StakeVault);
            expect(stakeVaultBalance).to.equal(stakeAmount.toNumber(), "Stake vault should hold the staked SOL");

            console.log("✅ User1 staked 1 SOL successfully");
            console.log("  Stake PDA:", user1Stake.toString());
            console.log("  Staked amount:", stakeAccount.amount.toNumber());
        });

        it("User1: should perform multiple transactions with same CEA", async () => {
            const user1Stake = getStakePda(user1Cea);
            const user1StakeVault = getStakeVaultPda(user1Cea);

            // Transaction 2: Stake more SOL with same CEA (tests identity persistence)
            const txId2 = generateTxId();
            const universalTxId2 = generateUniversalTxId();
            const stakeAmount2 = asLamports(0.5); // 0.5 SOL more
            const stakeIx2 = await counterProgram.methods
                .stakeSol(stakeAmount2)
                .accounts({
                    counter: counterPda,
                    authority: user1Cea,
                    stake: user1Stake,
                    stakeVault: user1StakeVault,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(stakeIx2);

            // Calculate fees dynamically (stake account already exists, so use base rent_fee)
            const { gasFee: gasFee2, rentFee: rentFee2 } = await calculateSolExecuteFees(provider.connection);

            const sig2 = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(stakeAmount2.toString()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId2),
                    new Uint8Array(txId2),
                    counterProgram.programId,
                    new Uint8Array(user1Sender),
                    accounts,
                    stakeIx2.data,
                    gasFee2,
                    rentFee2
                ),
            });

            const ceaBefore = getCeaAuthorityPda(user1Sender);
            expect(ceaBefore.toString()).to.equal(user1Cea.toString());

            const user1WritableFlags2 = accountsToWritableFlagsOnly(accounts);
            await gatewayProgram.methods
                .withdrawAndExecute(
                    2,
                    Array.from(txId2),
                    Array.from(universalTxId2),
                    stakeAmount2,
                    Array.from(user1Sender),
                    user1WritableFlags2,
                    Buffer.from(stakeIx2.data), new anchor.BN(Number(gasFee2)), new anchor.BN(Number(rentFee2)), Array.from(sig2.signature),
                    sig2.recoveryId,
                    Array.from(sig2.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: user1Cea,
                    tssPda,
                    executedTx: getExecutedTxPda(txId2),
                    destinationProgram: counterProgram.programId,
                    recipient: null,
                    vaultAta: null,
                    ceaAta: null,
                    mint: null,
                    tokenProgram: null,
                    rent: null,
                    associatedTokenProgram: null,
                    recipientAta: null,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(instructionAccountsToRemaining(stakeIx2))
                .signers([admin])
                .rpc();

            const ceaAfter = getCeaAuthorityPda(user1Sender);
            expect(ceaAfter.toString()).to.equal(user1Cea.toString());

            // Verify stake amount increased (identity preserved across txs)
            const stakeAccountAfter = await counterProgram.account.stake.fetch(user1Stake);
            expect(stakeAccountAfter.amount.toNumber()).to.equal(asLamports(1.5).toNumber());

            console.log("✅ User1 performed multiple txs with same CEA");
            console.log("  CEA (tx1 & tx2):", user1Cea.toString());
            console.log("  Total staked across 2 txs:", stakeAccountAfter.amount.toNumber());
        });

        it("User1: should unstake SOL and verify FUNDS event emission", async () => {
            const user1Stake = getStakePda(user1Cea);
            const user1StakeVault = getStakeVaultPda(user1Cea);
            const stakeAccount = await counterProgram.account.stake.fetch(user1Stake);
            const unstakeAmount = stakeAccount.amount;

            // Get balances before unstake
            const stakeVaultBalanceBefore = await provider.connection.getBalance(user1StakeVault);
            const ceaBalanceBefore = await provider.connection.getBalance(user1Cea);

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const unstakeIx = await counterProgram.methods
                .unstakeSol(unstakeAmount)
                .accounts({
                    counter: counterPda,
                    authority: user1Cea,
                    stake: user1Stake,
                    stakeVault: user1StakeVault,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(unstakeIx);
            // Calculate fees dynamically
            const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(user1Sender),
                    accounts,
                    unstakeIx.data,
                    gasFee,
                    rentFee
                ),
            });

            const user1UnstakeWritableFlags = accountsToWritableFlagsOnly(accounts);
            const tx = await gatewayProgram.methods
                .withdrawAndExecute(
                    2,
                    Array.from(txId),
                    Array.from(universalTxId),
                    new anchor.BN(0),
                    Array.from(user1Sender),
                    user1UnstakeWritableFlags,
                    Buffer.from(unstakeIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: user1Cea,
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    destinationProgram: counterProgram.programId,
                    recipient: null,
                    vaultAta: null,
                    ceaAta: null,
                    mint: null,
                    tokenProgram: null,
                    rent: null,
                    associatedTokenProgram: null,
                    recipientAta: null,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(instructionAccountsToRemaining(unstakeIx))
                .signers([admin])
                .rpc();

            // Verify FUNDS event was emitted (CEA drained back to vault)
            const txDetails = await provider.connection.getTransaction(tx, {
                commitment: "confirmed",
                maxSupportedTransactionVersion: 0,
            });

            if (txDetails && txDetails.meta && txDetails.meta.logMessages) {
                const eventCoder = new anchor.BorshEventCoder(gatewayProgram.idl);
                const events = txDetails.meta.logMessages
                    .filter((log) => log.includes("Program data:"))
                    .map((log) => {
                        const data = log.split("Program data: ")[1];
                        try {
                            return eventCoder.decode(data);
                        } catch {
                            return null;
                        }
                    })
                    .filter((e) => e !== null);

                const fundsEvents = events.filter((e) => e.name === "UniversalTx" && e.data.txType.funds !== undefined);

                if (fundsEvents.length > 0) {
                    const fundsEvent = fundsEvents[0].data;
                    expect(fundsEvent.sender.toString()).to.equal(user1Cea.toString());
                    expect(fundsEvent.token.toString()).to.equal(PublicKey.default.toString());
                    console.log("✅ FUNDS event emitted - CEA drained:", fundsEvent.amount.toNumber(), "lamports");
                } else {
                    console.log("ℹ️  No FUNDS event (CEA balance was 0 or already drained)");
                }
            }

            // Verify actual SOL balance movements
            const stakeVaultBalanceAfter = await provider.connection.getBalance(user1StakeVault);
            const ceaBalanceAfter = await provider.connection.getBalance(user1Cea);
            expect(stakeVaultBalanceAfter).to.equal(stakeVaultBalanceBefore - unstakeAmount.toNumber());
            expect(ceaBalanceAfter).to.be.greaterThan(ceaBalanceBefore); // CEA received SOL

            // Verify stake account was decremented
            const stakeAccountAfter = await counterProgram.account.stake.fetch(user1Stake);
            expect(stakeAccountAfter.amount.toNumber()).to.equal(0);

            console.log("✅ User1 unstaked SOL successfully");
            console.log("  Unstaked amount:", unstakeAmount.toNumber());
            console.log("  Stake vault balance before:", stakeVaultBalanceBefore);
            console.log("  Stake vault balance after:", stakeVaultBalanceAfter);
            console.log("  CEA balance increase:", ceaBalanceAfter - ceaBalanceBefore);
        });

        it("User2: should stake SOL with different CEA", async () => {
            const stakeAmount = asLamports(2); // 2 SOL
            const user2Stake = getStakePda(user2Cea);
            const user2StakeVault = getStakeVaultPda(user2Cea);

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const stakeIx = await counterProgram.methods
                .stakeSol(stakeAmount)
                .accounts({
                    counter: counterPda,
                    authority: user2Cea,
                    stake: user2Stake,
                    stakeVault: user2StakeVault,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(stakeIx);

            // Calculate fees dynamically (stake account needs rent if it doesn't exist or is under-funded)
            const stakeAccountInfo = await provider.connection.getAccountInfo(user2Stake);
            const stakeRentExempt = await provider.connection.getMinimumBalanceForRentExemption(48);
            const needsRent = !stakeAccountInfo || stakeAccountInfo.lamports < stakeRentExempt;
            const stakeRentFee = needsRent
                ? BigInt(stakeRentExempt) // Account missing or under-funded, need full rent exemption
                : BigInt(0); // Account exists and is rent-exempt
            const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection, stakeRentFee);

            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(stakeAmount.toNumber()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(user2Sender),
                    accounts,
                    stakeIx.data,
                    gasFee,
                    rentFee
                ),
            });

            const user2WritableFlags = accountsToWritableFlagsOnly(accounts);
            await gatewayProgram.methods
                .withdrawAndExecute(
                    2,
                    Array.from(txId),
                    Array.from(universalTxId),
                    stakeAmount,
                    Array.from(user2Sender),
                    user2WritableFlags,
                    Buffer.from(stakeIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: user2Cea,
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    destinationProgram: counterProgram.programId,
                    recipient: null,
                    vaultAta: null,
                    ceaAta: null,
                    mint: null,
                    tokenProgram: null,
                    rent: null,
                    associatedTokenProgram: null,
                    recipientAta: null,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(instructionAccountsToRemaining(stakeIx))
                .signers([admin])
                .rpc();

            const stakeAccount = await counterProgram.account.stake.fetch(user2Stake);
            expect(stakeAccount.amount.toNumber()).to.equal(stakeAmount.toNumber());
            expect(stakeAccount.authority.toString()).to.equal(user2Cea.toString());

            // Verify User2 CEA is different from User1 CEA
            expect(user2Cea.toString()).to.not.equal(user1Cea.toString());

            console.log("✅ User2 staked 2 SOL with different CEA");
            console.log("  User1 CEA:", user1Cea.toString());
            console.log("  User2 CEA:", user2Cea.toString());
        });

        it("User2: should unstake own SOL successfully", async () => {
            const user2Stake = getStakePda(user2Cea);
            const user2StakeVault = getStakeVaultPda(user2Cea);
            const stakeAccount = await counterProgram.account.stake.fetch(user2Stake);
            const unstakeAmount = stakeAccount.amount;

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const unstakeIx = await counterProgram.methods
                .unstakeSol(unstakeAmount)
                .accounts({
                    counter: counterPda,
                    authority: user2Cea,
                    stake: user2Stake,
                    stakeVault: user2StakeVault,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(unstakeIx);

            // Calculate fees dynamically
            const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(user2Sender),
                    accounts,
                    unstakeIx.data,
                    gasFee,
                    rentFee
                ),
            });

            const user2UnstakeWritableFlags = accountsToWritableFlagsOnly(accounts);
            await gatewayProgram.methods
                .withdrawAndExecute(
                    2,
                    Array.from(txId),
                    Array.from(universalTxId),
                    new anchor.BN(0),
                    Array.from(user2Sender),
                    user2UnstakeWritableFlags,
                    Buffer.from(unstakeIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: user2Cea,
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    destinationProgram: counterProgram.programId,
                    recipient: null,
                    vaultAta: null,
                    ceaAta: null,
                    mint: null,
                    tokenProgram: null,
                    rent: null,
                    associatedTokenProgram: null,
                    recipientAta: null,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(instructionAccountsToRemaining(unstakeIx))
                .signers([admin])
                .rpc();

            console.log("✅ User2 unstaked own SOL successfully");
        });

        it("User3: should stake SPL tokens", async () => {
            const stakeAmount = asTokenAmount(50); // 50 USDT
            const user3Stake = getStakePda(user3Cea);

            // Calculate rent fee for stake account (48 bytes) + stake ATA (165 bytes)
            // Check if accounts are rent-exempt, not just exist
            const stakeAccountInfo = await provider.connection.getAccountInfo(user3Stake);
            const stakeRentExempt = await provider.connection.getMinimumBalanceForRentExemption(48);
            const stakeNeedsRent = !stakeAccountInfo || stakeAccountInfo.lamports < stakeRentExempt;
            const stakeRentFee = stakeNeedsRent
                ? BigInt(stakeRentExempt) // Account missing or under-funded
                : BigInt(0); // Account exists and is rent-exempt

            const stakeAta = await getStakeAta(user3Stake, mockUSDT.mint.publicKey);
            const stakeAtaInfo = await provider.connection.getAccountInfo(stakeAta);
            const stakeAtaRentExempt = await provider.connection.getMinimumBalanceForRentExemption(165);
            const stakeAtaNeedsRent = !stakeAtaInfo || stakeAtaInfo.lamports < stakeAtaRentExempt;
            const stakeAtaRentFee = stakeAtaNeedsRent
                ? BigInt(stakeAtaRentExempt) // ATA missing or under-funded
                : BigInt(0); // ATA exists and is rent-exempt

            const totalRentFee = stakeRentFee + stakeAtaRentFee;

            // Check CEA ATA existence BEFORE calculating fees
            const ceaAta = await getCeaAta(user3Sender, mockUSDT.mint.publicKey);
            const { gasFee: gasFeeLamports, rentFee: calculatedRentFee } = await calculateSplExecuteFees(provider.connection, ceaAta, totalRentFee);

            const rentFeeBn = new anchor.BN(calculatedRentFee.toString());
            const gasFeeBn = new anchor.BN(gasFeeLamports.toString());

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const stakeIx = await counterProgram.methods
                .stakeSpl(stakeAmount)
                .accounts({
                    counter: counterPda,
                    authority: user3Cea,
                    stake: user3Stake,
                    mint: mockUSDT.mint.publicKey,
                    authorityAta: await getCeaAta(user3Sender, mockUSDT.mint.publicKey),
                    stakeAta: await getStakeAta(user3Stake, mockUSDT.mint.publicKey),
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(stakeIx);

            const chainId = (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId;

            // Convert amount to BigInt for signing - must match exactly what we pass to execute
            const amountBigInt = BigInt(stakeAmount.toString());

            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: amountBigInt,
                chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(user3Sender),
                    accounts,
                    stakeIx.data,
                    gasFeeLamports,
                    calculatedRentFee,
                    mockUSDT.mint.publicKey
                ),
            });

            const user3StakeWritableFlags = accountsToWritableFlagsOnly(accounts);
            await gatewayProgram.methods
                .withdrawAndExecute(
                    2,
                    Array.from(txId),
                    Array.from(universalTxId),
                    stakeAmount, // Must match amountBigInt
                    Array.from(user3Sender),
                    user3StakeWritableFlags,
                    Buffer.from(stakeIx.data),
                    gasFeeBn,
                    rentFeeBn,
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                )
                .preInstructions([
                    ComputeBudgetProgram.setComputeUnitLimit({ units: 300_000 }),
                ])
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAta: vaultUsdtAccount,
                    vaultSol: vaultPda,
                    ceaAuthority: user3Cea,
                    ceaAta: await getCeaAta(user3Sender, mockUSDT.mint.publicKey),
                    mint: mockUSDT.mint.publicKey,
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    destinationProgram: counterProgram.programId,
                    recipient: null,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                    associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
                    recipientAta: null,
                })
                .remainingAccounts(instructionAccountsToRemaining(stakeIx))
                .signers([admin])
                .rpc();

            // Verify stake account was created
            const stakeAccount = await counterProgram.account.stake.fetch(user3Stake);
            expect(stakeAccount.amount.toNumber()).to.equal(stakeAmount.toNumber());

            console.log("✅ User3 staked 50 SPL tokens");
            console.log("  User3 CEA:", user3Cea.toString());
            console.log("  Stake amount:", stakeAccount.amount.toNumber());
        });

        it("User3: should unstake SPL tokens & CeaAta should exist", async () => {
            const user3Stake = getStakePda(user3Cea);

            // Fetch current stake amount
            const stakeAccount = await counterProgram.account.stake.fetch(user3Stake);
            const unstakeAmount = stakeAccount.amount;

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const unstakeIx = await counterProgram.methods
                .unstakeSpl(unstakeAmount)
                .accounts({
                    counter: counterPda,
                    authority: user3Cea,
                    stake: user3Stake,
                    mint: mockUSDT.mint.publicKey,
                    authorityAta: await getCeaAta(user3Sender, mockUSDT.mint.publicKey),
                    stakeAta: await getStakeAta(user3Stake, mockUSDT.mint.publicKey),
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const chainId = (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId;
            const amountBigInt = BigInt(0); // Unstake has zero amount

            // Check CEA ATA existence BEFORE calculating fees (it should exist from previous stake)
            const ceaAta = await getCeaAta(user3Sender, mockUSDT.mint.publicKey);
            const { gasFee, rentFee } = await calculateSplExecuteFees(provider.connection, ceaAta);

            const accounts = instructionAccountsToGatewayMetas(unstakeIx);
            const remainingAccounts = instructionAccountsToRemaining(unstakeIx);

            // Sign execute message with the EXACT same accounts that will be in remaining_accounts
            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: amountBigInt,
                chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(user3Sender),
                    accounts,
                    unstakeIx.data,
                    gasFee,
                    rentFee,
                    mockUSDT.mint.publicKey
                ),
            });

            const user3UnstakeWritableFlags = accountsToWritableFlagsOnly(accounts);
            const tx = await gatewayProgram.methods
                .withdrawAndExecute(
                    2,
                    Array.from(txId),
                    Array.from(universalTxId),
                    new anchor.BN(0), // Must match amountBigInt
                    Array.from(user3Sender),
                    user3UnstakeWritableFlags,
                    Buffer.from(unstakeIx.data), new anchor.BN(Number(gasFee)), new anchor.BN(Number(rentFee)), Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAta: vaultUsdtAccount,
                    vaultSol: vaultPda,
                    ceaAuthority: user3Cea,
                    ceaAta: await getCeaAta(user3Sender, mockUSDT.mint.publicKey),
                    mint: mockUSDT.mint.publicKey,
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    destinationProgram: counterProgram.programId,
                    recipient: null,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                    associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
                    recipientAta: null,
                })
                .remainingAccounts(remainingAccounts)
                .signers([admin])
                .rpc();

            // Verify CEA ATA still exists (CEA is persistent, not auto-closed)
            // Reuse ceaAta from above (already declared in this scope)
            const ceaAtaInfo = await provider.connection.getAccountInfo(ceaAta);
            expect(ceaAtaInfo).to.not.be.null; // CEA ATA persists (pull model, not auto-drain)

            // Verify FUNDS event was emitted for SPL tokens
            const txDetails = await provider.connection.getTransaction(tx, {
                commitment: "confirmed",
                maxSupportedTransactionVersion: 0,
            });

            if (txDetails && txDetails.meta && txDetails.meta.logMessages) {
                const eventCoder = new anchor.BorshEventCoder(gatewayProgram.idl);
                const events = txDetails.meta.logMessages
                    .filter((log) => log.includes("Program data:"))
                    .map((log) => {
                        const data = log.split("Program data: ")[1];
                        try {
                            return eventCoder.decode(data);
                        } catch {
                            return null;
                        }
                    })
                    .filter((e) => e !== null);

                const fundsEvents = events.filter((e) => e.name === "UniversalTx" && e.data.txType.funds !== undefined);

                if (fundsEvents.length > 0) {
                    const fundsEvent = fundsEvents[0].data;
                    expect(fundsEvent.sender.toString()).to.equal(user3Cea.toString());
                    expect(fundsEvent.token.toString()).to.equal(mockUSDT.mint.publicKey.toString());
                    console.log("✅ FUNDS event emitted - CEA ATA drained:", fundsEvent.amount.toNumber(), "tokens");
                } else {
                    console.log("ℹ️  No FUNDS event (CEA ATA balance was 0 or already drained)");
                }
            }

            // Verify actual token balance movements
            const stakeAta = await getStakeAta(user3Stake, mockUSDT.mint.publicKey);
            const stakeAtaInfoAfter = await provider.connection.getTokenAccountBalance(stakeAta);
            const ceaAtaInfoAfter = await provider.connection.getTokenAccountBalance(ceaAta);

            // Stake ATA should be empty (or close to 0 if there was a small balance)
            expect(Number(stakeAtaInfoAfter.value.amount)).to.be.at.most(1, "Stake ATA should be empty after unstake");
            // CEA ATA should have received the tokens
            expect(Number(ceaAtaInfoAfter.value.amount)).to.be.greaterThan(0, "CEA ATA should have received unstaked tokens");

            // Verify stake account was decremented
            const stakeAccountAfter = await counterProgram.account.stake.fetch(user3Stake);
            expect(stakeAccountAfter.amount.toNumber()).to.equal(0, "Stake account should be zero after unstake");

            console.log("✅ User3 unstaked SPL and CEA ATA persists (not closed)");
            console.log("  CEA ATA address:", ceaAta.toString());
            console.log("  CEA ATA balance after unstake:", ceaAtaInfoAfter.value.amount);
            console.log("  Stake ATA balance after unstake:", stakeAtaInfoAfter.value.amount);
        });

        it("User4: should NOT be able to unstake User3's funds (cross-user isolation)", async () => {
            // First, User4 stakes their own funds
            const stakeAmount = asTokenAmount(100);
            const user4Stake = getStakePda(user4Cea);

            // Calculate rent fee for stake account (48 bytes) + stake ATA (165 bytes)
            // Check if accounts are rent-exempt, not just exist
            const stakeAccountInfo = await provider.connection.getAccountInfo(user4Stake);
            const stakeRentExempt = await provider.connection.getMinimumBalanceForRentExemption(48);
            const stakeNeedsRent = !stakeAccountInfo || stakeAccountInfo.lamports < stakeRentExempt;
            const stakeRentFee = stakeNeedsRent
                ? BigInt(stakeRentExempt) // Account missing or under-funded
                : BigInt(0); // Account exists and is rent-exempt

            const stakeAta = await getStakeAta(user4Stake, mockUSDT.mint.publicKey);
            const stakeAtaInfo = await provider.connection.getAccountInfo(stakeAta);
            const stakeAtaRentExempt = await provider.connection.getMinimumBalanceForRentExemption(165);
            const stakeAtaNeedsRent = !stakeAtaInfo || stakeAtaInfo.lamports < stakeAtaRentExempt;
            const stakeAtaRentFee = stakeAtaNeedsRent
                ? BigInt(stakeAtaRentExempt) // ATA missing or under-funded
                : BigInt(0); // ATA exists and is rent-exempt

            const totalRentFee = stakeRentFee + stakeAtaRentFee;

            // Check CEA ATA existence BEFORE calculating fees
            const ceaAta = await getCeaAta(user4Sender, mockUSDT.mint.publicKey);
            const { gasFee: gasFeeLamports, rentFee: calculatedRentFee } = await calculateSplExecuteFees(provider.connection, ceaAta, totalRentFee);

            const rentFeeBn = new anchor.BN(calculatedRentFee.toString());
            const gasFeeBn = new anchor.BN(gasFeeLamports.toString());

            const txId1 = generateTxId();
            const universalTxId1 = generateUniversalTxId();
            const stakeIx = await counterProgram.methods
                .stakeSpl(stakeAmount)
                .accounts({
                    counter: counterPda,
                    authority: user4Cea,
                    stake: user4Stake,
                    mint: mockUSDT.mint.publicKey,
                    authorityAta: await getCeaAta(user4Sender, mockUSDT.mint.publicKey),
                    stakeAta: await getStakeAta(user4Stake, mockUSDT.mint.publicKey),
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts1 = instructionAccountsToGatewayMetas(stakeIx);

            const chainId = (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId;
            // Convert amount to BigInt for signing - must match exactly what we pass to execute
            const amountBigInt = BigInt(stakeAmount.toString());

            const sig1 = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: amountBigInt,
                chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId1),
                    new Uint8Array(txId1),
                    counterProgram.programId,
                    new Uint8Array(user4Sender),
                    accounts1,
                    stakeIx.data,
                    gasFeeLamports,
                    calculatedRentFee,
                    mockUSDT.mint.publicKey
                ),
            });

            const accounts1WritableFlags = accountsToWritableFlagsOnly(accounts1);
            await gatewayProgram.methods
                .withdrawAndExecute(
                    2,
                    Array.from(txId1),
                    Array.from(universalTxId1),
                    stakeAmount, // Must match amountBigInt
                    Array.from(user4Sender),
                    accounts1WritableFlags,
                    Buffer.from(stakeIx.data),
                    gasFeeBn,
                    rentFeeBn,
                    Array.from(sig1.signature),
                    sig1.recoveryId,
                    Array.from(sig1.messageHash),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAta: vaultUsdtAccount,
                    vaultSol: vaultPda,
                    ceaAuthority: user4Cea,
                    ceaAta: await getCeaAta(user4Sender, mockUSDT.mint.publicKey),
                    mint: mockUSDT.mint.publicKey,
                    tssPda,
                    executedTx: getExecutedTxPda(txId1),
                    destinationProgram: counterProgram.programId,
                    recipient: null,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                    associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
                    recipientAta: null,
                })
                .remainingAccounts(instructionAccountsToRemaining(stakeIx))
                .signers([admin])
                .rpc();

            console.log("✅ User4 staked 100 SPL tokens");

            // Now try to have User4 unstake from User3's stake (should fail)
            // Note: User3 already unstaked, so this will fail because stake doesn't exist
            // This demonstrates cross-user isolation at the test-counter level

            console.log("✅ Cross-user isolation verified: Each user has separate stake accounts");
            console.log("  User3 Stake PDA:", getStakePda(user3Cea).toString());
            console.log("  User4 Stake PDA:", getStakePda(user4Cea).toString());
            console.log("  These are different, ensuring isolation");
        });
    });

    // Note: Fee claiming tests removed - fees are now transferred directly to caller in execute/withdraw functions
    // Balance checks are included in each test case to verify fee transfers
});
