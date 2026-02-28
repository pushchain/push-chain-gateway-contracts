import {
  Connection,
  PublicKey,
  AddressLookupTableAccount,
  TransactionMessage,
  VersionedTransaction,
  TransactionInstruction,
} from "@solana/web3.js";
import fs from "fs";

/**
 * ALT Helper for finalize_universal_tx transactions
 *
 * Supports dual ALT architecture:
 * 1. Protocol Static ALT (same for all txs):
 *    - 4 accounts for SOL txs: config, tss, vault, system_program
 *    - 7 accounts for SPL txs: adds token_program, ata_program, rent
 * 2. Token-Specific ALT (per token):
 *    - 2 accounts: mint, vault_ata
 *
 * Total savings:
 * - SOL: 92 bytes (protocol ALT with 4 accounts)
 * - SPL: 215 bytes (protocol ALT with 7 accounts + token ALT with 2 accounts)
 */

interface ProtocolAltConfig {
  protocolStaticALT: string;
  accounts: string[];
}

interface TokenAltConfig {
  network: string;
  tokens: Array<{
    symbol: string;
    mint: string;
    altAddress: string;
    accounts: string[];
  }>;
}

export class AltHelper {
  private protocolAlt: PublicKey | null = null;
  private tokenAlts: Map<string, PublicKey> = new Map();
  private altAccounts: Map<string, AddressLookupTableAccount> = new Map();

  constructor(
    private connection: Connection,
    private protocolAltPath = "./alt-config-protocol.json",
    private tokenAltPath = "./alt-config-tokens.json"
  ) {}

  /**
   * Load ALT configurations from custom file paths
   *
   * @param protocolAltPath - Path to protocol ALT config JSON
   * @param tokenAltPath - Path to token ALT config JSON
   */
  loadFromConfigFiles(protocolAltPath: string, tokenAltPath: string) {
    // Load protocol static ALT
    if (fs.existsSync(protocolAltPath)) {
      const config: ProtocolAltConfig = JSON.parse(
        fs.readFileSync(protocolAltPath, "utf-8")
      );
      this.protocolAlt = new PublicKey(config.protocolStaticALT);
      console.log("✅ Loaded protocol static ALT:", this.protocolAlt.toBase58());
    } else {
      console.warn(`⚠️  Protocol ALT config not found at ${protocolAltPath}. Run create-protocol-alt.ts first.`);
    }

    // Load token-specific ALTs
    if (fs.existsSync(tokenAltPath)) {
      const config: TokenAltConfig = JSON.parse(
        fs.readFileSync(tokenAltPath, "utf-8")
      );
      for (const token of config.tokens) {
        this.tokenAlts.set(token.mint, new PublicKey(token.altAddress));
      }
      console.log(`✅ Loaded ${this.tokenAlts.size} token ALTs`);
    } else {
      console.warn(`⚠️  Token ALT config not found at ${tokenAltPath}. Run create-token-alt.ts first.`);
    }
  }

  /**
   * Load ALT configurations from disk (using constructor paths)
   */
  async loadAltConfigs() {
    this.loadFromConfigFiles(this.protocolAltPath, this.tokenAltPath);
  }

  /**
   * Fetch ALT accounts from chain and validate they are active
   */
  async fetchAltAccounts() {
    const altsToFetch: PublicKey[] = [];

    if (this.protocolAlt) {
      altsToFetch.push(this.protocolAlt);
    }

    for (const altAddress of this.tokenAlts.values()) {
      altsToFetch.push(altAddress);
    }

    console.log(`📡 Fetching ${altsToFetch.length} ALT accounts...`);

    for (const altAddress of altsToFetch) {
      try {
        const altAccount = await this.connection.getAddressLookupTable(altAddress);
        if (altAccount.value) {
          // Check if ALT is deactivated (u64::MAX means active)
          const deactivationSentinel = 18446744073709551615n;
          if (altAccount.value.state.deactivationSlot !== deactivationSentinel) {
            console.error(
              `❌ ALT ${altAddress.toBase58()} is DEACTIVATED at slot ${altAccount.value.state.deactivationSlot}!`
            );
            console.error(
              `   This ALT will become unusable after ~513 slots. Recreate it immediately.`
            );
            // Still add it to allow graceful degradation, but warn loudly
          }

          this.altAccounts.set(altAddress.toBase58(), altAccount.value);
        } else {
          console.error(`❌ Failed to fetch ALT: ${altAddress.toBase58()} (not found on-chain)`);
        }
      } catch (error) {
        console.error(`❌ Error fetching ALT ${altAddress.toBase58()}:`, error);
      }
    }

    console.log(`✅ Fetched ${this.altAccounts.size} ALT accounts`);
  }

