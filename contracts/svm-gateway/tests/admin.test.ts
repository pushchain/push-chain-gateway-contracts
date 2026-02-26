import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import * as sharedState from "./shared-state";
import { getTssEthAddress, TSS_CHAIN_ID } from "./helpers/tss";
import { ensureTestSetup } from "./helpers/test-setup";


describe("Universal Gateway - Admin Functions Tests", () => {
    anchor.setProvider(anchor.AnchorProvider.env());
    const provider = anchor.getProvider() as anchor.AnchorProvider;
    const program = anchor.workspace.UniversalGateway as Program<UniversalGateway>;

    before(async () => {
        await ensureTestSetup();
    });

    // Test accounts
    let admin: Keypair;
    let newAdmin: Keypair;
    let tssAddress: Keypair;
    let pauser: Keypair;
    let newPauser: Keypair;
    let unauthorizedUser: Keypair;

    // Program PDAs
    let configPda: PublicKey;
    let vaultPda: PublicKey;
    let tssPda: PublicKey;
    let rateLimitConfigPda: PublicKey;

    // Mock assets
    let mockPriceFeed: PublicKey;
    let mockUSDT: any;
    before(async () => {
        admin = sharedState.getAdmin();
        tssAddress = sharedState.getTssAddress();
        pauser = sharedState.getPauser();
        mockUSDT = sharedState.getMockUSDT();
        mockPriceFeed = sharedState.getMockPriceFeed();

        // Additional actors for admin mutation tests
        newAdmin = Keypair.generate();
        newPauser = Keypair.generate();
        unauthorizedUser = Keypair.generate();

        // Airdrop SOL
        const airdropAmount = 10 * anchor.web3.LAMPORTS_PER_SOL;
        await Promise.all([
            provider.connection.requestAirdrop(admin.publicKey, airdropAmount),
            provider.connection.requestAirdrop(newAdmin.publicKey, airdropAmount),
            provider.connection.requestAirdrop(newPauser.publicKey, airdropAmount),
            provider.connection.requestAirdrop(unauthorizedUser.publicKey, airdropAmount),
        ]);

        await new Promise(resolve => setTimeout(resolve, 2000));

        // Derive PDAs
        [configPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("config")],
            program.programId
        );

        [vaultPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("vault")],
            program.programId
        );

        [tssPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("tsspda_v2")],
            program.programId
        );

        [rateLimitConfigPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit_config")],
            program.programId
        );

        const config = await program.account.config.fetch(configPda);
        expect(config.admin.toString()).to.equal(admin.publicKey.toString());
        expect(config.pauser.toString()).to.equal(pauser.publicKey.toString());
        expect(config.tssAddress.toString()).to.equal(tssAddress.publicKey.toString());

    });

    describe("Access Control", () => {
        it("Verifies initial admin configuration", async () => {

            const config = await program.account.config.fetch(configPda);

            expect(config.admin.toString()).to.equal(admin.publicKey.toString());
            expect(config.tssAddress.toString()).to.equal(tssAddress.publicKey.toString());
            expect(config.pauser.toString()).to.equal(pauser.publicKey.toString());
            expect(config.paused).to.be.false;

        });

        it("Updates USD caps", async () => {

            const newMinCap = new anchor.BN(150_000_000);
            const newMaxCap = new anchor.BN(2_000_000_000);

            await program.methods
                .setCapsUsd(newMinCap, newMaxCap)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            const config = await program.account.config.fetch(configPda);
            expect(config.minCapUniversalTxUsd.toString()).to.equal(newMinCap.toString());
            expect(config.maxCapUniversalTxUsd.toString()).to.equal(newMaxCap.toString());

        });

        it("Rejects unauthorized admin operations", async () => {
            try {
                const newMinCap = new anchor.BN(200_000_000);
                const newMaxCap = new anchor.BN(300_000_000);

                await program.methods
                    .setCapsUsd(newMinCap, newMaxCap)
                    .accounts({
                        admin: unauthorizedUser.publicKey,
                        config: configPda,
                    })
                    .signers([unauthorizedUser])
                    .rpc();

                expect.fail("Unauthorized TSS update should have failed");
            } catch (error: any) {
                expect(error).to.exist;
                const errorCode = error.error?.errorCode?.code || error.errorCode?.code || error.code || error.error?.code;
                expect(errorCode).to.equal("Unauthorized");
            }
        });
    });

    describe("Pause/Unpause Functionality", () => {
        it("Pauses the contract", async () => {

            await program.methods
                .pause()
                .accounts({
                    pauser: pauser.publicKey,
                    config: configPda,
                })
                .signers([pauser])
                .rpc();

            const config = await program.account.config.fetch(configPda);
            expect(config.paused).to.be.true;

        });

        it("Unpauses the contract", async () => {

            await program.methods
                .unpause()
                .accounts({
                    pauser: pauser.publicKey,
                    config: configPda,
                })
                .signers([pauser])
                .rpc();

            const config = await program.account.config.fetch(configPda);
            expect(config.paused).to.be.false;

        });

        it("Rejects pause/unpause from unauthorized users", async () => {
            try {
                await program.methods
                    .pause()
                    .accounts({
                        pauser: unauthorizedUser.publicKey,
                        config: configPda,
                    })
                    .signers([unauthorizedUser])
                    .rpc();

                expect.fail("Unauthorized pause should have failed");
            } catch (error: any) {
                expect(error).to.exist;
                const errorCode = error.error?.errorCode?.code || error.errorCode?.code || error.code || error.error?.code;
                expect(errorCode).to.equal("Unauthorized");
            }

            try {
                await program.methods
                    .unpause()
                    .accounts({
                        pauser: unauthorizedUser.publicKey,
                        config: configPda,
                    })
                    .signers([unauthorizedUser])
                    .rpc();

                expect.fail("Unauthorized unpause should have failed");
            } catch (error: any) {
                expect(error).to.exist;
                const errorCode = error.error?.errorCode?.code || error.errorCode?.code || error.code || error.error?.code;
                expect(errorCode).to.equal("Unauthorized");
            }
        });
    });

    describe("Configuration Updates", () => {
        it("Updates USD caps", async () => {

            const newMinCap = new anchor.BN(200_000_000); // $2
            const newMaxCap = new anchor.BN(2_000_000_000); // $20

            await program.methods
                .setCapsUsd(newMinCap, newMaxCap)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            const config = await program.account.config.fetch(configPda);
            expect(config.minCapUniversalTxUsd.toString()).to.equal(newMinCap.toString());
            expect(config.maxCapUniversalTxUsd.toString()).to.equal(newMaxCap.toString());

        });

        it("Updates Pyth configuration", async () => {
            const newPriceFeed = Keypair.generate().publicKey;
            const newConfidenceThreshold = new anchor.BN(2000000);

            // Update price feed
            await program.methods
                .setPythPriceFeed(newPriceFeed)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            // Update confidence threshold
            await program.methods
                .setPythConfidenceThreshold(newConfidenceThreshold)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();

            const config = await program.account.config.fetch(configPda);
            expect(config.pythPriceFeed.toString()).to.equal(newPriceFeed.toString());
            expect(config.pythConfidenceThreshold.toString()).to.equal(newConfidenceThreshold.toString());

            // Restore original price feed for other tests
            await program.methods
                .setPythPriceFeed(mockPriceFeed)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                })
                .signers([admin])
                .rpc();
        });

        it("Updates rate limiting configuration", async () => {

            const newBlockCap = new anchor.BN(1_000_000_000_000); // $10,000
            const newEpochDuration = new anchor.BN(7200); // 2 hours

            await program.methods
                .setBlockUsdCap(newBlockCap)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            await program.methods
                .updateEpochDuration(newEpochDuration)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                    rateLimitConfig: rateLimitConfigPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            const rateLimitConfig = await program.account.rateLimitConfig.fetch(rateLimitConfigPda);
            expect(rateLimitConfig.blockUsdCap.toString()).to.equal(newBlockCap.toString());
            expect(rateLimitConfig.epochDurationSec.toString()).to.equal(newEpochDuration.toString());

        });
    });

    describe("Token Rate Limits", () => {
        it("Sets token rate limit threshold", async () => {

            const limitThreshold = new anchor.BN(1000 * Math.pow(10, 6)); // 1000 tokens

            const [tokenRateLimitPda] = PublicKey.findProgramAddressSync(
                [Buffer.from("rate_limit"), mockUSDT.mint.publicKey.toBuffer()],
                program.programId
            );

            await program.methods
                .setTokenRateLimit(limitThreshold)
                .accounts({
                    admin: admin.publicKey,
                    config: configPda,
                    tokenRateLimit: tokenRateLimitPda,
                    tokenMint: mockUSDT.mint.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            const tokenRateLimit = await program.account.tokenRateLimit.fetch(tokenRateLimitPda);
            expect(tokenRateLimit.tokenMint.toString()).to.equal(mockUSDT.mint.publicKey.toString());
            expect(tokenRateLimit.limitThreshold.toString()).to.equal(limitThreshold.toString());

        });
    });

    describe("TSS Management", () => {
        it("Rejects TSS initialization by non-admin", async () => {
            // Use the correct TSS PDA seed (just "tss", not with extra bytes)
            const [actualTssPda] = PublicKey.findProgramAddressSync(
                [Buffer.from("tsspda_v2")],
                program.programId
            );

            // Check if TSS already exists
            let tssExists = false;
            try {
                await program.account.tssPda.fetch(actualTssPda);
                tssExists = true;
            } catch {
                // TSS doesn't exist yet
            }

            if (tssExists) {
                // TSS already exists, test that non-admin can't update it (also requires authority)
                const newTssEthAddress = Array.from(Buffer.alloc(20, 99));
                try {
                    await program.methods
                        .updateTss(newTssEthAddress, "999")
                        .accounts({
                            authority: unauthorizedUser.publicKey,
                            tssPda: actualTssPda,
                        })
                        .signers([unauthorizedUser])
                        .rpc();

                    expect.fail("Unauthorized TSS update should have failed");
                } catch (error: any) {
                    expect(error).to.exist;
                    // Constraint returns ConstraintRaw when validation fails
                    const errorCode = error.error?.errorCode?.code || error.errorCode?.code || error.code || error.error?.code;
                    expect(errorCode).to.equal("ConstraintRaw");
                }
            } else {
                // TSS doesn't exist, test that non-admin can't initialize it
                // The constraint check happens during account validation, before init
                const expectedTssEthAddress = getTssEthAddress();
                const chainId = TSS_CHAIN_ID;

                try {
                    await program.methods
                        .initTss(expectedTssEthAddress, chainId)
                        .accounts({
                            authority: unauthorizedUser.publicKey,
                            tssPda: actualTssPda,
                            config: configPda,
                            systemProgram: SystemProgram.programId,
                        })
                        .signers([unauthorizedUser])
                        .rpc();

                    expect.fail("Unauthorized TSS initialization should have failed");
                } catch (error: any) {
                    expect(error).to.exist;
                    // Constraint returns ConstraintRaw when validation fails
                    const errorCode = error.error?.errorCode?.code || error.errorCode?.code || error.code || error.error?.code;
                    expect(errorCode).to.equal("ConstraintRaw");
                }
            }
        });

        it("Initializes TSS PDA if not already initialized", async () => {
            const expectedTssEthAddress = getTssEthAddress();
            const chainId = TSS_CHAIN_ID;

            try {
                const existingTss = await program.account.tssPda.fetch(tssPda);
                // Verify it's already initialized correctly
                expect(existingTss.chainId).to.equal(chainId);
                return;
            } catch {
                // Not initialized, proceed with initialization
            }

            await program.methods
                .initTss(expectedTssEthAddress, chainId)
                .accounts({
                    authority: admin.publicKey,
                    tssPda: tssPda,
                    config: configPda,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();

            const tss = await program.account.tssPda.fetch(tssPda);
            expect(tss.chainId).to.equal(chainId);
        });

        it("Updates TSS configuration", async () => {
            const newTssEthAddress = Array.from(Buffer.alloc(20, 2));
            const newChainId = "137";

            await program.methods
                .updateTss(newTssEthAddress, newChainId)
                .accounts({
                    authority: admin.publicKey,
                    tssPda: tssPda,
                })
                .signers([admin])
                .rpc();

            const tss = await program.account.tssPda.fetch(tssPda);
            expect(tss.chainId).to.equal(newChainId);
        });

    });


    describe("Price Oracle Functions", () => {
        it("Gets SOL price from Pyth oracle", async () => {
            const priceData = await program.methods
                .getSolPrice()
                .accounts({
                    priceUpdate: mockPriceFeed,
                })
                .view();

            expect(priceData).to.not.be.null;
            expect(priceData.price.toNumber()).to.be.greaterThan(0);
            expect(priceData.exponent).to.be.a('number');
        });
    });

    describe("Error Conditions", () => {
        it("Rejects invalid USD caps (min > max)", async () => {
            const invalidMinCap = new anchor.BN(2_000_000_000); // $20
            const invalidMaxCap = new anchor.BN(1_000_000_000); // $10 (less than min)

            try {
                await program.methods
                    .setCapsUsd(invalidMinCap, invalidMaxCap)
                    .accounts({
                        admin: admin.publicKey,
                        config: configPda,
                    })
                    .signers([admin])
                    .rpc();

                expect.fail("Invalid caps should have been rejected");
            } catch (error: any) {
                expect(error).to.exist;
                const errorCode = error.error?.errorCode?.code || error.errorCode?.code || error.code || error.error?.code;
                expect(errorCode).to.equal("InvalidCapRange");
            }
        });

    });

    after(async () => {
        const expectedTssEthAddress = getTssEthAddress();
        await program.methods
            .updateTss(expectedTssEthAddress, TSS_CHAIN_ID)
            .accounts({
                tssPda,
                authority: admin.publicKey,
            })
            .signers([admin])
            .rpc();

    });
});
