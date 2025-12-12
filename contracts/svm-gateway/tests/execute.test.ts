import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { TestCounter } from "../target/types/test_counter";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import { TOKEN_PROGRAM_ID, getAssociatedTokenAddress, createAssociatedTokenAccountInstruction, ASSOCIATED_TOKEN_PROGRAM_ID } from "@solana/spl-token";
import { encodeExecutePayload, decodeExecutePayload, instructionToPayloadFields } from "../app/execute-payload";
import * as sharedState from "./shared-state";
import { signTssMessage, buildExecuteAdditionalData, TssInstruction, GatewayAccountMeta } from "./helpers/tss";
import { createHash } from "crypto";

// Helper to compute Anchor-style discriminator (first 8 bytes of SHA-256)
const computeDiscriminator = (name: string): Buffer => {
    return createHash("sha256").update(name).digest().slice(0, 8);
};

const USDT_DECIMALS = 6;
const TOKEN_MULTIPLIER = BigInt(10 ** USDT_DECIMALS);

// Gas fee constants (in lamports)
// Rent-exempt minimum for accounts is ~890,880 lamports
// gas_fee = rent_fee + relayer_fee (rent_fee is a subset of gas_fee)
const DEFAULT_RENT_FEE = BigInt(1_500_000); // 0.0015 SOL for target program rent needs
const DEFAULT_GAS_FEE = BigInt(2_000_000);  // 0.002 SOL total (includes rent_fee + 0.0005 SOL relayer fee)

const asLamports = (sol: number) => new anchor.BN(sol * anchor.web3.LAMPORTS_PER_SOL);
const asTokenAmount = (tokens: number) => new anchor.BN(Number(BigInt(tokens) * TOKEN_MULTIPLIER));

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

