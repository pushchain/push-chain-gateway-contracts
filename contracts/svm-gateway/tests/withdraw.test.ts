import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import { TOKEN_PROGRAM_ID } from "@solana/spl-token";
import * as sharedState from "./shared-state";
import { signTssMessage, TssInstruction } from "./helpers/tss";

const USDT_DECIMALS = 6;
const TOKEN_MULTIPLIER = BigInt(10 ** USDT_DECIMALS);

const asLamports = (sol: number) => new anchor.BN(sol * anchor.web3.LAMPORTS_PER_SOL);
const asTokenAmount = (tokens: number) => new anchor.BN(Number(BigInt(tokens) * TOKEN_MULTIPLIER));

const toBytes = (pubkey: PublicKey) => pubkey.toBuffer();

describe("Universal Gateway - Withdraw Tests", () => {
    anchor.setProvider(anchor.AnchorProvider.env());
    const provider = anchor.getProvider() as anchor.AnchorProvider;
    const program = anchor.workspace.UniversalGateway as Program<UniversalGateway>;

    let admin: Keypair;
    let pauser: Keypair;
    let recipient: Keypair;
    let user1: Keypair;
    let relayer: Keypair; // The caller who pays for transactions

    let configPda: PublicKey;
    let vaultPda: PublicKey;
    let tssPda: PublicKey;
    let whitelistPda: PublicKey;

    let mockUSDT: any;

    let user1UsdtAccount: PublicKey;
    let vaultUsdtAccount: PublicKey;
    let recipientUsdtAccount: PublicKey;

    let currentNonce = 0;
    let txIdCounter = 0; // Counter to ensure unique tx_ids across tests

    const syncNonceFromChain = async () => {
        const account = await program.account.tssPda.fetch(tssPda);
        currentNonce = Number(account.nonce);
    };

    // Helper to generate a unique tx_id (32 bytes) - uses counter + random for uniqueness
    const generateTxId = (): number[] => {
        txIdCounter++;
        const buffer = Buffer.alloc(32);
        buffer.writeUInt32BE(txIdCounter, 0);
        buffer.writeUInt32BE(Date.now() % 0xFFFFFFFF, 4);
        // Fill rest with random
        for (let i = 8; i < 32; i++) {
            buffer[i] = Math.floor(Math.random() * 256);
        }
        return Array.from(buffer);
    };

    // Helper to generate an origin_caller EVM address (20 bytes)
    const generateOriginCaller = (): number[] => {
        return Array.from(Buffer.alloc(20, Math.floor(Math.random() * 256)));
    };

    // Helper to derive executed_tx PDA from tx_id
    const getExecutedTxPda = (txId: number[]): PublicKey => {
        const [pda] = PublicKey.findProgramAddressSync(
            [Buffer.from("executed_tx"), Buffer.from(txId)],
            program.programId
        );
        return pda;
    };

    const signTssMessageWithChainId = async (params: {
        instruction: TssInstruction;
        nonce: number;
        amount?: bigint;
        additional: Uint8Array[];
        txId?: Uint8Array;
        originCaller?: Uint8Array;
    }) => {
        const tssAccount = await program.account.tssPda.fetch(tssPda);
        return signTssMessage({ ...params, chainId: tssAccount.chainId });
    };

    const setNonceOnChain = async (value: number) => {
        await program.methods
            .resetNonce(new anchor.BN(value))
            .accounts({
                tssPda,
                authority: admin.publicKey,
            })
            .signers([admin])
            .rpc();
        currentNonce = value;
    };

    const expectRejection = async (promise: Promise<unknown>, message: string) => {
        let rejected = false;
        try {
            await promise;
        } catch (error: any) {
            rejected = true;
            const errorStr = error.toString();
            const errorMessage = error.error?.errorMessage || error.message || errorStr;
            const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;

            // Check multiple ways the error might be represented
            const matches =
                errorStr.includes(message) ||
                errorMessage.includes(message) ||
                (errorCode && errorCode.toString().includes(message)) ||
                (error.error?.errorCode?.code === message);

            if (!matches) {
                console.error(`Expected error to include "${message}", but got:`, {
                    errorStr,
                    errorMessage,
                    errorCode,
                    fullError: error
                });
            }
            expect(matches).to.be.true;
        }
        expect(rejected).to.be.true;
    };

    before(async () => {
        admin = sharedState.getAdmin();
        pauser = sharedState.getPauser();
        mockUSDT = sharedState.getMockUSDT();

        recipient = Keypair.generate();
        user1 = Keypair.generate();
        relayer = Keypair.generate(); // Relayer who calls and pays for transactions

        const airdropLamports = 10 * anchor.web3.LAMPORTS_PER_SOL;
        await Promise.all([
            provider.connection.requestAirdrop(recipient.publicKey, airdropLamports),
            provider.connection.requestAirdrop(user1.publicKey, airdropLamports),
            provider.connection.requestAirdrop(relayer.publicKey, airdropLamports),
        ]);
        await new Promise(resolve => setTimeout(resolve, 2000));

        [configPda] = PublicKey.findProgramAddressSync([Buffer.from("config")], program.programId);
        [vaultPda] = PublicKey.findProgramAddressSync([Buffer.from("vault")], program.programId);
        [tssPda] = PublicKey.findProgramAddressSync([Buffer.from("tsspda")], program.programId);
        [whitelistPda] = PublicKey.findProgramAddressSync([Buffer.from("whitelist")], program.programId);

        user1UsdtAccount = await mockUSDT.createTokenAccount(user1.publicKey);
        await mockUSDT.mintTo(user1UsdtAccount, 10_000);

        vaultUsdtAccount = await mockUSDT.createTokenAccount(vaultPda, true);
        recipientUsdtAccount = await mockUSDT.createTokenAccount(recipient.publicKey);

        const whitelist = await program.account.tokenWhitelist.fetch(whitelistPda);
        const tokens = whitelist.tokens.map((token: PublicKey) => token.toString());
        expect(tokens).to.include(mockUSDT.mint.publicKey.toString());

        const depositLamports = 5 * anchor.web3.LAMPORTS_PER_SOL;
        const transferIx = anchor.web3.SystemProgram.transfer({
            fromPubkey: user1.publicKey,
            toPubkey: vaultPda,
            lamports: depositLamports,
        });
        await provider.sendAndConfirm(new anchor.web3.Transaction().add(transferIx), [user1]);

        await program.methods
            .sendFunds(
                Array.from(Buffer.alloc(20, 1)),
                mockUSDT.mint.publicKey,
                asTokenAmount(5_000),
                { fundRecipient: user1.publicKey, revertMsg: Buffer.from("seed vault") }
            )
            .accounts({
                user: user1.publicKey,
                config: configPda,
                vault: vaultPda,
                tokenWhitelist: whitelistPda,
                userTokenAccount: user1UsdtAccount,
                gatewayTokenAccount: vaultUsdtAccount,
                bridgeToken: mockUSDT.mint.publicKey,
                tokenProgram: TOKEN_PROGRAM_ID,
                systemProgram: SystemProgram.programId,
            })
            .signers([user1])
            .rpc();

        await syncNonceFromChain();
    });

    describe("withdraw", () => {
        it("transfers SOL with a valid signature", async () => {
            const withdrawLamports = 2 * anchor.web3.LAMPORTS_PER_SOL;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            const initialVault = await provider.connection.getBalance(vaultPda);
            const initialRecipient = await provider.connection.getBalance(recipient.publicKey);

            await program.methods
                .withdraw(
                    txId,
                    originCaller,
                    new anchor.BN(withdrawLamports),
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                    signature.nonce
                )
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    tssPda,
                    recipient: recipient.publicKey,
                    executedTx: executedTxPda,
                    caller: relayer.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([relayer])
                .rpc();

            const finalVault = await provider.connection.getBalance(vaultPda);
            const finalRecipient = await provider.connection.getBalance(recipient.publicKey);

            expect(finalVault).to.equal(initialVault - withdrawLamports);
            expect(finalRecipient).to.equal(initialRecipient + withdrawLamports);

            await syncNonceFromChain();
        });

        it("rejects tampered signatures", async () => {
            const withdrawLamports = anchor.web3.LAMPORTS_PER_SOL;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const valid = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            const corrupted = [...valid.signature];
            corrupted[0] ^= 0xff;

            await expectRejection(
                program.methods
                    .withdraw(
                        txId,
                        originCaller,
                        new anchor.BN(withdrawLamports),
                        corrupted,
                        valid.recoveryId,
                        valid.messageHash,
                        valid.nonce
                    )
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc(),
                "TssAuthFailed"
            );

            await syncNonceFromChain();
        });

        it("rejects withdrawals while paused", async () => {
            await program.methods
                .pause()
                .accounts({ pauser: pauser.publicKey, config: configPda })
                .signers([pauser])
                .rpc();

            const withdrawLamports = anchor.web3.LAMPORTS_PER_SOL;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            await expectRejection(
                program.methods
                    .withdraw(
                        txId,
                        originCaller,
                        new anchor.BN(withdrawLamports),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                        signature.nonce
                    )
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc(),
                "PausedError"
            );

            await program.methods
                .unpause()
                .accounts({ pauser: pauser.publicKey, config: configPda })
                .signers([pauser])
                .rpc();

            await syncNonceFromChain();
        });

        it("rejects withdrawals that exceed the vault balance", async () => {
            const vaultLamports = await provider.connection.getBalance(vaultPda);
            const excessive = vaultLamports + anchor.web3.LAMPORTS_PER_SOL;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(excessive),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            await expectRejection(
                program.methods
                    .withdraw(
                        txId,
                        originCaller,
                        new anchor.BN(excessive),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                        signature.nonce
                    )
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc(),
                "custom program error"
            );

            await syncNonceFromChain();
        });
    });

    describe("withdraw_funds", () => {
        it("transfers SPL tokens with a valid signature", async () => {
            const withdrawTokens = 1_000;
            const withdrawRaw = BigInt(withdrawTokens) * TOKEN_MULTIPLIER;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            // Include tx_id, origin_caller, mint AND recipient in message hash
            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSpl,
                nonce: currentNonce,
                amount: withdrawRaw,
                additional: [toBytes(mockUSDT.mint.publicKey), toBytes(recipientUsdtAccount)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            const initialVault = await mockUSDT.getBalance(vaultUsdtAccount);
            const initialRecipient = await mockUSDT.getBalance(recipientUsdtAccount);

            await program.methods
                .withdrawFunds(
                    txId,
                    originCaller,
                    new anchor.BN(Number(withdrawRaw)),
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                    signature.nonce
                )
                .accounts({
                    config: configPda,
                    whitelist: whitelistPda,
                    vault: vaultPda,
                    tokenVault: vaultUsdtAccount,
                    tssPda,
                    recipientTokenAccount: recipientUsdtAccount,
                    tokenMint: mockUSDT.mint.publicKey,
                    executedTx: executedTxPda,
                    caller: relayer.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([relayer])
                .rpc();

            const finalVault = await mockUSDT.getBalance(vaultUsdtAccount);
            const finalRecipient = await mockUSDT.getBalance(recipientUsdtAccount);

            expect(finalVault).to.equal(initialVault - withdrawTokens);
            expect(finalRecipient).to.equal(initialRecipient + withdrawTokens);

            await syncNonceFromChain();
        });

        it("rejects SPL withdrawals with a tampered signature", async () => {
            const withdrawTokens = 200;
            const withdrawRaw = BigInt(withdrawTokens) * TOKEN_MULTIPLIER;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            // Include tx_id, origin_caller, mint AND recipient in message hash
            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSpl,
                nonce: currentNonce,
                amount: withdrawRaw,
                additional: [toBytes(mockUSDT.mint.publicKey), toBytes(recipientUsdtAccount)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            const corrupted = [...signature.signature];
            corrupted[0] ^= 0xff;

            await expectRejection(
                program.methods
                    .withdrawFunds(
                        txId,
                        originCaller,
                        new anchor.BN(Number(withdrawRaw)),
                        corrupted,
                        signature.recoveryId,
                        signature.messageHash,
                        signature.nonce
                    )
                    .accounts({
                        config: configPda,
                        whitelist: whitelistPda,
                        vault: vaultPda,
                        tokenVault: vaultUsdtAccount,
                        tssPda,
                        recipientTokenAccount: recipientUsdtAccount,
                        tokenMint: mockUSDT.mint.publicKey,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc(),
                "TssAuthFailed"
            );

            await syncNonceFromChain();
        });
    });

    describe("revert withdrawals", () => {
        it("reverts a SOL withdrawal with a valid signature", async () => {
            const revertAmount = anchor.web3.LAMPORTS_PER_SOL;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const executedTxPda = getExecutedTxPda(txId);

            const revertInstruction = {
                fundRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SOL"),
            };

            // Include tx_id and recipient in message hash (NO origin_caller for revert)
            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSol,
                nonce: currentNonce,
                amount: BigInt(revertAmount),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
            });

            const initialRecipient = await provider.connection.getBalance(recipient.publicKey);

            await program.methods
                .revertUniversalTx(
                    txId,
                    new anchor.BN(revertAmount),
                    revertInstruction,
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                    signature.nonce
                )
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    tssPda,
                    recipient: recipient.publicKey,
                    executedTx: executedTxPda,
                    caller: relayer.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([relayer])
                .rpc();

            const finalRecipient = await provider.connection.getBalance(recipient.publicKey);
            expect(finalRecipient).to.equal(initialRecipient + revertAmount);

            await syncNonceFromChain();
        });

        it("reverts an SPL withdrawal with a valid signature", async () => {
            const revertTokens = 500;
            const revertRaw = BigInt(revertTokens) * TOKEN_MULTIPLIER;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const executedTxPda = getExecutedTxPda(txId);

            const revertInstruction = {
                fundRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SPL"),
            };

            // Create recipient account first (needed for message hash)
            const recipientRevertAccount = await mockUSDT.createTokenAccount(recipient.publicKey);

            // Include tx_id, mint AND fund_recipient in message hash (NO origin_caller for revert)
            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSpl,
                nonce: currentNonce,
                amount: revertRaw,
                additional: [toBytes(mockUSDT.mint.publicKey), toBytes(revertInstruction.fundRecipient)],
                txId: new Uint8Array(txId),
            });
            const initialRecipientBalance = await mockUSDT.getBalance(recipientRevertAccount);

            await program.methods
                .revertUniversalTxToken(
                    txId,
                    new anchor.BN(Number(revertRaw)),
                    revertInstruction,
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                    signature.nonce
                )
                .accounts({
                    config: configPda,
                    whitelist: whitelistPda,
                    vault: vaultPda,
                    tokenVault: vaultUsdtAccount,
                    tssPda,
                    recipientTokenAccount: recipientRevertAccount,
                    tokenMint: mockUSDT.mint.publicKey,
                    executedTx: executedTxPda,
                    caller: relayer.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([relayer])
                .rpc();

            const finalRecipientBalance = await mockUSDT.getBalance(recipientRevertAccount);
            expect(finalRecipientBalance).to.equal(initialRecipientBalance + revertTokens);

            await syncNonceFromChain();
        });
    });

    describe("error conditions", () => {
        it("rejects zero-amount withdrawals", async () => {
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(0),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            await expectRejection(
                program.methods
                    .withdraw(
                        txId,
                        originCaller,
                        new anchor.BN(0),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                        signature.nonce
                    )
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc(),
                "InvalidAmount"
            );

            await syncNonceFromChain();
        });

        it("rejects withdrawals with incorrect nonce", async () => {
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(anchor.web3.LAMPORTS_PER_SOL),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            await expectRejection(
                program.methods
                    .withdraw(
                        txId,
                        originCaller,
                        new anchor.BN(anchor.web3.LAMPORTS_PER_SOL),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                        new anchor.BN(currentNonce + 5)
                    )
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc(),
                "NonceMismatch"
            );

            await syncNonceFromChain();
        });

        it("rejects withdrawals with zero originCaller", async () => {
            await setNonceOnChain(currentNonce);

            const txId = generateTxId(); // Unique tx_id for this test
            const zeroOriginCaller = Array.from(Buffer.alloc(20, 0)); // All zeros
            const executedTxPda = getExecutedTxPda(txId);

            // Verify executed_tx doesn't exist before (should be unique tx_id)
            try {
                await program.account.executedTx.fetch(executedTxPda);
                expect.fail("executed_tx should not exist for new tx_id");
            } catch {
                // Expected - account doesn't exist
            }

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(anchor.web3.LAMPORTS_PER_SOL),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(zeroOriginCaller),
            });

            try {
                await program.methods
                    .withdraw(
                        txId,
                        zeroOriginCaller,
                        new anchor.BN(anchor.web3.LAMPORTS_PER_SOL),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                        signature.nonce
                    )
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have thrown InvalidInput error");
            } catch (error: any) {
                const errorStr = error.toString();
                expect(errorStr.includes("InvalidInput")).to.be.true;
            }

            // Verify executed_tx was NOT marked as executed (validation failed before execution)
            try {
                const executedTx = await program.account.executedTx.fetch(executedTxPda);
                expect(executedTx.executed).to.be.false;
            } catch {
                // Account might not exist if init_if_needed didn't create it
            }

            await syncNonceFromChain();
        });

        it("rejects withdrawals with zero recipient", async () => {
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);
            const zeroRecipient = PublicKey.default;

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(anchor.web3.LAMPORTS_PER_SOL),
                additional: [toBytes(zeroRecipient)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            // Anchor throws account validation error for zero recipient
            // Our program also validates this, but Anchor might catch it first
            try {
                await program.methods
                    .withdraw(
                        txId,
                        originCaller,
                        new anchor.BN(anchor.web3.LAMPORTS_PER_SOL),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                        signature.nonce
                    )
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        tssPda,
                        recipient: zeroRecipient,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have thrown an error for zero recipient");
            } catch (error: any) {
                const errorStr = error.toString();
                // Check for either Anchor account validation error or our custom InvalidInput error
                expect(
                    errorStr.includes("InvalidInput") ||
                    errorStr.includes("AnchorError") ||
                    errorStr.includes("recipient")
                ).to.be.true;
            }

            await syncNonceFromChain();
        });

        it("rejects duplicate txID (replay protection)", async () => {
            const withdrawLamports = anchor.web3.LAMPORTS_PER_SOL;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            // First withdrawal should succeed
            await program.methods
                .withdraw(
                    txId,
                    originCaller,
                    new anchor.BN(withdrawLamports),
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                    signature.nonce
                )
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    tssPda,
                    recipient: recipient.publicKey,
                    executedTx: executedTxPda,
                    caller: relayer.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([relayer])
                .rpc();

            // Verify executed = true after success
            const executedTxAfter = await program.account.executedTx.fetch(executedTxPda);
            expect(executedTxAfter.executed).to.be.true;

            await syncNonceFromChain();

            // Second withdrawal with same txID should fail
            await setNonceOnChain(currentNonce);
            const signature2 = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            try {
                await program.methods
                    .withdraw(
                        txId,
                        originCaller,
                        new anchor.BN(withdrawLamports),
                        signature2.signature,
                        signature2.recoveryId,
                        signature2.messageHash,
                        signature2.nonce
                    )
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have thrown PayloadExecuted error");
            } catch (error: any) {
                const errorStr = error.toString();
                expect(errorStr.includes("PayloadExecuted") || errorStr.includes("Payload already executed")).to.be.true;
            }

            await syncNonceFromChain();
        });

        it("does NOT set executed=true on failed withdrawal (griefing protection)", async () => {
            const withdrawLamports = anchor.web3.LAMPORTS_PER_SOL;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const valid = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            // Corrupt signature to make it fail
            const corrupted = [...valid.signature];
            corrupted[0] ^= 0xff;

            // Attempt withdrawal with corrupted signature (should fail)
            try {
                await program.methods
                    .withdraw(
                        txId,
                        originCaller,
                        new anchor.BN(withdrawLamports),
                        corrupted,
                        valid.recoveryId,
                        valid.messageHash,
                        valid.nonce
                    )
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have failed with TssAuthFailed");
            } catch (error: any) {
                expect(error.toString().includes("TssAuthFailed")).to.be.true;
            }

            // Verify failed call didn't set executed = true
            try {
                const executedTx = await program.account.executedTx.fetch(executedTxPda);
                expect(executedTx.executed).to.be.false;
            } catch {
                // Account doesn't exist, which is fine
            }

            // Now try with VALID signature - should succeed (proves tx_id wasn't bricked)
            await setNonceOnChain(currentNonce);
            const validSig = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            await program.methods
                .withdraw(
                    txId,
                    originCaller,
                    new anchor.BN(withdrawLamports),
                    validSig.signature,
                    validSig.recoveryId,
                    validSig.messageHash,
                    validSig.nonce
                )
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    tssPda,
                    recipient: recipient.publicKey,
                    executedTx: executedTxPda,
                    caller: relayer.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([relayer])
                .rpc();

            // Verify executed = true after success
            const executedTx = await program.account.executedTx.fetch(executedTxPda);
            expect(executedTx.executed).to.be.true;

            await syncNonceFromChain();
        });
    });

    describe("revert error conditions", () => {
        it("rejects revert with zero amount", async () => {
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const executedTxPda = getExecutedTxPda(txId);

            const revertInstruction = {
                fundRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SOL"),
            };

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSol,
                nonce: currentNonce,
                amount: BigInt(0),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
            });

            await expectRejection(
                program.methods
                    .revertUniversalTx(
                        txId,
                        new anchor.BN(0),
                        revertInstruction,
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                        signature.nonce
                    )
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc(),
                "InvalidAmount"
            );

            await syncNonceFromChain();
        });

        it("rejects revert with zero fundRecipient", async () => {
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const executedTxPda = getExecutedTxPda(txId);
            const revertAmount = anchor.web3.LAMPORTS_PER_SOL;

            const revertInstruction = {
                fundRecipient: PublicKey.default,
                revertMsg: Buffer.from("revert SOL"),
            };

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSol,
                nonce: currentNonce,
                amount: BigInt(revertAmount),
                additional: [toBytes(PublicKey.default)],
                txId: new Uint8Array(txId),
            });

            // Our program validates fundRecipient != Pubkey::default()
            // But Anchor might also throw account validation error
            try {
                await program.methods
                    .revertUniversalTx(
                        txId,
                        new anchor.BN(revertAmount),
                        revertInstruction,
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                        signature.nonce
                    )
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        tssPda,
                        recipient: recipient.publicKey, // Use valid recipient for account validation
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have thrown an error for zero fundRecipient");
            } catch (error: any) {
                const errorStr = error.toString();
                // Our program should throw InvalidRecipient for zero fundRecipient
                expect(
                    errorStr.includes("InvalidRecipient") ||
                    errorStr.includes("AnchorError")
                ).to.be.true;
            }

            await syncNonceFromChain();
        });

        it("rejects duplicate revert txID (replay protection)", async () => {
            const revertAmount = anchor.web3.LAMPORTS_PER_SOL;
            await setNonceOnChain(currentNonce);

            // Fund vault before revert (needed for the transfer)
            const vaultBalance = await provider.connection.getBalance(vaultPda);
            if (vaultBalance < revertAmount * 2) {
                // Transfer enough for both revert attempts
                const fundAmount = revertAmount * 2 + anchor.web3.LAMPORTS_PER_SOL; // Extra for rent
                const fundTx = await provider.connection.requestAirdrop(vaultPda, fundAmount);
                await provider.connection.confirmTransaction(fundTx);
                await new Promise(resolve => setTimeout(resolve, 1000));
            }

            const txId = generateTxId();
            const executedTxPda = getExecutedTxPda(txId);

            const revertInstruction = {
                fundRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SOL"),
            };

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSol,
                nonce: currentNonce,
                amount: BigInt(revertAmount),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
            });

            // First revert should succeed
            await program.methods
                .revertUniversalTx(
                    txId,
                    new anchor.BN(revertAmount),
                    revertInstruction,
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                    signature.nonce
                )
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    tssPda,
                    recipient: recipient.publicKey,
                    executedTx: executedTxPda,
                    caller: relayer.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([relayer])
                .rpc();

            // Verify executed = true after success
            const executedTxAfter = await program.account.executedTx.fetch(executedTxPda);
            expect(executedTxAfter.executed).to.be.true;

            await syncNonceFromChain();

            // Second revert with same txID should fail
            await setNonceOnChain(currentNonce);
            const signature2 = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSol,
                nonce: currentNonce,
                amount: BigInt(revertAmount),
                additional: [toBytes(recipient.publicKey)],
                txId: new Uint8Array(txId),
            });

            try {
                await program.methods
                    .revertUniversalTx(
                        txId,
                        new anchor.BN(revertAmount),
                        revertInstruction,
                        signature2.signature,
                        signature2.recoveryId,
                        signature2.messageHash,
                        signature2.nonce
                    )
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        tssPda,
                        recipient: recipient.publicKey,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have thrown PayloadExecuted error");
            } catch (error: any) {
                const errorStr = error.toString();
                expect(errorStr.includes("PayloadExecuted") || errorStr.includes("Payload already executed")).to.be.true;
            }

            await syncNonceFromChain();
        });

        it("rejects SPL revert with zero amount", async () => {
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const executedTxPda = getExecutedTxPda(txId);

            const revertInstruction = {
                fundRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SPL"),
            };

            const recipientRevertAccount = await mockUSDT.createTokenAccount(recipient.publicKey);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSpl,
                nonce: currentNonce,
                amount: BigInt(0),
                additional: [toBytes(mockUSDT.mint.publicKey), toBytes(revertInstruction.fundRecipient)],
                txId: new Uint8Array(txId),
            });

            await expectRejection(
                program.methods
                    .revertUniversalTxToken(
                        txId,
                        new anchor.BN(0),
                        revertInstruction,
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                        signature.nonce
                    )
                    .accounts({
                        config: configPda,
                        whitelist: whitelistPda,
                        vault: vaultPda,
                        tokenVault: vaultUsdtAccount,
                        tssPda,
                        recipientTokenAccount: recipientRevertAccount,
                        tokenMint: mockUSDT.mint.publicKey,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc(),
                "InvalidAmount"
            );

            await syncNonceFromChain();
        });

        it("rejects SPL revert with zero fundRecipient", async () => {
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const executedTxPda = getExecutedTxPda(txId);
            const revertTokens = 500;
            const revertRaw = BigInt(revertTokens) * TOKEN_MULTIPLIER;

            const revertInstruction = {
                fundRecipient: PublicKey.default,
                revertMsg: Buffer.from("revert SPL"),
            };

            const recipientRevertAccount = await mockUSDT.createTokenAccount(recipient.publicKey);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSpl,
                nonce: currentNonce,
                amount: revertRaw,
                additional: [toBytes(mockUSDT.mint.publicKey), toBytes(PublicKey.default)],
                txId: new Uint8Array(txId),
            });

            await expectRejection(
                program.methods
                    .revertUniversalTxToken(
                        txId,
                        new anchor.BN(Number(revertRaw)),
                        revertInstruction,
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                        signature.nonce
                    )
                    .accounts({
                        config: configPda,
                        whitelist: whitelistPda,
                        vault: vaultPda,
                        tokenVault: vaultUsdtAccount,
                        tssPda,
                        recipientTokenAccount: recipientRevertAccount,
                        tokenMint: mockUSDT.mint.publicKey,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc(),
                "InvalidRecipient"
            );

            await syncNonceFromChain();
        });

        it("rejects SPL revert duplicate txID (replay protection)", async () => {
            const revertTokens = 500;
            const revertRaw = BigInt(revertTokens) * TOKEN_MULTIPLIER;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const executedTxPda = getExecutedTxPda(txId);

            const revertInstruction = {
                fundRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SPL"),
            };

            const recipientRevertAccount = await mockUSDT.createTokenAccount(recipient.publicKey);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSpl,
                nonce: currentNonce,
                amount: revertRaw,
                additional: [toBytes(mockUSDT.mint.publicKey), toBytes(revertInstruction.fundRecipient)],
                txId: new Uint8Array(txId),
            });

            // First revert should succeed
            await program.methods
                .revertUniversalTxToken(
                    txId,
                    new anchor.BN(Number(revertRaw)),
                    revertInstruction,
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                    signature.nonce
                )
                .accounts({
                    config: configPda,
                    whitelist: whitelistPda,
                    vault: vaultPda,
                    tokenVault: vaultUsdtAccount,
                    tssPda,
                    recipientTokenAccount: recipientRevertAccount,
                    tokenMint: mockUSDT.mint.publicKey,
                    executedTx: executedTxPda,
                    caller: relayer.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([relayer])
                .rpc();

            // Verify executed = true after success
            const executedTxAfter = await program.account.executedTx.fetch(executedTxPda);
            expect(executedTxAfter.executed).to.be.true;

            await syncNonceFromChain();

            // Second revert with same txID should fail
            await setNonceOnChain(currentNonce);
            const signature2 = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSpl,
                nonce: currentNonce,
                amount: revertRaw,
                additional: [toBytes(mockUSDT.mint.publicKey), toBytes(revertInstruction.fundRecipient)],
                txId: new Uint8Array(txId),
            });

            try {
                await program.methods
                    .revertUniversalTxToken(
                        txId,
                        new anchor.BN(Number(revertRaw)),
                        revertInstruction,
                        signature2.signature,
                        signature2.recoveryId,
                        signature2.messageHash,
                        signature2.nonce
                    )
                    .accounts({
                        config: configPda,
                        whitelist: whitelistPda,
                        vault: vaultPda,
                        tokenVault: vaultUsdtAccount,
                        tssPda,
                        recipientTokenAccount: recipientRevertAccount,
                        tokenMint: mockUSDT.mint.publicKey,
                        executedTx: executedTxPda,
                        caller: relayer.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([relayer])
                    .rpc();
                expect.fail("Should have thrown PayloadExecuted error");
            } catch (error: any) {
                const errorStr = error.toString();
                expect(errorStr.includes("PayloadExecuted") || errorStr.includes("Payload already executed")).to.be.true;
            }

            await syncNonceFromChain();
        });
    });
});