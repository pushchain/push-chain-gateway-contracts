import * as anchor from "@coral-xyz/anchor";
import {
    PublicKey,
    Keypair,
    SystemProgram,
    Transaction,
    sendAndConfirmTransaction,
} from "@solana/web3.js";
import {
    TOKEN_PROGRAM_ID,
    ASSOCIATED_TOKEN_PROGRAM_ID,
    MINT_SIZE,
    ACCOUNT_SIZE,
    createInitializeMintInstruction,
    createInitializeAccount3Instruction,
    getMinimumBalanceForRentExemptMint,
    getMinimumBalanceForRentExemptAccount,
    createMintToInstruction,
    getAccount,
    createAssociatedTokenAccountInstruction,
    getAssociatedTokenAddress,
    createTransferInstruction,
} from "@solana/spl-token";

const debug = (...args: unknown[]) => {
    if (process.env.DEBUG_TESTS === "1") {
        console.debug(...args);
    }
};

export interface MockTokenConfig {
    name: string;
    symbol: string;
    decimals: number;
    initialSupply?: number;
}

export class MockSplToken {
    private connection: anchor.web3.Connection;
    private payer: Keypair;
    public mint: Keypair;
    public mintAuthority: Keypair;
    public config: MockTokenConfig;
    private offCurveAccounts: Map<string, PublicKey>;

    constructor(
        connection: anchor.web3.Connection,
        payer: Keypair,
        config: MockTokenConfig
    ) {
        this.connection = connection;
        this.payer = payer;
        this.mint = Keypair.generate();
        this.mintAuthority = Keypair.generate();
        this.config = config;
        this.offCurveAccounts = new Map();
    }

    /**
     * Creates a new SPL token mint
     */
    async createMint(): Promise<PublicKey> {
        debug(`🪙 Creating mock SPL token: ${this.config.name} (${this.config.symbol})`);

        const lamports = await getMinimumBalanceForRentExemptMint(this.connection as any);

        const transaction = new Transaction().add(
            SystemProgram.createAccount({
                fromPubkey: this.payer.publicKey,
                newAccountPubkey: this.mint.publicKey,
                space: MINT_SIZE,
                lamports,
                programId: TOKEN_PROGRAM_ID,
            }),
            createInitializeMintInstruction(
                this.mint.publicKey,
                this.config.decimals,
                this.mintAuthority.publicKey,
                this.mintAuthority.publicKey,
                TOKEN_PROGRAM_ID
            )
        );

        await sendAndConfirmTransaction(
            this.connection,
            transaction,
            [this.payer, this.mint]
        );

        debug(`✅ Mock SPL token created: ${this.mint.publicKey.toString()}`);
        return this.mint.publicKey;
    }

    /**
     * Creates a token account for a user
     */
    async createTokenAccount(owner: PublicKey, allowOwnerOffCurve: boolean = false): Promise<PublicKey> {
        debug(`📝 Creating token account for owner: ${owner.toString()} (off-curve allowed: ${allowOwnerOffCurve})`);

        if (!allowOwnerOffCurve) {
            const tokenAccount = await getAssociatedTokenAddress(
                this.mint.publicKey,
                owner,
                false,
                TOKEN_PROGRAM_ID,
                ASSOCIATED_TOKEN_PROGRAM_ID
            );

            const existingAccount = await this.connection.getAccountInfo(tokenAccount);
            if (existingAccount) {
                debug(`ℹ️  ATA already exists, reusing: ${tokenAccount.toString()}`);
                return tokenAccount;
            }

            const transaction = new Transaction().add(
                createAssociatedTokenAccountInstruction(
                    this.payer.publicKey,
                    tokenAccount,
                    owner,
                    this.mint.publicKey,
                    TOKEN_PROGRAM_ID,
                    ASSOCIATED_TOKEN_PROGRAM_ID
                )
            );

            await sendAndConfirmTransaction(this.connection as any, transaction, [this.payer]);

            debug(`✅ Token account created: ${tokenAccount.toString()}`);
            return tokenAccount;
        }

        const existing = this.offCurveAccounts.get(owner.toString());
        if (existing) {
            debug(`ℹ️  Reusing cached off-curve token account: ${existing.toString()}`);
            return existing;
        }

        // For off-curve owners (PDAs) we must create the account manually
        const tokenAccount = Keypair.generate();
        const rent = await getMinimumBalanceForRentExemptAccount(this.connection as any);

        const existingAccount = await this.connection.getAccountInfo(tokenAccount.publicKey);
        if (existingAccount) {
            debug(`ℹ️  Off-curve account already exists: ${tokenAccount.publicKey.toString()}`);
            this.offCurveAccounts.set(owner.toString(), tokenAccount.publicKey);
            return tokenAccount.publicKey;
        }

        const transaction = new Transaction().add(
            SystemProgram.createAccount({
                fromPubkey: this.payer.publicKey,
                newAccountPubkey: tokenAccount.publicKey,
                lamports: rent,
                space: ACCOUNT_SIZE,
                programId: TOKEN_PROGRAM_ID,
            }),
            createInitializeAccount3Instruction(
                tokenAccount.publicKey,
                this.mint.publicKey,
                owner,
                TOKEN_PROGRAM_ID
            )
        );

        await sendAndConfirmTransaction(
            this.connection as any,
            transaction,
            [this.payer, tokenAccount]
        );

        debug(`✅ Token account created (manual): ${tokenAccount.publicKey.toString()}`);
        this.offCurveAccounts.set(owner.toString(), tokenAccount.publicKey);
        return tokenAccount.publicKey;
    }

