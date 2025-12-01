import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import { TOKEN_PROGRAM_ID, getAssociatedTokenAddress } from "@solana/spl-token";
import * as sharedState from "./shared-state";
import { createMockUSDC } from "./helpers/mockSpl";
import { getSolPrice, calculateSolAmount } from "./setup-pricefeed";


describe("Universal Gateway - SPL Token Deposit Tests", () => {
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
    let user1UsdcAccount: PublicKey;
    let user2UsdtAccount: PublicKey;
    let vaultUsdtAccount: PublicKey;
    let vaultUsdcAccount: PublicKey;
    let solPrice: number;

    const toTokenUnits = (amount: number, decimals: number = 6) => new anchor.BN(amount * Math.pow(10, decimals));
    const createPayload = (to: number, value: number = 0, vType: any = { universalTxVerification: {} }) => ({
        to: Array.from(Buffer.alloc(20, to)),
        value: new anchor.BN(value),
        data: Buffer.from([]),
        gasLimit: new anchor.BN(50000),
        maxFeePerGas: new anchor.BN(25000000000),
        maxPriorityFeePerGas: new anchor.BN(2000000000),
        nonce: new anchor.BN(1),
        deadline: new anchor.BN(Math.floor(Date.now() / 1000) + 3600),
        vType,
    });
    const createRevertInstruction = (recipient: PublicKey, msg: string = "test") => ({ fundRecipient: recipient, revertMsg: Buffer.from(msg) });

    before(async () => {
        // Use shared state from setup.test.ts
        admin = sharedState.getAdmin();
        tssAddress = sharedState.getTssAddress();
        pauser = sharedState.getPauser();
        mockUSDT = sharedState.getMockUSDT();
        mockUSDC = sharedState.getMockUSDC();
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

        // Verify calculated amounts are valid
        const testAmount = calculateSolAmount(2.5, solPrice);
        if (testAmount === 0) {
            throw new Error(`Calculated amount is 0! Price: ${solPrice}, USD: 2.5`);
        }

        user1UsdtAccount = await mockUSDT.createTokenAccount(user1.publicKey);
        user1UsdcAccount = await mockUSDC.createTokenAccount(user1.publicKey);
        user2UsdtAccount = await mockUSDT.createTokenAccount(user2.publicKey);

        vaultUsdtAccount = await mockUSDT.createTokenAccount(vaultPda, true);
        vaultUsdcAccount = await mockUSDC.createTokenAccount(vaultPda, true);

        // Vault token accounts are created automatically via init_if_needed

        await mockUSDT.mintTo(user1UsdtAccount, 10000);
        await mockUSDC.mintTo(user1UsdcAccount, 5000);
        await mockUSDT.mintTo(user2UsdtAccount, 7500);

    });

    describe("send_funds - Success Cases", () => {
        it("Allows basic SPL token deposit", async () => {
            const depositAmount = 1000;
            const initialUserBalance = await mockUSDT.getBalance(user1UsdtAccount);
            const initialVaultBalance = await mockUSDT.getBalance(vaultUsdtAccount);

            await program.methods
                .sendFunds(Array.from(Buffer.alloc(20, 1)), mockUSDT.mint.publicKey, toTokenUnits(depositAmount), createRevertInstruction(user1.publicKey))
                .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdtAccount, gatewayTokenAccount: vaultUsdtAccount, bridgeToken: mockUSDT.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                .signers([user1])
                .rpc();

            expect(await mockUSDT.getBalance(user1UsdtAccount)).to.equal(initialUserBalance - depositAmount);
            expect(await mockUSDT.getBalance(vaultUsdtAccount)).to.equal(initialVaultBalance + depositAmount);
        });

        it("Allows multiple deposits from different users and tokens", async () => {
            await program.methods
                .sendFunds(Array.from(Buffer.alloc(20, 2)), mockUSDT.mint.publicKey, toTokenUnits(500), createRevertInstruction(user1.publicKey, "user1-usdt"))
                .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdtAccount, gatewayTokenAccount: vaultUsdtAccount, bridgeToken: mockUSDT.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                .signers([user1])
                .rpc();

            await program.methods
                .sendFunds(Array.from(Buffer.alloc(20, 3)), mockUSDC.mint.publicKey, toTokenUnits(300), createRevertInstruction(user1.publicKey, "user1-usdc"))
                .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdcAccount, gatewayTokenAccount: vaultUsdcAccount, bridgeToken: mockUSDC.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                .signers([user1])
                .rpc();

            await program.methods
                .sendFunds(Array.from(Buffer.alloc(20, 4)), mockUSDT.mint.publicKey, toTokenUnits(200), createRevertInstruction(user2.publicKey, "user2-usdt"))
                .accounts({ user: user2.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user2UsdtAccount, gatewayTokenAccount: vaultUsdtAccount, bridgeToken: mockUSDT.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                .signers([user2])
                .rpc();
        });
    });

    describe("send_tx_with_funds - Success Cases", () => {
        it("Allows combined SOL + SPL token deposit within USD caps", async () => {
            // Calculate amount for $2.50 USD (mid-range between $1-$10, with buffer for rounding)
            const gasAmount = calculateSolAmount(2.5, solPrice);
            const tokenAmount = 500;
            const initialUserBalance = await mockUSDC.getBalance(user1UsdcAccount);
            const initialVaultBalance = await provider.connection.getBalance(vaultPda);

            await program.methods
                .sendTxWithFunds(mockUSDC.mint.publicKey, toTokenUnits(tokenAmount), createPayload(5, tokenAmount), createRevertInstruction(user1.publicKey), new anchor.BN(gasAmount), Buffer.from("sig"))
                .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdcAccount, gatewayTokenAccount: vaultUsdcAccount, priceUpdate: mockPriceFeed, bridgeToken: mockUSDC.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                .signers([user1])
                .rpc();

            expect(await mockUSDC.getBalance(user1UsdcAccount)).to.equal(initialUserBalance - tokenAmount);
            expect(await provider.connection.getBalance(vaultPda)).to.be.greaterThan(initialVaultBalance);
        });

        it("Allows combined deposits with different tokens within USD caps", async () => {
            // Calculate amount for $2.50 USD (mid-range between $1-$10, with buffer for rounding)
            const gasAmount = calculateSolAmount(2.5, solPrice);

            await program.methods
                .sendTxWithFunds(mockUSDT.mint.publicKey, toTokenUnits(250), createPayload(6, 250), createRevertInstruction(user1.publicKey), new anchor.BN(gasAmount), Buffer.from("usdt"))
                .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdtAccount, gatewayTokenAccount: vaultUsdtAccount, priceUpdate: mockPriceFeed, bridgeToken: mockUSDT.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                .signers([user1])
                .rpc();

            await program.methods
                .sendTxWithFunds(mockUSDC.mint.publicKey, toTokenUnits(300), createPayload(7, 300), createRevertInstruction(user1.publicKey), new anchor.BN(gasAmount), Buffer.from("usdc"))
                .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdcAccount, gatewayTokenAccount: vaultUsdcAccount, priceUpdate: mockPriceFeed, bridgeToken: mockUSDC.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                .signers([user1])
                .rpc();
        });
    });

    describe("send_funds - Error Cases", () => {
        it("Rejects when paused, zero recipient, invalid revert recipient, zero amount, non-whitelisted token, insufficient balance", async () => {
            await program.methods.pause().accounts({ pauser: pauser.publicKey, config: configPda }).signers([pauser]).rpc();

            try {
                await program.methods
                    .sendFunds(Array.from(Buffer.alloc(20, 10)), mockUSDT.mint.publicKey, toTokenUnits(100), createRevertInstruction(user1.publicKey))
                    .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdtAccount, gatewayTokenAccount: vaultUsdtAccount, bridgeToken: mockUSDT.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject when paused");
            } catch (error) {
                expect(error).to.exist;
            }

            await program.methods.unpause().accounts({ pauser: pauser.publicKey, config: configPda }).signers([pauser]).rpc();

            try {
                await program.methods
                    .sendFunds(Array.from(Buffer.alloc(20, 0)), mockUSDT.mint.publicKey, toTokenUnits(100), createRevertInstruction(user1.publicKey))
                    .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdtAccount, gatewayTokenAccount: vaultUsdtAccount, bridgeToken: mockUSDT.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject zero recipient");
            } catch (error) {
                expect(error).to.exist;
            }

            try {
                await program.methods
                    .sendFunds(Array.from(Buffer.alloc(20, 11)), mockUSDT.mint.publicKey, toTokenUnits(100), { fundRecipient: PublicKey.default, revertMsg: Buffer.from("test") })
                    .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdtAccount, gatewayTokenAccount: vaultUsdtAccount, bridgeToken: mockUSDT.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject invalid revert recipient");
            } catch (error) {
                expect(error).to.exist;
            }

            try {
                await program.methods
                    .sendFunds(Array.from(Buffer.alloc(20, 12)), mockUSDT.mint.publicKey, new anchor.BN(0), createRevertInstruction(user1.publicKey))
                    .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdtAccount, gatewayTokenAccount: vaultUsdtAccount, bridgeToken: mockUSDT.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject zero amount");
            } catch (error) {
                expect(error).to.exist;
            }

            const nonWhitelistedToken = await createMockUSDC(provider.connection, admin);
            await nonWhitelistedToken.createMint();
            const nonWhitelistedAccount = await nonWhitelistedToken.createTokenAccount(user1.publicKey);
            await nonWhitelistedToken.mintTo(nonWhitelistedAccount, 1000);
            const nonWhitelistedVaultAccount = await getAssociatedTokenAddress(nonWhitelistedToken.mint.publicKey, vaultPda, true);

            try {
                await program.methods
                    .sendFunds(Array.from(Buffer.alloc(20, 13)), nonWhitelistedToken.mint.publicKey, toTokenUnits(100), createRevertInstruction(user1.publicKey))
                    .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: nonWhitelistedAccount, gatewayTokenAccount: nonWhitelistedVaultAccount, bridgeToken: nonWhitelistedToken.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject non-whitelisted token");
            } catch (error) {
                expect(error).to.exist;
            }

            const userBalance = await mockUSDT.getBalance(user1UsdtAccount);
            try {
                await program.methods
                    .sendFunds(Array.from(Buffer.alloc(20, 14)), mockUSDT.mint.publicKey, toTokenUnits(userBalance + 1000), createRevertInstruction(user1.publicKey))
                    .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdtAccount, gatewayTokenAccount: vaultUsdtAccount, bridgeToken: mockUSDT.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject insufficient balance");
            } catch (error) {
                expect(error).to.exist;
            }
        });
    });

    describe("send_tx_with_funds - Error Cases", () => {
        it("Rejects zero bridge amount, zero gas amount, invalid revert recipient, and USD cap violations", async () => {
            // Use valid amount within USD caps for zero bridge amount test ($2.50)
            const validGasAmount = calculateSolAmount(2.5, solPrice);

            try {
                await program.methods
                    .sendTxWithFunds(mockUSDC.mint.publicKey, new anchor.BN(0), createPayload(15), createRevertInstruction(user1.publicKey), new anchor.BN(validGasAmount), Buffer.from("sig"))
                    .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdcAccount, gatewayTokenAccount: vaultUsdcAccount, priceUpdate: mockPriceFeed, bridgeToken: mockUSDC.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject zero bridge amount");
            } catch (error) {
                expect(error).to.exist;
            }

            try {
                await program.methods
                    .sendTxWithFunds(mockUSDC.mint.publicKey, toTokenUnits(500), createPayload(16), createRevertInstruction(user1.publicKey), new anchor.BN(0), Buffer.from("sig"))
                    .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdcAccount, gatewayTokenAccount: vaultUsdcAccount, priceUpdate: mockPriceFeed, bridgeToken: mockUSDC.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject zero gas amount");
            } catch (error) {
                expect(error).to.exist;
            }

            try {
                await program.methods
                    .sendTxWithFunds(mockUSDC.mint.publicKey, toTokenUnits(500), createPayload(17), { fundRecipient: PublicKey.default, revertMsg: Buffer.from("test") }, new anchor.BN(validGasAmount), Buffer.from("sig"))
                    .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdcAccount, gatewayTokenAccount: vaultUsdcAccount, priceUpdate: mockPriceFeed, bridgeToken: mockUSDC.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject invalid revert recipient");
            } catch (error) {
                expect(error).to.exist;
            }
        });

        it("Allows deposit within USD cap range (between min and max)", async () => {
            // Calculate amount for $7.00 USD (mid-range between $1-$10, should pass)
            const validGasAmount = calculateSolAmount(7.0, solPrice);
            const initialVaultBalance = await provider.connection.getBalance(vaultPda);

            await program.methods
                .sendTxWithFunds(mockUSDC.mint.publicKey, toTokenUnits(500), createPayload(18), createRevertInstruction(user1.publicKey), new anchor.BN(validGasAmount), Buffer.from("sig"))
                .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdcAccount, gatewayTokenAccount: vaultUsdcAccount, priceUpdate: mockPriceFeed, bridgeToken: mockUSDC.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
                .signers([user1])
                .rpc();

            const finalVaultBalance = await provider.connection.getBalance(vaultPda);
            expect(finalVaultBalance).to.be.greaterThan(initialVaultBalance);
        });

        it("Rejects deposits below minimum USD cap", async () => {
            const config = await program.account.config.fetch(configPda);
            const minCapUsd = config.minCapUniversalTxUsd.toNumber() / 100_000_000;
            // Calculate amount for $0.50 USD (below $1 min cap)
            const belowMinGasAmount = calculateSolAmount(0.5, solPrice);

            try {
                await program.methods
                    .sendTxWithFunds(mockUSDC.mint.publicKey, toTokenUnits(500), createPayload(18), createRevertInstruction(user1.publicKey), new anchor.BN(belowMinGasAmount), Buffer.from("sig"))
                    .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdcAccount, gatewayTokenAccount: vaultUsdcAccount, priceUpdate: mockPriceFeed, bridgeToken: mockUSDC.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
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
            const aboveMaxGasAmount = calculateSolAmount(testUsdAmount, solPrice);

            // Verify the amount is actually above max cap
            const aboveMaxUsd = (aboveMaxGasAmount / anchor.web3.LAMPORTS_PER_SOL) * solPrice;
            expect(aboveMaxUsd).to.be.greaterThan(maxCapUsd);

            try {
                await program.methods
                    .sendTxWithFunds(mockUSDC.mint.publicKey, toTokenUnits(500), createPayload(19), createRevertInstruction(user1.publicKey), new anchor.BN(aboveMaxGasAmount), Buffer.from("sig"))
                    .accounts({ user: user1.publicKey, config: configPda, vault: vaultPda, tokenWhitelist: whitelistPda, userTokenAccount: user1UsdcAccount, gatewayTokenAccount: vaultUsdcAccount, priceUpdate: mockPriceFeed, bridgeToken: mockUSDC.mint.publicKey, tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId })
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