import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { PublicKey, Keypair, SystemProgram, LAMPORTS_PER_SOL } from "@solana/web3.js";
import { expect } from "chai";
import * as sharedState from "./shared-state";
import { getSolPrice, calculateSolAmount } from "./setup-pricefeed";
import * as spl from "@solana/spl-token";

describe("Universal Gateway - send_universal_tx Tests", () => {
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
    let rateLimitConfigPda: PublicKey;
    let mockPriceFeed: PublicKey;
    let solPrice: number;
    let mockUSDT: any;
    let mockUSDC: any;

    // Helper to create payload
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

    // Helper to serialize payload to bytes (for UniversalTxRequest.payload field)
    // For FUNDS_AND_PAYLOAD validation, we just need a non-empty buffer
    // The actual serialization format doesn't matter for the validation check
    const serializePayload = (payload: any): Buffer => {
        // Create a non-empty buffer to satisfy FUNDS_AND_PAYLOAD payload requirement
        // In production, this would be Anchor-serialized bytes of UniversalPayload
        return Buffer.from(JSON.stringify(payload));
    };

    // Helper to create revert instruction
    const createRevertInstruction = (recipient: PublicKey, msg: string = "test") => ({
        fundRecipient: recipient,
        revertMsg: Buffer.from(msg),
    });

    // Helper to get token rate limit PDA
    const getTokenRateLimitPda = (tokenMint: PublicKey): PublicKey => {
        const [pda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit"), tokenMint.toBuffer()],
            program.programId
        );
        return pda;
    };

    before(async () => {
        admin = sharedState.getAdmin();
        tssAddress = sharedState.getTssAddress();
        pauser = sharedState.getPauser();
        user1 = Keypair.generate();
        user2 = Keypair.generate();

        const airdropAmount = 20 * LAMPORTS_PER_SOL;
        await Promise.all([
            provider.connection.requestAirdrop(user1.publicKey, airdropAmount),
            provider.connection.requestAirdrop(user2.publicKey, airdropAmount),
        ]);
        await new Promise(resolve => setTimeout(resolve, 2000));

        [configPda] = PublicKey.findProgramAddressSync([Buffer.from("config")], program.programId);
        [vaultPda] = PublicKey.findProgramAddressSync([Buffer.from("vault")], program.programId);
        [rateLimitConfigPda] = PublicKey.findProgramAddressSync([Buffer.from("rate_limit_config")], program.programId);

        mockPriceFeed = sharedState.getMockPriceFeed();
        solPrice = await getSolPrice(mockPriceFeed);

        // Get mock tokens
        mockUSDT = sharedState.getMockUSDT();
        mockUSDC = sharedState.getMockUSDC();

        // Initialize token rate limit accounts (required for universal gateway)
        // Use a very large threshold to effectively disable rate limits (since admin function requires > 0)
        // The rate limit will be effectively disabled because epoch_duration is 0 by default
        const veryLargeThreshold = new anchor.BN("1000000000000000000000"); // 1 sextillion (effectively unlimited)

        // Initialize native SOL rate limit
        const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);
        try {
            await program.account.tokenRateLimit.fetch(nativeSolTokenRateLimitPda);
        } catch {
            // Not initialized, create it with very large threshold (effectively disabled)
            await program.methods
                .setTokenRateLimit(veryLargeThreshold)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenMint: PublicKey.default,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        }

        // Initialize USDT rate limit
        const usdtTokenRateLimitPda = getTokenRateLimitPda(mockUSDT.mint.publicKey);
        try {
            await program.account.tokenRateLimit.fetch(usdtTokenRateLimitPda);
        } catch {
            await program.methods
                .setTokenRateLimit(veryLargeThreshold)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: usdtTokenRateLimitPda,
                    tokenMint: mockUSDT.mint.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        }

        // Initialize USDC rate limit
        const usdcTokenRateLimitPda = getTokenRateLimitPda(mockUSDC.mint.publicKey);
        try {
            await program.account.tokenRateLimit.fetch(usdcTokenRateLimitPda);
        } catch {
            await program.methods
                .setTokenRateLimit(veryLargeThreshold)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: usdcTokenRateLimitPda,
                    tokenMint: mockUSDC.mint.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        }
    });

    describe("GAS Route (TxType.GAS)", () => {
        it("Should deposit native SOL as gas without payload", async () => {
            const gasAmount = calculateSolAmount(2.5, solPrice);
            const initialVaultBalance = await provider.connection.getBalance(vaultPda);
            const initialUserBalance = await provider.connection.getBalance(user1.publicKey);

            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(0),
                payload: Buffer.from([]),
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("gas_sig"),
            };

            await program.methods
                .sendUniversalTx(req, new anchor.BN(gasAmount))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    userTokenAccount: vaultPda, // Dummy account for native SOL routes
                    gatewayTokenAccount: vaultPda, // Dummy account for native SOL routes
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            const finalVaultBalance = await provider.connection.getBalance(vaultPda);
            expect(finalVaultBalance - initialVaultBalance).to.equal(gasAmount);
        });

        it("Should route GAS request with payload to GAS_AND_PAYLOAD (not reject)", async () => {
            // NOTE: This test verifies the correct behavior - amount==0 + payload>0 routes to GAS_AND_PAYLOAD
            // The payload validation is commented out in send_tx_with_gas_route (matching EVM V0)
            const gasAmount = calculateSolAmount(2.5, solPrice);
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);
            const initialVaultBalance = await provider.connection.getBalance(vaultPda);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(0),
                payload: serializePayload(createPayload(99)), // Non-empty payload
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("sig"),
            };

            // Should succeed and route to GAS_AND_PAYLOAD (fetchTxType logic)
            await program.methods
                .sendUniversalTx(req, new anchor.BN(gasAmount))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    userTokenAccount: vaultPda, // Correct: use vaultPda as dummy for native SOL
                    gatewayTokenAccount: vaultPda, // Correct: use vaultPda as dummy for native SOL
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            // Verify transaction succeeded (vault balance increased)
            const finalVaultBalance = await provider.connection.getBalance(vaultPda);
            expect(finalVaultBalance - initialVaultBalance).to.equal(gasAmount);
        });
    });

    describe("GAS_AND_PAYLOAD Route", () => {
        it("Should deposit gas with payload", async () => {
            const gasAmount = calculateSolAmount(2.5, solPrice);
            const initialVaultBalance = await provider.connection.getBalance(vaultPda);
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(0),
                payload: serializePayload(createPayload(1)),
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("gas_payload_sig"),
            };

            await program.methods
                .sendUniversalTx(req, new anchor.BN(gasAmount))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    userTokenAccount: vaultPda, // Dummy account for native SOL routes
                    gatewayTokenAccount: vaultPda, // Dummy account for native SOL routes
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            const finalVaultBalance = await provider.connection.getBalance(vaultPda);
            expect(finalVaultBalance - initialVaultBalance).to.equal(gasAmount);
        });

        it("Should allow payload-only execution (gas_amount == 0)", async () => {
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(0),
                payload: serializePayload(createPayload(1)),
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("payload_only"),
            };

            // Should succeed with 0 native amount
            await program.methods
                .sendUniversalTx(req, new anchor.BN(0))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    userTokenAccount: vaultPda, // Dummy account for native SOL routes
                    gatewayTokenAccount: vaultPda, // Dummy account for native SOL routes
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();
        });
    });

    describe("FUNDS Route - Native SOL", () => {
        it("Should bridge native SOL funds", async () => {
            const fundsAmount = 0.5 * LAMPORTS_PER_SOL;
            const initialVaultBalance = await provider.connection.getBalance(vaultPda);
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 0)), // Must be zero for FUNDS
                token: PublicKey.default,
                amount: new anchor.BN(fundsAmount),
                payload: Buffer.from([]),
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("funds_sig"),
            };

            await program.methods
                .sendUniversalTx(req, new anchor.BN(fundsAmount))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    userTokenAccount: vaultPda, // Dummy account for native SOL routes
                    gatewayTokenAccount: vaultPda, // Dummy account for native SOL routes
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            const finalVaultBalance = await provider.connection.getBalance(vaultPda);
            expect(finalVaultBalance - initialVaultBalance).to.equal(fundsAmount);
        });

        it("Should bridge native SOL funds to explicit recipient", async () => {
            const fundsAmount = 0.75 * LAMPORTS_PER_SOL;
            const initialVaultBalance = await provider.connection.getBalance(vaultPda);
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 1)), // Non-zero recipient now allowed
                token: PublicKey.default,
                amount: new anchor.BN(fundsAmount),
                payload: Buffer.from([]),
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("funds_nonzero_recipient"),
            };

            await program.methods
                .sendUniversalTx(req, new anchor.BN(fundsAmount))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    userTokenAccount: vaultPda,
                    gatewayTokenAccount: vaultPda,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            const finalVaultBalance = await provider.connection.getBalance(vaultPda);
            expect(finalVaultBalance - initialVaultBalance).to.equal(fundsAmount);
        });

        it("Should reject FUNDS when native amount does not match bridge amount", async () => {
            const fundsAmount = 0.5 * LAMPORTS_PER_SOL;
            const wrongNativeAmount = fundsAmount - 1234;
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(fundsAmount),
                payload: Buffer.from([]),
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("invalid_native_amount"),
            };

            try {
                await program.methods
                    .sendUniversalTx(req, new anchor.BN(wrongNativeAmount))
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        userTokenAccount: vaultPda,
                        gatewayTokenAccount: vaultPda,
                        user: user1.publicKey,
                        priceUpdate: mockPriceFeed,
                        rateLimitConfig: rateLimitConfigPda,
                        tokenRateLimit: nativeSolTokenRateLimitPda,
                        tokenProgram: spl.TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject FUNDS when native amount mismatches");
            } catch (error: any) {
                expect(error).to.exist;
                const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
                expect(errorCode).to.equal("InvalidAmount");
            }
        });
    });

    describe("FUNDS Route - SPL Token", () => {
        it("Should bridge SPL token funds", async () => {
            // Create user token account and mint tokens using mock token's methods
            const userTokenAccount = await mockUSDT.createTokenAccount(user1.publicKey);
            const gatewayTokenAccount = await mockUSDT.createTokenAccount(vaultPda, true);

            // Mint tokens using mock token's mintTo method (uses correct mint authority)
            await mockUSDT.mintTo(userTokenAccount, 1000);
            const tokenAmount = new anchor.BN(1000 * 10 ** mockUSDT.config.decimals);

            const initialGatewayBalance = await mockUSDT.getBalance(gatewayTokenAccount);
            const usdtTokenRateLimitPda = getTokenRateLimitPda(mockUSDT.mint.publicKey);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: mockUSDT.mint.publicKey,
                amount: tokenAmount,
                payload: Buffer.from([]),
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("spl_funds_sig"),
            };

            await program.methods
                .sendUniversalTx(req, new anchor.BN(0)) // No native SOL for SPL funds
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    userTokenAccount: userTokenAccount,
                    gatewayTokenAccount: gatewayTokenAccount,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: usdtTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            const finalGatewayBalance = await mockUSDT.getBalance(gatewayTokenAccount);
            const balanceIncrease = (finalGatewayBalance - initialGatewayBalance) * 10 ** mockUSDT.config.decimals;
            expect(balanceIncrease).to.equal(tokenAmount.toNumber());
        });

        it("Should reject FUNDS SPL when native SOL is provided", async () => {
            const userTokenAccount = await mockUSDT.createTokenAccount(user1.publicKey);
            const gatewayTokenAccount = await mockUSDT.createTokenAccount(vaultPda, true);

            await mockUSDT.mintTo(userTokenAccount, 1000);
            const tokenAmount = new anchor.BN(1000 * 10 ** mockUSDT.config.decimals);
            const usdtTokenRateLimitPda = getTokenRateLimitPda(mockUSDT.mint.publicKey);
            const nativeAmount = calculateSolAmount(1.5, solPrice);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: mockUSDT.mint.publicKey,
                amount: tokenAmount,
                payload: Buffer.from([]),
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("spl_native_invalid"),
            };

            try {
                await program.methods
                    .sendUniversalTx(req, new anchor.BN(nativeAmount))
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        userTokenAccount: userTokenAccount,
                        gatewayTokenAccount: gatewayTokenAccount,
                        user: user1.publicKey,
                        priceUpdate: mockPriceFeed,
                        rateLimitConfig: rateLimitConfigPda,
                        tokenRateLimit: usdtTokenRateLimitPda,
                        tokenProgram: spl.TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject FUNDS SPL when native SOL is attached");
            } catch (error: any) {
                expect(error).to.exist;
                const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
                expect(errorCode).to.equal("InvalidAmount");
            }
        });
    });

    describe("FUNDS_AND_PAYLOAD Route - Native SOL with Batching", () => {
        it("Should batch gas + funds for native SOL", async () => {
            // Case 2.2: Batching with native SOL
            // Split: gasAmount = native_amount - req.amount
            // Gas must be >= $1 USD (min cap), funds can be any amount
            // Strategy: Use larger gas amount ($3) and small funds amount to ensure gas >= $1 after split
            const gasAmountLamports = calculateSolAmount(3.0, solPrice); // $3.00 for gas (well above $1 min cap)
            const fundsAmountLamports = calculateSolAmount(0.1, solPrice); // $0.10 for funds (very small)
            const totalAmount = gasAmountLamports + fundsAmountLamports; // Total = gas + funds

            // Verify: after split, gas_amount = totalAmount - fundsAmount = gasAmountLamports (should be >= $1)
            const expectedGasAfterSplit = totalAmount - fundsAmountLamports;
            const expectedGasUsd = (expectedGasAfterSplit / LAMPORTS_PER_SOL) * solPrice;
            if (expectedGasUsd < 1.0) {
                throw new Error(`Expected gas after split ${expectedGasUsd.toFixed(4)} USD is below minimum $1 USD cap. Gas: ${gasAmountLamports}, Funds: ${fundsAmountLamports}, Total: ${totalAmount}`);
            }

            const initialVaultBalance = await provider.connection.getBalance(vaultPda);
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 1)), // Non-zero allowed for FUNDS_AND_PAYLOAD
                token: PublicKey.default,
                amount: new anchor.BN(fundsAmountLamports),
                payload: serializePayload(createPayload(1)), // Non-empty payload required
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("batched_sig"),
            };

            await program.methods
                .sendUniversalTx(req, new anchor.BN(totalAmount))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    userTokenAccount: vaultPda, // Dummy account for native SOL routes
                    gatewayTokenAccount: vaultPda, // Dummy account for native SOL routes
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            const finalVaultBalance = await provider.connection.getBalance(vaultPda);
            // Should receive both gas and funds
            expect(finalVaultBalance - initialVaultBalance).to.equal(totalAmount);
        });

        it("Should reject FUNDS_AND_PAYLOAD native when native amount is insufficient", async () => {
            const fundsAmount = calculateSolAmount(0.75, solPrice);
            const insufficientNative = fundsAmount - 50_000; // native < funds
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 1)),
                token: PublicKey.default,
                amount: new anchor.BN(fundsAmount),
                payload: serializePayload(createPayload(1)),
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("insufficient_native_sig"),
            };

            try {
                await program.methods
                    .sendUniversalTx(req, new anchor.BN(insufficientNative))
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        userTokenAccount: vaultPda,
                        gatewayTokenAccount: vaultPda,
                        user: user1.publicKey,
                        priceUpdate: mockPriceFeed,
                        rateLimitConfig: rateLimitConfigPda,
                        tokenRateLimit: nativeSolTokenRateLimitPda,
                        tokenProgram: spl.TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject when native gas is below bridge amount");
            } catch (error: any) {
                expect(error).to.exist;
                const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
                expect(errorCode).to.equal("InvalidAmount");
            }
        });
    });

    describe("FUNDS_AND_PAYLOAD Route - SPL Token", () => {
        it("Should bridge SPL funds with payload without batching (Case 2.1)", async () => {
            // Case 2.1: No Batching (native_amount == 0): user already has UEA with gas on Push Chain
            // User can directly move req.amount for req.token to Push Chain (SPL token only for Case 2.1)
            // Use USDC to avoid rate limit conflicts with USDT used in previous tests
            const userTokenAccount = await mockUSDC.createTokenAccount(user1.publicKey);
            const gatewayTokenAccount = await mockUSDC.createTokenAccount(vaultPda, true);

            // Mint tokens using mock token's mintTo method
            await mockUSDC.mintTo(userTokenAccount, 500);
            const tokenAmount = new anchor.BN(500 * 10 ** mockUSDC.config.decimals);

            const initialGatewayBalance = await mockUSDC.getBalance(gatewayTokenAccount);
            const usdcTokenRateLimitPda = getTokenRateLimitPda(mockUSDC.mint.publicKey);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 1)), // Non-zero allowed for FUNDS_AND_PAYLOAD
                token: mockUSDC.mint.publicKey,
                amount: tokenAmount,
                payload: serializePayload(createPayload(1)), // Must have payload for FUNDS_AND_PAYLOAD
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("spl_no_batch_sig"),
            };

            // native_amount == 0: user already has UEA with gas
            await program.methods
                .sendUniversalTx(req, new anchor.BN(0))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    userTokenAccount: userTokenAccount,
                    gatewayTokenAccount: gatewayTokenAccount,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: usdcTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            // Should only receive SPL tokens, no native SOL
            const finalGatewayBalance = await mockUSDC.getBalance(gatewayTokenAccount);
            const balanceIncrease = (finalGatewayBalance - initialGatewayBalance) * 10 ** mockUSDC.config.decimals;
            expect(balanceIncrease).to.equal(tokenAmount.toNumber());
        });

        it("Should batch native gas + SPL funds (Case 2.3)", async () => {
            // Setup SPL token accounts using mock token's methods
            const userTokenAccount = await mockUSDC.createTokenAccount(user1.publicKey);
            const gatewayTokenAccount = await mockUSDC.createTokenAccount(vaultPda, true);

            // Mint tokens using mock token's mintTo method
            await mockUSDC.mintTo(userTokenAccount, 500);
            const tokenAmount = new anchor.BN(500 * 10 ** mockUSDC.config.decimals);

            // Case 2.3: Batching with SPL + native gas
            // Gas amount must be >= $1 USD (min cap) and <= $10 USD (max cap)
            // native_amount is sent as gas, req.amount is SPL bridge amount
            const gasAmount = calculateSolAmount(2.5, solPrice); // $2.50 for gas (within $1-$10 cap)

            // Verify gas amount is >= $1 USD
            const gasUsd = (gasAmount / LAMPORTS_PER_SOL) * solPrice;
            if (gasUsd < 1.0) {
                throw new Error(`Gas amount ${gasUsd} USD is below minimum $1 USD cap`);
            }
            const initialVaultBalance = await provider.connection.getBalance(vaultPda);
            const initialGatewayBalance = await mockUSDC.getBalance(gatewayTokenAccount);
            const usdcTokenRateLimitPda = getTokenRateLimitPda(mockUSDC.mint.publicKey);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 1)),
                token: mockUSDC.mint.publicKey,
                amount: tokenAmount,
                payload: serializePayload(createPayload(1)), // Non-empty payload required
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("spl_batched_sig"),
            };

            await program.methods
                .sendUniversalTx(req, new anchor.BN(gasAmount))
                .accounts({
                    config: configPda,
                    vault: vaultPda,
                    userTokenAccount: userTokenAccount,
                    gatewayTokenAccount: gatewayTokenAccount,
                    user: user1.publicKey,
                    priceUpdate: mockPriceFeed,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: usdcTokenRateLimitPda,
                    tokenProgram: spl.TOKEN_PROGRAM_ID,
                    systemProgram: SystemProgram.programId,
                })
                .signers([user1])
                .rpc();

            const finalVaultBalance = await provider.connection.getBalance(vaultPda);
            expect(finalVaultBalance - initialVaultBalance).to.equal(gasAmount);

            const finalGatewayBalance = await mockUSDC.getBalance(gatewayTokenAccount);
            const balanceIncrease = (finalGatewayBalance - initialGatewayBalance) * 10 ** mockUSDC.config.decimals;
            expect(balanceIncrease).to.equal(tokenAmount.toNumber());
        });

        it("Should reject FUNDS_AND_PAYLOAD SPL when token rate limit PDA mismatches", async () => {
            const userTokenAccount = await mockUSDC.createTokenAccount(user1.publicKey);
            const gatewayTokenAccount = await mockUSDC.createTokenAccount(vaultPda, true);

            await mockUSDC.mintTo(userTokenAccount, 500);
            const tokenAmount = new anchor.BN(500 * 10 ** mockUSDC.config.decimals);
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default); // intentionally wrong

            const req = {
                recipient: Array.from(Buffer.alloc(20, 1)),
                token: mockUSDC.mint.publicKey,
                amount: tokenAmount,
                payload: serializePayload(createPayload(1)),
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("spl_bad_rate_limit"),
            };

            try {
                await program.methods
                    .sendUniversalTx(req, new anchor.BN(0))
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        userTokenAccount: userTokenAccount,
                        gatewayTokenAccount: gatewayTokenAccount,
                        user: user1.publicKey,
                        priceUpdate: mockPriceFeed,
                        rateLimitConfig: rateLimitConfigPda,
                        tokenRateLimit: nativeSolTokenRateLimitPda,
                        tokenProgram: spl.TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject FUNDS_AND_PAYLOAD SPL when token rate limit PDA is invalid");
            } catch (error: any) {
                expect(error).to.exist;
                const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
                expect(errorCode).to.equal("InvalidToken");
            }
        });
    });

    describe("Error Cases", () => {
        it("Should reject when paused", async () => {
            await program.methods
                .pause()
                .accounts({ pauser: pauser.publicKey, config: configPda })
                .signers([pauser])
                .rpc();

            const gasAmount = calculateSolAmount(2.5, solPrice);
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(0),
                payload: Buffer.from([]),
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("sig"),
            };

            try {
                await program.methods
                    .sendUniversalTx(req, new anchor.BN(gasAmount))
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        userTokenAccount: vaultPda, // Dummy account for native SOL routes
                        gatewayTokenAccount: vaultPda, // Dummy account for native SOL routes
                        user: user1.publicKey,
                        priceUpdate: mockPriceFeed,
                        rateLimitConfig: rateLimitConfigPda,
                        tokenRateLimit: nativeSolTokenRateLimitPda,
                        tokenProgram: spl.TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject when paused");
            } catch (error: any) {
                expect(error).to.exist;
                expect(error.error?.errorCode?.code || error.code).to.equal("Paused");
            }

            await program.methods
                .unpause()
                .accounts({ pauser: pauser.publicKey, config: configPda })
                .signers([pauser])
                .rpc();
        });

        it("Should reject invalid parameter combinations (no gas or funds)", async () => {
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);

            const req = {
                recipient: Array.from(Buffer.alloc(20, 0)),
                token: PublicKey.default,
                amount: new anchor.BN(0),
                payload: Buffer.from([]),
                revertInstruction: createRevertInstruction(user1.publicKey),
                signatureData: Buffer.from("sig"),
            };

            try {
                await program.methods
                    .sendUniversalTx(req, new anchor.BN(0))
                    .accounts({
                        config: configPda,
                        vault: vaultPda,
                        userTokenAccount: vaultPda,
                        gatewayTokenAccount: vaultPda,
                        user: user1.publicKey,
                        priceUpdate: mockPriceFeed,
                        rateLimitConfig: rateLimitConfigPda,
                        tokenRateLimit: nativeSolTokenRateLimitPda,
                        tokenProgram: spl.TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject parameter set without gas or funds");
            } catch (error: any) {
                expect(error).to.exist;
                const errorCode = error.error?.errorCode?.code || error.error?.errorCode || error.code;
                expect(errorCode).to.equal("InvalidInput");
            }
        });
    });

    after(async () => {
        // Ensure contract is unpaused after all tests
        try {
            const config = await program.account.config.fetch(configPda);
            if (config.paused) {
                await program.methods
                    .unpause()
                    .accounts({ pauser: pauser.publicKey, config: configPda })
                    .signers([pauser])
                    .rpc();
            }
        } catch (error) {
            // Ignore errors
        }

        // Disable rate limits to prevent interference with other tests
        try {
            // Disable epoch duration
            await program.methods
                .updateEpochDuration(new anchor.BN(0))
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            // Set very large thresholds to effectively disable
            const veryLargeThreshold = new anchor.BN("1000000000000000000000");
            const nativeSolTokenRateLimitPda = getTokenRateLimitPda(PublicKey.default);
            await program.methods
                .setTokenRateLimit(veryLargeThreshold)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    tokenRateLimit: nativeSolTokenRateLimitPda,
                    tokenMint: PublicKey.default,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        } catch (error) {
            // Ignore errors
        }
    });
});