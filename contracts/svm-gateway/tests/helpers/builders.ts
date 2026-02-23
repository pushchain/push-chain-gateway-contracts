import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../../target/types/universal_gateway";
import { PublicKey, SystemProgram } from "@solana/web3.js";
import { getCeaAuthorityPda, getExecutedTxPda } from "./test-utils";

// =============================================================================
// WithdrawAndExecute builder
// =============================================================================

export interface WithdrawAndExecuteArgs {
    instructionId: number;
    txId: number[];
    universalTxId: number[] | Uint8Array;
    amount: anchor.BN;
    sender: number[];
    writableFlags?: Buffer;
    ixData?: Buffer;
    gasFee: anchor.BN;
    rentFee?: anchor.BN;
    sig: {
        signature: ArrayLike<number>;
        recoveryId: number;
        messageHash: ArrayLike<number>;
        nonce: anchor.BN | number;
    };
    caller: PublicKey;
    destinationProgram?: PublicKey;
    recipient?: PublicKey | null;
    vaultAta?: PublicKey | null;
    ceaAta?: PublicKey | null;
    mint?: PublicKey | null;
    tokenProgram?: PublicKey | null;
    rent?: PublicKey | null;
    associatedTokenProgram?: PublicKey | null;
    recipientAta?: PublicKey | null;
    rateLimitConfig?: PublicKey | null;
    tokenRateLimit?: PublicKey | null;
}

/**
 * Returns a `withdrawAndExecute` builder bound to the given program and PDAs.
 *
 * Usage (call once in before(), assign to a `let` variable):
 *   withdrawAndExecute = makeWithdrawAndExecuteBuilder(gatewayProgram, configPda, vaultPda, tssPda);
 *
 * The returned function collapses the 13-arg method call + 15-field accounts block.
 * Call sites still chain .signers([...]).rpc() — and .remainingAccounts([...]) for execute.
 * All test assertions remain in the test body unchanged.
 */
export const makeWithdrawAndExecuteBuilder = (
    program: Program<UniversalGateway>,
    configPda: PublicKey,
    vaultPda: PublicKey,
    tssPda: PublicKey,
) => ({
    instructionId,
    txId,
    universalTxId,
    amount,
    sender,
    writableFlags = Buffer.alloc(0),
    ixData = Buffer.from([]),
    gasFee,
    rentFee = new anchor.BN(0),
    sig,
    caller,
    destinationProgram,
    recipient = null,
    vaultAta = null,
    ceaAta = null,
    mint = null,
    tokenProgram = null,
    rent = null,
    associatedTokenProgram = null,
    recipientAta = null,
    rateLimitConfig = null,
    tokenRateLimit = null,
}: WithdrawAndExecuteArgs) =>
    program.methods
        .withdrawAndExecute(
            instructionId,
            Array.from(txId),
            Array.from(universalTxId),
            amount,
            Array.from(sender),
            writableFlags,
            ixData,
            gasFee,
            rentFee,
            Array.from(sig.signature),
            sig.recoveryId,
            Array.from(sig.messageHash),
            typeof sig.nonce === "number" ? new anchor.BN(sig.nonce) : sig.nonce,
        )
        .accounts({
            caller,
            config: configPda,
            vaultSol: vaultPda,
            ceaAuthority: getCeaAuthorityPda(Array.from(sender), program.programId),
            tssPda,
            executedTx: getExecutedTxPda(Array.from(txId), program.programId),
            destinationProgram: destinationProgram ?? SystemProgram.programId,
            recipient,
            vaultAta,
            ceaAta,
            mint,
            tokenProgram,
            rent,
            associatedTokenProgram,
            recipientAta,
            rateLimitConfig,
            tokenRateLimit,
            systemProgram: SystemProgram.programId,
        });
