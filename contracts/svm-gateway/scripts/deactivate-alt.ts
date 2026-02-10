import {
  Connection,
  Keypair,
  PublicKey,
  AddressLookupTableProgram,
  Transaction,
} from "@solana/web3.js";
import fs from "fs";

/**
 * Deactivate an existing ALT
 *
 * WARNING: This is irreversible! The ALT will become unusable after ~513 slots (4 minutes).
 *          Only use this if you're replacing the ALT with a new one.
 *
 * Usage:
 *   npx ts-node scripts/deactivate-alt.ts --alt <ALT_ADDRESS>
 *
 * Example:
 *   npx ts-node scripts/deactivate-alt.ts --alt FkX...
 */

async function main() {
  const args = process.argv.slice(2);

  // Parse arguments
  const altIndex = args.indexOf("--alt");

  if (altIndex === -1) {
    console.error("Usage: npx ts-node scripts/deactivate-alt.ts --alt <ADDRESS>");
    process.exit(1);
  }

  const altAddress = new PublicKey(args[altIndex + 1]);

  console.log("⚠️  WARNING: You are about to DEACTIVATE an ALT!");
  console.log("   ALT Address:", altAddress.toBase58());
  console.log();
  console.log("   This action is IRREVERSIBLE and will:");
  console.log("   - Make the ALT unusable after ~513 slots (4 minutes)");
  console.log("   - Break any transactions currently using this ALT");
  console.log("   - Require creating a new ALT to replace it");
  console.log();

  const connection = new Connection(
    process.env.ANCHOR_PROVIDER_URL || "https://api.devnet.solana.com",
    "confirmed"
  );

  const wallet = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync("./upgrade-keypair.json", "utf8")))
  );

  // Verify current ALT state
  const altAccount = await connection.getAddressLookupTable(altAddress);
  if (!altAccount.value) {
    console.error("❌ ALT not found on-chain:", altAddress.toBase58());
    process.exit(1);
  }

  console.log("📋 Current ALT state:");
  console.log("   Addresses:", altAccount.value.state.addresses.length);
  console.log("   Authority:", altAccount.value.state.authority?.toBase58());

  if (altAccount.value.state.authority?.toBase58() !== wallet.publicKey.toBase58()) {
    console.error("❌ Wallet is not the authority for this ALT");
    console.error(`   Expected: ${wallet.publicKey.toBase58()}`);
    console.error(`   Actual: ${altAccount.value.state.authority?.toBase58()}`);
    process.exit(1);
  }

  if (altAccount.value.state.deactivationSlot !== undefined) {
    console.log(`ℹ️  ALT is already deactivated at slot ${altAccount.value.state.deactivationSlot}`);
    process.exit(0);
  }

  // Confirm deactivation
  console.log("\n⚠️  Type 'DEACTIVATE' to confirm (case-sensitive):");
  const confirmation = await new Promise<string>((resolve) => {
    process.stdin.once("data", (data) => {
      resolve(data.toString().trim());
    });
  });

  if (confirmation !== "DEACTIVATE") {
    console.log("❌ Deactivation cancelled.");
    process.exit(0);
  }

  // Deactivate ALT
  console.log("\n🔧 Deactivating ALT...");

  const deactivateIx = AddressLookupTableProgram.deactivateLookupTable({
    lookupTable: altAddress,
    authority: wallet.publicKey,
  });

  const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash();

  const tx = new Transaction().add(deactivateIx);
  tx.recentBlockhash = blockhash;
  tx.feePayer = wallet.publicKey;

  const sig = await connection.sendTransaction(tx, [wallet]);
  await connection.confirmTransaction({
    signature: sig,
    blockhash,
    lastValidBlockHeight,
  });

  console.log("\n✅ ALT deactivated!");
  console.log("   Signature:", sig);

  // Get current slot
  const currentSlot = await connection.getSlot();
  console.log(`   Current slot: ${currentSlot}`);
  console.log(`   ALT will be fully deactivated after slot: ${currentSlot + 513}`);
  console.log(`   Estimated time: ~4 minutes`);

  // Wait and verify
  console.log("\n⏳ Waiting for deactivation to propagate...");
  await new Promise(resolve => setTimeout(resolve, 1000));

  const deactivatedAlt = await connection.getAddressLookupTable(altAddress);
  if (deactivatedAlt.value?.state.deactivationSlot !== undefined) {
    console.log("\n✅ Deactivation confirmed:");
    console.log("   Deactivation slot:", deactivatedAlt.value.state.deactivationSlot);
  }

  console.log("\n⚠️  Next steps:");
  console.log("   1. Create a new ALT to replace this one");
  console.log("   2. Update alt-config-*.json with new ALT address");
  console.log("   3. Redeploy backend with new ALT config");
  console.log("   4. (Optional) Close this ALT after 513 slots to reclaim rent");
}

main().catch(console.error);
