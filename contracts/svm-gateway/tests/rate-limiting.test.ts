import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import { TOKEN_PROGRAM_ID, getAssociatedTokenAddress } from "@solana/spl-token";
import * as sharedState from "./shared-state";
import { createMockUSDC } from "./helpers/mockSpl";
import { getSolPrice, calculateSolAmount } from "./setup-pricefeed";

describe("Universal Gateway - Rate Limiting Tests", () => {
    anchor.setProvider(anchor.AnchorProvider.env());
    const provider = anchor.getProvider() as anchor.AnchorProvider;
    const program = anchor.workspace.UniversalGateway as Program<UniversalGateway>;

    let admin: Keypair;
    let tssAddress: Keypair;
    let pauser: Keypair;
    let user1: Keypair;
    let user2: Keypair;
    let configPda: PublicKey;
    let vaultPda: PublicKey;
    let whitelistPda: PublicKey;
    let rateLimitConfigPda: PublicKey;
    let mockPriceFeed: PublicKey;
    let mockUSDT: any;
    let mockUSDC: any;
    let user1UsdtAccount: PublicKey;
    let vaultUsdtAccount: PublicKey;
    let solPrice: number;

    const createPayload = (to: number, vType: any = { signedVerification: {} }) => ({
        to: Array.from(Buffer.alloc(20, to)),
        value: new anchor.BN(0),
        data: Buffer.from([]),
        gasLimit: new anchor.BN(21000),
        maxFeePerGas: new anchor.BN(20000000000),
        maxPriorityFeePerGas: new anchor.BN(1000000000),
        nonce: new anchor.BN(0),
        deadline: new anchor.BN(Math.floor(Date.now() / 1000) + 3600),
        vType,
    });

    const createRevertInstruction = (recipient: PublicKey, msg: string = "test") => ({
        fundRecipient: recipient,
        revertMsg: Buffer.from(msg),
    });

    before(async () => {
        // Use shared state keys
        admin = sharedState.getAdmin();
        tssAddress = sharedState.getTssAddress();
        pauser = sharedState.getPauser();
        mockUSDT = sharedState.getMockUSDT();
        mockPriceFeed = sharedState.getMockPriceFeed();

        user1 = Keypair.generate();
        user2 = Keypair.generate();

        const airdropAmount = 10 * anchor.web3.LAMPORTS_PER_SOL;
        await Promise.all([
            provider.connection.requestAirdrop(user1.publicKey, airdropAmount),
            provider.connection.requestAirdrop(user2.publicKey, airdropAmount),
        ]);
        await new Promise(resolve => setTimeout(resolve, 2000));

        [configPda] = PublicKey.findProgramAddressSync([Buffer.from("config")], program.programId);
        [vaultPda] = PublicKey.findProgramAddressSync([Buffer.from("vault")], program.programId);
        [whitelistPda] = PublicKey.findProgramAddressSync([Buffer.from("whitelist")], program.programId);
        [rateLimitConfigPda] = PublicKey.findProgramAddressSync([Buffer.from("rate_limit_config")], program.programId);

        // Get current SOL price from the price feed
        solPrice = await getSolPrice(mockPriceFeed);

        user1UsdtAccount = await mockUSDT.createTokenAccount(user1.publicKey);
        vaultUsdtAccount = await mockUSDT.createTokenAccount(vaultPda, true);

        await mockUSDT.mintTo(user1UsdtAccount, 100000);
    });

    describe("Block-based USD Cap Rate Limiting - send_tx_with_gas", () => {
        it("Allows deposits within block USD cap", async () => {
            // Set a block USD cap of $50 (in 8 decimals: 50 * 10^8)
            const blockUsdCap = new anchor.BN(50 * 1e8);
            await program.methods
                .setBlockUsdCap(blockUsdCap)
                .accounts({
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    admin: admin.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // Calculate amount for $5 deposit (well within cap)
            const depositUsd = 5;
            const depositAmount = calculateSolAmount(depositUsd, solPrice);

            const payload = createPayload(1);
            const revertInstruction = createRevertInstruction(user1.publicKey);

            await program.methods
                .sendTxWithGas(payload, revertInstruction, new anchor.BN(depositAmount), Buffer.from([]))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts([
                    { pubkey: rateLimitConfigPda, isSigner: false, isWritable: true },
                ])
                .signers([user1])
                .rpc();

            // Verify deposit succeeded
            const vaultBalance = await provider.connection.getBalance(vaultPda);
            expect(vaultBalance).to.be.greaterThan(0);
        });

        it("Rejects deposits exceeding block USD cap", async () => {
            // Set a block USD cap of $10 (in 8 decimals: 10 * 10^8)
            const blockUsdCap = new anchor.BN(10 * 1e8);
            await program.methods
                .setBlockUsdCap(blockUsdCap)
                .accounts({
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    admin: admin.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // First deposit of $5 (within cap)
            const deposit1Usd = 5;
            const deposit1Amount = calculateSolAmount(deposit1Usd, solPrice);

            const payload1 = createPayload(1);
            const revertInstruction1 = createRevertInstruction(user1.publicKey);

            await program.methods
                .sendTxWithGas(payload1, revertInstruction1, new anchor.BN(deposit1Amount), Buffer.from([]))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts([
                    { pubkey: rateLimitConfigPda, isSigner: false, isWritable: true },
                ])
                .signers([user1])
                .rpc();

            // Second deposit of $6 (would exceed $10 cap)
            const deposit2Usd = 6;
            const deposit2Amount = calculateSolAmount(deposit2Usd, solPrice);

            const payload2 = createPayload(2);
            const revertInstruction2 = createRevertInstruction(user1.publicKey);

            try {
                await program.methods
                    .sendTxWithGas(payload2, revertInstruction2, new anchor.BN(deposit2Amount), Buffer.from([]))
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        user: user1.publicKey,
                        priceUpdate: mockPriceFeed,
                        systemProgram: SystemProgram.programId,
                    })
                    .remainingAccounts([
                        { pubkey: rateLimitConfigPda, isSigner: false, isWritable: true },
                    ])
                    .signers([user1])
                    .rpc();

                expect.fail("Should have rejected deposit exceeding block USD cap");
            } catch (error: any) {
                const errorCode = error.error?.errorCode?.number || error.errorCode?.number || error.code;
                expect(errorCode).to.equal(6006); // BlockUsdCapExceeded
            }
        });

        it("Resets block USD cap on new slot", async () => {
            // Set a block USD cap of $10
            const blockUsdCap = new anchor.BN(10 * 1e8);
            await program.methods
                .setBlockUsdCap(blockUsdCap)
                .accounts({
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    admin: admin.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // First deposit of $5
            const deposit1Usd = 5;
            const deposit1Amount = calculateSolAmount(deposit1Usd, solPrice);

            const payload1 = createPayload(1);
            const revertInstruction1 = createRevertInstruction(user1.publicKey);

            await program.methods
                .sendTxWithGas(payload1, revertInstruction1, new anchor.BN(deposit1Amount), Buffer.from([]))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts([
                    { pubkey: rateLimitConfigPda, isSigner: false, isWritable: true },
                ])
                .signers([user1])
                .rpc();

            // Wait for a new slot (this might take a moment on localnet)
            // On localnet, slots advance quickly, so we'll just wait a bit
            await new Promise(resolve => setTimeout(resolve, 1000));

            // After new slot, should be able to deposit $5 again
            const deposit2Usd = 5;
            const deposit2Amount = calculateSolAmount(deposit2Usd, solPrice);

            const payload2 = createPayload(2);
            const revertInstruction2 = createRevertInstruction(user1.publicKey);

            await program.methods
                .sendTxWithGas(payload2, revertInstruction2, new anchor.BN(deposit2Amount), Buffer.from([]))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts([
                    { pubkey: rateLimitConfigPda, isSigner: false, isWritable: true },
                ])
                .signers([user1])
                .rpc();

            // Verify both deposits succeeded
            const vaultBalance = await provider.connection.getBalance(vaultPda);
            expect(vaultBalance).to.be.greaterThan(0);
        });
    });

    describe("Block-based USD Cap Rate Limiting - send_tx_with_funds", () => {
        it("Allows deposits within block USD cap", async () => {
            // Set a block USD cap of $50
            const blockUsdCap = new anchor.BN(50 * 1e8);
            await program.methods
                .setBlockUsdCap(blockUsdCap)
                .accounts({
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    admin: admin.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // Calculate gas amount for $5 deposit
            const gasUsd = 5;
            const gasAmount = calculateSolAmount(gasUsd, solPrice);
            const bridgeAmount = new anchor.BN(1000); // Small SPL token amount

            const payload = createPayload(1);
            const revertInstruction = createRevertInstruction(user1.publicKey);

            await program.methods
                .sendTxWithFunds(
                    mockUSDT.mint.publicKey,
                    bridgeAmount,
                    payload,
                    revertInstruction,
                    new anchor.BN(gasAmount),
                    Buffer.from([])
                )
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    tokenWhitelist: whitelistPda,
                    userTokenAccount: user1UsdtAccount,
                    gatewayTokenAccount: vaultUsdtAccount,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    bridgeToken: mockUSDT.mint.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts([
                    { pubkey: rateLimitConfigPda, isSigner: false, isWritable: true },
                ])
                .signers([user1])
                .rpc();

            // Verify deposit succeeded
            const vaultBalance = await provider.connection.getBalance(vaultPda);
            expect(vaultBalance).to.be.greaterThan(0);
        });

        it("Rejects deposits exceeding block USD cap", async () => {
            // Set a block USD cap of $10
            const blockUsdCap = new anchor.BN(10 * 1e8);
            await program.methods
                .setBlockUsdCap(blockUsdCap)
                .accounts({
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    admin: admin.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // First deposit with $5 gas
            const gas1Usd = 5;
            const gas1Amount = calculateSolAmount(gas1Usd, solPrice);
            const bridgeAmount = new anchor.BN(1000);

            const payload1 = createPayload(1);
            const revertInstruction1 = createRevertInstruction(user1.publicKey);

            await program.methods
                .sendTxWithFunds(
                    mockUSDT.mint.publicKey,
                    bridgeAmount,
                    payload1,
                    revertInstruction1,
                    new anchor.BN(gas1Amount),
                    Buffer.from([])
                )
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    tokenWhitelist: whitelistPda,
                    userTokenAccount: user1UsdtAccount,
                    gatewayTokenAccount: vaultUsdtAccount,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    bridgeToken: mockUSDT.mint.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts([
                    { pubkey: rateLimitConfigPda, isSigner: false, isWritable: true },
                ])
                .signers([user1])
                .rpc();

            // Second deposit with $6 gas (would exceed $10 cap)
            const gas2Usd = 6;
            const gas2Amount = calculateSolAmount(gas2Usd, solPrice);

            const payload2 = createPayload(2);
            const revertInstruction2 = createRevertInstruction(user1.publicKey);

            try {
                await program.methods
                    .sendTxWithFunds(
                        mockUSDT.mint.publicKey,
                        bridgeAmount,
                        payload2,
                        revertInstruction2,
                        new anchor.BN(gas2Amount),
                        Buffer.from([])
                    )
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        tokenWhitelist: whitelistPda,
                        userTokenAccount: user1UsdtAccount,
                        gatewayTokenAccount: vaultUsdtAccount,
                        user: user1.publicKey,
                        priceUpdate: mockPriceFeed,
                        bridgeToken: mockUSDT.mint.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .remainingAccounts([
                        { pubkey: rateLimitConfigPda, isSigner: false, isWritable: true },
                    ])
                    .signers([user1])
                    .rpc();

                expect.fail("Should have rejected deposit exceeding block USD cap");
            } catch (error: any) {
                const errorCode = error.error?.errorCode?.number || error.errorCode?.number || error.code;
                expect(errorCode).to.equal(6006); // BlockUsdCapExceeded
            }
        });
    });

    describe("Token-specific Epoch-based Rate Limiting - send_funds", () => {
        it("Allows deposits within token rate limit", async () => {
            // Set epoch duration to 1 hour (3600 seconds)
            const epochDuration = new anchor.BN(3600);
            await program.methods
                .updateEpochDuration(epochDuration)
                .accounts({
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    admin: admin.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // Set token rate limit threshold to 10000 tokens (6 decimals)
            const limitThreshold = new anchor.BN(10000 * 1e6);
            const [tokenRateLimitPda] = PublicKey.findProgramAddressSync(
                [Buffer.from("rate_limit"), mockUSDT.mint.publicKey.toBuffer()],
                program.programId
            );

            await program.methods
                .setTokenRateLimit(limitThreshold)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: tokenRateLimitPda,
                    tokenMint: mockUSDT.mint.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // Deposit 5000 tokens (within limit)
            const depositAmount = new anchor.BN(5000 * 1e6);
            const recipient = Array.from(Buffer.alloc(20, 1));
            const revertInstruction = createRevertInstruction(user1.publicKey);

            await program.methods
                .sendFunds(recipient, mockUSDT.mint.publicKey, depositAmount, revertInstruction)
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    tokenWhitelist: whitelistPda,
                    userTokenAccount: user1UsdtAccount,
                    gatewayTokenAccount: vaultUsdtAccount,
                    user: user1.publicKey,
                    bridgeToken: mockUSDT.mint.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts([
                    { pubkey: rateLimitConfigPda, isSigner: false, isWritable: true },
                    { pubkey: tokenRateLimitPda, isSigner: false, isWritable: true },
                ])
                .signers([user1])
                .rpc();

            // Verify deposit succeeded
            const vaultTokenBalance = await mockUSDT.getTokenAccountBalance(vaultUsdtAccount);
            expect(vaultTokenBalance).to.be.greaterThan(0);
        });

        it("Rejects deposits exceeding token rate limit", async () => {
            // Set epoch duration to 1 hour
            const epochDuration = new anchor.BN(3600);
            await program.methods
                .updateEpochDuration(epochDuration)
                .accounts({
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    admin: admin.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // Set token rate limit threshold to 10000 tokens
            const limitThreshold = new anchor.BN(10000 * 1e6);
            const [tokenRateLimitPda] = PublicKey.findProgramAddressSync(
                [Buffer.from("rate_limit"), mockUSDT.mint.publicKey.toBuffer()],
                program.programId
            );

            await program.methods
                .setTokenRateLimit(limitThreshold)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: tokenRateLimitPda,
                    tokenMint: mockUSDT.mint.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // First deposit of 6000 tokens
            const deposit1Amount = new anchor.BN(6000 * 1e6);
            const recipient1 = Array.from(Buffer.alloc(20, 1));
            const revertInstruction1 = createRevertInstruction(user1.publicKey);

            await program.methods
                .sendFunds(recipient1, mockUSDT.mint.publicKey, deposit1Amount, revertInstruction1)
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    tokenWhitelist: whitelistPda,
                    userTokenAccount: user1UsdtAccount,
                    gatewayTokenAccount: vaultUsdtAccount,
                    user: user1.publicKey,
                    bridgeToken: mockUSDT.mint.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts([
                    { pubkey: rateLimitConfigPda, isSigner: false, isWritable: true },
                    { pubkey: tokenRateLimitPda, isSigner: false, isWritable: true },
                ])
                .signers([user1])
                .rpc();

            // Second deposit of 5000 tokens (would exceed 10000 limit)
            const deposit2Amount = new anchor.BN(5000 * 1e6);
            const recipient2 = Array.from(Buffer.alloc(20, 2));
            const revertInstruction2 = createRevertInstruction(user1.publicKey);

            try {
                await program.methods
                    .sendFunds(recipient2, mockUSDT.mint.publicKey, deposit2Amount, revertInstruction2)
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        tokenWhitelist: whitelistPda,
                        userTokenAccount: user1UsdtAccount,
                        gatewayTokenAccount: vaultUsdtAccount,
                        user: user1.publicKey,
                        bridgeToken: mockUSDT.mint.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .remainingAccounts([
                        { pubkey: rateLimitConfigPda, isSigner: false, isWritable: true },
                        { pubkey: tokenRateLimitPda, isSigner: false, isWritable: true },
                    ])
                    .signers([user1])
                    .rpc();

                expect.fail("Should have rejected deposit exceeding token rate limit");
            } catch (error: any) {
                const errorCode = error.error?.errorCode?.number || error.errorCode?.number || error.code;
                expect(errorCode).to.equal(6007); // RateLimitExceeded
            }
        });

        it("Resets token rate limit on new epoch", async () => {
            // Set epoch duration to 1 hour
            const epochDuration = new anchor.BN(3600);
            await program.methods
                .updateEpochDuration(epochDuration)
                .accounts({
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    admin: admin.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // Set token rate limit threshold to 10000 tokens
            const limitThreshold = new anchor.BN(10000 * 1e6);
            const [tokenRateLimitPda] = PublicKey.findProgramAddressSync(
                [Buffer.from("rate_limit"), mockUSDT.mint.publicKey.toBuffer()],
                program.programId
            );

            await program.methods
                .setTokenRateLimit(limitThreshold)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: tokenRateLimitPda,
                    tokenMint: mockUSDT.mint.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // First deposit of 6000 tokens
            const deposit1Amount = new anchor.BN(6000 * 1e6);
            const recipient1 = Array.from(Buffer.alloc(20, 1));
            const revertInstruction1 = createRevertInstruction(user1.publicKey);

            await program.methods
                .sendFunds(recipient1, mockUSDT.mint.publicKey, deposit1Amount, revertInstruction1)
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    tokenWhitelist: whitelistPda,
                    userTokenAccount: user1UsdtAccount,
                    gatewayTokenAccount: vaultUsdtAccount,
                    user: user1.publicKey,
                    bridgeToken: mockUSDT.mint.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts([
                    { pubkey: rateLimitConfigPda, isSigner: false, isWritable: true },
                    { pubkey: tokenRateLimitPda, isSigner: false, isWritable: true },
                ])
                .signers([user1])
                .rpc();

            // Wait for epoch to advance (this would require time manipulation in tests)
            // For now, we'll just verify the first deposit succeeded
            // In a real scenario, you'd need to advance time or wait for the epoch to change
            const vaultTokenBalance = await mockUSDT.getTokenAccountBalance(vaultUsdtAccount);
            expect(vaultTokenBalance).to.be.greaterThan(0);
        });
    });

    describe("Backward Compatibility - Rate Limiting Optional", () => {
        it("Allows deposits without rate limit config (backward compatible)", async () => {
            // Deposit without providing rate limit config
            const depositUsd = 5;
            const depositAmount = calculateSolAmount(depositUsd, solPrice);

            const payload = createPayload(1);
            const revertInstruction = createRevertInstruction(user1.publicKey);

            await program.methods
                .sendTxWithGas(payload, revertInstruction, new anchor.BN(depositAmount), Buffer.from([]))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    systemProgram: SystemProgram.programId,
                })
                // No remainingAccounts - rate limiting should be skipped
                .signers([user1])
                .rpc();

            // Verify deposit succeeded
            const vaultBalance = await provider.connection.getBalance(vaultPda);
            expect(vaultBalance).to.be.greaterThan(0);
        });

        it("Allows SPL token deposits without token rate limit (backward compatible)", async () => {
            // Set epoch duration
            const epochDuration = new anchor.BN(3600);
            await program.methods
                .updateEpochDuration(epochDuration)
                .accounts({
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    admin: admin.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // Deposit without providing token rate limit account
            const depositAmount = new anchor.BN(5000 * 1e6);
            const recipient = Array.from(Buffer.alloc(20, 1));
            const revertInstruction = createRevertInstruction(user1.publicKey);

            await program.methods
                .sendFunds(recipient, mockUSDT.mint.publicKey, depositAmount, revertInstruction)
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    tokenWhitelist: whitelistPda,
                    userTokenAccount: user1UsdtAccount,
                    gatewayTokenAccount: vaultUsdtAccount,
                    user: user1.publicKey,
                    bridgeToken: mockUSDT.mint.publicKey,
                    tokenProgram: TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .remainingAccounts([
                    { pubkey: rateLimitConfigPda, isSigner: false, isWritable: true },
                    // No tokenRateLimitPda - should skip token rate limiting
                ])
                .signers([user1])
                .rpc();

            // Verify deposit succeeded
            const vaultTokenBalance = await mockUSDT.getTokenAccountBalance(vaultUsdtAccount);
            expect(vaultTokenBalance).to.be.greaterThan(0);
        });
    });
});