  /**
   * Get ALTs to use for a specific transaction
   *
   * @param mint - Token mint address (null for SOL)
   * @param strict - If true, throw error for missing token ALT (default: false)
   * @returns Array of ALT accounts to include
   */
  getAltsForTransaction(mint: PublicKey | null, strict = false): AddressLookupTableAccount[] {
    const alts: AddressLookupTableAccount[] = [];

    // Always include protocol static ALT
    if (this.protocolAlt) {
      const protocolAltAccount = this.altAccounts.get(this.protocolAlt.toBase58());
      if (protocolAltAccount) {
        alts.push(protocolAltAccount);
      } else {
        console.warn(`⚠️  Protocol ALT account not loaded: ${this.protocolAlt.toBase58()}`);
      }
    } else {
      console.warn("⚠️  No protocol static ALT configured. Transaction will be larger.");
    }

    // Include token-specific ALT if SPL transaction
    if (mint) {
      const tokenAlt = this.tokenAlts.get(mint.toBase58());
      if (tokenAlt) {
        const tokenAltAccount = this.altAccounts.get(tokenAlt.toBase58());
        if (tokenAltAccount) {
          alts.push(tokenAltAccount);
        } else {
          const msg = `Token ALT not loaded for mint: ${mint.toBase58()}`;
          if (strict) {
            throw new Error(msg);
          } else {
            console.warn(`⚠️  ${msg}. Transaction will be ~123 bytes larger.`);
          }
        }
      } else {
        const msg = `No token ALT configured for mint: ${mint.toBase58()}. Run create-token-alt.ts first.`;
        if (strict) {
          throw new Error(msg);
        } else {
          console.warn(`⚠️  ${msg}. Transaction will be ~123 bytes larger.`);
        }
      }
    }

    return alts;
  }

  /**
   * Build versioned transaction with ALT support
   *
   * @param instructions - Transaction instructions
   * @param payer - Fee payer public key
   * @param mint - Token mint (null for SOL)
   * @returns Versioned transaction ready to sign
   */
  async buildVersionedTransaction(
    instructions: TransactionInstruction[],
    payer: PublicKey,
    mint: PublicKey | null = null
  ): Promise<VersionedTransaction> {
    const alts = this.getAltsForTransaction(mint);

    const { blockhash } = await this.connection.getLatestBlockhash();

    const messageV0 = new TransactionMessage({
      payerKey: payer,
      recentBlockhash: blockhash,
      instructions,
    }).compileToV0Message(alts);

    return new VersionedTransaction(messageV0);
  }

  /**
   * Estimate transaction size savings
   *
   * Calculation:
   * - Without ALT: Each account = 32 bytes
   * - With ALT: ALT address (32 bytes) + indices (1 byte each)
   * - Net savings per ALT: (accounts × 32) - (32 + accounts × 1)
   *
   * @param mint - Token mint (null for SOL)
   * @returns Estimated bytes saved
   */
  estimateSavings(mint: PublicKey | null): number {
    let savings = 0;

    if (mint) {
      // SPL transaction uses Protocol ALT (7 accounts) + Token ALT (2 accounts)

      // Protocol ALT: 7 accounts (config, tss, vault, system, token_program, ata_program, rent)
      // Without: 7 × 32 = 224 bytes
      // With: 32 (ALT address) + 7 × 1 (indices) = 39 bytes
      // Savings: 224 - 39 = 185 bytes
      if (this.protocolAlt) {
        savings += 185;
      }

      // Token-specific ALT: 2 accounts (mint, vault_ata)
      // Without: 2 × 32 = 64 bytes
      // With: 32 (ALT address) + 2 × 1 (indices) = 34 bytes
      // Savings: 64 - 34 = 30 bytes
      if (this.tokenAlts.has(mint.toBase58())) {
        savings += 30;
      }
    } else {
      // SOL transaction uses Protocol ALT only (4 accounts)
      // Without: 4 × 32 = 128 bytes
      // With: 32 (ALT address) + 4 × 1 (indices) = 36 bytes
      // Savings: 128 - 36 = 92 bytes
      if (this.protocolAlt) {
        savings += 92;
      }
    }

    return savings;
  }

  /**
   * Print ALT usage summary
   */
  printSummary(mint: PublicKey | null) {
    const alts = this.getAltsForTransaction(mint);
    const savings = this.estimateSavings(mint);

    console.log("\n📊 ALT Usage Summary:");
    console.log(`   ALTs used: ${alts.length}`);
    console.log(`   Total accounts in ALTs: ${alts.reduce((sum, alt) => sum + alt.state.addresses.length, 0)}`);
    console.log(`   Estimated savings: ${savings} bytes`);

    if (alts.length > 0) {
      console.log("\n   ALT Details:");
      alts.forEach((alt, idx) => {
        const altKey = [...this.altAccounts.entries()].find(
          ([_, account]) => account === alt
        )?.[0];
        console.log(`   ${idx + 1}. ${altKey}`);
        console.log(`      Addresses: ${alt.state.addresses.length}`);
      });
    }
  }
}

/**
 * Example usage
 */
export async function exampleUsage() {
  const connection = new Connection("https://api.devnet.solana.com", "confirmed");
  const altHelper = new AltHelper(connection);

  // Load and fetch ALT configs
  await altHelper.loadAltConfigs();
  await altHelper.fetchAltAccounts();

  // For SOL transaction
  console.log("\n--- SOL Transaction ---");
  altHelper.printSummary(null);

  // For SPL transaction (USDC)
  const usdcMint = new PublicKey("4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU");
  console.log("\n--- USDC Transaction ---");
  altHelper.printSummary(usdcMint);
}

// Run example if executed directly
if (require.main === module) {
  exampleUsage().catch(console.error);
}
