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

    let configPda: PublicKey;
    let vaultPda: PublicKey;
    let tssPda: PublicKey;
    let whitelistPda: PublicKey;

    let mockUSDT: any;

    let user1UsdtAccount: PublicKey;
    let vaultUsdtAccount: PublicKey;
    let recipientUsdtAccount: PublicKey;

    let currentNonce = 0;

    const syncNonceFromChain = async () => {
        const account = await program.account.tssPda.fetch(tssPda);
        currentNonce = Number(account.nonce);
    };

    const signTssMessageWithChainId = async (params: {
        instruction: TssInstruction;
        nonce: number;
        amount?: bigint;
        additional: Uint8Array[];
    }) => {
        const tssAccount = await program.account.tssPda.fetch(tssPda);
        return signTssMessage({ ...params, chainId: tssAccount.chainId.toNumber() });
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
            expect(`${error}`).to.include(message);
        }
        expect(rejected).to.be.true;
    };

    before(async () => {
        admin = sharedState.getAdmin();
        pauser = sharedState.getPauser();
        mockUSDT = sharedState.getMockUSDT();

        recipient = Keypair.generate();
        user1 = Keypair.generate();

        const airdropLamports = 10 * anchor.web3.LAMPORTS_PER_SOL;
        await Promise.all([
            provider.connection.requestAirdrop(recipient.publicKey, airdropLamports),
            provider.connection.requestAirdrop(user1.publicKey, airdropLamports),
        ]);
        await new Promise(resolve => setTimeout(resolve, 2000));

        [configPda] = PublicKey.findProgramAddressSync([Buffer.from("config")], program.programId);
        [vaultPda] = PublicKey.findProgramAddressSync([Buffer.from("vault")], program.programId);
        [tssPda] = PublicKey.findProgramAddressSync([Buffer.from("tss")], program.programId);
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

    describe("withdraw_tss", () => {
        it("transfers SOL with a valid signature", async () => {
            const withdrawLamports = 2 * anchor.web3.LAMPORTS_PER_SOL;
            await setNonceOnChain(currentNonce);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                additional: [toBytes(recipient.publicKey)],
            });

            const initialVault = await provider.connection.getBalance(vaultPda);
            const initialRecipient = await provider.connection.getBalance(recipient.publicKey);

            await program.methods
                .withdrawTss(
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
                    systemProgram: SystemProgram.programId,
                })
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

            const valid = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                additional: [toBytes(recipient.publicKey)],
            });

            const corrupted = [...valid.signature];
            corrupted[0] ^= 0xff;

            await expectRejection(
                program.methods
                    .withdrawTss(
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
                        systemProgram: SystemProgram.programId,
                    })
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

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                additional: [toBytes(recipient.publicKey)],
            });

            await expectRejection(
                program.methods
                    .withdrawTss(
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
                        systemProgram: SystemProgram.programId,
                    })
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

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(excessive),
                additional: [toBytes(recipient.publicKey)],
            });

            await expectRejection(
                program.methods
                    .withdrawTss(
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
                        systemProgram: SystemProgram.programId,
                    })
                    .rpc(),
                "custom program error"
            );

            await syncNonceFromChain();
        });
    });

    describe("withdrawSplTokenTss", () => {
        it("transfers SPL tokens with a valid signature", async () => {
            const withdrawTokens = 1_000;
            const withdrawRaw = BigInt(withdrawTokens) * TOKEN_MULTIPLIER;
            await setNonceOnChain(currentNonce);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSpl,
                nonce: currentNonce,
                amount: withdrawRaw,
                additional: [toBytes(mockUSDT.mint.publicKey)],
            });

            const initialVault = await mockUSDT.getBalance(vaultUsdtAccount);
            const initialRecipient = await mockUSDT.getBalance(recipientUsdtAccount);

            await program.methods
                .withdrawSplTokenTss(
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
                    tokenProgram: TOKEN_PROGRAM_ID,
                })
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

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSpl,
                nonce: currentNonce,
                amount: withdrawRaw,
                additional: [toBytes(mockUSDT.mint.publicKey)],
            });

            const corrupted = [...signature.signature];
            corrupted[0] ^= 0xff;

            await expectRejection(
                program.methods
                    .withdrawSplTokenTss(
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
                        tokenProgram: TOKEN_PROGRAM_ID,
                    })
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

            const revertInstruction = {
                fundRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SOL"),
            };

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSol,
                nonce: currentNonce,
                amount: BigInt(revertAmount),
                additional: [toBytes(recipient.publicKey)],
            });

            const initialRecipient = await provider.connection.getBalance(recipient.publicKey);

            await program.methods
                .revertWithdraw(
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
                    systemProgram: SystemProgram.programId,
                })
                .rpc();

            const finalRecipient = await provider.connection.getBalance(recipient.publicKey);
            expect(finalRecipient).to.equal(initialRecipient + revertAmount);

            await syncNonceFromChain();
        });

        it("reverts an SPL withdrawal with a valid signature", async () => {
            const revertTokens = 500;
            const revertRaw = BigInt(revertTokens) * TOKEN_MULTIPLIER;
            await setNonceOnChain(currentNonce);

            const revertInstruction = {
                fundRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SPL"),
            };

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSpl,
                nonce: currentNonce,
                amount: revertRaw,
                additional: [toBytes(mockUSDT.mint.publicKey)],
            });

            const recipientRevertAccount = await mockUSDT.createTokenAccount(recipient.publicKey);
            const initialRecipientBalance = await mockUSDT.getBalance(recipientRevertAccount);

            await program.methods
                .revertWithdrawSplToken(
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
                    tokenProgram: TOKEN_PROGRAM_ID,
                })
                .rpc();

            const finalRecipientBalance = await mockUSDT.getBalance(recipientRevertAccount);
            expect(finalRecipientBalance).to.equal(initialRecipientBalance + revertTokens);

            await syncNonceFromChain();
        });
    });

    describe("error conditions", () => {
        it("rejects zero-amount withdrawals", async () => {
            await setNonceOnChain(currentNonce);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(0),
                additional: [toBytes(recipient.publicKey)],
            });

            await expectRejection(
                program.methods
                    .withdrawTss(
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
                        systemProgram: SystemProgram.programId,
                    })
                    .rpc(),
                "InvalidAmount"
            );

            await syncNonceFromChain();
        });

        it("rejects withdrawals with incorrect nonce", async () => {
            await setNonceOnChain(currentNonce);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(anchor.web3.LAMPORTS_PER_SOL),
                additional: [toBytes(recipient.publicKey)],
            });

            await expectRejection(
                program.methods
                    .withdrawTss(
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
                        systemProgram: SystemProgram.programId,
                    })
                    .rpc(),
                "NonceMismatch"
            );

            await syncNonceFromChain();
        });
    });
});