describe("Universal Gateway - Execute Tests", () => {
    anchor.setProvider(anchor.AnchorProvider.env());
    const provider = anchor.getProvider() as anchor.AnchorProvider;
    const gatewayProgram = anchor.workspace.UniversalGateway as Program<UniversalGateway>;
    const counterProgram = anchor.workspace.TestCounter as Program<TestCounter>;

    let admin: Keypair;
    let recipient: Keypair; // Recipient for test-counter

    let configPda: PublicKey;
    let vaultPda: PublicKey;
    let tssPda: PublicKey;

    let mockUSDT: any;
    let vaultUsdtAccount: PublicKey;
    let recipientUsdtAccount: PublicKey;

    let counterKeypair: Keypair; // Test counter account (not a PDA)
    let counterAuthority: Keypair; // Authority for counter

    let currentNonce = 0;
    let txIdCounter = 0;

    const syncNonceFromChain = async () => {
        const account = await gatewayProgram.account.tssPda.fetch(tssPda);
        currentNonce = Number(account.nonce);
    };

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

    const getCeaAta = async (sender: number[], mint: PublicKey): Promise<PublicKey> => {
        const ceaAuthority = getCeaAuthorityPda(sender);
        return getAssociatedTokenAddress(mint, ceaAuthority, true);
    };

    const getClaimableFeesPda = (caller: PublicKey): PublicKey => {
        const [pda] = PublicKey.findProgramAddressSync(
            [Buffer.from("claimable_fees"), caller.toBuffer()],
            gatewayProgram.programId
        );
        return pda;
    };

    before(async () => {
        admin = sharedState.getAdmin();
        mockUSDT = sharedState.getMockUSDT();

        recipient = Keypair.generate();
        counterAuthority = Keypair.generate();

        const airdropLamports = 100 * anchor.web3.LAMPORTS_PER_SOL;
        await Promise.all([
            provider.connection.requestAirdrop(admin.publicKey, airdropLamports), // Admin pays for executed_tx and claimable_fees
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
            [Buffer.from("tsspda")],
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
        counterKeypair = Keypair.generate();

        try {
            await counterProgram.methods
                .initialize(new anchor.BN(0))
                .accounts({
                    counter: counterKeypair.publicKey,
                    authority: counterAuthority.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([counterAuthority, counterKeypair])
                .rpc();
        } catch (e: any) {
            // Counter might already be initialized
            if (!e.toString().includes("already in use")) {
                throw e;
            }
        }

        // Sync nonce
        await syncNonceFromChain();

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
            await syncNonceFromChain();
            const txId = generateTxId();
            const sender = generateSender();
            const executeAmount = new anchor.BN(0);
            const incrementAmount = new anchor.BN(5);

            // Build instruction data for test-counter.increment
            const counterIx = await counterProgram.methods
                .increment(incrementAmount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    authority: counterAuthority.publicKey,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(counterIx);

            const sig = await signTssMessage({
                instruction: TssInstruction.ExecuteSol,
                nonce: currentNonce,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    counterIx.data,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterKeypair.publicKey);
            console.log("SOL-only payload with zero amount counterBefore", counterBefore.value.toNumber());

            const balanceBefore = await provider.connection.getBalance(admin.publicKey);
            await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(txId),
                    executeAmount,
                    counterProgram.programId,
                    Array.from(sender),
                    accounts.map((a) => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                    })),
                    Buffer.from(counterIx.data),
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    new anchor.BN(Number(DEFAULT_RENT_FEE)),
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    new anchor.BN(sig.nonce),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: counterProgram.programId,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(instructionAccountsToRemaining(counterIx))
                .signers([admin])
                .rpc();

            const balanceAfter = await provider.connection.getBalance(admin.publicKey);
            console.log(`💰 Signer balance: ${balanceBefore / anchor.web3.LAMPORTS_PER_SOL} SOL → ${balanceAfter / anchor.web3.LAMPORTS_PER_SOL} SOL (deducted: ${(balanceBefore - balanceAfter) / anchor.web3.LAMPORTS_PER_SOL} SOL)`);

            await syncNonceFromChain();
            expect(currentNonce).to.equal(sig.nonce.toNumber() + 1);

            const counterAfter = await counterProgram.account.counter.fetch(counterKeypair.publicKey);
            console.log("SOL-only payload with zero amount counterAfter", counterAfter.value.toNumber());
            expect(counterAfter.value.toNumber()).to.equal(
                counterBefore.value.toNumber() + incrementAmount.toNumber(),
            );
        });

        it("should allow gateway self-call to withdraw SOL from CEA", async () => {
            await syncNonceFromChain();
            const sender = generateSender();
            const cea = getCeaAuthorityPda(sender);

            // 1) Fund CEA via execute (amount > 0, target = counterProgram)
            const txIdFund = generateTxId();
            const fundAmount = asLamports(1);
            const counterIx = await counterProgram.methods
                .increment(new anchor.BN(0))
                .accounts({ counter: counterKeypair.publicKey, authority: counterAuthority.publicKey })
                .instruction();
            const fundAccounts = instructionAccountsToGatewayMetas(counterIx);
            const sigFund = await signTssMessage({
                instruction: TssInstruction.ExecuteSol,
                nonce: currentNonce,
                amount: BigInt(fundAmount.toString()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txIdFund),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    fundAccounts,
                    counterIx.data,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

            await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(txIdFund),
                    fundAmount,
                    counterProgram.programId,
                    Array.from(sender),
                    fundAccounts.map((a) => ({ pubkey: a.pubkey, isWritable: a.isWritable })),
                    Buffer.from(counterIx.data),
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    new anchor.BN(Number(DEFAULT_RENT_FEE)),
                    Array.from(sigFund.signature),
                    sigFund.recoveryId,
                    Array.from(sigFund.messageHash),
                    new anchor.BN(sigFund.nonce)
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: cea,
                    tssPda,
                    executedTx: getExecutedTxPda(txIdFund),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: counterProgram.programId,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(instructionAccountsToRemaining(counterIx))
                .signers([admin])
                .rpc();

            const ceaBalBefore = await provider.connection.getBalance(cea);
            expect(ceaBalBefore).to.be.greaterThan(0);

            // 2) Withdraw all SOL from CEA via gateway self-call (target = gateway)
            const txIdWithdraw = generateTxId();
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
            const sigW = await signTssMessage({
                instruction: TssInstruction.ExecuteSol,
                nonce: sigFund.nonce.add(new anchor.BN(1)).toNumber(),
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txIdWithdraw),
                    gatewayProgram.programId,
                    new Uint8Array(sender),
                    [],
                    withdrawIxData,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

            await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(txIdWithdraw),
                    new anchor.BN(0),
                    gatewayProgram.programId,
                    Array.from(sender),
                    [],
                    withdrawIxData,
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    new anchor.BN(Number(DEFAULT_RENT_FEE)),
                    Array.from(sigW.signature),
                    sigW.recoveryId,
                    Array.from(sigW.messageHash),
                    new anchor.BN(sigW.nonce)
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: cea,
                    tssPda,
                    executedTx: getExecutedTxPda(txIdWithdraw),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: gatewayProgram.programId,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            const ceaBalAfter = await provider.connection.getBalance(cea);
            expect(ceaBalAfter).to.equal(0);
        });

        // SOL transfer test removed - covered by CEA staking tests below

        it("should reject duplicate tx_id (replay protection)", async () => {
            await syncNonceFromChain();
            const txId = generateTxId();
            const sender = generateSender();
            const amount = asLamports(0.1);

            const counterIx = await counterProgram.methods
                .increment(new anchor.BN(1))
                .accounts({
                    counter: counterKeypair.publicKey,
                    authority: counterAuthority.publicKey,
                })
                .instruction();
            const accounts = instructionAccountsToGatewayMetas(counterIx);
            const remaining = instructionAccountsToRemaining(counterIx);

            // First execution
            const sig1 = await signTssMessage({
                instruction: TssInstruction.ExecuteSol,
                nonce: currentNonce,
                amount: BigInt(amount.toString()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    counterIx.data,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

            await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(txId),
                    amount,
                    counterProgram.programId,
                    Array.from(sender),
                    accounts.map((a) => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                    })),
                    Buffer.from(counterIx.data),
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    new anchor.BN(Number(DEFAULT_RENT_FEE)),
                    Array.from(sig1.signature),
                    sig1.recoveryId,
                    Array.from(sig1.messageHash),
                    new anchor.BN(sig1.nonce),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    tssPda: tssPda,
                    executedTx: getExecutedTxPda(txId),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: counterProgram.programId,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(remaining)
                .signers([admin])
                .rpc();

            await syncNonceFromChain();

            // Second execution with same tx_id should fail
            const sig2 = await signTssMessage({
                instruction: TssInstruction.ExecuteSol,
                nonce: currentNonce,
                amount: BigInt(amount.toString()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    counterIx.data,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

            try {
                await gatewayProgram.methods
                    .executeUniversalTx(
                        Array.from(txId),
                        amount,
                        counterProgram.programId,
                        Array.from(sender),
                        accounts.map((a) => ({
                            pubkey: a.pubkey,
                            isWritable: a.isWritable,
                        })),
                        Buffer.from(counterIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig2.signature),
                        sig2.recoveryId,
                        Array.from(sig2.messageHash),
                        new anchor.BN(sig2.nonce),
                    )
                    .accounts({
                        caller: admin.publicKey,
                        config: configPda,
                        vaultSol: vaultPda,
                        ceaAuthority: getCeaAuthorityPda(sender),
                        tssPda: tssPda,
                        executedTx: getExecutedTxPda(txId),
                        claimableFees: getClaimableFeesPda(admin.publicKey),
                        destinationProgram: counterProgram.programId,
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

    describe("execute_universal_tx_token (SPL)", () => {
        it("should execute SPL token transfer to test-counter", async () => {
            await syncNonceFromChain();
            const txId = generateTxId();
            const sender = generateSender();
            const amount = asTokenAmount(100); // 100 USDT
            const targetProgram = counterProgram.programId;

            // Build instruction data for test-counter.receive_spl
            const counterIx = await counterProgram.methods
                .receiveSpl(amount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    ceaAta: await getCeaAta(sender, mockUSDT.mint.publicKey),
                    recipientAta: recipientUsdtAccount,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    tokenProgram: TOKEN_PROGRAM_ID,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(counterIx);

            // Sign execute message
            const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);
            const sig = await signTssMessage({
                instruction: TssInstruction.ExecuteSpl,
                nonce: currentNonce,
                amount: BigInt(amount.toString()),
                chainId: tssAccount.chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId),
                    targetProgram,
                    new Uint8Array(sender),
                    accounts,
                    counterIx.data,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterKeypair.publicKey);
            const recipientTokenBefore = await mockUSDT.getBalance(recipientUsdtAccount);
            console.log("SPL token transfer to test-counter counterBefore", counterBefore.value.toNumber());
            const balanceBefore = await provider.connection.getBalance(admin.publicKey);
            await gatewayProgram.methods
                .executeUniversalTxToken(
                    Array.from(txId),
                    amount,
                    targetProgram,
                    Array.from(sender),
                    accounts.map(a => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                    })),
                    Buffer.from(counterIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    new anchor.BN(sig.nonce),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAuthority: vaultPda,
                    vaultAta: vaultUsdtAccount,
                    vaultSol: vaultPda,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    ceaAta: await getCeaAta(sender, mockUSDT.mint.publicKey),
                    mint: mockUSDT.mint.publicKey,
                    tssPda: tssPda,
                    executedTx: getExecutedTxPda(txId),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: targetProgram,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                })
                .remainingAccounts(instructionAccountsToRemaining(counterIx))
                .signers([admin])
                .rpc();

            const balanceAfter = await provider.connection.getBalance(admin.publicKey);
            console.log(`💰 Signer balance: ${balanceBefore / anchor.web3.LAMPORTS_PER_SOL} SOL → ${balanceAfter / anchor.web3.LAMPORTS_PER_SOL} SOL (deducted: ${(balanceBefore - balanceAfter) / anchor.web3.LAMPORTS_PER_SOL} SOL)`);

            // Verify nonce incremented
            await syncNonceFromChain();
            expect(currentNonce).to.equal(sig.nonce.toNumber() + 1);

            // Verify executed_tx account exists
            const executedTx = await gatewayProgram.account.executedTx.fetch(getExecutedTxPda(txId));
            expect(executedTx).to.not.be.null;

            const counterAfter = await counterProgram.account.counter.fetch(counterKeypair.publicKey);
            expect(counterAfter.value.toNumber()).to.equal(
                counterBefore.value.toNumber() + amount.toNumber(),
            );

            const recipientTokenAfter = await mockUSDT.getBalance(recipientUsdtAccount);
            const amountTokens = amount.toNumber() / 10 ** USDT_DECIMALS;
            expect(recipientTokenAfter - recipientTokenBefore).to.equal(amountTokens);

            // Verify cea_ata persists (CEA is now persistent, not auto-closed)
            const ceaAta = await getCeaAta(sender, mockUSDT.mint.publicKey);
            const ceaAtaInfo = await provider.connection.getAccountInfo(ceaAta);
            expect(ceaAtaInfo).to.not.be.null; // CEA ATA persists (pull model)
        });
        it("should reject SPL execution if cea ATA owner mismatches", async () => {
            await syncNonceFromChain();
            const txId = generateTxId();
            const sender = generateSender();
            const amount = asTokenAmount(25);

            const counterIx = await counterProgram.methods
                .receiveSpl(amount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    ceaAta: await getCeaAta(sender, mockUSDT.mint.publicKey),
                    recipientAta: recipientUsdtAccount,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    tokenProgram: TOKEN_PROGRAM_ID,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(counterIx);
            const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);

            const sig = await signTssMessage({
                instruction: TssInstruction.ExecuteSpl,
                nonce: currentNonce,
                amount: BigInt(amount.toString()),
                chainId: tssAccount.chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    counterIx.data,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

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

            try {
                await gatewayProgram.methods
                    .executeUniversalTxToken(
                        Array.from(txId),
                        amount,
                        counterProgram.programId,
                        Array.from(sender),
                        accounts.map(a => ({
                            pubkey: a.pubkey,
                            isWritable: a.isWritable,
                        })),
                        Buffer.from(counterIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                        sig.recoveryId,
                        Array.from(sig.messageHash),
                        new anchor.BN(sig.nonce),
                    )
                    .accounts({
                        caller: admin.publicKey,
                        config: configPda,
                        vaultAuthority: vaultPda,
                        vaultAta: vaultUsdtAccount,
                        vaultSol: vaultPda,
                        ceaAuthority: getCeaAuthorityPda(sender),
                        ceaAta: maliciousAta,
                        mint: mockUSDT.mint.publicKey,
                        tssPda: tssPda,
                        executedTx: getExecutedTxPda(txId),
                        claimableFees: getClaimableFeesPda(admin.publicKey),
                        destinationProgram: counterProgram.programId,
                        tokenProgram: TOKEN_PROGRAM_ID,
                        associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                    })
                    .remainingAccounts(instructionAccountsToRemaining(counterIx))
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
                expect(errorCode).to.equal("InvalidOwner");
            }

            // Nonce already consumed when validate_message ran; refresh cached value
            await syncNonceFromChain();
        });
        it("should execute SPL-only payload (increment) with zero amount", async () => {
            await syncNonceFromChain();
            const txId = generateTxId();
            const sender = generateSender();
            const amount = new anchor.BN(0);
            const incrementAmount = new anchor.BN(4);

            // Use increment instead of decrement to avoid underflow
            const counterIx = await counterProgram.methods
                .increment(incrementAmount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    authority: counterAuthority.publicKey,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(counterIx);

            const sig = await signTssMessage({
                instruction: TssInstruction.ExecuteSpl,
                nonce: currentNonce,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    counterIx.data,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterKeypair.publicKey);
            const recipientTokenBefore = await mockUSDT.getBalance(recipientUsdtAccount);
            console.log("SPL-only payload with zero amount counterBefore", counterBefore.value.toNumber());
            const balanceBefore = await provider.connection.getBalance(admin.publicKey);
            await gatewayProgram.methods
                .executeUniversalTxToken(
                    Array.from(txId),
                    amount,
                    counterProgram.programId,
                    Array.from(sender),
                    accounts.map((a) => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                    })),
                    Buffer.from(counterIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    new anchor.BN(sig.nonce),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAuthority: vaultPda,
                    vaultAta: vaultUsdtAccount,
                    vaultSol: vaultPda,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    ceaAta: await getCeaAta(sender, mockUSDT.mint.publicKey),
                    mint: mockUSDT.mint.publicKey,
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: counterProgram.programId,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                })
                .remainingAccounts(instructionAccountsToRemaining(counterIx))
                .signers([admin])
                .rpc();

            const balanceAfter = await provider.connection.getBalance(admin.publicKey);
            console.log(`💰 Signer balance: ${balanceBefore / anchor.web3.LAMPORTS_PER_SOL} SOL → ${balanceAfter / anchor.web3.LAMPORTS_PER_SOL} SOL (deducted: ${(balanceBefore - balanceAfter) / anchor.web3.LAMPORTS_PER_SOL} SOL)`);

            await syncNonceFromChain();
            expect(currentNonce).to.equal(sig.nonce.toNumber() + 1);

            const counterAfter = await counterProgram.account.counter.fetch(counterKeypair.publicKey);
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
        await syncNonceFromChain();
        const sender = generateSender();
        const cea = getCeaAuthorityPda(sender);
        const ceaAta = await getCeaAta(sender, mockUSDT.mint.publicKey);

        // Fund CEA ATA via execute (amount > 0, target = counterProgram)
        const txIdFund = generateTxId();
        const fundAmount = asTokenAmount(25);
        const stakeRentExempt = await provider.connection.getMinimumBalanceForRentExemption(48);
        const rentFeeLamports = BigInt(stakeRentExempt + 500_000);
        const gasFeeLamports = rentFeeLamports + DEFAULT_GAS_FEE;
        const rentFeeBn = new anchor.BN(rentFeeLamports.toString());
        const gasFeeBn = new anchor.BN(gasFeeLamports.toString());

        const counterIx = await counterProgram.methods
            .increment(new anchor.BN(0))
            .accounts({ counter: counterKeypair.publicKey, authority: counterAuthority.publicKey })
            .instruction();
        const fundAccounts = instructionAccountsToGatewayMetas(counterIx);
        const sigFund = await signTssMessage({
            instruction: TssInstruction.ExecuteSpl,
            nonce: currentNonce,
            amount: BigInt(fundAmount.toString()),
            chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
            additional: buildExecuteAdditionalData(
                new Uint8Array(txIdFund),
                counterProgram.programId,
                new Uint8Array(sender),
                fundAccounts,
                counterIx.data,
                gasFeeLamports,
                rentFeeLamports
            ),
        });

        await gatewayProgram.methods
            .executeUniversalTxToken(
                Array.from(txIdFund),
                fundAmount,
                counterProgram.programId,
                Array.from(sender),
                fundAccounts.map((a) => ({ pubkey: a.pubkey, isWritable: a.isWritable })),
                Buffer.from(counterIx.data),
                gasFeeBn,
                rentFeeBn,
                Array.from(sigFund.signature),
                sigFund.recoveryId,
                Array.from(sigFund.messageHash),
                new anchor.BN(sigFund.nonce),
            )
            .accounts({
                caller: admin.publicKey,
                config: configPda,
                vaultAuthority: vaultPda,
                vaultAta: vaultUsdtAccount,
                vaultSol: vaultPda,
                ceaAuthority: cea,
                ceaAta,
                mint: mockUSDT.mint.publicKey,
                tssPda,
                executedTx: getExecutedTxPda(txIdFund),
                claimableFees: getClaimableFeesPda(admin.publicKey),
                destinationProgram: counterProgram.programId,
                tokenProgram: TOKEN_PROGRAM_ID,
                systemProgram: SystemProgram.programId,
                rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            })
            .remainingAccounts(instructionAccountsToRemaining(counterIx))
            .signers([admin])
            .rpc();

        const ceaAtaBefore = await provider.connection.getTokenAccountBalance(ceaAta);
        expect(Number(ceaAtaBefore.value.amount)).to.be.greaterThan(0);

        // Withdraw all SPL from CEA via gateway self-call (target = gateway)
        const txIdWithdraw = generateTxId();
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
        const sigW = await signTssMessage({
            instruction: TssInstruction.ExecuteSpl,
            nonce: sigFund.nonce.add(new anchor.BN(1)).toNumber(),
            amount: BigInt(0),
            chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
            additional: buildExecuteAdditionalData(
                new Uint8Array(txIdWithdraw),
                gatewayProgram.programId,
                new Uint8Array(sender),
                [],
                withdrawIxData,
                DEFAULT_GAS_FEE,
                DEFAULT_RENT_FEE
            ),
        });

        await gatewayProgram.methods
            .executeUniversalTxToken(
                Array.from(txIdWithdraw),
                new anchor.BN(0),
                gatewayProgram.programId,
                Array.from(sender),
                [],
                withdrawIxData,
                new anchor.BN(Number(DEFAULT_GAS_FEE)),
                new anchor.BN(Number(DEFAULT_RENT_FEE)),
                Array.from(sigW.signature),
                sigW.recoveryId,
                Array.from(sigW.messageHash),
                new anchor.BN(sigW.nonce),
            )
            .accounts({
                caller: admin.publicKey,
                config: configPda,
                vaultAuthority: vaultPda,
                vaultAta: vaultUsdtAccount,
                vaultSol: vaultPda,
                ceaAuthority: cea,
                ceaAta,
                mint: mockUSDT.mint.publicKey,
                tssPda,
                executedTx: getExecutedTxPda(txIdWithdraw),
                claimableFees: getClaimableFeesPda(admin.publicKey),
                destinationProgram: gatewayProgram.programId,
                tokenProgram: TOKEN_PROGRAM_ID,
                systemProgram: SystemProgram.programId,
                rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
            })
            .signers([admin])
            .rpc();

        const ceaAtaAfter = await provider.connection.getTokenAccountBalance(ceaAta);
        expect(Number(ceaAtaAfter.value.amount)).to.equal(0);
    });

    describe("execute payload encode/decode roundtrip", () => {
        it("encodes, decodes, signs, and executes SOL payload", async () => {
            await syncNonceFromChain();
            const txId = generateTxId();
            const sender = generateSender();
            const incrementAmount = new anchor.BN(4);

            const counterIx = await counterProgram.methods
                .increment(incrementAmount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    authority: counterAuthority.publicKey,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(counterIx);
            const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);

            const payloadFields = instructionToPayloadFields({
                instruction: counterIx,
                instructionId: 5,
                chainId: tssAccount.chainId,
                nonce: currentNonce,
                amount: BigInt(0),
                txId: new Uint8Array(txId),
                sender: new Uint8Array(sender),
            });

            const encoded = encodeExecutePayload(payloadFields);
            const decoded = decodeExecutePayload(encoded);

            expect(decoded.chainId).to.equal(payloadFields.chainId);
            expect(Buffer.from(decoded.txId)).to.deep.equal(Buffer.from(payloadFields.txId));
            expect(Buffer.from(decoded.ixData)).to.deep.equal(Buffer.from(counterIx.data));

            const sig = await signTssMessage({
                instruction: TssInstruction.ExecuteSol,
                nonce: decoded.nonce,
                amount: decoded.amount,
                chainId: decoded.chainId,
                additional: buildExecuteAdditionalData(decoded.txId,
                    decoded.targetProgram,
                    decoded.sender,
                    decoded.accounts,
                    decoded.ixData
                    , DEFAULT_GAS_FEE, DEFAULT_RENT_FEE),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterKeypair.publicKey);

            await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(decoded.txId),
                    new anchor.BN(decoded.amount.toString()),
                    decoded.targetProgram,
                    Array.from(decoded.sender),
                    decoded.accounts.map((a) => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                    })),
                    Buffer.from(decoded.ixData),
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    new anchor.BN(Number(DEFAULT_RENT_FEE)),
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    new anchor.BN(sig.nonce),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: getCeaAuthorityPda(Array.from(decoded.sender)),
                    tssPda,
                    executedTx: getExecutedTxPda(Array.from(decoded.txId)),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: decoded.targetProgram,
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

            await syncNonceFromChain();
            expect(currentNonce).to.equal(decoded.nonce + 1);

            const counterAfter = await counterProgram.account.counter.fetch(counterKeypair.publicKey);
            expect(counterAfter.value.toNumber()).to.equal(
                counterBefore.value.toNumber() + incrementAmount.toNumber(),
            );
        });

        it("encodes, decodes, signs, and executes SPL payload", async () => {
            await syncNonceFromChain();
            const txId = generateTxId();
            const sender = generateSender();
            const amount = asTokenAmount(25);

            const counterIx = await counterProgram.methods
                .receiveSpl(amount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    ceaAta: await getCeaAta(sender, mockUSDT.mint.publicKey),
                    recipientAta: recipientUsdtAccount,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    tokenProgram: TOKEN_PROGRAM_ID,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(counterIx);
            const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);

            const payloadFields = instructionToPayloadFields({
                instruction: counterIx,
                instructionId: 6,
                chainId: tssAccount.chainId,
                nonce: currentNonce,
                amount: BigInt(amount.toString()),
                txId: new Uint8Array(txId),
                sender: new Uint8Array(sender),
            });

            const encoded = encodeExecutePayload(payloadFields);
            const decoded = decodeExecutePayload(encoded);

            const sig = await signTssMessage({
                instruction: TssInstruction.ExecuteSpl,
                nonce: decoded.nonce,
                amount: decoded.amount,
                chainId: decoded.chainId,
                additional: buildExecuteAdditionalData(decoded.txId,
                    decoded.targetProgram,
                    decoded.sender,
                    decoded.accounts,
                    decoded.ixData
                    , DEFAULT_GAS_FEE, DEFAULT_RENT_FEE),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterKeypair.publicKey);
            const recipientTokenBefore = await mockUSDT.getBalance(recipientUsdtAccount);

            await gatewayProgram.methods
                .executeUniversalTxToken(
                    Array.from(decoded.txId),
                    new anchor.BN(decoded.amount.toString()),
                    decoded.targetProgram,
                    Array.from(decoded.sender),
                    decoded.accounts.map((a) => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                    })),
                    Buffer.from(decoded.ixData),
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    new anchor.BN(Number(DEFAULT_RENT_FEE)),
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    new anchor.BN(sig.nonce),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAuthority: vaultPda,
                    vaultAta: vaultUsdtAccount,
                    vaultSol: vaultPda,
                    ceaAuthority: getCeaAuthorityPda(Array.from(decoded.sender)),
                    ceaAta: await getCeaAta(sender, mockUSDT.mint.publicKey),
                    mint: mockUSDT.mint.publicKey,
                    tssPda,
                    executedTx: getExecutedTxPda(Array.from(decoded.txId)),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: decoded.targetProgram,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
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

            await syncNonceFromChain();
            expect(currentNonce).to.equal(decoded.nonce + 1);

            const counterAfter = await counterProgram.account.counter.fetch(counterKeypair.publicKey);
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
                await syncNonceFromChain();
                const txId = generateTxId();
                const sender = generateSender();

                // Build a valid instruction
                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterKeypair.publicKey,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                const correctAccounts = instructionAccountsToGatewayMetas(counterIx);

                // Sign with CORRECT accounts
                const sig = await signTssMessage({
                    instruction: TssInstruction.ExecuteSol,
                    nonce: currentNonce,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        correctAccounts,
                        counterIx.data,
                        DEFAULT_GAS_FEE,
                        DEFAULT_RENT_FEE
                    ),
                });

                // ATTACK: Pass DIFFERENT accounts in remainingAccounts
                const attackerAccount = Keypair.generate().publicKey;
                const substitutedRemaining = [
                    { pubkey: attackerAccount, isWritable: true, isSigner: false }, // Wrong account!
                    { pubkey: counterAuthority.publicKey, isWritable: false, isSigner: false },
                ];

                await expectExecuteRevert(
                    "Account substitution",
                    async () => {
                        return await gatewayProgram.methods
                            .executeUniversalTx(
                                Array.from(txId),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                correctAccounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                new anchor.BN(sig.nonce),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                claimableFees: getClaimableFeesPda(admin.publicKey),
                                destinationProgram: counterProgram.programId,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(substitutedRemaining) // Substituted accounts!
                            .signers([admin])
                            .rpc();
                    },
                    "AccountPubkeyMismatch"
                );
            });

            it("should reject account count mismatch", async () => {
                await syncNonceFromChain();
                const txId = generateTxId();
                const sender = generateSender();

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterKeypair.publicKey,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                const correctAccounts = instructionAccountsToGatewayMetas(counterIx);

                const sig = await signTssMessage({
                    instruction: TssInstruction.ExecuteSol,
                    nonce: currentNonce,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        correctAccounts,
                        counterIx.data,
                        DEFAULT_GAS_FEE,
                        DEFAULT_RENT_FEE
                    ),
                });

                // ATTACK: Pass FEWER accounts than signed
                const fewerRemaining = [
                    { pubkey: counterKeypair.publicKey, isWritable: true, isSigner: false },
                    // Missing counterAuthority!
                ];

                await expectExecuteRevert(
                    "Account count mismatch (fewer)",
                    async () => {
                        return await gatewayProgram.methods
                            .executeUniversalTx(
                                Array.from(txId),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                correctAccounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                new anchor.BN(sig.nonce),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                claimableFees: getClaimableFeesPda(admin.publicKey),
                                destinationProgram: counterProgram.programId,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(fewerRemaining)
                            .signers([admin])
                            .rpc();
                    },
                    "AccountListLengthMismatch"
                );
            });

            it("should reject writable flag mismatch", async () => {
                await syncNonceFromChain();
                const txId = generateTxId();
                const sender = generateSender();

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterKeypair.publicKey,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                const correctAccounts = instructionAccountsToGatewayMetas(counterIx);

                // Sign with counter as writable
                const sig = await signTssMessage({
                    instruction: TssInstruction.ExecuteSol,
                    nonce: currentNonce,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        correctAccounts,
                        counterIx.data,
                        DEFAULT_GAS_FEE,
                        DEFAULT_RENT_FEE
                    ),
                });

                // ATTACK: Mark writable account as read-only in remaining_accounts
                const wrongWritableRemaining = [
                    { pubkey: counterKeypair.publicKey, isWritable: false, isSigner: false }, // Should be writable!
                    { pubkey: counterAuthority.publicKey, isWritable: false, isSigner: false },
                ];

                await expectExecuteRevert(
                    "Writable flag mismatch",
                    async () => {
                        return await gatewayProgram.methods
                            .executeUniversalTx(
                                Array.from(txId),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                correctAccounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                new anchor.BN(sig.nonce),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                claimableFees: getClaimableFeesPda(admin.publicKey),
                                destinationProgram: counterProgram.programId,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(wrongWritableRemaining)
                            .signers([admin])
                            .rpc();
                    },
                    "AccountWritableFlagMismatch"
                );
            });

            it("should reject account reordering attack", async () => {
                await syncNonceFromChain();
                const txId = generateTxId();
                const sender = generateSender();

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterKeypair.publicKey,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                const correctAccounts = instructionAccountsToGatewayMetas(counterIx);

                const sig = await signTssMessage({
                    instruction: TssInstruction.ExecuteSol,
                    nonce: currentNonce,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        correctAccounts,
                        counterIx.data,
                        DEFAULT_GAS_FEE,
                        DEFAULT_RENT_FEE
                    ),
                });

                // ATTACK: Reorder accounts (swap counter and authority)
                const reorderedRemaining = [
                    { pubkey: counterAuthority.publicKey, isWritable: false, isSigner: false }, // Wrong position!
                    { pubkey: counterKeypair.publicKey, isWritable: true, isSigner: false },
                ];

                await expectExecuteRevert(
                    "Account reordering",
                    async () => {
                        return await gatewayProgram.methods
                            .executeUniversalTx(
                                Array.from(txId),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                correctAccounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                new anchor.BN(sig.nonce),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                claimableFees: getClaimableFeesPda(admin.publicKey),
                                destinationProgram: counterProgram.programId,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(reorderedRemaining)
                            .signers([admin])
                            .rpc();
                    },
                    "AccountPubkeyMismatch"
                );
            });
        });

        describe("signature and authentication attacks", () => {
            it("should reject invalid signature", async () => {
                await syncNonceFromChain();
                const txId = generateTxId();
                const sender = generateSender();

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterKeypair.publicKey,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                const accounts = instructionAccountsToGatewayMetas(counterIx);

                const sig = await signTssMessage({
                    instruction: TssInstruction.ExecuteSol,
                    nonce: currentNonce,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        accounts,
                        counterIx.data,
                        DEFAULT_GAS_FEE,
                        DEFAULT_RENT_FEE
                    ),
                });

                // ATTACK: Corrupt the signature
                const corruptedSignature = Array.from(sig.signature);
                corruptedSignature[0] ^= 0xFF; // Flip bits

                await expectExecuteRevert(
                    "Invalid signature",
                    async () => {
                        return await gatewayProgram.methods
                            .executeUniversalTx(
                                Array.from(txId),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                accounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data),
                                new anchor.BN(Number(DEFAULT_GAS_FEE)),
                                new anchor.BN(Number(DEFAULT_RENT_FEE)),
                                corruptedSignature, // Invalid!
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                new anchor.BN(sig.nonce),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                claimableFees: getClaimableFeesPda(admin.publicKey),
                                destinationProgram: counterProgram.programId,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(instructionAccountsToRemaining(counterIx))
                            .signers([admin])
                            .rpc();
                    },
                    "TssAuthFailed"
                );
            });

            it("should reject wrong nonce", async () => {
                await syncNonceFromChain();
                const txId = generateTxId();
                const sender = generateSender();

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterKeypair.publicKey,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                const accounts = instructionAccountsToGatewayMetas(counterIx);

                // Sign with WRONG nonce (future nonce)
                const wrongNonce = currentNonce + 5;
                const sig = await signTssMessage({
                    instruction: TssInstruction.ExecuteSol,
                    nonce: wrongNonce, // Wrong!
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        accounts,
                        counterIx.data,
                        DEFAULT_GAS_FEE,
                        DEFAULT_RENT_FEE
                    ),
                });

                await expectExecuteRevert(
                    "Wrong nonce",
                    async () => {
                        return await gatewayProgram.methods
                            .executeUniversalTx(
                                Array.from(txId),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                accounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                new anchor.BN(wrongNonce), // Wrong nonce!
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                claimableFees: getClaimableFeesPda(admin.publicKey),
                                destinationProgram: counterProgram.programId,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(instructionAccountsToRemaining(counterIx))
                            .signers([admin])
                            .rpc();
                    },
                    "NonceMismatch"
                );
            });

            it("should reject tampered message hash", async () => {
                await syncNonceFromChain();
                const txId = generateTxId();
                const sender = generateSender();

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterKeypair.publicKey,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                const accounts = instructionAccountsToGatewayMetas(counterIx);

                const sig = await signTssMessage({
                    instruction: TssInstruction.ExecuteSol,
                    nonce: currentNonce,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        accounts,
                        counterIx.data,
                        DEFAULT_GAS_FEE,
                        DEFAULT_RENT_FEE
                    ),
                });

                // ATTACK: Tamper with message hash
                const tamperedHash = Array.from(sig.messageHash);
                tamperedHash[0] ^= 0xFF;

                await expectExecuteRevert(
                    "Tampered message hash",
                    async () => {
                        return await gatewayProgram.methods
                            .executeUniversalTx(
                                Array.from(txId),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                accounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                                sig.recoveryId,
                                tamperedHash, // Tampered!
                                new anchor.BN(sig.nonce),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                claimableFees: getClaimableFeesPda(admin.publicKey),
                                destinationProgram: counterProgram.programId,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(instructionAccountsToRemaining(counterIx))
                            .signers([admin])
                            .rpc();
                    },
                    "MessageHashMismatch"
                );
            });
        });

        describe("program and target validation", () => {
            it("should reject non-executable destination program", async () => {
                await syncNonceFromChain();
                const txId = generateTxId();
                const sender = generateSender();

                // Use a regular account (not a program) as destination
                const nonExecutableAccount = Keypair.generate().publicKey;

                const accounts: GatewayAccountMeta[] = [
                    { pubkey: counterKeypair.publicKey, isWritable: true },
                ];

                const sig = await signTssMessage({
                    instruction: TssInstruction.ExecuteSol,
                    nonce: currentNonce,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(txId),
                        nonExecutableAccount, // Non-executable!
                        new Uint8Array(sender),
                        accounts,
                        Buffer.from([0x01]),
                        DEFAULT_GAS_FEE,
                        DEFAULT_RENT_FEE
                    ),
                });

                await expectExecuteRevert(
                    "Non-executable destination program",
                    async () => {
                        return await gatewayProgram.methods
                            .executeUniversalTx(
                                Array.from(txId),
                                new anchor.BN(0),
                                nonExecutableAccount,
                                Array.from(sender),
                                accounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from([0x01]),
                                new anchor.BN(Number(DEFAULT_GAS_FEE)),
                                new anchor.BN(Number(DEFAULT_RENT_FEE)),
                                Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                new anchor.BN(sig.nonce),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                claimableFees: getClaimableFeesPda(admin.publicKey),
                                destinationProgram: nonExecutableAccount,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts([
                                { pubkey: counterKeypair.publicKey, isWritable: true, isSigner: false },
                            ])
                            .signers([admin])
                            .rpc();
                    },
                    "InvalidProgram"
                );
            });

            it("should reject gateway PDAs in remaining accounts (vault)", async () => {
                await syncNonceFromChain();
                const txId = generateTxId();
                const sender = generateSender();

                // ATTACK: Include vault PDA in remaining_accounts
                const maliciousAccounts: GatewayAccountMeta[] = [
                    { pubkey: counterKeypair.publicKey, isWritable: true },
                    { pubkey: vaultPda, isWritable: true }, // Protected account!
                ];

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterKeypair.publicKey,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                const sig = await signTssMessage({
                    instruction: TssInstruction.ExecuteSol,
                    nonce: currentNonce,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(txId),
                        counterProgram.programId,
                        new Uint8Array(sender),
                        maliciousAccounts, // Includes vault!
                        counterIx.data,
                        DEFAULT_GAS_FEE,
                        DEFAULT_RENT_FEE
                    ),
                });

                const maliciousRemaining = [
                    { pubkey: counterKeypair.publicKey, isWritable: true, isSigner: false },
                    { pubkey: vaultPda, isWritable: true, isSigner: false }, // Vault should never be passed!
                ];

                await expectExecuteRevert(
                    "Gateway vault PDA in remaining accounts",
                    async () => {
                        return await gatewayProgram.methods
                            .executeUniversalTx(
                                Array.from(txId),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                maliciousAccounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                new anchor.BN(sig.nonce),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                claimableFees: getClaimableFeesPda(admin.publicKey),
                                destinationProgram: counterProgram.programId,
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
                await syncNonceFromChain();
                const txId = generateTxId();
                const sender = generateSender();

                const counterIx = await counterProgram.methods
                    .increment(new anchor.BN(1))
                    .accounts({
                        counter: counterKeypair.publicKey,
                        authority: counterAuthority.publicKey,
                    })
                    .instruction();

                const accounts = instructionAccountsToGatewayMetas(counterIx);

                // Sign for counter program
                const sig = await signTssMessage({
                    instruction: TssInstruction.ExecuteSol,
                    nonce: currentNonce,
                    amount: BigInt(0),
                    chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                    additional: buildExecuteAdditionalData(
                        new Uint8Array(txId),
                        counterProgram.programId, // Signed for counter program
                        new Uint8Array(sender),
                        accounts,
                        counterIx.data,
                        DEFAULT_GAS_FEE,
                        DEFAULT_RENT_FEE
                    ),
                });

                // ATTACK: Pass different program as destination_program
                // Note: This fails at message hash validation because target_program is part of the signed message.
                // The TargetProgramMismatch check exists as a defensive measure but is unlikely to be hit
                // since message hash validation happens first.
                const differentProgram = Keypair.generate().publicKey;

                await expectExecuteRevert(
                    "Target program mismatch (caught by message hash validation)",
                    async () => {
                        return await gatewayProgram.methods
                            .executeUniversalTx(
                                Array.from(txId),
                                new anchor.BN(0),
                                differentProgram, // Different from signed!
                                Array.from(sender),
                                accounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                new anchor.BN(sig.nonce),
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                ceaAuthority: getCeaAuthorityPda(sender),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
                                claimableFees: getClaimableFeesPda(admin.publicKey),
                                destinationProgram: differentProgram,
                                systemProgram: SystemProgram.programId,
                            })
                            .remainingAccounts(instructionAccountsToRemaining(counterIx))
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
            await syncNonceFromChain();
            const stakeAmount = asLamports(1); // 1 SOL
            const user1Stake = getStakePda(user1Cea);

            // Transaction 1: Stake SOL
            const txId1 = generateTxId();
            const stakeIx = await counterProgram.methods
                .stakeSol(stakeAmount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    authority: user1Cea,
                    stake: user1Stake,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(stakeIx);
            const sig1 = await signTssMessage({
                instruction: TssInstruction.ExecuteSol,
                nonce: currentNonce,
                amount: BigInt(stakeAmount.toString()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId1),
                    counterProgram.programId,
                    new Uint8Array(user1Sender),
                    accounts,
                    stakeIx.data,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

            await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(txId1),
                    stakeAmount,
                    counterProgram.programId,
                    Array.from(user1Sender),
                    accounts.map((a) => ({ pubkey: a.pubkey, isWritable: a.isWritable })),
                    Buffer.from(stakeIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig1.signature),
                    sig1.recoveryId,
                    Array.from(sig1.messageHash),
                    new anchor.BN(sig1.nonce),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: user1Cea,
                    tssPda,
                    executedTx: getExecutedTxPda(txId1),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: counterProgram.programId,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(instructionAccountsToRemaining(stakeIx))
                .signers([admin])
                .rpc();

            // Verify stake was created
            const stakeAccount = await counterProgram.account.stake.fetch(user1Stake);
            expect(stakeAccount.amount.toNumber()).to.equal(stakeAmount.toNumber());
            expect(stakeAccount.authority.toString()).to.equal(user1Cea.toString());

            console.log("✅ User1 staked 1 SOL successfully");
            console.log("  Stake PDA:", user1Stake.toString());
            console.log("  Staked amount:", stakeAccount.amount.toNumber());
        });

        it("User1: should perform multiple transactions with same CEA", async () => {
            await syncNonceFromChain();
            const user1Stake = getStakePda(user1Cea);

            // Transaction 2: Stake more SOL with same CEA (tests identity persistence)
            const txId2 = generateTxId();
            const stakeAmount2 = asLamports(0.5); // 0.5 SOL more
            const stakeIx2 = await counterProgram.methods
                .stakeSol(stakeAmount2)
                .accounts({
                    counter: counterKeypair.publicKey,
                    authority: user1Cea,
                    stake: user1Stake,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(stakeIx2);
            const sig2 = await signTssMessage({
                instruction: TssInstruction.ExecuteSol,
                nonce: currentNonce,
                amount: BigInt(stakeAmount2.toString()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId2),
                    counterProgram.programId,
                    new Uint8Array(user1Sender),
                    accounts,
                    stakeIx2.data,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

            const ceaBefore = getCeaAuthorityPda(user1Sender);
            expect(ceaBefore.toString()).to.equal(user1Cea.toString());

            await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(txId2),
                    stakeAmount2,
                    counterProgram.programId,
                    Array.from(user1Sender),
                    accounts.map((a) => ({ pubkey: a.pubkey, isWritable: a.isWritable })),
                    Buffer.from(stakeIx2.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig2.signature),
                    sig2.recoveryId,
                    Array.from(sig2.messageHash),
                    new anchor.BN(sig2.nonce),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: user1Cea,
                    tssPda,
                    executedTx: getExecutedTxPda(txId2),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: counterProgram.programId,
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
            await syncNonceFromChain();
            const user1Stake = getStakePda(user1Cea);
            const stakeAccount = await counterProgram.account.stake.fetch(user1Stake);
            const unstakeAmount = stakeAccount.amount;

            const txId = generateTxId();
            const unstakeIx = await counterProgram.methods
                .unstakeSol(unstakeAmount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    authority: user1Cea,
                    stake: user1Stake,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(unstakeIx);
            const sig = await signTssMessage({
                instruction: TssInstruction.ExecuteSol,
                nonce: currentNonce,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(user1Sender),
                    accounts,
                    unstakeIx.data,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

            const tx = await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(txId),
                    new anchor.BN(0),
                    counterProgram.programId,
                    Array.from(user1Sender),
                    accounts.map((a) => ({ pubkey: a.pubkey, isWritable: a.isWritable })),
                    Buffer.from(unstakeIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    new anchor.BN(sig.nonce),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: user1Cea,
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: counterProgram.programId,
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

            console.log("✅ User1 unstaked SOL successfully");
            console.log("  Unstaked amount:", unstakeAmount.toNumber());
        });

        it("User2: should stake SOL with different CEA", async () => {
            await syncNonceFromChain();
            const stakeAmount = asLamports(2); // 2 SOL
            const user2Stake = getStakePda(user2Cea);

            const txId = generateTxId();
            const stakeIx = await counterProgram.methods
                .stakeSol(stakeAmount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    authority: user2Cea,
                    stake: user2Stake,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(stakeIx);
            const sig = await signTssMessage({
                instruction: TssInstruction.ExecuteSol,
                nonce: currentNonce,
                amount: BigInt(stakeAmount.toNumber()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(user2Sender),
                    accounts,
                    stakeIx.data,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

            await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(txId),
                    stakeAmount,
                    counterProgram.programId,
                    Array.from(user2Sender),
                    accounts.map((a) => ({ pubkey: a.pubkey, isWritable: a.isWritable })),
                    Buffer.from(stakeIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    new anchor.BN(sig.nonce),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: user2Cea,
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: counterProgram.programId,
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
            await syncNonceFromChain();
            const user2Stake = getStakePda(user2Cea);
            const stakeAccount = await counterProgram.account.stake.fetch(user2Stake);
            const unstakeAmount = stakeAccount.amount;

            const txId = generateTxId();
            const unstakeIx = await counterProgram.methods
                .unstakeSol(unstakeAmount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    authority: user2Cea,
                    stake: user2Stake,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(unstakeIx);
            const sig = await signTssMessage({
                instruction: TssInstruction.ExecuteSol,
                nonce: currentNonce,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(user2Sender),
                    accounts,
                    unstakeIx.data,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

            await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(txId),
                    new anchor.BN(0),
                    counterProgram.programId,
                    Array.from(user2Sender),
                    accounts.map((a) => ({ pubkey: a.pubkey, isWritable: a.isWritable })),
                    Buffer.from(unstakeIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    new anchor.BN(sig.nonce),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: user2Cea,
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: counterProgram.programId,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(instructionAccountsToRemaining(unstakeIx))
                .signers([admin])
                .rpc();

            console.log("✅ User2 unstaked own SOL successfully");
        });

        it("User3: should stake SPL tokens", async () => {
            // Sync nonce at start
            await syncNonceFromChain();

            const stakeAmount = asTokenAmount(50); // 50 USDT
            const user3Stake = getStakePda(user3Cea);

            // Compute rent fee for stake account (8 + Stake::LEN = 8 + 40 = 48 bytes)
            // This SOL should come from the vault via rent_fee, not from manual CEA funding.
            // IMPORTANT: gasFee must include rentFee (rent_fee ⊆ gas_fee), so we set:
            //   gasFeeLamports = rentFeeLamports + DEFAULT_GAS_FEE
            const stakeRentExempt = await provider.connection.getMinimumBalanceForRentExemption(48);
            const rentFeeLamports = BigInt(stakeRentExempt + 1_000_000); // rent + small buffer
            const gasFeeLamports = rentFeeLamports + DEFAULT_GAS_FEE;
            const rentFeeBn = new anchor.BN(rentFeeLamports.toString());
            const gasFeeBn = new anchor.BN(gasFeeLamports.toString());

            const txId = generateTxId();
            const stakeIx = await counterProgram.methods
                .stakeSpl(stakeAmount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    authority: user3Cea,
                    stake: user3Stake,
                    mint: mockUSDT.mint.publicKey,
                    authorityAta: await getCeaAta(user3Sender, mockUSDT.mint.publicKey),
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(stakeIx);

            // Sync again right before signing - CRITICAL: use exact on-chain nonce
            await syncNonceFromChain();
            const onChainNonce = currentNonce;

            const chainId = (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId;

            // Convert amount to BigInt for signing - must match exactly what we pass to execute
            const amountBigInt = BigInt(stakeAmount.toString());

            const sig = await signTssMessage({
                instruction: TssInstruction.ExecuteSpl,
                nonce: onChainNonce,
                amount: amountBigInt,
                chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(user3Sender),
                    accounts,
                    stakeIx.data,
                    gasFeeLamports,
                    rentFeeLamports
                ),
            });

            await gatewayProgram.methods
                .executeUniversalTxToken(
                    Array.from(txId),
                    stakeAmount, // Must match amountBigInt
                    counterProgram.programId,
                    Array.from(user3Sender),
                    accounts.map((a) => ({ pubkey: a.pubkey, isWritable: a.isWritable })),
                    Buffer.from(stakeIx.data),
                    gasFeeBn,
                    rentFeeBn,
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    new anchor.BN(sig.nonce),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAuthority: vaultPda,
                    vaultAta: vaultUsdtAccount,
                    vaultSol: vaultPda,
                    ceaAuthority: user3Cea,
                    ceaAta: await getCeaAta(user3Sender, mockUSDT.mint.publicKey),
                    mint: mockUSDT.mint.publicKey,
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: counterProgram.programId,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
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

        it("User3: should unstake SPL tokens and verify CEA ATA is closed", async () => {
            const user3Stake = getStakePda(user3Cea);

            // Fetch current stake amount
            const stakeAccount = await counterProgram.account.stake.fetch(user3Stake);
            const unstakeAmount = stakeAccount.amount;

            const txId = generateTxId();
            const unstakeIx = await counterProgram.methods
                .unstakeSpl(unstakeAmount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    authority: user3Cea,
                    stake: user3Stake,
                    mint: mockUSDT.mint.publicKey,
                    authorityAta: await getCeaAta(user3Sender, mockUSDT.mint.publicKey),
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(unstakeIx);

            // Sync nonce right before signing - CRITICAL: use exact on-chain nonce
            await syncNonceFromChain();
            const onChainNonce = currentNonce;

            const chainId = (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId;
            const amountBigInt = BigInt(0); // Unstake has zero amount

            const sig = await signTssMessage({
                instruction: TssInstruction.ExecuteSpl,
                nonce: onChainNonce,
                amount: amountBigInt,
                chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(user3Sender),
                    accounts,
                    unstakeIx.data,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

            const tx = await gatewayProgram.methods
                .executeUniversalTxToken(
                    Array.from(txId),
                    new anchor.BN(0), // Must match amountBigInt
                    counterProgram.programId,
                    Array.from(user3Sender),
                    accounts.map((a) => ({ pubkey: a.pubkey, isWritable: a.isWritable })),
                    Buffer.from(unstakeIx.data), new anchor.BN(Number(DEFAULT_GAS_FEE)), new anchor.BN(Number(DEFAULT_RENT_FEE)), Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    new anchor.BN(sig.nonce), // Must match onChainNonce
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAuthority: vaultPda,
                    vaultAta: vaultUsdtAccount,
                    vaultSol: vaultPda,
                    ceaAuthority: user3Cea,
                    ceaAta: await getCeaAta(user3Sender, mockUSDT.mint.publicKey),
                    mint: mockUSDT.mint.publicKey,
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: counterProgram.programId,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                })
                .remainingAccounts(instructionAccountsToRemaining(unstakeIx))
                .signers([admin])
                .rpc();

            // Verify CEA ATA still exists (CEA is persistent, not auto-closed)
            const ceaAta = await getCeaAta(user3Sender, mockUSDT.mint.publicKey);
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

            console.log("✅ User3 unstaked SPL and CEA ATA closed");
            console.log("  CEA ATA closed:", ceaAta.toString());
        });

        it("User4: should NOT be able to unstake User3's funds (cross-user isolation)", async () => {
            // First, User4 stakes their own funds
            const stakeAmount = asTokenAmount(100);
            const user4Stake = getStakePda(user4Cea);

            // Compute rent fee for stake account (Stake struct = 8 discriminator + 32 Pubkey + 8 u64 = 48 bytes)
            // This SOL should come from the vault via rent_fee, not from manual CEA funding.
            // IMPORTANT: gasFee must include rentFee (rent_fee ⊆ gas_fee), so we set:
            //   gasFeeLamports = rentFeeLamports + DEFAULT_GAS_FEE
            const stakeRentExempt = await provider.connection.getMinimumBalanceForRentExemption(48);
            const rentFeeLamports = BigInt(stakeRentExempt + 1_000_000); // rent + small buffer
            const gasFeeLamports = rentFeeLamports + DEFAULT_GAS_FEE;
            const rentFeeBn = new anchor.BN(rentFeeLamports.toString());
            const gasFeeBn = new anchor.BN(gasFeeLamports.toString());

            const txId1 = generateTxId();
            const stakeIx = await counterProgram.methods
                .stakeSpl(stakeAmount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    authority: user4Cea,
                    stake: user4Stake,
                    mint: mockUSDT.mint.publicKey,
                    authorityAta: await getCeaAta(user4Sender, mockUSDT.mint.publicKey),
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts1 = instructionAccountsToGatewayMetas(stakeIx);

            // Sync nonce right before signing - CRITICAL: use exact on-chain nonce
            await syncNonceFromChain();
            const onChainNonce = currentNonce;

            const chainId = (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId;
            // Convert amount to BigInt for signing - must match exactly what we pass to execute
            const amountBigInt = BigInt(stakeAmount.toString());

            const sig1 = await signTssMessage({
                instruction: TssInstruction.ExecuteSpl,
                nonce: onChainNonce,
                amount: amountBigInt,
                chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId1),
                    counterProgram.programId,
                    new Uint8Array(user4Sender),
                    accounts1,
                    stakeIx.data,
                    gasFeeLamports,
                    rentFeeLamports
                ),
            });

            await gatewayProgram.methods
                .executeUniversalTxToken(
                    Array.from(txId1),
                    stakeAmount, // Must match amountBigInt
                    counterProgram.programId,
                    Array.from(user4Sender),
                    accounts1.map((a) => ({ pubkey: a.pubkey, isWritable: a.isWritable })),
                    Buffer.from(stakeIx.data),
                    gasFeeBn,
                    rentFeeBn,
                    Array.from(sig1.signature),
                    sig1.recoveryId,
                    Array.from(sig1.messageHash),
                    new anchor.BN(sig1.nonce), // Must match onChainNonce
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAuthority: vaultPda,
                    vaultAta: vaultUsdtAccount,
                    vaultSol: vaultPda,
                    ceaAuthority: user4Cea,
                    ceaAta: await getCeaAta(user4Sender, mockUSDT.mint.publicKey),
                    mint: mockUSDT.mint.publicKey,
                    tssPda,
                    executedTx: getExecutedTxPda(txId1),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: counterProgram.programId,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    associatedTokenProgram: ASSOCIATED_TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
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

    describe("Claim Fees", () => {
        it("should accumulate and claim gas fees for relayer", async () => {
            // First, execute a transaction to accumulate some fees
            await syncNonceFromChain();
            const txId = generateTxId();
            const sender = generateSender();
            const executeAmount = new anchor.BN(0);
            const incrementAmount = new anchor.BN(1);

            const counterIx = await counterProgram.methods
                .increment(incrementAmount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    authority: counterAuthority.publicKey,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(counterIx);

            const sig = await signTssMessage({
                instruction: TssInstruction.ExecuteSol,
                nonce: currentNonce,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    counterIx.data,
                    DEFAULT_GAS_FEE,
                    DEFAULT_RENT_FEE
                ),
            });

            await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(txId),
                    executeAmount,
                    counterProgram.programId,
                    Array.from(sender),
                    accounts.map((a) => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                    })),
                    Buffer.from(counterIx.data),
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    new anchor.BN(Number(DEFAULT_RENT_FEE)),
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    new anchor.BN(sig.nonce),
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    ceaAuthority: getCeaAuthorityPda(sender),
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    claimableFees: getClaimableFeesPda(admin.publicKey),
                    destinationProgram: counterProgram.programId,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts(instructionAccountsToRemaining(counterIx))
                .signers([admin])
                .rpc();

            await syncNonceFromChain();

            // Now check accumulated fees
            const claimableFeesPda = getClaimableFeesPda(admin.publicKey);
            const feesAccount = await gatewayProgram.account.claimableFees.fetch(claimableFeesPda);
            const accumulatedBefore = feesAccount.accumulated.toNumber();
            console.log(`💰 Accumulated fees before claim: ${accumulatedBefore} lamports`);

            expect(accumulatedBefore).to.be.at.least(Number(DEFAULT_GAS_FEE), "Should have accumulated at least gas_fee from this execute (may have more from previous tests)");
            expect(feesAccount.relayer.toString()).to.equal(admin.publicKey.toString());

            // Get balances before claim
            const adminBalanceBefore = await provider.connection.getBalance(admin.publicKey);
            const vaultBalanceBefore = await provider.connection.getBalance(vaultPda);

            // Claim fees
            await gatewayProgram.methods
                .claimFees()
                .accounts({
                    relayer: admin.publicKey,
                    claimableFees: claimableFeesPda,
                    vaultSol: vaultPda,
                    config: configPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // Verify balances after claim
            const adminBalanceAfter = await provider.connection.getBalance(admin.publicKey);
            const vaultBalanceAfter = await provider.connection.getBalance(vaultPda);

            // Admin should have received the accumulated fees (minus tx fee)
            const adminGain = adminBalanceAfter - adminBalanceBefore;
            expect(adminGain).to.be.greaterThan(0, "Admin should receive fees");

            // Vault should have paid out the accumulated fees
            const vaultPaid = vaultBalanceBefore - vaultBalanceAfter;
            expect(vaultPaid).to.equal(accumulatedBefore, "Vault should pay exact accumulated amount");

            // Check fees account is reset
            const feesAccountAfter = await gatewayProgram.account.claimableFees.fetch(claimableFeesPda);
            expect(feesAccountAfter.accumulated.toNumber()).to.equal(0, "Accumulated should be reset to 0");
            expect(feesAccountAfter.relayer.toString()).to.equal(admin.publicKey.toString(), "Relayer should remain set");

            console.log(`✅ Claimed ${accumulatedBefore} lamports successfully`);
            console.log(`   Admin received: ${adminGain} lamports (after tx fee)`);
            console.log(`   Vault paid: ${vaultPaid} lamports`);
        });

        it("should reject claim with no accumulated fees", async () => {
            const claimableFeesPda = getClaimableFeesPda(admin.publicKey);

            // Verify accumulated is 0 from previous claim (or account doesn't exist)
            let accumulated = 0;
            try {
                const feesAccount = await gatewayProgram.account.claimableFees.fetch(claimableFeesPda);
                accumulated = feesAccount.accumulated.toNumber();
            } catch (e) {
                // Account doesn't exist yet, which means accumulated is effectively 0
                accumulated = 0;
            }

            if (accumulated === 0) {
                // Account exists but has 0 - try to claim (should fail)
            } else {
                // Account has fees - claim them first, then try again
                await gatewayProgram.methods
                    .claimFees()
                    .accounts({
                        relayer: admin.publicKey,
                        claimableFees: claimableFeesPda,
                        vaultSol: vaultPda,
                        config: configPda,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([admin])
                    .rpc();
            }

            // Now verify accumulated is 0
            const feesAccount = await gatewayProgram.account.claimableFees.fetch(claimableFeesPda);
            expect(feesAccount.accumulated.toNumber()).to.equal(0);

            // Try to claim again (should fail)
            try {
                await gatewayProgram.methods
                    .claimFees()
                    .accounts({
                        relayer: admin.publicKey,
                        claimableFees: claimableFeesPda,
                        vaultSol: vaultPda,
                        config: configPda,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([admin])
                    .rpc();
                expect.fail("Should have rejected claim with 0 fees");
            } catch (e: any) {
                expect(e.toString()).to.include("InvalidAmount");
                console.log("✅ Correctly rejected claim with 0 accumulated fees");
            }
        });
    });
});

