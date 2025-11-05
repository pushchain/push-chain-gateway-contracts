import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import { createMockUSDT, createMockUSDC } from "./helpers/mockSpl";
import * as sharedState from "./shared-state";
import { getTssEthAddress, TSS_CHAIN_ID } from "./helpers/tss";

describe("Universal Gateway - Setup Tests", () => {
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

    // Mock tokens
    let mockPriceFeed: PublicKey;
    let mockUSDT: any;
    let mockUSDC: any;

    before(async () => {
        const adminWallet = provider.wallet as anchor.Wallet;
        admin = adminWallet.payer as Keypair;
        tssAddress = Keypair.generate();
        pauser = Keypair.generate();
        user1 = Keypair.generate();
        user2 = Keypair.generate();

        sharedState.setAdmin(admin);
        sharedState.setTssAddress(tssAddress);
        sharedState.setPauser(pauser);

        const airdropAmount = 10 * anchor.web3.LAMPORTS_PER_SOL;
        await Promise.all([
            provider.connection.requestAirdrop(admin.publicKey, airdropAmount),
            provider.connection.requestAirdrop(tssAddress.publicKey, airdropAmount),
            provider.connection.requestAirdrop(pauser.publicKey, airdropAmount),
            provider.connection.requestAirdrop(user1.publicKey, airdropAmount),
            provider.connection.requestAirdrop(user2.publicKey, airdropAmount),
        ]);

        await new Promise(resolve => setTimeout(resolve, 2000));
    });

    it("Initializes mock SPL tokens", async () => {
        // Create mock USDT
        mockUSDT = await createMockUSDT(provider.connection, admin);
        await mockUSDT.createMint();
        sharedState.setMockUSDT(mockUSDT);

        mockUSDC = await createMockUSDC(provider.connection, admin);
        await mockUSDC.createMint();
        sharedState.setMockUSDC(mockUSDC);
        const user1UsdtAccount = await mockUSDT.createTokenAccount(user1.publicKey);
        await mockUSDT.mintTo(user1UsdtAccount, 10000);
        const user1UsdcAccount = await mockUSDC.createTokenAccount(user1.publicKey);
        await mockUSDC.mintTo(user1UsdcAccount, 5000);
        const user2UsdtAccount = await mockUSDT.createTokenAccount(user2.publicKey);
        await mockUSDT.mintTo(user2UsdtAccount, 7500);
        const user1UsdtBalance = await mockUSDT.getBalance(user1UsdtAccount);
        const user1UsdcBalance = await mockUSDC.getBalance(user1UsdcAccount);
        const user2UsdtBalance = await mockUSDT.getBalance(user2UsdtAccount);

        expect(user1UsdtBalance).to.equal(10000);
        expect(user1UsdcBalance).to.equal(5000);
        expect(user2UsdtBalance).to.equal(7500);

    });

    it("Derives program PDAs", async () => {
        [configPda] = PublicKey.findProgramAddressSync([Buffer.from("config")], program.programId);
        [vaultPda] = PublicKey.findProgramAddressSync([Buffer.from("vault")], program.programId);
        [whitelistPda] = PublicKey.findProgramAddressSync([Buffer.from("whitelist")], program.programId);
        [rateLimitConfigPda] = PublicKey.findProgramAddressSync([Buffer.from("rate_limit_config")], program.programId);
    });

    it("Initializes the Universal Gateway program and whitelists tokens", async () => {
        let configAccount: any;
        try {
            configAccount = await program.account.config.fetch(configPda);
            sharedState.setMockPriceFeed(configAccount.pythPriceFeed);
            if (configAccount.admin.toString() !== admin.publicKey.toString()) {
                throw new Error(
                    `Config admin ${configAccount.admin.toString()} does not match provider wallet ${admin.publicKey.toString()}. Delete .anchor/test-ledger and rerun tests.`
                );
            }
        } catch {
            const dummyPyth = Keypair.generate().publicKey;
            sharedState.setMockPriceFeed(dummyPyth);
            await program.methods
                .initialize(
                    admin.publicKey,
                    pauser.publicKey,
                    tssAddress.publicKey,
                    new anchor.BN(100_000_000),
                    new anchor.BN(1_000_000_000),
                    dummyPyth
                )
                .accounts({ admin: admin.publicKey })
                .signers([admin])
                .rpc();
            configAccount = await program.account.config.fetch(configPda);
        }

        const whitelistToken = async (mint: PublicKey) => {
            try {
                await program.methods
                    .whitelistToken(mint)
                    .accounts({
                        admin: admin.publicKey,
                        config: configPda,
                        tokenWhitelist: whitelistPda,
                        systemProgram: anchor.web3.SystemProgram.programId,
                    })
                    .signers([admin])
                    .rpc();
            } catch (err: any) {
                if (!(`${err}`.includes("TokenAlreadyWhitelisted") || `${err}`.includes("6006"))) {
                    throw err;
                }
            }
        };

        await Promise.all([
            whitelistToken(mockUSDT.mint.publicKey),
            whitelistToken(mockUSDC.mint.publicKey),
        ]);

        const config = await program.account.config.fetch(configPda);
        expect(config.admin.toString()).to.equal(admin.publicKey.toString());
        expect(config.paused).to.be.false;

        const whitelist = await program.account.tokenWhitelist.fetch(whitelistPda);
        const tokenAddresses = whitelist.tokens.map((t: PublicKey) => t.toString());
        expect(tokenAddresses).to.include(mockUSDT.mint.publicKey.toString());
        expect(tokenAddresses).to.include(mockUSDC.mint.publicKey.toString());

        const [tssPda] = PublicKey.findProgramAddressSync([Buffer.from("tss")], program.programId);
        const expectedTssEthAddress = getTssEthAddress();
        const expectedChainId = TSS_CHAIN_ID;

        try {
            const existingTss = await program.account.tssPda.fetch(tssPda);
            const storedAddress = Buffer.from(existingTss.tssEthAddress);
            const expectedAddress = Buffer.from(expectedTssEthAddress);
            if (!storedAddress.equals(expectedAddress) || existingTss.chainId.toNumber() !== expectedChainId) {
                await program.methods
                    .updateTss(expectedTssEthAddress, new anchor.BN(expectedChainId))
                    .accounts({ tssPda, authority: admin.publicKey })
                    .signers([admin])
                    .rpc();
            }
        } catch {
            await program.methods
                .initTss(expectedTssEthAddress, new anchor.BN(expectedChainId))
                .accounts({
                    tssPda,
                    authority: admin.publicKey,
                    systemProgram: SystemProgram.programId,
                })
                .signers([admin])
                .rpc();
        }
    });
});