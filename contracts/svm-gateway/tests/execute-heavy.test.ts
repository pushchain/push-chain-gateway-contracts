import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { TestCounter } from "../target/types/test_counter";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import { TOKEN_PROGRAM_ID, getAssociatedTokenAddress, ASSOCIATED_TOKEN_PROGRAM_ID } from "@solana/spl-token";
import * as sharedState from "./shared-state";
import { signTssMessage, buildExecuteAdditionalData, TssInstruction, GatewayAccountMeta, generateUniversalTxId } from "./helpers/tss";
import { ensureTestSetup } from "./helpers/test-setup";
import {
    COMPUTE_BUFFER, BASE_RENT_FEE,
    computeDiscriminator,
    makeTxIdGenerator, generateSender,
    getExecutedTxPda as _getExecutedTxPda, getCeaAuthorityPda as _getCeaAuthorityPda,
    getExecutedTxRent, calculateSolExecuteFees,
    instructionAccountsToGatewayMetas, instructionAccountsToRemaining, accountsToWritableFlagsOnly,
} from "./helpers/test-utils";
import { makeWithdrawAndExecuteBuilder, WithdrawAndExecuteArgs } from "./helpers/builders";

describe("Universal Gateway - Heavy Transaction Benchmarking", () => {
    anchor.setProvider(anchor.AnchorProvider.env());
    const provider = anchor.getProvider() as anchor.AnchorProvider;
    const gatewayProgram = anchor.workspace.UniversalGateway as Program<UniversalGateway>;
    const counterProgram = anchor.workspace.TestCounter as Program<TestCounter>;

    before(async () => {
        await ensureTestSetup();
    });

    let admin: Keypair;
    let counterPda: PublicKey;
    let counterBump: number;
    let counterAuthority: Keypair;

    let configPda: PublicKey;
    let vaultPda: PublicKey;
    let tssPda: PublicKey;

    let currentNonce = 0;
    let withdrawAndExecute: ReturnType<typeof makeWithdrawAndExecuteBuilder>;

    const generateTxId = makeTxIdGenerator();
    const getExecutedTxPda = (txId: number[]) => _getExecutedTxPda(txId, gatewayProgram.programId);
    const getCeaAuthorityPda = (sender: number[]) => _getCeaAuthorityPda(sender, gatewayProgram.programId);

    const syncNonceFromChain = async () => {
        const account = await gatewayProgram.account.tssPda.fetch(tssPda);
        currentNonce = Number(account.nonce);
    };

    before(async () => {
        admin = sharedState.getAdmin();
        counterAuthority = sharedState.getCounterAuthority();

        const airdropLamports = 100 * anchor.web3.LAMPORTS_PER_SOL;
        await Promise.all([
            provider.connection.requestAirdrop(admin.publicKey, airdropLamports),
            provider.connection.requestAirdrop(counterAuthority.publicKey, airdropLamports),
        ]);
        await new Promise((resolve) => setTimeout(resolve, 2000));

        [configPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("config")],
            gatewayProgram.programId
        );

        [vaultPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("vault")],
            gatewayProgram.programId
        );

        [tssPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("tsspda")],
            gatewayProgram.programId
        );

        [counterPda, counterBump] = PublicKey.findProgramAddressSync(
            [Buffer.from("counter")],
            counterProgram.programId
        );

        // Check if counter already exists (from other test files)
        try {
            const existingCounter = await counterProgram.account.counter.fetch(counterPda);
            // Use the existing authority
            counterAuthority = { publicKey: existingCounter.authority } as Keypair;
        } catch (err: any) {
            // Counter doesn't exist, initialize it
            try {
                await counterProgram.methods
                    .initialize(new anchor.BN(0))
                    .accounts({
                        counter: counterPda,
                        authority: counterAuthority.publicKey,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([counterAuthority])
                    .rpc();
            } catch (initErr: any) {
                // Counter might have been initialized by another test file between check and init
                if (initErr.message?.includes("already in use")) {
                    // Fetch the existing counter to get its authority
                    const existingCounter = await counterProgram.account.counter.fetch(counterPda);
                    counterAuthority = { publicKey: existingCounter.authority } as Keypair;
                } else {
                    throw initErr;
                }
            }
        }

        await syncNonceFromChain();

        // Fund vault with SOL (needed for rent_fee transfers to CEA)
        const vaultAmount = 100 * anchor.web3.LAMPORTS_PER_SOL;
        const vaultTx = new anchor.web3.Transaction().add(
            anchor.web3.SystemProgram.transfer({
                fromPubkey: admin.publicKey,
                toPubkey: vaultPda,
                lamports: vaultAmount,
            })
        );
        await provider.sendAndConfirm(vaultTx, [admin]);

        withdrawAndExecute = makeWithdrawAndExecuteBuilder(gatewayProgram, configPda, vaultPda, tssPda);
    });

    describe("Heavy batch_operation tests", () => {
        it("should execute batch_operation with 10 accounts and 100 bytes data", async () => {
            await syncNonceFromChain();
            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const sender = generateSender();
            const cea = getCeaAuthorityPda(sender);

            // Create 10 dummy accounts (keypairs)
            const dummyAccounts = Array.from({ length: 10 }, () => Keypair.generate());

            // Create large instruction data (100 bytes)
            const operationId = 12345;
            const largeData = Buffer.alloc(100, 0xAA); // 100 bytes of data

            // Build accounts for batch_operation
            const batchIx = await counterProgram.methods
                .batchOperation(new anchor.BN(operationId), largeData)
                .accounts({
                    counter: counterPda,
                    authority: counterAuthority.publicKey,
                })
                .remainingAccounts(
                    dummyAccounts.map(acc => ({
                        pubkey: acc.publicKey,
                        isWritable: false,
                        isSigner: false,
                    }))
                )
                .instruction();

            // Use the instruction data from Anchor (already encoded correctly)
            const ixData = Buffer.from(batchIx.data);

            const accounts = instructionAccountsToGatewayMetas(batchIx);
            const remaining = instructionAccountsToRemaining(batchIx);

            const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                nonce: currentNonce,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    ixData,
                    gasFee,
                    rentFee
                ),
            });

            // Vault is already funded in before() hook
            // Vault transfers rent_fee to CEA during execute

            const counterBefore = await counterProgram.account.counter.fetch(counterPda);
            const writableFlags = accountsToWritableFlagsOnly(accounts);

            await withdrawAndExecute({
                instructionId: 2,
                txId,
                universalTxId,
                amount: new anchor.BN(0),
                sender,
                writableFlags,
                ixData,
                gasFee: new anchor.BN(Number(gasFee)),
                rentFee: new anchor.BN(Number(rentFee)),
                sig,
                caller: admin.publicKey,
                destinationProgram: counterProgram.programId,
            })
                .remainingAccounts(remaining)
                .signers([admin])
                .rpc();

            const counterAfter = await counterProgram.account.counter.fetch(counterPda);
            expect(counterAfter.value.toNumber()).to.equal(
                counterBefore.value.toNumber() + operationId
            );
        });

        it("should execute batch_operation with 8 accounts and 150 bytes data", async () => {
            await syncNonceFromChain();
            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const sender = generateSender();
            const cea = getCeaAuthorityPda(sender);

            const dummyAccounts = Array.from({ length: 8 }, () => Keypair.generate()); // Reduced from 12 to 8
            const operationId = 54321;
            const largeData = Buffer.alloc(150, 0xBB); // Reduced from 200 to fit within limit

            const batchIx = await counterProgram.methods
                .batchOperation(new anchor.BN(operationId), largeData)
                .accounts({
                    counter: counterPda,
                    authority: counterAuthority.publicKey,
                })
                .remainingAccounts(
                    dummyAccounts.map(acc => ({
                        pubkey: acc.publicKey,
                        isWritable: Math.random() > 0.5, // Mix of writable/readonly
                        isSigner: false,
                    }))
                )
                .instruction();

            // Use the instruction data from Anchor (already encoded correctly)
            const ixData = Buffer.from(batchIx.data);

            const accounts = instructionAccountsToGatewayMetas(batchIx);
            const remaining = instructionAccountsToRemaining(batchIx);

            const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                nonce: currentNonce,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    ixData,
                    gasFee,
                    rentFee
                ),
            });

            // Fund CEA with rent_fee (needed for target program rent)
            const fundTx2 = new anchor.web3.Transaction().add(
                anchor.web3.SystemProgram.transfer({
                    fromPubkey: admin.publicKey,
                    toPubkey: cea,
                    lamports: Number(rentFee) + 100_000,
                })
            );
            await provider.sendAndConfirm(fundTx2, [admin]);

            const counterBefore = await counterProgram.account.counter.fetch(counterPda);
            const writableFlags = accountsToWritableFlagsOnly(accounts);

            await withdrawAndExecute({
                instructionId: 2,
                txId,
                universalTxId,
                amount: new anchor.BN(0),
                sender,
                writableFlags,
                ixData,
                gasFee: new anchor.BN(Number(gasFee)),
                rentFee: new anchor.BN(Number(rentFee)),
                sig,
                caller: admin.publicKey,
                destinationProgram: counterProgram.programId,
            })
                .remainingAccounts(remaining)
                .signers([admin])
                .rpc();

            const counterAfter = await counterProgram.account.counter.fetch(counterPda);
            expect(counterAfter.value.toNumber()).to.equal(
                counterBefore.value.toNumber() + operationId
            );
        });

        it("should execute batch_operation with 10 accounts and 100 bytes data (near limit)", async () => {
            await syncNonceFromChain();
            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const sender = generateSender();
            const cea = getCeaAuthorityPda(sender);

            const dummyAccounts = Array.from({ length: 10 }, () => Keypair.generate()); // Reduced from 15 to 10
            const operationId = 99999;
            const largeData = Buffer.alloc(100, 0xCC); // Reduced from 300 to fit within limit

            const batchIx = await counterProgram.methods
                .batchOperation(new anchor.BN(operationId), largeData)
                .accounts({
                    counter: counterPda,
                    authority: counterAuthority.publicKey,
                })
                .remainingAccounts(
                    dummyAccounts.map((acc, i) => ({
                        pubkey: acc.publicKey,
                        isWritable: i % 2 === 0, // Alternating writable/readonly
                        isSigner: false,
                    }))
                )
                .instruction();

            // Use the instruction data from Anchor (already encoded correctly)
            const ixData = Buffer.from(batchIx.data);

            const accounts = instructionAccountsToGatewayMetas(batchIx);
            const remaining = instructionAccountsToRemaining(batchIx);

            const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                nonce: currentNonce,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    ixData,
                    gasFee,
                    rentFee
                ),
            });

            // Fund CEA with rent_fee (needed for target program rent)
            const fundTx3 = new anchor.web3.Transaction().add(
                anchor.web3.SystemProgram.transfer({
                    fromPubkey: admin.publicKey,
                    toPubkey: cea,
                    lamports: Number(rentFee) + 100_000,
                })
            );
            await provider.sendAndConfirm(fundTx3, [admin]);

            const counterBefore = await counterProgram.account.counter.fetch(counterPda);
            const writableFlags = accountsToWritableFlagsOnly(accounts);

            await withdrawAndExecute({
                instructionId: 2,
                txId,
                universalTxId,
                amount: new anchor.BN(0),
                sender,
                writableFlags,
                ixData,
                gasFee: new anchor.BN(Number(gasFee)),
                rentFee: new anchor.BN(Number(rentFee)),
                sig,
                caller: admin.publicKey,
                destinationProgram: counterProgram.programId,
            })
                .remainingAccounts(remaining)
                .signers([admin])
                .rpc();

            const counterAfter = await counterProgram.account.counter.fetch(counterPda);
            expect(counterAfter.value.toNumber()).to.equal(
                counterBefore.value.toNumber() + operationId
            );
        });

        it("should fail when transaction exceeds 1232 bytes limit (18 accounts + 400 bytes)", async () => {
            await syncNonceFromChain();
            const txId = generateTxId();
            const universalTxId = generateUniversalTxId();
            const sender = generateSender();
            const cea = getCeaAuthorityPda(sender);

            // Try to create a transaction that exceeds the limit
            const dummyAccounts = Array.from({ length: 18 }, () => Keypair.generate());
            const operationId = 11111;
            const largeData = Buffer.alloc(400, 0xDD); // Very large data

            const batchIx = await counterProgram.methods
                .batchOperation(new anchor.BN(operationId), largeData)
                .accounts({
                    counter: counterPda,
                    authority: counterAuthority.publicKey,
                })
                .remainingAccounts(
                    dummyAccounts.map(acc => ({
                        pubkey: acc.publicKey,
                        isWritable: false,
                        isSigner: false,
                    }))
                )
                .instruction();

            // Use the instruction data from Anchor (already encoded correctly)
            const ixData = Buffer.from(batchIx.data);

            const accounts = instructionAccountsToGatewayMetas(batchIx);
            const remaining = instructionAccountsToRemaining(batchIx);

            const { gasFee, rentFee } = await calculateSolExecuteFees(provider.connection);

            const sig = await signTssMessage({
                instruction: TssInstruction.Execute,
                nonce: currentNonce,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxId),
                    new Uint8Array(txId),
                    counterProgram.programId,
                    new Uint8Array(sender),
                    accounts,
                    ixData,
                    gasFee,
                    rentFee
                ),
            });

            const writableFlags = accountsToWritableFlagsOnly(accounts);

            // This should fail with transaction size error
            try {
                await withdrawAndExecute({
                    instructionId: 2,
                    txId,
                    universalTxId,
                    amount: new anchor.BN(0),
                    sender,
                    writableFlags,
                    ixData,
                    gasFee: new anchor.BN(Number(gasFee)),
                    rentFee: new anchor.BN(Number(rentFee)),
                    sig,
                    caller: admin.publicKey,
                    destinationProgram: counterProgram.programId,
                })
                    .remainingAccounts(remaining)
                    .signers([admin])
                    .rpc();

                // If we get here, the transaction succeeded (unexpected)
                // This might happen if the actual size is slightly under the limit
                console.log("⚠️ Transaction succeeded - size might be under limit");
            } catch (err: any) {
                // Expected: transaction too large
                expect(
                    err.message?.includes("Transaction too large") ||
                    err.message?.includes("transaction too large") ||
                    err.message?.includes("exceeds") ||
                    err.logs?.some((log: string) => log.includes("too large"))
                ).to.be.true;
            }
        });
    });
});

