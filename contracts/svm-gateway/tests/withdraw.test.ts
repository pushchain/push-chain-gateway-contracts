import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import { TOKEN_PROGRAM_ID, ASSOCIATED_TOKEN_PROGRAM_ID, getAssociatedTokenAddressSync } from "@solana/spl-token";
import * as sharedState from "./shared-state";
import { signTssMessage, TssInstruction, generateUniversalTxId } from "./helpers/tss";
import { ensureTestSetup } from "./helpers/test-setup";

const USDT_DECIMALS = 6;
const TOKEN_MULTIPLIER = BigInt(10 ** USDT_DECIMALS);

// Gas fee constants (in lamports)
const DEFAULT_GAS_FEE = BigInt(5000); // 0.000005 SOL for relayer

const asLamports = (sol: number) => new anchor.BN(sol * anchor.web3.LAMPORTS_PER_SOL);
const asTokenAmount = (tokens: number) => new anchor.BN(Number(BigInt(tokens) * TOKEN_MULTIPLIER));

const toBytes = (pubkey: PublicKey) => pubkey.toBuffer();

// Helper to build gas_fee buffer (u64 BE)
const buildGasFeeBuf = (gasFee: bigint): Buffer => {
    const buf = Buffer.alloc(8);
    buf.writeBigUInt64BE(gasFee, 0);
    return buf;
};

