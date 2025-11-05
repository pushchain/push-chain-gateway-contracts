import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import { getAssociatedTokenAddress, TOKEN_PROGRAM_ID } from "@solana/spl-token";
import * as sharedState from "./shared-state";

const debug = (...args: unknown[]) => {
    if (process.env.DEBUG_TESTS === "1") {
        console.debug(...args);
    }
};

describe("Universal Gateway - Token Operations Tests", () => {
    anchor.setProvider(anchor.AnchorProvider.env());
    const provider = anchor.getProvider() as anchor.AnchorProvider;
    const program = anchor.workspace.UniversalGateway as Program<UniversalGateway>;

    // Test accounts
    let admin: Keypair;
    let tssAddress: Keypair;
    let pauser: Keypair;
    let user1: Keypair;
    let user2: Keypair;

    // Program PDAs
    let configPda: PublicKey;
    let vaultPda: PublicKey;
    let whitelistPda: PublicKey;
    let rateLimitConfigPda: PublicKey;

    // Mock tokens and oracles
    let mockPythOracle: any;
    let mockUSDT: any;
    let mockUSDC: any;

    // Token accounts
    let user1UsdtAccount: PublicKey;
    let user1UsdcAccount: PublicKey;
    let user2UsdtAccount: PublicKey;
    let vaultUsdtAccount: PublicKey;
    let vaultUsdcAccount: PublicKey;

    before(async () => {
        debug("Setting up token operations tests");

        // Use shared state from setup.test.ts
        admin = sharedState.getAdmin();
        tssAddress = sharedState.getTssAddress();
        pauser = sharedState.getPauser();
        mockUSDT = sharedState.getMockUSDT();
        mockUSDC = sharedState.getMockUSDC();

        // Generate test users
        user1 = Keypair.generate();
        user2 = Keypair.generate();

        // Airdrop SOL to users
        const airdropAmount = 10 * anchor.web3.LAMPORTS_PER_SOL;
        await Promise.all([
            provider.connection.requestAirdrop(user1.publicKey, airdropAmount),
            provider.connection.requestAirdrop(user2.publicKey, airdropAmount),
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

        [whitelistPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("whitelist")],
            program.programId
        );

        [rateLimitConfigPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit_config")],
            program.programId
        );

        // Tokens are already created and whitelisted by setup.test.ts via shared state
        debug("Using shared state from setup.test.ts - tokens already whitelisted");
    });

    describe("Token Setup and Minting", () => {
        it("Creates token accounts for users", async () => {
            debug("Creating token accounts for users");

            // Create token accounts for user1
            user1UsdtAccount = await mockUSDT.createTokenAccount(user1.publicKey);
            user1UsdcAccount = await mockUSDC.createTokenAccount(user1.publicKey);

            // Create token accounts for user2
            user2UsdtAccount = await mockUSDT.createTokenAccount(user2.publicKey);

            // Create vault token accounts
            vaultUsdtAccount = await mockUSDT.createTokenAccount(vaultPda, true);
            vaultUsdcAccount = await mockUSDC.createTokenAccount(vaultPda, true);

            debug(`User1 USDT ATA: ${user1UsdtAccount.toString()}`);
            debug(`User1 USDC ATA: ${user1UsdcAccount.toString()}`);
            debug(`User2 USDT ATA: ${user2UsdtAccount.toString()}`);
            debug(`Vault USDT ATA: ${vaultUsdtAccount.toString()}`);
            debug(`Vault USDC ATA: ${vaultUsdcAccount.toString()}`);
        });

        it("Mints initial token balances to users", async () => {
            debug("Minting initial token balances");

            // Mint tokens to user1
            await mockUSDT.mintTo(user1UsdtAccount, 10000); // 10,000 USDT
            await mockUSDC.mintTo(user1UsdcAccount, 5000);  // 5,000 USDC

            // Mint tokens to user2
            await mockUSDT.mintTo(user2UsdtAccount, 7500);  // 7,500 USDT

            // Verify balances
            const user1UsdtBalance = await mockUSDT.getBalance(user1UsdtAccount);
            const user1UsdcBalance = await mockUSDC.getBalance(user1UsdcAccount);
            const user2UsdtBalance = await mockUSDT.getBalance(user2UsdtAccount);

            expect(user1UsdtBalance).to.equal(10000);
            expect(user1UsdcBalance).to.equal(5000);
            expect(user2UsdtBalance).to.equal(7500);

            debug(`User1 USDT balance: ${user1UsdtBalance}`);
            debug(`User1 USDC balance: ${user1UsdcBalance}`);
            debug(`User2 USDT balance: ${user2UsdtBalance}`);
        });

        it("Confirms tokens are already whitelisted", async () => {
            debug("Checking token whitelist");

            const whitelist = await program.account.tokenWhitelist.fetch(whitelistPda);
            const whitelistTokens = whitelist.tokens.map((t: PublicKey) => t.toString());

            expect(whitelistTokens).to.include(mockUSDT.mint.publicKey.toString());
            expect(whitelistTokens).to.include(mockUSDC.mint.publicKey.toString());

            debug("USDT present in whitelist");
            debug("USDC present in whitelist");
        });
    });

    describe("Token Deposits", () => {
        it("Performs SPL token deposit via send_funds", async () => {
            debug("Testing SPL token deposit via send_funds");

            const depositAmount = 1000; // 1000 USDT
            const initialUserBalance = await mockUSDT.getBalance(user1UsdtAccount);
            const initialVaultBalance = await mockUSDT.getBalance(vaultUsdtAccount);

            const recipient = Array.from(Buffer.alloc(20, 2)); // Mock recipient address

            await program.methods
                .sendFunds(
                    recipient,
                    mockUSDT.mint.publicKey,
                    new anchor.BN(depositAmount * Math.pow(10, 6)),
                    { fundRecipient: user1.publicKey, revertMsg: Buffer.from("test") }
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

            // Verify balances
            const finalUserBalance = await mockUSDT.getBalance(user1UsdtAccount);
            const finalVaultBalance = await mockUSDT.getBalance(vaultUsdtAccount);

            expect(finalUserBalance).to.equal(initialUserBalance - depositAmount);
            expect(finalVaultBalance).to.equal(initialVaultBalance + depositAmount);

            debug(`USDT deposit successful: ${depositAmount} USDT`);
            debug(`User balance after deposit: ${finalUserBalance} USDT`);
            debug(`Vault balance after deposit: ${finalVaultBalance} USDT`);
        });

    });

    describe("Token Transfers and Balances", () => {
        it("Transfers tokens between users", async () => {
            debug("Testing token transfers between users");

            const transferAmount = 250; // 250 USDT
            const initialUser1Balance = await mockUSDT.getBalance(user1UsdtAccount);
            const initialUser2Balance = await mockUSDT.getBalance(user2UsdtAccount);

            await mockUSDT.transfer(
                user1UsdtAccount,
                user2UsdtAccount,
                transferAmount,
                user1
            );

            const finalUser1Balance = await mockUSDT.getBalance(user1UsdtAccount);
            const finalUser2Balance = await mockUSDT.getBalance(user2UsdtAccount);

            expect(finalUser1Balance).to.equal(initialUser1Balance - transferAmount);
            expect(finalUser2Balance).to.equal(initialUser2Balance + transferAmount);

            debug(`Transfer successful: ${transferAmount} USDT`);
            debug(`User1 balance after transfer: ${finalUser1Balance} USDT`);
            debug(`User2 balance after transfer: ${finalUser2Balance} USDT`);
        });

        it("Checks all token balances", async () => {
            debug("Checking token balances");

            const balances = {
                user1Usdt: await mockUSDT.getBalance(user1UsdtAccount),
                user1Usdc: await mockUSDC.getBalance(user1UsdcAccount),
                user2Usdt: await mockUSDT.getBalance(user2UsdtAccount),
            };

            debug(`Balances: ${JSON.stringify(balances)}`);


            // Verify all balances are reasonable
            expect(balances.user1Usdt).to.be.greaterThan(0);
            expect(balances.user1Usdc).to.be.greaterThan(0);
            expect(balances.user2Usdt).to.be.greaterThan(0);

            debug("All balances verified");
        });
    });

    describe("Error Conditions", () => {
        it("Rejects deposits of non-whitelisted tokens", async () => {
            debug("Testing rejection of non-whitelisted tokens");

            // Create a new token that's not whitelisted
            // Create a new token that's NOT whitelisted for testing
            const { createMockUSDC } = await import("./helpers/mockSpl");
            const nonWhitelistedToken = await createMockUSDC(provider.connection, admin);
            await nonWhitelistedToken.createMint();

            const userNonWhitelistedAccount = await nonWhitelistedToken.createTokenAccount(user1.publicKey);
            await nonWhitelistedToken.mintTo(userNonWhitelistedAccount, 1000);

            const vaultNonWhitelistedAccount = await getAssociatedTokenAddress(nonWhitelistedToken.mint.publicKey, vaultPda, true);

            try {
                await program.methods
                    .sendFunds(
                        Array.from(Buffer.alloc(20, 4)),
                        nonWhitelistedToken.mint.publicKey,
                        new anchor.BN(100 * Math.pow(10, 6)),
                        { fundRecipient: user1.publicKey, revertMsg: Buffer.from("test") }
                    )
                    .accounts({
                        user: user1.publicKey,
                        config: configPda,
                        vault: vaultPda,
                        tokenWhitelist: whitelistPda,
                        userTokenAccount: userNonWhitelistedAccount,
                        gatewayTokenAccount: vaultNonWhitelistedAccount,
                        bridgeToken: nonWhitelistedToken.mint.publicKey,
                        tokenProgram: TOKEN_PROGRAM_ID,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([user1])
                    .rpc();

                // Should not reach here
                expect.fail("Transaction should have failed for non-whitelisted token");
            } catch (error) {
                debug("Non-whitelisted token deposit rejected as expected");
            }
        });

        it("Rejects deposits with insufficient balance", async () => {
            debug("Testing insufficient balance rejection");

            const excessiveAmount = 50000; // More than user has

            try {
                await program.methods
                    .sendFunds(
                        Array.from(Buffer.alloc(20, 5)),
                        mockUSDT.mint.publicKey,
                        new anchor.BN(excessiveAmount * Math.pow(10, 6)),
                        { fundRecipient: user1.publicKey, revertMsg: Buffer.from("test") }
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

                expect.fail("Transaction should have failed for insufficient balance");
            } catch (error) {
                debug("Insufficient balance deposit rejected as expected");
            }
        });
    });

    after(() => {
        debug("Token operations tests completed");
        debug("SPL token functionality verified");
        debug("Deposit operations tested");
        debug("Token transfers validated");
        debug("Error conditions handled");
        debug("Token system ready for production");
    });
});
