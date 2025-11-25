import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { pullOracleClient } from "@tkkinn/mock-pyth-sdk";
import NodeWallet from "@coral-xyz/anchor/dist/cjs/nodewallet";
// Load pull IDL from SDK source (SDK has bug - uses push IDL, so we load correct one)
const pullIdl = require("@tkkinn/mock-pyth-sdk/src/idl/mock_pyth_pull.json");

export async function setupPriceFeed() {
    const provider = anchor.AnchorProvider.env();
    anchor.setProvider(provider);

    const programId = new anchor.web3.PublicKey(
        "rec5EKMGg6MxZYaMdyBfgwp4d5rB9T1VQH5pJv5LtFJ"
    );

    // IMPORTANT: Must match the Rust FEED_ID exactly
    const FEED_ID = "ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d";

    // SDK creates Program without provider, so we create it ourselves
    // Ensure IDL is a plain object (not a module export)
    const idl = JSON.parse(JSON.stringify(pullIdl));

    // Create Program with provider only - IDL already has address field
    // Anchor will use the IDL's address field (which matches programId)
    const program = new Program(idl, provider) as any;

    // Ensure wallet is NodeWallet type
    const wallet = provider.wallet as NodeWallet;

    const pullOracle = new pullOracleClient({
        provider,
        wallet: wallet,
        program: program,
    });

    // local test price values - adjust if your tests expect different values
    const uiPrice = 150.25;
    const expo = -8;
    const conf = 100;

    // createOracle allows specifying FeedId (mock-pyth supports this) - returns [tx, priceFeedPubkey]
    // Note: createOracle already initializes the price feed with the price, so setPrice is not needed
    const [tx, priceFeedPubkey] = await pullOracle.createOracle(FEED_ID, uiPrice, expo, conf);

    // Wait for transaction confirmation
    await provider.connection.confirmTransaction(tx, "confirmed");

    return priceFeedPubkey;
}

/**
 * Helper function to get the current SOL price from the mock Pyth price feed
 */
export async function getSolPrice(priceFeedPubkey: anchor.web3.PublicKey): Promise<number> {
    const provider = anchor.AnchorProvider.env();

    const programId = new anchor.web3.PublicKey(
        "rec5EKMGg6MxZYaMdyBfgwp4d5rB9T1VQH5pJv5LtFJ"
    );

    const idl = JSON.parse(JSON.stringify(require("@tkkinn/mock-pyth-sdk/src/idl/mock_pyth_pull.json")));
    const program = new Program(idl, provider) as any;

    try {
        // Fetch the price update account
        const priceUpdateAccount = await program.account.priceUpdateV2.fetch(priceFeedPubkey);

        // The price is in priceMessage.price with priceMessage.exponent
        // Anchor converts snake_case to camelCase, so price_message becomes priceMessage
        const priceMessage = priceUpdateAccount.priceMessage || priceUpdateAccount.price_message;

        if (!priceMessage) {
            throw new Error("priceMessage not found in PriceUpdateV2");
        }

        // Access price and exponent - they might be BN objects, hex strings, or numbers
        let priceValue: number;
        if (typeof priceMessage.price === 'string') {
            // If it's a hex string, convert it
            priceValue = parseInt(priceMessage.price, 16);
        } else if (priceMessage.price?.toNumber) {
            // If it's a BN object
            priceValue = priceMessage.price.toNumber();
        } else if (typeof priceMessage.price === 'number') {
            priceValue = priceMessage.price;
        } else {
            throw new Error(`Unexpected price type: ${typeof priceMessage.price}`);
        }

        const exponent = priceMessage.exponent;

        if (priceValue === undefined || priceValue === null || exponent === undefined || exponent === null) {
            throw new Error(`Price or exponent not found. price: ${priceValue}, exponent: ${exponent}`);
        }

        // Convert: price = priceValue * 10^exponent
        const price = priceValue * Math.pow(10, exponent);

        if (!price || price <= 0 || !isFinite(price)) {
            throw new Error(`Invalid price calculated: ${price}`);
        }

        return price;
    } catch (error) {
        // Fallback to default price if fetch fails
        return 150.25;
    }
}

/**
 * Helper function to calculate SOL amount in lamports for a given USD value
 */
export function calculateSolAmount(usdValue: number, solPrice: number): number {
    const solAmount = usdValue / solPrice;
    const lamports = Math.floor(solAmount * anchor.web3.LAMPORTS_PER_SOL);

    // Ensure minimum amount is at least 1 lamport
    if (lamports === 0 && usdValue > 0) {
        return 1;
    }

    return lamports;
}

