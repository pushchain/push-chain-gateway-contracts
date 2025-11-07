import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import * as sharedState from "./shared-state";
import { getSolPrice, calculateSolAmount } from "./setup-pricefeed";


describe("Universal Gateway - Native SOL Deposit Tests", () => {
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
        // Use shared state keys for consistency
        admin = sharedState.getAdmin();
        tssAddress = sharedState.getTssAddress();
        pauser = sharedState.getPauser();
        user1 = Keypair.generate();
        user2 = Keypair.generate();

        const airdropAmount = 10 * anchor.web3.LAMPORTS_PER_SOL;
        await Promise.all([
            provider.connection.requestAirdrop(admin.publicKey, airdropAmount),
            provider.connection.requestAirdrop(user1.publicKey, airdropAmount),
            provider.connection.requestAirdrop(user2.publicKey, airdropAmount),
        ]);
        await new Promise(resolve => setTimeout(resolve, 2000));

        [configPda] = PublicKey.findProgramAddressSync([Buffer.from("config")], program.programId);
        [vaultPda] = PublicKey.findProgramAddressSync([Buffer.from("vault")], program.programId);
        [rateLimitConfigPda] = PublicKey.findProgramAddressSync([Buffer.from("rate_limit_config")], program.programId);

        // Use mock Pyth price feed from shared state
        mockPriceFeed = sharedState.getMockPriceFeed();

        // Get current SOL price from the price feed
        solPrice = await getSolPrice(mockPriceFeed);

        // Verify calculated amounts are valid
        const testAmount = calculateSolAmount(2.5, solPrice);
        if (testAmount === 0) {
            throw new Error(`Calculated amount is 0! Price: ${solPrice}, USD: 2.5`);
        }

        // Gateway should already be initialized by 00-setup.test.ts
        // If not, we'll initialize it here as a fallback
        try {
            const config = await program.account.config.fetch(configPda);
            // Verify we're using the same admin from shared state
            if (config.admin.toString() !== admin.publicKey.toString()) {
                throw new Error("Config admin mismatch - use shared state admin");
            }
        } catch {
            // Fallback initialization if gateway doesn't exist
            await program.methods
                .initialize(admin.publicKey, pauser.publicKey, tssAddress.publicKey, new anchor.BN(100_000_000), new anchor.BN(1_000_000_000), mockPriceFeed)
                .accounts({ admin: admin.publicKey })
                .signers([admin])
                .rpc();

            await program.methods
                .setBlockUsdCap(new anchor.BN(500_000_000_000))
                .accounts({ config: configPda, rateLimitConfig: rateLimitConfigPda, admin: admin.publicKey, systemProgram: SystemProgram.programId })
                .signers([admin])
                .rpc();

            await program.methods
                .updateEpochDuration(new anchor.BN(3600))
                .accounts({ config: configPda, rateLimitConfig: rateLimitConfigPda, admin: admin.publicKey, systemProgram: SystemProgram.programId })
                .signers([admin])
                .rpc();
        }
    });

    describe("send_tx_with_gas - Success Cases", () => {
        it("Allows basic SOL deposit within USD caps", async () => {
            // Calculate amount for $2.50 USD (mid-range between $1-$10, with buffer for rounding)
            const depositAmount = calculateSolAmount(2.5, solPrice);
            const initialVaultBalance = await provider.connection.getBalance(vaultPda);

            await program.methods
                .sendTxWithGas(createPayload(1), createRevertInstruction(user1.publicKey), new anchor.BN(depositAmount), Buffer.from("signature"))
                .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                .signers([user1])
                .rpc();

            const finalVaultBalance = await provider.connection.getBalance(vaultPda);
            expect(finalVaultBalance).to.be.greaterThan(initialVaultBalance);
        });

        it("Allows multiple deposits from different users within USD caps", async () => {
            // Calculate amounts for $2.50 USD each (mid-range between $1-$10, with buffer for rounding)
            const deposit1 = calculateSolAmount(2.5, solPrice);
            const deposit2 = calculateSolAmount(2.5, solPrice);
            const initialVaultBalance = await provider.connection.getBalance(vaultPda);

            await program.methods
                .sendTxWithGas(createPayload(1), createRevertInstruction(user1.publicKey, "user1"), new anchor.BN(deposit1), Buffer.from("sig1"))
                .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                .signers([user1])
                .rpc();

            await program.methods
                .sendTxWithGas(createPayload(2, { universalTxVerification: {} }), createRevertInstruction(user2.publicKey, "user2"), new anchor.BN(deposit2), Buffer.from("sig2"))
                .accounts({ config: configPda, vault: vaultPda, user: user2.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                .signers([user2])
                .rpc();

            const finalVaultBalance = await provider.connection.getBalance(vaultPda);
            // Vault should receive the full deposit amounts (transaction fees are paid by users, not deducted from deposits)
            expect(finalVaultBalance - initialVaultBalance).to.equal(deposit1 + deposit2);
        });

        it("Allows deposits with different gas parameters and payload data within USD caps", async () => {
            // Calculate amount for $2.50 USD (mid-range between $1-$10, with buffer for rounding)
            const depositAmount = calculateSolAmount(2.5, solPrice);

            const highGasPayload = { ...createPayload(3), gasLimit: new anchor.BN(50000), maxFeePerGas: new anchor.BN(100_000_000_000), maxPriorityFeePerGas: new anchor.BN(10_000_000_000) };
            await program.methods
                .sendTxWithGas(highGasPayload, createRevertInstruction(user1.publicKey), new anchor.BN(depositAmount), Buffer.from("high_gas"))
                .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                .signers([user1])
                .rpc();

            const payloadWithData = { ...createPayload(4), value: new anchor.BN(1_000_000_000), data: Buffer.from("test payload") };
            await program.methods
                .sendTxWithGas(payloadWithData, createRevertInstruction(user1.publicKey), new anchor.BN(depositAmount), Buffer.from("payload"))
                .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                .signers([user1])
                .rpc();
        });
    });

    describe("send_tx_with_gas - Error Cases", () => {
        it("Rejects when paused, zero amount, invalid recipient, insufficient balance", async () => {
            await program.methods.pause().accounts({ pauser: pauser.publicKey, config: configPda }).signers([pauser]).rpc();

            // Use a valid amount within USD caps for the paused test ($2.50)
            const validAmount = calculateSolAmount(2.5, solPrice);
            try {
                await program.methods
                    .sendTxWithGas(createPayload(1), createRevertInstruction(user1.publicKey), new anchor.BN(validAmount), Buffer.from("sig"))
                    .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject when paused");
            } catch (error: any) {
                expect(error).to.exist;
                expect(error.error?.errorCode?.code || error.code).to.equal("Paused");
            }

            await program.methods.unpause().accounts({ pauser: pauser.publicKey, config: configPda }).signers([pauser]).rpc();

            try {
                await program.methods
                    .sendTxWithGas(createPayload(1), createRevertInstruction(user1.publicKey), new anchor.BN(0), Buffer.from("sig"))
                    .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject zero amount");
            } catch (error) {
                expect(error).to.exist;
            }

            try {
                await program.methods
                    .sendTxWithGas(createPayload(1), { fundRecipient: PublicKey.default, revertMsg: Buffer.from("test") }, new anchor.BN(validAmount), Buffer.from("sig"))
                    .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject invalid recipient");
            } catch (error) {
                expect(error).to.exist;
            }

            const userBalance = await provider.connection.getBalance(user1.publicKey);
            try {
                await program.methods
                    .sendTxWithGas(createPayload(1), createRevertInstruction(user1.publicKey), new anchor.BN(userBalance + anchor.web3.LAMPORTS_PER_SOL), Buffer.from("sig"))
                    .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject insufficient balance");
            } catch (error) {
                expect(error).to.exist;
            }
        });

        it("Allows deposit within USD cap range (between min and max)", async () => {
            // Calculate amount for $7.00 USD (mid-range between $1-$10, should pass)
            const validAmount = calculateSolAmount(7.0, solPrice);
            const initialVaultBalance = await provider.connection.getBalance(vaultPda);

            await program.methods
                .sendTxWithGas(createPayload(1), createRevertInstruction(user1.publicKey), new anchor.BN(validAmount), Buffer.from("sig"))
                .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                .signers([user1])
                .rpc();

            const finalVaultBalance = await provider.connection.getBalance(vaultPda);
            expect(finalVaultBalance).to.be.greaterThan(initialVaultBalance);
        });

        it("Rejects deposits below minimum USD cap", async () => {
            const config = await program.account.config.fetch(configPda);
            const minCapUsd = config.minCapUniversalTxUsd.toNumber() / 100_000_000;
            // Calculate amount for $0.50 USD (below $1 min cap)
            const belowMinAmount = calculateSolAmount(0.5, solPrice);

            try {
                await program.methods
                    .sendTxWithGas(createPayload(1), createRevertInstruction(user1.publicKey), new anchor.BN(belowMinAmount), Buffer.from("sig"))
                    .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail(`Should reject below min cap ($${minCapUsd})`);
            } catch (error: any) {
                expect(error).to.exist;
                // Check error code structure - Anchor errors can be nested
                // AnchorError structure: error.error.errorCode.code or error.errorCode.code
                const errorCode = error.error?.errorCode?.code ||
                    error.errorCode?.code ||
                    error.code ||
                    error.error?.code;
                expect(errorCode).to.equal("BelowMinCap");
            }
        });

        it("Rejects deposits above maximum USD cap", async () => {
            const config = await program.account.config.fetch(configPda);
            const maxCapUsd = config.maxCapUniversalTxUsd.toNumber() / 100_000_000;
            // Calculate amount for an amount above the actual max cap (use maxCapUsd + 10 to ensure it's above)
            const testUsdAmount = maxCapUsd + 10;
            const aboveMaxAmount = calculateSolAmount(testUsdAmount, solPrice);

            // Verify the amount is actually above max cap
            const aboveMaxUsd = (aboveMaxAmount / anchor.web3.LAMPORTS_PER_SOL) * solPrice;
            expect(aboveMaxUsd).to.be.greaterThan(maxCapUsd);

            try {
                await program.methods
                    .sendTxWithGas(createPayload(1), createRevertInstruction(user1.publicKey), new anchor.BN(aboveMaxAmount), Buffer.from("sig"))
                    .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail(`Should reject above max cap ($${maxCapUsd})`);
            } catch (error: any) {
                expect(error).to.exist;
                // First check error number (6005 = AboveMaxCap) - this is more reliable
                if (error.error?.errorCode?.number === 6005 || error.errorCode?.number === 6005) {
                    // Error number confirms it's AboveMaxCap
                    return;
                }
                // Extract error code - use the exact same pattern as BelowMinCap which works
                const errorCode = error.error?.errorCode?.code ||
                    error.errorCode?.code ||
                    error.code ||
                    error.error?.code;

                expect(errorCode).to.equal("AboveMaxCap");
            }
        });
    });
});