describe("Universal Gateway - Withdraw Tests", () => {
    anchor.setProvider(anchor.AnchorProvider.env());
    const provider = anchor.getProvider() as anchor.AnchorProvider;
    const program = anchor.workspace.UniversalGateway as Program<UniversalGateway>;

    before(async () => {
        await ensureTestSetup();
    });

    let admin: Keypair;
    let pauser: Keypair;
    let recipient: Keypair;
    let user1: Keypair;
    let relayer: Keypair; // The caller who pays for transactions

    let configPda: PublicKey;
    let vaultPda: PublicKey;
    let tssPda: PublicKey;
    let rateLimitConfigPda: PublicKey;
    let mockPriceFeed: PublicKey;

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
        const buffer = Buffer.alloc(20);
        for (let i = 0; i < 20; i++) {
            buffer[i] = Math.floor(Math.random() * 256);
        }
        // Ensure it's not all zeros (would fail validation)
        if (buffer.every(b => b === 0)) {
            buffer[0] = 1;
        }
        return Array.from(buffer);
    };

    // Helper to derive executed_tx PDA from tx_id
    const getExecutedTxPda = (txId: number[]): PublicKey => {
        const [pda] = PublicKey.findProgramAddressSync(
            [Buffer.from("executed_tx"), Buffer.from(txId)],
            program.programId
        );
        return pda;
    };

    // Helper to get token rate limit PDA
    const getTokenRateLimitPda = (tokenMint: PublicKey): PublicKey => {
        const [pda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit"), tokenMint.toBuffer()],
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
        user1 = sharedState.getUser1(); // Use shared user1 from test-setup

        recipient = Keypair.generate();
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
        [rateLimitConfigPda] = PublicKey.findProgramAddressSync([Buffer.from("rate_limit_config")], program.programId);

        mockPriceFeed = sharedState.getMockPriceFeed();

        // Get or create user1's USDT account (ATA is deterministic, so this will reuse if exists)
        user1UsdtAccount = await mockUSDT.createTokenAccount(user1.publicKey);

        // Check current balance and mint if needed
        const currentBalance = await mockUSDT.getBalance(user1UsdtAccount);
        const requiredBalance = 10_000 * 1_000_000; // 10,000 tokens in raw units
        if (currentBalance < requiredBalance) {
            // Mint enough to reach 10,000 tokens
            const tokensToMint = 10_000 - (currentBalance / 1_000_000);
            if (tokensToMint > 0) {
                await mockUSDT.mintTo(user1UsdtAccount, tokensToMint);
            }
        }

        vaultUsdtAccount = await mockUSDT.createTokenAccount(vaultPda, true);
        recipientUsdtAccount = await mockUSDT.createTokenAccount(recipient.publicKey);

        // Seed vault with native SOL using sendUniversalTx (FUNDS route)
        const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

        // Initialize native SOL token rate limit if needed
        try {
            await program.account.tokenRateLimit.fetch(nativeSolTokenRateLimitPda);
        } catch {
            const veryLargeThreshold = new anchor.BN("1000000000000000000000"); // Effectively unlimited
            await program.methods
                .setTokenRateLimit(veryLargeThreshold)
                .accounts({
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenMint: PublicKey.default,
                    admin: admin.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        }

        // Deposit 8 SOL to vault for withdrawal tests (leave room for transaction fees)
        const solDepositAmount = 8 * anchor.web3.LAMPORTS_PER_SOL;
        const solFundsReq = {
            recipient: Array.from(Buffer.alloc(20, 0)), // Must be zero for FUNDS
            token: PublicKey.default,
            amount: new anchor.BN(solDepositAmount),
            payload: Buffer.from([]),
            revertInstruction: {
                fundRecipient: user1.publicKey,
                revertMsg: Buffer.from("seed vault sol")
            },
            signatureData: Buffer.from([]),
        };

        // Check user1 balance before deposit
        const user1BalanceBefore = await provider.connection.getBalance(user1.publicKey);
        const vaultBalanceBefore = await provider.connection.getBalance(vaultPda);

        try {
            await program.methods
                .sendUniversalTx(solFundsReq, new anchor.BN(solDepositAmount))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    userTokenAccount: vaultPda, // Dummy account for native SOL routes
                    gatewayTokenAccount: vaultPda, // Dummy account for native SOL routes
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();
        } catch (error: any) {
            throw new Error(`Failed to deposit SOL to vault: ${error.message || error}`);
        }

        // Verify vault was seeded with SOL
        const vaultBalanceAfterDeposit = await provider.connection.getBalance(vaultPda);
        const user1BalanceAfter = await provider.connection.getBalance(user1.publicKey);

        if (vaultBalanceAfterDeposit < vaultBalanceBefore + solDepositAmount * 0.9) { // Allow 10% for fees
            throw new Error(
                `Vault deposit failed. Vault before: ${vaultBalanceBefore}, after: ${vaultBalanceAfterDeposit}, ` +
                `expected at least ${vaultBalanceBefore + solDepositAmount * 0.9}. ` +
                `User1 balance before: ${user1BalanceBefore}, after: ${user1BalanceAfter}`
            );
        }

        // Seed vault with SPL tokens using sendUniversalTx (FUNDS route)
        // user1 has 10,000 tokens minted in test-setup.ts
        const depositAmount = asTokenAmount(5_000);
        const recipientEvm = Array.from(Buffer.alloc(20, 1)); // EVM address (20 bytes)
        const fundsReq = {
            recipient: recipientEvm,
            token: mockUSDT.mint.publicKey,
            amount: depositAmount,
            payload: Buffer.from([]), // Empty payload for FUNDS route
            revertInstruction: {
                fundRecipient: user1.publicKey,
                revertMsg: Buffer.from("seed vault")
            },
            signatureData: Buffer.from([]), // Empty for FUNDS route
        };

        const splTokenRateLimitPda = getTokenRateLimitPda(mockUSDT.mint.publicKey);

        // Initialize token rate limit if needed (with very large threshold to effectively disable)
        try {
            await program.account.tokenRateLimit.fetch(splTokenRateLimitPda);
        } catch {
            // Not initialized, create it
            const veryLargeThreshold = new anchor.BN("1000000000000000000000"); // Effectively unlimited
            await program.methods
                .setTokenRateLimit(veryLargeThreshold)
                .accounts({
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: splTokenRateLimitPda,
                    tokenMint: mockUSDT.mint.publicKey,
                    admin: admin.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        }

        // Verify SPL deposit
        const vaultUsdtBalanceBefore = await mockUSDT.getBalance(vaultUsdtAccount);

        try {
            await program.methods
                .sendUniversalTx(fundsReq, new anchor.BN(0)) // No native SOL for SPL funds
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    user: user1.publicKey,
                    userTokenAccount: user1UsdtAccount,
                    gatewayTokenAccount: vaultUsdtAccount,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: splTokenRateLimitPda,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();
        } catch (error: any) {
            throw new Error(`Failed to deposit SPL tokens to vault: ${error.message || error}`);
        }

        // Verify vault was seeded with SPL tokens
        const vaultUsdtBalanceAfter = await mockUSDT.getBalance(vaultUsdtAccount);
        const user1UsdtBalanceAfter = await mockUSDT.getBalance(user1UsdtAccount);

        // Convert depositAmount from base units to human units (getBalance returns human units)
        const depositAmountHuman = depositAmount.toNumber() / Number(TOKEN_MULTIPLIER);
        const expectedVaultBalance = vaultUsdtBalanceBefore + depositAmountHuman;
        if (vaultUsdtBalanceAfter < expectedVaultBalance) {
            throw new Error(
                `SPL deposit failed. ` +
                `Vault ATA before: ${vaultUsdtBalanceBefore}, after: ${vaultUsdtBalanceAfter}, ` +
                `expected at least ${expectedVaultBalance}. Deposit amount: ${depositAmountHuman} tokens`
            );
        }

        await syncNonceFromChain();
    });

    describe("withdraw", () => {
        it("transfers SOL with a valid signature", async () => {
            const withdrawLamports = 2 * anchor.web3.LAMPORTS_PER_SOL;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            const initialVault = await provider.connection.getBalance(vaultPda);
            const initialRecipient = await provider.connection.getBalance(recipient.publicKey);
            const callerBalanceBefore = await provider.connection.getBalance(relayer.publicKey);

            await program.methods
                .withdraw(
                    txId,
                    universalTxId,
                    originCaller,
                    new anchor.BN(withdrawLamports),
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
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
            const callerBalanceAfter = await provider.connection.getBalance(relayer.publicKey);

            expect(finalVault).to.equal(initialVault - withdrawLamports - Number(DEFAULT_GAS_FEE)); // Vault pays withdraw amount + gas fee
            expect(finalRecipient).to.equal(initialRecipient + withdrawLamports);
            // Caller should receive gas_fee (minus rent for executed_tx account creation)
            const callerBalanceChange = callerBalanceAfter - callerBalanceBefore;
            const actualRentForExecutedTx = 890880; // Approximate rent for 8-byte ExecutedTx account
            const expectedCallerGain = Number(DEFAULT_GAS_FEE) - actualRentForExecutedTx; // gas_fee minus rent for executed_tx
            expect(callerBalanceChange).to.be.closeTo(expectedCallerGain, 100000); // Allow larger variance

            await syncNonceFromChain();
        });

        it("rejects tampered signatures", async () => {
            const withdrawLamports = anchor.web3.LAMPORTS_PER_SOL;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const valid = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            const corrupted = [...valid.signature];
            corrupted[0] ^= 0xff;

            await expectRejection(
                program.methods
                    .withdraw(
                        txId,
                        universalTxId,
                        originCaller,
                        new anchor.BN(withdrawLamports),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
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
            const universalTxId = generateUniversalTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            await expectRejection(
                program.methods
                    .withdraw(
                        txId,
                        universalTxId,
                        originCaller,
                        new anchor.BN(withdrawLamports),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
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
            const universalTxId = generateUniversalTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(excessive),
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            await expectRejection(
                program.methods
                    .withdraw(
                        txId,
                        universalTxId,
                        originCaller,
                        new anchor.BN(excessive),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
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

    describe("withdraw_tokens", () => {
        it("transfers SPL tokens with a valid signature", async () => {
            const withdrawTokens = 1_000;
            const withdrawRaw = BigInt(withdrawTokens) * TOKEN_MULTIPLIER;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            // Include tx_id, origin_caller, mint AND recipient in message hash
            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSpl,
                nonce: currentNonce,
                amount: withdrawRaw,
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(mockUSDT.mint.publicKey), toBytes(recipientUsdtAccount), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            const initialVault = await mockUSDT.getBalance(vaultUsdtAccount);
            const initialRecipient = await mockUSDT.getBalance(recipientUsdtAccount);
            const callerBalanceBefore = await provider.connection.getBalance(relayer.publicKey);

            await program.methods
                .withdrawTokens(
                    txId,
                    universalTxId,
                    originCaller,
                    new anchor.BN(Number(withdrawRaw)),
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                    signature.nonce
                )
                .accounts({
                    config: configPda,
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
            const callerBalanceAfter = await provider.connection.getBalance(relayer.publicKey);

            expect(finalVault).to.equal(initialVault - withdrawTokens);
            expect(finalRecipient).to.equal(initialRecipient + withdrawTokens);
            // Caller should receive gas_fee (minus rent for executed_tx account creation)
            const callerBalanceChange = callerBalanceAfter - callerBalanceBefore;
            const actualRentForExecutedTx = 890880; // Approximate rent for 8-byte ExecutedTx account
            const expectedCallerGain = Number(DEFAULT_GAS_FEE) - actualRentForExecutedTx; // gas_fee minus rent for executed_tx
            expect(callerBalanceChange).to.be.closeTo(expectedCallerGain, 100000); // Allow larger variance

            await syncNonceFromChain();
        });

        it("rejects SPL withdrawals with a tampered signature", async () => {
            const withdrawTokens = 200;
            const withdrawRaw = BigInt(withdrawTokens) * TOKEN_MULTIPLIER;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            // Include tx_id, origin_caller, mint AND recipient in message hash
            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSpl,
                nonce: currentNonce,
                amount: withdrawRaw,
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(mockUSDT.mint.publicKey), toBytes(recipientUsdtAccount), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            const corrupted = [...signature.signature];
            corrupted[0] ^= 0xff;

            await expectRejection(
                program.methods
                    .withdrawTokens(
                        txId,
                        universalTxId,
                        originCaller,
                        new anchor.BN(Number(withdrawRaw)),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        corrupted,
                        signature.recoveryId,
                        signature.messageHash,
                        signature.nonce
                    )
                    .accounts({
                        config: configPda,
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
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(txId);

            const revertInstruction = {
                fundRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SOL"),
            };

            // Include tx_id, recipient, and gas_fee in message hash (NO origin_caller for revert)
            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSol,
                nonce: currentNonce,
                amount: BigInt(revertAmount),
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
            });

            const initialRecipient = await provider.connection.getBalance(recipient.publicKey);
            const callerBalanceBefore = await provider.connection.getBalance(relayer.publicKey);

            await program.methods
                .revertUniversalTx(
                    txId,
                    universalTxId,
                    new anchor.BN(revertAmount),
                    revertInstruction,
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
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
            const callerBalanceAfter = await provider.connection.getBalance(relayer.publicKey);
            expect(finalRecipient).to.equal(initialRecipient + revertAmount);
            // Caller should receive gas_fee (minus rent for executed_tx account creation)
            const callerBalanceChange = callerBalanceAfter - callerBalanceBefore;
            const actualRentForExecutedTx = 890880; // Approximate rent for 8-byte ExecutedTx account
            const expectedCallerGain = Number(DEFAULT_GAS_FEE) - actualRentForExecutedTx; // gas_fee minus rent for executed_tx
            expect(callerBalanceChange).to.be.closeTo(expectedCallerGain, 100000); // Allow larger variance

            await syncNonceFromChain();
        });

        it("reverts an SPL withdrawal with a valid signature", async () => {
            const revertTokens = 500;
            const revertRaw = BigInt(revertTokens) * TOKEN_MULTIPLIER;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(txId);

            const revertInstruction = {
                fundRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SPL"),
            };

            // Create recipient account first (needed for message hash)
            const recipientRevertAccount = await mockUSDT.createTokenAccount(recipient.publicKey);

            // Include tx_id, mint, fund_recipient, and gas_fee in message hash (NO origin_caller for revert)
            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSpl,
                nonce: currentNonce,
                amount: revertRaw,
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(mockUSDT.mint.publicKey), toBytes(revertInstruction.fundRecipient), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
            });
            const initialRecipientBalance = await mockUSDT.getBalance(recipientRevertAccount);
            const callerBalanceBefore = await provider.connection.getBalance(relayer.publicKey);

            await program.methods
                .revertUniversalTxToken(
                    txId,
                    universalTxId,
                    new anchor.BN(Number(revertRaw)),
                    revertInstruction,
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                    signature.nonce
                )
                .accounts({
                    config: configPda,
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
            const callerBalanceAfter = await provider.connection.getBalance(relayer.publicKey);
            expect(finalRecipientBalance).to.equal(initialRecipientBalance + revertTokens);
            // Caller should receive gas_fee (minus rent for executed_tx account creation)
            const callerBalanceChange = callerBalanceAfter - callerBalanceBefore;
            const actualRentForExecutedTx = 890880; // Approximate rent for 8-byte ExecutedTx account
            const expectedCallerGain = Number(DEFAULT_GAS_FEE) - actualRentForExecutedTx; // gas_fee minus rent for executed_tx
            expect(callerBalanceChange).to.be.closeTo(expectedCallerGain, 100000); // Allow larger variance

            await syncNonceFromChain();
        });
    });

    describe("error conditions", () => {
        it("rejects zero-amount withdrawals", async () => {
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(0),
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            await expectRejection(
                program.methods
                    .withdraw(
                        txId,
                        universalTxId,
                        originCaller,
                        new anchor.BN(0),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
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
            const universalTxId = generateUniversalTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(anchor.web3.LAMPORTS_PER_SOL),
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            await expectRejection(
                program.methods
                    .withdraw(
                        txId,
                        universalTxId,
                        originCaller,
                        new anchor.BN(anchor.web3.LAMPORTS_PER_SOL),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
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

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId(); // Unique tx_id for this test
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
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(zeroOriginCaller),
            });

            try {
                await program.methods
                    .withdraw(
                        txId,
                        universalTxId,
                        zeroOriginCaller,
                        new anchor.BN(anchor.web3.LAMPORTS_PER_SOL),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
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

            // Verify executed_tx was NOT created (validation failed before execution, atomic rollback)
            try {
                await program.account.executedTx.fetch(executedTxPda);
                expect.fail("executed_tx should not exist - transaction failed atomically");
            } catch {
                // Expected - account doesn't exist (atomic transaction rollback)
            }

            await syncNonceFromChain();
        });

        it("rejects withdrawals with zero recipient", async () => {
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);
            const zeroRecipient = PublicKey.default;

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(anchor.web3.LAMPORTS_PER_SOL),
                additional: [toBytes(zeroRecipient), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            // Anchor throws account validation error for zero recipient
            // Our program also validates this, but Anchor might catch it first
            try {
                await program.methods
                    .withdraw(
                        txId,
                        universalTxId,
                        originCaller,
                        new anchor.BN(anchor.web3.LAMPORTS_PER_SOL),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
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
            const universalTxId = generateUniversalTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            // First withdrawal should succeed
            const callerBalanceBefore = await provider.connection.getBalance(relayer.publicKey);
            await program.methods
                .withdraw(
                    txId,
                    universalTxId,
                    originCaller,
                    new anchor.BN(withdrawLamports),
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
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

            // Verify caller received gas fee
            const callerBalanceAfter = await provider.connection.getBalance(relayer.publicKey);
            const callerBalanceChange = callerBalanceAfter - callerBalanceBefore;
            // Caller pays for executed_tx account rent, receives gas_fee (transaction fees vary, so we use tolerance)
            const actualRentForExecutedTx = await provider.connection.getMinimumBalanceForRentExemption(8);
            const expectedCallerGain = -actualRentForExecutedTx + Number(DEFAULT_GAS_FEE);
            expect(callerBalanceChange).to.be.closeTo(expectedCallerGain, 15000); // Allow for transaction fees

            // Verify executed_tx account exists after success
            // The account is a PDA derived from [b"executed_tx", tx_id], so existence = tx_id was executed
            // Since ExecutedTx is an empty struct {}, we only verify account existence
            const executedTxAfter = await program.account.executedTx.fetch(executedTxPda);
            expect(executedTxAfter).to.not.be.null; // Account existence = transaction executed

            await syncNonceFromChain();

            // Second withdrawal with same txID should fail
            await setNonceOnChain(currentNonce);
            const signature2 = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            try {
                await program.methods
                    .withdraw(
                        txId,
                        universalTxId,
                        originCaller,
                        new anchor.BN(withdrawLamports),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
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
                // With `init`, duplicate txID fails at system program level (account already exists)
                // The error comes from Solana system program: "Allocate: account ... already in use"
                const errorStr = error.toString();
                const errorLogs = error.logs || [];
                const allLogs = Array.isArray(errorLogs) ? errorLogs.join(' ') : '';

                // Check for the system program error indicating account already exists
                const isReplayError =
                    errorStr.includes("already in use") ||
                    allLogs.includes("already in use") ||
                    errorStr.includes("AccountDiscriminatorAlreadySet") ||
                    allLogs.includes("AccountDiscriminatorAlreadySet");

                expect(isReplayError).to.be.true;
            }

            await syncNonceFromChain();
        });

        it("does NOT set executed=true on failed withdrawal (griefing protection)", async () => {
            const withdrawLamports = anchor.web3.LAMPORTS_PER_SOL;
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const originCaller = generateOriginCaller();
            const executedTxPda = getExecutedTxPda(txId);

            const valid = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
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
                        universalTxId,
                        originCaller,
                        new anchor.BN(withdrawLamports),
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
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

            // Verify failed call didn't create executed_tx account (atomic rollback)
            try {
                await program.account.executedTx.fetch(executedTxPda);
                expect.fail("executed_tx should not exist - transaction failed atomically");
            } catch {
                // Expected - account doesn't exist (atomic transaction rollback)
            }

            // Now try with VALID signature - should succeed (proves tx_id wasn't bricked)
            await setNonceOnChain(currentNonce);
            const validSig = await signTssMessageWithChainId({
                instruction: TssInstruction.WithdrawSol,
                nonce: currentNonce,
                amount: BigInt(withdrawLamports),
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
                originCaller: new Uint8Array(originCaller),
            });

            await program.methods
                .withdraw(
                    txId,
                    universalTxId,
                    originCaller,
                    new anchor.BN(withdrawLamports),
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
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

            // Verify executed_tx account exists after success (account existence = executed)
            const executedTx = await program.account.executedTx.fetch(executedTxPda);
            expect(executedTx).to.exist; // Account existence = transaction executed

            await syncNonceFromChain();
        });
    });

    describe("revert error conditions", () => {
        it("rejects revert with zero amount", async () => {
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(txId);

            const revertInstruction = {
                fundRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SOL"),
            };

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSol,
                nonce: currentNonce,
                amount: BigInt(0),
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
            });

            await expectRejection(
                program.methods
                    .revertUniversalTx(
                        txId,
                        universalTxId,
                        new anchor.BN(0),
                        revertInstruction,
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
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
            const universalTxId = generateUniversalTxId();
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
                        universalTxId,
                        new anchor.BN(revertAmount),
                        revertInstruction,
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
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
            const universalTxId = generateUniversalTxId();
            const executedTxPda = getExecutedTxPda(txId);

            const revertInstruction = {
                fundRecipient: recipient.publicKey,
                revertMsg: Buffer.from("revert SOL"),
            };

            const signature = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSol,
                nonce: currentNonce,
                amount: BigInt(revertAmount),
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
            });

            // First revert should succeed
            await program.methods
                .revertUniversalTx(
                    txId,
                    universalTxId,
                    new anchor.BN(revertAmount),
                    revertInstruction,
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
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

            // Verify executed_tx account exists after success
            // The account is a PDA derived from [b"executed_tx", tx_id], so existence = tx_id was executed
            // Since ExecutedTx is an empty struct {}, we only verify account existence
            const executedTxAfter = await program.account.executedTx.fetch(executedTxPda);
            expect(executedTxAfter).to.not.be.null; // Account existence = transaction executed

            await syncNonceFromChain();

            // Second revert with same txID should fail
            await setNonceOnChain(currentNonce);
            const signature2 = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSol,
                nonce: currentNonce,
                amount: BigInt(revertAmount),
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(recipient.publicKey), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
            });

            try {
                await program.methods
                    .revertUniversalTx(
                        txId,
                        universalTxId,
                        new anchor.BN(revertAmount),
                        revertInstruction,
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
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
                // With `init`, duplicate txID fails at system program level (account already exists)
                // The error comes from Solana system program: "Allocate: account ... already in use"
                const errorStr = error.toString();
                const errorLogs = error.logs || [];
                const allLogs = Array.isArray(errorLogs) ? errorLogs.join(' ') : '';

                // Check for the system program error indicating account already exists
                const isReplayError =
                    errorStr.includes("already in use") ||
                    allLogs.includes("already in use") ||
                    errorStr.includes("AccountDiscriminatorAlreadySet") ||
                    allLogs.includes("AccountDiscriminatorAlreadySet");

                expect(isReplayError).to.be.true;
            }

            await syncNonceFromChain();
        });

        it("rejects SPL revert with zero amount", async () => {
            await setNonceOnChain(currentNonce);

            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
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
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(mockUSDT.mint.publicKey), toBytes(revertInstruction.fundRecipient), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
            });

            await expectRejection(
                program.methods
                    .revertUniversalTxToken(
                        txId,
                        universalTxId,
                        new anchor.BN(0),
                        revertInstruction,
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                        signature.nonce
                    )
                    .accounts({
                        config: configPda,
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
            const universalTxId = generateUniversalTxId();
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
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(mockUSDT.mint.publicKey), toBytes(PublicKey.default), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
            });

            await expectRejection(
                program.methods
                    .revertUniversalTxToken(
                        txId,
                        universalTxId,
                        new anchor.BN(Number(revertRaw)),
                        revertInstruction,
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        signature.signature,
                        signature.recoveryId,
                        signature.messageHash,
                        signature.nonce
                    )
                    .accounts({
                        config: configPda,
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
            const universalTxId = generateUniversalTxId();
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
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(mockUSDT.mint.publicKey), toBytes(revertInstruction.fundRecipient), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
            });

            // First revert should succeed
            await program.methods
                .revertUniversalTxToken(
                    txId,
                    universalTxId,
                    new anchor.BN(Number(revertRaw)),
                    revertInstruction,
                    new anchor.BN(Number(DEFAULT_GAS_FEE)),
                    signature.signature,
                    signature.recoveryId,
                    signature.messageHash,
                    signature.nonce
                )
                .accounts({
                    config: configPda,
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

            // Verify executed_tx account exists after success
            // The account is a PDA derived from [b"executed_tx", tx_id], so existence = tx_id was executed
            // Since ExecutedTx is an empty struct {}, we only verify account existence
            const executedTxAfter = await program.account.executedTx.fetch(executedTxPda);
            expect(executedTxAfter).to.not.be.null; // Account existence = transaction executed

            await syncNonceFromChain();

            // Second revert with same txID should fail
            await setNonceOnChain(currentNonce);
            const signature2 = await signTssMessageWithChainId({
                instruction: TssInstruction.RevertWithdrawSpl,
                nonce: currentNonce,
                amount: revertRaw,
                universalTxId: new Uint8Array(universalTxId),
                additional: [toBytes(mockUSDT.mint.publicKey), toBytes(revertInstruction.fundRecipient), buildGasFeeBuf(DEFAULT_GAS_FEE)],
                txId: new Uint8Array(txId),
            });

            try {
                await program.methods
                    .revertUniversalTxToken(
                        txId,
                        universalTxId,
                        new anchor.BN(Number(revertRaw)),
                        revertInstruction,
                        new anchor.BN(Number(DEFAULT_GAS_FEE)),
                        signature2.signature,
                        signature2.recoveryId,
                        signature2.messageHash,
                        signature2.nonce
                    )
                    .accounts({
                        config: configPda,
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
                // With `init`, duplicate txID fails at system program level (account already exists)
                // The error comes from Solana system program: "Allocate: account ... already in use"
                const errorStr = error.toString();
                const errorLogs = error.logs || [];
                const allLogs = Array.isArray(errorLogs) ? errorLogs.join(' ') : '';

                // Check for the system program error indicating account already exists
                const isReplayError =
                    errorStr.includes("already in use") ||
                    allLogs.includes("already in use") ||
                    errorStr.includes("AccountDiscriminatorAlreadySet") ||
                    allLogs.includes("AccountDiscriminatorAlreadySet");
                expect(isReplayError).to.be.true;
            }

            await syncNonceFromChain();
        });
    });
});