    /**
     * Mints tokens to a specific account
     */
    async mintTo(
        destination: PublicKey,
        amount: number
    ): Promise<void> {
        const mintAmount = amount * Math.pow(10, this.config.decimals);
        debug(`🏭 Minting ${amount} ${this.config.symbol} tokens to ${destination.toString()}`);

        const transaction = new Transaction().add(
            createMintToInstruction(
                this.mint.publicKey,
                destination,
                this.mintAuthority.publicKey,
                mintAmount
            )
        );

        await sendAndConfirmTransaction(
            this.connection as any,
            transaction,
            [this.payer, this.mintAuthority]
        );

        debug(`✅ Minted ${amount} ${this.config.symbol} tokens`);
    }

    /**
     * Gets the token balance of an account
     */
    async getBalance(tokenAccount: PublicKey): Promise<number> {
        try {
            const account = await getAccount(this.connection as any, tokenAccount);
            return Number(account.amount) / Math.pow(10, this.config.decimals);
        } catch (error) {
            console.error("Error getting token balance:", error);
            return 0;
        }
    }

    /**
     * Transfers tokens between accounts
     */
    async transfer(
        from: PublicKey,
        to: PublicKey,
        amount: number,
        owner: Keypair
    ): Promise<void> {
        const transferAmount = amount * Math.pow(10, this.config.decimals);
        debug(`💸 Transferring ${amount} ${this.config.symbol} tokens`);

        const transaction = new Transaction().add(
            createTransferInstruction(
                from,
                to,
                owner.publicKey,
                transferAmount
            )
        );

        await sendAndConfirmTransaction(this.connection, transaction, [this.payer, owner]);

        debug(`✅ Transferred ${amount} ${this.config.symbol} tokens`);
    }

    /**
     * Creates a complete token setup: mint + user account + initial tokens
     */
    async setupTokenForUser(
        user: PublicKey,
        initialAmount: number = 1000
    ): Promise<{ mint: PublicKey; tokenAccount: PublicKey }> {
        await this.createMint();
        const tokenAccount = await this.createTokenAccount(user);

        if (initialAmount > 0) {
            await this.mintTo(tokenAccount, initialAmount);
        }

        return {
            mint: this.mint.publicKey,
            tokenAccount,
        };
    }
}

/**
 * Helper function to create a USDT-like mock token
 */
export async function createMockUSDT(
    connection: anchor.web3.Connection,
    payer: Keypair
): Promise<MockSplToken> {
    const config: MockTokenConfig = {
        name: "Mock Tether USD",
        symbol: "USDT",
        decimals: 6,
    };

    return new MockSplToken(connection, payer, config);
}

/**
 * Helper function to create a USDC-like mock token
 */
export async function createMockUSDC(
    connection: anchor.web3.Connection,
    payer: Keypair
): Promise<MockSplToken> {
    const config: MockTokenConfig = {
        name: "Mock USD Coin",
        symbol: "USDC",
        decimals: 6,
    };

    return new MockSplToken(connection, payer, config);
}

/**
 * Helper function to create a custom mock token
 */
export async function createMockToken(
    connection: anchor.web3.Connection,
    payer: Keypair,
    config: MockTokenConfig
): Promise<MockSplToken> {
    return new MockSplToken(connection, payer, config);
}

/**
 * Setup multiple users with token accounts and initial balances
 */
export async function setupUsersWithTokens(
    mockToken: MockSplToken,
    users: PublicKey[],
    initialBalance: number = 1000
): Promise<{ [key: string]: PublicKey }> {
    const tokenAccounts: { [key: string]: PublicKey } = {};

    for (const user of users) {
        const tokenAccount = await mockToken.createTokenAccount(user);
        await mockToken.mintTo(tokenAccount, initialBalance);
        tokenAccounts[user.toString()] = tokenAccount;

        debug(`👤 User ${user.toString().slice(0, 8)}... setup with ${initialBalance} tokens`);
    }

    return tokenAccounts;
}
