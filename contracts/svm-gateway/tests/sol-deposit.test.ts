import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import * as sharedState from "./shared-state";


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
        admin = Keypair.generate();
        tssAddress = Keypair.generate();
        pauser = Keypair.generate();
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

        // Pyth tests commented out temporarily
        // const { oracle, priceFeedPubkey } = await createMockPythFeed(provider.connection, admin, 150.0);
        // mockPythOracle = oracle;
        // mockPriceFeed = priceFeedPubkey;
        const dummyPythAccount = Keypair.generate().publicKey; // Temporary dummy account (random pubkey)
        mockPriceFeed = dummyPythAccount;

        try {
            await program.account.config.fetch(configPda);
        } catch {
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

    // Pyth-related tests commented out temporarily
    /*
    describe("send_tx_with_gas - Success Cases", () => {
        it("Allows basic SOL deposit", async () => {
            const depositAmount = 1 * anchor.web3.LAMPORTS_PER_SOL;
            const initialVaultBalance = await provider.connection.getBalance(vaultPda);

            await program.methods
                .sendTxWithGas(createPayload(1), createRevertInstruction(user1.publicKey), new anchor.BN(depositAmount), Buffer.from("signature"))
                .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                .signers([user1])
                .rpc();

            const finalVaultBalance = await provider.connection.getBalance(vaultPda);
            expect(finalVaultBalance).to.be.greaterThan(initialVaultBalance);
        });

        it("Allows multiple deposits from different users", async () => {
            const deposit1 = 0.5 * anchor.web3.LAMPORTS_PER_SOL;
            const deposit2 = 0.5 * anchor.web3.LAMPORTS_PER_SOL;
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
            expect(finalVaultBalance - initialVaultBalance).to.be.approximately(deposit1 + deposit2, (deposit1 + deposit2) * 0.1);
        });

        it("Allows deposits with different gas parameters and payload data", async () => {
            const depositAmount = 0.5 * anchor.web3.LAMPORTS_PER_SOL;

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

            try {
                await program.methods
                    .sendTxWithGas(createPayload(1), createRevertInstruction(user1.publicKey), new anchor.BN(anchor.web3.LAMPORTS_PER_SOL), Buffer.from("sig"))
                    .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail("Should reject when paused");
            } catch (error) {
                expect(error).to.exist;
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
                    .sendTxWithGas(createPayload(1), { fundRecipient: PublicKey.default, revertMsg: Buffer.from("test") }, new anchor.BN(anchor.web3.LAMPORTS_PER_SOL), Buffer.from("sig"))
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

        it("Rejects deposits below minimum and above maximum USD caps", async () => {
            const config = await program.account.config.fetch(configPda);
            const minCapUsd = config.minCapUniversalTxUsd.toNumber() / 100_000_000;
            const maxCapUsd = config.maxCapUniversalTxUsd.toNumber() / 100_000_000;

            const belowMinAmount = Math.floor(0.001 * anchor.web3.LAMPORTS_PER_SOL);
            try {
                await program.methods
                    .sendTxWithGas(createPayload(1), createRevertInstruction(user1.publicKey), new anchor.BN(belowMinAmount), Buffer.from("sig"))
                    .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail(`Should reject below min cap ($${minCapUsd})`);
            } catch (error) {
                expect(error).to.exist;
            }

            const aboveMaxAmount = 1 * anchor.web3.LAMPORTS_PER_SOL;
            try {
                await program.methods
                    .sendTxWithGas(createPayload(1), createRevertInstruction(user1.publicKey), new anchor.BN(aboveMaxAmount), Buffer.from("sig"))
                    .accounts({ config: configPda, vault: vaultPda, user: user1.publicKey, priceUpdate: mockPriceFeed, systemProgram: SystemProgram.programId })
                    .signers([user1])
                    .rpc();
                expect.fail(`Should reject above max cap ($${maxCapUsd})`);
            } catch (error) {
                expect(error).to.exist;
            }
        });
    });
    */
});