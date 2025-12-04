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

const USDT_DECIMALS = 6;
const TOKEN_MULTIPLIER = BigInt(10 ** USDT_DECIMALS);

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

    const getStagingAuthorityPda = (txId: number[]): PublicKey => {
        const [pda] = PublicKey.findProgramAddressSync(
            [Buffer.from("staging"), Buffer.from(txId)],
            gatewayProgram.programId
        );
        return pda;
    };

    const getStagingAta = async (txId: number[], mint: PublicKey): Promise<PublicKey> => {
        const stagingAuthority = getStagingAuthorityPda(txId);
        return getAssociatedTokenAddress(mint, stagingAuthority, true);
    };

    before(async () => {
        admin = sharedState.getAdmin();
        mockUSDT = sharedState.getMockUSDT();

        recipient = Keypair.generate();
        counterAuthority = Keypair.generate();

        const airdropLamports = 10 * anchor.web3.LAMPORTS_PER_SOL;
        await Promise.all([
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
                    counterIx.data
                ),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterKeypair.publicKey);
            console.log("SOL-only payload with zero amount counterBefore", counterBefore.value.toNumber());

            const balanceBefore = await provider.connection.getBalance(admin.publicKey);
            await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(txId),
                    Array.from(sender),
                    executeAmount,
                    counterProgram.programId,
                    Array.from(sender),
                    accounts.map((a) => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                    })),
                    Buffer.from(counterIx.data),
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    sig.nonce,
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    stagingAuthority: getStagingAuthorityPda(txId),
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
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

        it("should execute SOL transfer to test-counter", async () => {
            await syncNonceFromChain();
            const txId = generateTxId();
            const sender = generateSender();
            const amount = asLamports(1); // 1 SOL
            const targetProgram = counterProgram.programId;

            // Build instruction data for test-counter.receive_sol
            const counterIx = await counterProgram.methods
                .receiveSol(amount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    recipient: recipient.publicKey,
                    stagingAuthority: getStagingAuthorityPda(txId),
                    systemProgram: SystemProgram.programId,
                })
                .instruction();

            const accounts = instructionAccountsToGatewayMetas(counterIx);

            // Sign execute message
            const tssAccount = await gatewayProgram.account.tssPda.fetch(tssPda);
            const sig = await signTssMessage({
                instruction: TssInstruction.ExecuteSol,
                nonce: currentNonce,
                amount: BigInt(amount.toString()),
                chainId: tssAccount.chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(txId),
                    targetProgram,
                    new Uint8Array(sender),
                    accounts,
                    counterIx.data
                ),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterKeypair.publicKey);
            const recipientBefore = await provider.connection.getBalance(recipient.publicKey);
            console.log("recipientBefore", recipientBefore, "\n", "counterBefore", counterBefore.value.toNumber());

            const balanceBefore = await provider.connection.getBalance(admin.publicKey);
            await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(txId),
                    Array.from(sender),
                    amount,
                    targetProgram,
                    Array.from(sender),
                    accounts.map(a => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                    })),
                    Buffer.from(counterIx.data),
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    sig.nonce,
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    stagingAuthority: getStagingAuthorityPda(txId),
                    tssPda: tssPda,
                    executedTx: getExecutedTxPda(txId),
                    destinationProgram: targetProgram,
                    systemProgram: SystemProgram.programId,
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

            const recipientAfter = await provider.connection.getBalance(recipient.publicKey);
            expect(recipientAfter - recipientBefore).to.equal(amount.toNumber());
            console.log("SOL transfer to test-counter counterAfter", counterAfter.value.toNumber(), "\n", "recipientAfter", recipientAfter, "\n", "recipientBefore", recipientBefore);
        });

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
                    counterIx.data
                ),
            });

            await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(txId),
                    Array.from(sender),
                    amount,
                    counterProgram.programId,
                    Array.from(sender),
                    accounts.map((a) => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                    })),
                    Buffer.from(counterIx.data),
                    Array.from(sig1.signature),
                    sig1.recoveryId,
                    Array.from(sig1.messageHash),
                    sig1.nonce,
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    stagingAuthority: getStagingAuthorityPda(txId),
                    tssPda: tssPda,
                    executedTx: getExecutedTxPda(txId),
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
                    counterIx.data
                ),
            });

            try {
                await gatewayProgram.methods
                    .executeUniversalTx(
                        Array.from(txId),
                        Array.from(sender),
                        amount,
                        counterProgram.programId,
                        Array.from(sender),
                        accounts.map((a) => ({
                            pubkey: a.pubkey,
                            isWritable: a.isWritable,
                        })),
                        Buffer.from(counterIx.data),
                        Array.from(sig2.signature),
                        sig2.recoveryId,
                        Array.from(sig2.messageHash),
                        sig2.nonce,
                    )
                    .accounts({
                        caller: admin.publicKey,
                        config: configPda,
                        vaultSol: vaultPda,
                        stagingAuthority: getStagingAuthorityPda(txId),
                        tssPda: tssPda,
                        executedTx: getExecutedTxPda(txId),
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
                    stagingAta: await getStagingAta(txId, mockUSDT.mint.publicKey),
                    recipientAta: recipientUsdtAccount,
                    stagingAuthority: getStagingAuthorityPda(txId),
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
                    counterIx.data
                ),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterKeypair.publicKey);
            const recipientTokenBefore = await mockUSDT.getBalance(recipientUsdtAccount);
            console.log("SPL token transfer to test-counter counterBefore", counterBefore.value.toNumber());
            const balanceBefore = await provider.connection.getBalance(admin.publicKey);
            await gatewayProgram.methods
                .executeUniversalTxToken(
                    Array.from(txId),
                    Array.from(sender),
                    amount,
                    targetProgram,
                    Array.from(sender),
                    accounts.map(a => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                    })),
                    Buffer.from(counterIx.data),
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    sig.nonce,
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAuthority: vaultPda,
                    vaultAta: vaultUsdtAccount,
                    stagingAuthority: getStagingAuthorityPda(txId),
                    stagingAta: await getStagingAta(txId, mockUSDT.mint.publicKey),
                    mint: mockUSDT.mint.publicKey,
                    tssPda: tssPda,
                    executedTx: getExecutedTxPda(txId),
                    destinationProgram: targetProgram,
                    tokenProgram: TOKEN_PROGRAM_ID,
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

            // Verify staging_ata is closed (rent reclaimed)
            const stagingAta = await getStagingAta(txId, mockUSDT.mint.publicKey);
            const stagingAtaInfo = await provider.connection.getAccountInfo(stagingAta);
            expect(stagingAtaInfo).to.be.null; // Account should be closed
        });
        it("should reject SPL execution if staging ATA owner mismatches", async () => {
            await syncNonceFromChain();
            const txId = generateTxId();
            const sender = generateSender();
            const amount = asTokenAmount(25);

            const counterIx = await counterProgram.methods
                .receiveSpl(amount)
                .accounts({
                    counter: counterKeypair.publicKey,
                    stagingAta: await getStagingAta(txId, mockUSDT.mint.publicKey),
                    recipientAta: recipientUsdtAccount,
                    stagingAuthority: getStagingAuthorityPda(txId),
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
                    counterIx.data
                ),
            });

            // Create a malicious ATA owned by an attacker (not the staging PDA)
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
                        Array.from(sender),
                        amount,
                        counterProgram.programId,
                        Array.from(sender),
                        accounts.map(a => ({
                            pubkey: a.pubkey,
                            isWritable: a.isWritable,
                        })),
                        Buffer.from(counterIx.data),
                        Array.from(sig.signature),
                        sig.recoveryId,
                        Array.from(sig.messageHash),
                        sig.nonce,
                    )
                    .accounts({
                        caller: admin.publicKey,
                        config: configPda,
                        vaultAuthority: vaultPda,
                        vaultAta: vaultUsdtAccount,
                        stagingAuthority: getStagingAuthorityPda(txId),
                        stagingAta: maliciousAta,
                        mint: mockUSDT.mint.publicKey,
                        tssPda: tssPda,
                        executedTx: getExecutedTxPda(txId),
                        destinationProgram: counterProgram.programId,
                        tokenProgram: TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                        rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                    })
                    .remainingAccounts(instructionAccountsToRemaining(counterIx))
                    .signers([admin])
                    .rpc();
                expect.fail("Should have rejected malicious staging ATA");
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
        it("should execute SPL-only payload (decrement) with zero amount", async () => {
            await syncNonceFromChain();
            const txId = generateTxId();
            const sender = generateSender();
            const amount = new anchor.BN(0);
            const decrementAmount = new anchor.BN(7);

            const counterIx = await counterProgram.methods
                .decrement(decrementAmount)
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
                    counterIx.data
                ),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterKeypair.publicKey);
            const recipientTokenBefore = await mockUSDT.getBalance(recipientUsdtAccount);
            console.log("SPL-only payload with zero amount counterBefore", counterBefore.value.toNumber());
            const balanceBefore = await provider.connection.getBalance(admin.publicKey);
            await gatewayProgram.methods
                .executeUniversalTxToken(
                    Array.from(txId),
                    Array.from(sender),
                    amount,
                    counterProgram.programId,
                    Array.from(sender),
                    accounts.map((a) => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                    })),
                    Buffer.from(counterIx.data),
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    sig.nonce,
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAuthority: vaultPda,
                    vaultAta: vaultUsdtAccount,
                    stagingAuthority: getStagingAuthorityPda(txId),
                    stagingAta: await getStagingAta(txId, mockUSDT.mint.publicKey),
                    mint: mockUSDT.mint.publicKey,
                    tssPda,
                    executedTx: getExecutedTxPda(txId),
                    destinationProgram: counterProgram.programId,
                    tokenProgram: TOKEN_PROGRAM_ID,
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
                counterBefore.value.toNumber() - decrementAmount.toNumber(),
            );

            const recipientTokenAfter = await mockUSDT.getBalance(recipientUsdtAccount);
            expect(recipientTokenAfter).to.equal(recipientTokenBefore);

            const stagingAtaInfo = await provider.connection.getAccountInfo(
                await getStagingAta(txId, mockUSDT.mint.publicKey),
            );
            // No staging ATA should have been created for zero-amount SPL execution
            expect(stagingAtaInfo).to.be.null;
        });
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
                additional: buildExecuteAdditionalData(
                    decoded.txId,
                    decoded.targetProgram,
                    decoded.sender,
                    decoded.accounts,
                    decoded.ixData
                ),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterKeypair.publicKey);

            await gatewayProgram.methods
                .executeUniversalTx(
                    Array.from(decoded.txId),
                    Array.from(decoded.sender),
                    new anchor.BN(decoded.amount.toString()),
                    decoded.targetProgram,
                    Array.from(decoded.sender),
                    decoded.accounts.map((a) => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                    })),
                    Buffer.from(decoded.ixData),
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    sig.nonce,
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultSol: vaultPda,
                    stagingAuthority: getStagingAuthorityPda(Array.from(decoded.txId)),
                    tssPda,
                    executedTx: getExecutedTxPda(Array.from(decoded.txId)),
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
                    stagingAta: await getStagingAta(txId, mockUSDT.mint.publicKey),
                    recipientAta: recipientUsdtAccount,
                    stagingAuthority: getStagingAuthorityPda(txId),
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
                additional: buildExecuteAdditionalData(
                    decoded.txId,
                    decoded.targetProgram,
                    decoded.sender,
                    decoded.accounts,
                    decoded.ixData
                ),
            });

            const counterBefore = await counterProgram.account.counter.fetch(counterKeypair.publicKey);
            const recipientTokenBefore = await mockUSDT.getBalance(recipientUsdtAccount);

            await gatewayProgram.methods
                .executeUniversalTxToken(
                    Array.from(decoded.txId),
                    Array.from(decoded.sender),
                    new anchor.BN(decoded.amount.toString()),
                    decoded.targetProgram,
                    Array.from(decoded.sender),
                    decoded.accounts.map((a) => ({
                        pubkey: a.pubkey,
                        isWritable: a.isWritable,
                    })),
                    Buffer.from(decoded.ixData),
                    Array.from(sig.signature),
                    sig.recoveryId,
                    Array.from(sig.messageHash),
                    sig.nonce,
                )
                .accounts({
                    caller: admin.publicKey,
                    config: configPda,
                    vaultAuthority: vaultPda,
                    vaultAta: vaultUsdtAccount,
                    stagingAuthority: getStagingAuthorityPda(Array.from(decoded.txId)),
                    stagingAta: await getStagingAta(txId, mockUSDT.mint.publicKey),
                    mint: mockUSDT.mint.publicKey,
                    tssPda,
                    executedTx: getExecutedTxPda(Array.from(decoded.txId)),
                    destinationProgram: decoded.targetProgram,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                    rent: anchor.web3.SYSVAR_RENT_PUBKEY,
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
                        counterIx.data
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
                                Array.from(sender),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                correctAccounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data),
                                Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                sig.nonce,
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                stagingAuthority: getStagingAuthorityPda(txId),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
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
                        counterIx.data
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
                                Array.from(sender),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                correctAccounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data),
                                Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                sig.nonce,
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                stagingAuthority: getStagingAuthorityPda(txId),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
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
                        counterIx.data
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
                                Array.from(sender),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                correctAccounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data),
                                Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                sig.nonce,
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                stagingAuthority: getStagingAuthorityPda(txId),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
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
                        counterIx.data
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
                                Array.from(sender),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                correctAccounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data),
                                Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                sig.nonce,
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                stagingAuthority: getStagingAuthorityPda(txId),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
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
                        counterIx.data
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
                                Array.from(sender),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                accounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data),
                                corruptedSignature, // Invalid!
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                sig.nonce,
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                stagingAuthority: getStagingAuthorityPda(txId),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
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
                        counterIx.data
                    ),
                });

                await expectExecuteRevert(
                    "Wrong nonce",
                    async () => {
                        return await gatewayProgram.methods
                            .executeUniversalTx(
                                Array.from(txId),
                                Array.from(sender),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                accounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data),
                                Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                new anchor.BN(wrongNonce), // Wrong nonce!
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                stagingAuthority: getStagingAuthorityPda(txId),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
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
                        counterIx.data
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
                                Array.from(sender),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                accounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data),
                                Array.from(sig.signature),
                                sig.recoveryId,
                                tamperedHash, // Tampered!
                                sig.nonce,
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                stagingAuthority: getStagingAuthorityPda(txId),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
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
                        Buffer.from([0x01])
                    ),
                });

                await expectExecuteRevert(
                    "Non-executable destination program",
                    async () => {
                        return await gatewayProgram.methods
                            .executeUniversalTx(
                                Array.from(txId),
                                Array.from(sender),
                                new anchor.BN(0),
                                nonExecutableAccount,
                                Array.from(sender),
                                accounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from([0x01]),
                                Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                sig.nonce,
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                stagingAuthority: getStagingAuthorityPda(txId),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
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
                        counterIx.data
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
                                Array.from(sender),
                                new anchor.BN(0),
                                counterProgram.programId,
                                Array.from(sender),
                                maliciousAccounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data),
                                Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                sig.nonce,
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                stagingAuthority: getStagingAuthorityPda(txId),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
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
                        counterIx.data
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
                                Array.from(sender),
                                new anchor.BN(0),
                                differentProgram, // Different from signed!
                                Array.from(sender),
                                accounts.map((a) => ({
                                    pubkey: a.pubkey,
                                    isWritable: a.isWritable,
                                })),
                                Buffer.from(counterIx.data),
                                Array.from(sig.signature),
                                sig.recoveryId,
                                Array.from(sig.messageHash),
                                sig.nonce,
                            )
                            .accounts({
                                caller: admin.publicKey,
                                config: configPda,
                                vaultSol: vaultPda,
                                stagingAuthority: getStagingAuthorityPda(txId),
                                tssPda,
                                executedTx: getExecutedTxPda(txId),
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
});

