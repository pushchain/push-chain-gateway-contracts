import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { UniversalGateway } from "../target/types/universal_gateway";
import { TestCounter } from "../target/types/test_counter";
import { PublicKey, Keypair, SystemProgram } from "@solana/web3.js";
import { expect } from "chai";
import { TOKEN_PROGRAM_ID, getAssociatedTokenAddress, createAssociatedTokenAccountInstruction, ASSOCIATED_TOKEN_PROGRAM_ID } from "@solana/spl-token";
import * as spl from "@solana/spl-token";
import * as sharedState from "./shared-state";
import { signTssMessage, buildExecuteAdditionalData, TssInstruction, GatewayAccountMeta, generateUniversalTxId } from "./helpers/tss";
import { ensureTestSetup } from "./helpers/test-setup";
import {
    USDT_DECIMALS, TOKEN_MULTIPLIER, COMPUTE_BUFFER, BASE_RENT_FEE,
    asLamports, asTokenAmount, computeDiscriminator,
    makeTxIdGenerator, generateSender,
    getExecutedTxPda as _getExecutedTxPda, getCeaAuthorityPda as _getCeaAuthorityPda,
    getCeaAta as _getCeaAta,
    getExecutedTxRent, getTokenAccountRent, ceaAtaExists,
    calculateSolExecuteFees, calculateSplExecuteFees, calculateRentFeeForAccountSize,
    instructionAccountsToGatewayMetas, instructionAccountsToRemaining, accountsToWritableFlagsOnly,
} from "./helpers/test-utils";
import { makeFinalizeUniversalTxBuilder, FinalizeUniversalTxArgs } from "./helpers/builders";

describe("Universal Gateway - CEA to UEA Tests", () => {
    anchor.setProvider(anchor.AnchorProvider.env());
    const provider = anchor.getProvider() as anchor.AnchorProvider;
    const gatewayProgram = anchor.workspace.UniversalGateway as Program<UniversalGateway>;
    const counterProgram = anchor.workspace.TestCounter as Program<TestCounter>;

    before(async () => {
        await ensureTestSetup();
    });

    let admin: Keypair;

    let configPda: PublicKey;
    let vaultPda: PublicKey;
    let tssPda: PublicKey;
    let rateLimitConfigPda: PublicKey;
    let nativeSolTokenRateLimitPda: PublicKey;
    let usdtTokenRateLimitPda: PublicKey;

    let mockUSDT: any;
    let vaultUsdtAccount: PublicKey;

    let counterPda: PublicKey;
    let counterAuthority: Keypair;

    let finalizeUniversalTx: ReturnType<typeof makeFinalizeUniversalTxBuilder>;

    const generateTxId = makeTxIdGenerator();
    const getExecutedTxPda = (subTxId: number[]) => _getExecutedTxPda(subTxId, gatewayProgram.programId);
    const getCeaAuthorityPda = (pushAccount: number[]) => _getCeaAuthorityPda(pushAccount, gatewayProgram.programId);
    const getCeaAta = (pushAccount: number[], mint: PublicKey) => _getCeaAta(pushAccount, mint, gatewayProgram.programId);

    before(async () => {
        admin = sharedState.getAdmin();
        mockUSDT = sharedState.getMockUSDT();
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
            [Buffer.from("tsspda_v2")],
            gatewayProgram.programId
        );
        [rateLimitConfigPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit_config")],
            gatewayProgram.programId
        );
        [nativeSolTokenRateLimitPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit"), Buffer.alloc(32, 0)],
            gatewayProgram.programId
        );
        [usdtTokenRateLimitPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("rate_limit"), mockUSDT.mint.publicKey.toBuffer()],
            gatewayProgram.programId
        );

        // Initialize token rate limits if not already done
        const veryLargeThreshold = new anchor.BN("1000000000000000000000");
        for (const [pda, mint] of [
            [nativeSolTokenRateLimitPda, PublicKey.default],
            [usdtTokenRateLimitPda, mockUSDT.mint.publicKey],
        ] as [PublicKey, PublicKey][]) {
            try {
                await gatewayProgram.account.tokenRateLimit.fetch(pda);
            } catch {
                await gatewayProgram.methods
                    .setTokenRateLimit(veryLargeThreshold)
                    .accounts({
                        config: configPda,
                        rateLimitConfig: rateLimitConfigPda,
                        tokenRateLimit: pda,
                        tokenMint: mint,
                        admin: admin.publicKey,
                        systemProgram: SystemProgram.programId,
                    })
                    .signers([admin])
                    .rpc();
            }
        }

        // Get vault ATA and create if needed
        vaultUsdtAccount = await getAssociatedTokenAddress(
            mockUSDT.mint.publicKey,
            vaultPda,
            true,
            TOKEN_PROGRAM_ID,
            ASSOCIATED_TOKEN_PROGRAM_ID
        );
        const vaultAtaInfo = await provider.connection.getAccountInfo(vaultUsdtAccount);
        if (!vaultAtaInfo) {
            const createVaultAtaIx = createAssociatedTokenAccountInstruction(
                admin.publicKey,
                vaultUsdtAccount,
                vaultPda,
                mockUSDT.mint.publicKey,
                TOKEN_PROGRAM_ID,
                ASSOCIATED_TOKEN_PROGRAM_ID
            );
            await provider.sendAndConfirm(new anchor.web3.Transaction().add(createVaultAtaIx), [admin]);
        }

        // Fund vault with SOL (needed for execute operations in these tests)
        const vaultSolTx = new anchor.web3.Transaction().add(
            anchor.web3.SystemProgram.transfer({
                fromPubkey: admin.publicKey,
                toPubkey: vaultPda,
                lamports: asLamports(100).toNumber(),
            })
        );
        await provider.sendAndConfirm(vaultSolTx, [admin]);

        // Fund vault with USDT tokens (needed for SPL execute tests)
        await mockUSDT.mintTo(vaultUsdtAccount, 1000);

        // Initialize test counter with dedicated authority
        [counterPda] = PublicKey.findProgramAddressSync(
            [Buffer.from("counter")],
            counterProgram.programId
        );
        try {
            await counterProgram.methods
                .initialize(new anchor.BN(0))
                .accounts({
                    counter: counterPda,
                    authority: counterAuthority.publicKey,
                    rateLimitConfig: null,
                    tokenRateLimit: null,
                    systemProgram: SystemProgram.programId,
                })
                .signers([counterAuthority])
                .rpc();
        } catch {
            // Already initialized — fine
        }

        finalizeUniversalTx = makeFinalizeUniversalTxBuilder(gatewayProgram, configPda, vaultPda, tssPda);
    });

    describe("CEA → UEA: SOL", () => {
        it("should allow gateway self-call to withdraw SOL from CEA", async () => {
            const pushAccount = generateSender();
            const cea = getCeaAuthorityPda(pushAccount);

            // 1) Fund CEA via execute (amount > 0, target = counterProgram)
            const txIdFund = generateTxId();
            const universalTxIdFund = generateUniversalTxId();
            const fundAmount = asLamports(1);
            const counterIx = await counterProgram.methods
                .increment(new anchor.BN(0))
                .accounts({ counter: counterPda, authority: counterAuthority.publicKey })
                .instruction();
            // CRITICAL: Use the EXACT same accounts for signing and remaining_accounts
            const remainingAccounts = instructionAccountsToRemaining(counterIx);
            const fundAccounts = remainingAccounts.map((acc) => ({
                pubkey: acc.pubkey,
                isWritable: acc.isWritable,
            }));

            // Calculate fees dynamically for fund operation
            const { gasFee: gasFeeFund, rentFee: rentFeeFund } = await calculateSolExecuteFees(provider.connection);

            const sigFund = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(fundAmount.toString()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxIdFund),
                    new Uint8Array(txIdFund),
                    counterProgram.programId,
                    new Uint8Array(pushAccount),
                    fundAccounts,
                    counterIx.data,
                    gasFeeFund,
                    rentFeeFund
                ),
            });

            const fundWritableFlags = accountsToWritableFlagsOnly(fundAccounts);
            await finalizeUniversalTx({
                instructionId: 2,
                subTxId: txIdFund,
                universalTxId: universalTxIdFund,
                amount: fundAmount,
                pushAccount,
                writableFlags: fundWritableFlags,
                ixData: Buffer.from(counterIx.data),
                gasFee: new anchor.BN(Number(gasFeeFund)),
                rentFee: new anchor.BN(Number(rentFeeFund)),
                sig: sigFund,
                caller: admin.publicKey,
                destinationProgram: counterProgram.programId,
            })
                .remainingAccounts(remainingAccounts)
                .signers([admin])
                .rpc();

            const ceaBalBefore = await provider.connection.getBalance(cea);
            expect(ceaBalBefore).to.be.greaterThan(0);

            // 2) Withdraw all SOL from CEA via gateway self-call (target = gateway)
            const txIdWithdraw = generateTxId();
            const universalTxIdWithdraw = generateUniversalTxId();
            const withdrawDiscr = computeDiscriminator("global:send_universal_tx_to_uea");

            // Calculate fees before building args so we can compute the exact drain amount.
            // Before send_universal_tx_to_uea runs, the outer execute adds (0 + rentFeeWithdraw)
            // to CEA. So CEA balance at that point = ceaBalBefore + rentFeeWithdraw.
            // Setting args.amount = ceaBalBefore + rentFeeWithdraw drains CEA to exactly 0.
            const { gasFee: gasFeeWithdraw, rentFee: rentFeeWithdraw } = await calculateSolExecuteFees(provider.connection);
            const ceaDrainAmount = BigInt(ceaBalBefore) + rentFeeWithdraw;

            const withdrawArgs = Buffer.concat([
                Buffer.alloc(32, 0), // token = Pubkey::default()
                (() => {
                    const b = Buffer.alloc(8);
                    b.writeBigUInt64LE(ceaDrainAmount);
                    return b;
                })(),
                Buffer.from([0, 0, 0, 0]), // payload = empty Vec<u8> (Borsh: 4-byte LE length = 0)
                admin.publicKey.toBuffer(), // revert_recipient
            ]);
            const withdrawIxData = Buffer.concat([withdrawDiscr, withdrawArgs]);

            const sigW = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxIdWithdraw),
                    new Uint8Array(txIdWithdraw),
                    gatewayProgram.programId,
                    new Uint8Array(pushAccount),
                    [],
                    withdrawIxData,
                    gasFeeWithdraw,
                    rentFeeWithdraw
                ),
            });

            const callerBalanceBeforeWithdraw = await provider.connection.getBalance(admin.publicKey);
            const withdrawWritableFlags = accountsToWritableFlagsOnly([]);
            const txWithdraw = await finalizeUniversalTx({
                instructionId: 2,
                subTxId: txIdWithdraw,
                universalTxId: universalTxIdWithdraw,
                amount: new anchor.BN(0),
                pushAccount,
                writableFlags: withdrawWritableFlags,
                ixData: withdrawIxData,
                gasFee: new anchor.BN(Number(gasFeeWithdraw)),
                rentFee: new anchor.BN(Number(rentFeeWithdraw)),
                sig: sigW,
                caller: admin.publicKey,
                destinationProgram: gatewayProgram.programId,
                rateLimitConfig: rateLimitConfigPda,
                tokenRateLimit: nativeSolTokenRateLimitPda,
            })
                .signers([admin])
                .rpc();

            // Verify dual-event: UniversalTx(from_cea=true) + UniversalTxFinalized
            let txWithdrawDetails = null;
            for (let attempt = 0; attempt < 10; attempt++) {
                txWithdrawDetails = await provider.connection.getTransaction(txWithdraw, {
                    commitment: "confirmed",
                    maxSupportedTransactionVersion: 0,
                });
                if (txWithdrawDetails) break;
                await new Promise((r) => setTimeout(r, 500));
            }
            expect(txWithdrawDetails, "getTransaction returned null after retries").to.exist;

            const eventCoderSol = new anchor.BorshEventCoder(gatewayProgram.idl);
            const eventsSol = (txWithdrawDetails.meta?.logMessages ?? [])
                .filter((log) => log.includes("Program data:"))
                .map((log) => {
                    try { return eventCoderSol.decode(log.split("Program data: ")[1]); }
                    catch { return null; }
                })
                .filter((e) => e !== null);

            const universalTxEventSol = eventsSol.find((e) => e.name === "universalTx");
            expect(universalTxEventSol, "UniversalTx should be emitted").to.exist;
            expect(universalTxEventSol.data.fromCea, "from_cea should be true").to.be.true;

            const finalizedEventSol = eventsSol.find((e) => e.name === "universalTxFinalized");
            expect(finalizedEventSol, "UniversalTxFinalized should be emitted for CEA→UEA SOL path").to.exist;
            expect(finalizedEventSol.data.target.toString()).to.equal(gatewayProgram.programId.toString());
            expect(finalizedEventSol.data.token.toString()).to.equal(new anchor.web3.PublicKey(new Uint8Array(32)).toString());
            expect(finalizedEventSol.data.amount.toString()).to.equal("0"); // outer amount = 0 for CEA→UEA
            expect(Buffer.from(finalizedEventSol.data.subTxId).toString("hex")).to.equal(Buffer.from(txIdWithdraw).toString("hex"));
            expect(Buffer.from(finalizedEventSol.data.universalTxId).toString("hex")).to.equal(Buffer.from(universalTxIdWithdraw).toString("hex"));
            expect(Buffer.from(finalizedEventSol.data.pushAccount).toString("hex")).to.equal(Buffer.from(pushAccount).toString("hex"));
            expect(Buffer.from(finalizedEventSol.data.payload).toString("hex")).to.equal(withdrawIxData.toString("hex"));

            const callerBalanceAfterWithdraw = await provider.connection.getBalance(admin.publicKey);
            const actualBalanceChangeWithdraw = callerBalanceAfterWithdraw - callerBalanceBeforeWithdraw;
            // Balance flow (Option 1: relayer pays gateway costs, gets relayer_fee reimbursement):
            // 1. Caller PAYS for executed_sub_tx account creation: -890k (replay protection account)
            // 2. Caller PAYS transaction fees: ~-10-20k (Solana network compute fees)
            // 3. Vault TRANSFERS relayer_fee to caller: relayer_fee = gas_fee - rent_fee (reimbursement for gateway costs)
            // relayer_fee = (rent_fee + executed_sub_tx_rent + compute_buffer) - rent_fee = executed_sub_tx_rent + compute_buffer
            // Net expected: -executed_sub_tx_rent - tx_fees + (executed_sub_tx_rent + compute_buffer) ≈ +compute_buffer - tx_fees
            // Note: CEA is a PDA - caller doesn't pay for its creation (auto-created by Solana on first transfer)
            const actualRentForExecutedTx = await getExecutedTxRent(provider.connection);
            const relayerFeeWithdraw = Number(gasFeeWithdraw - rentFeeWithdraw);
            const expectedBalanceChangeWithdraw = -actualRentForExecutedTx + relayerFeeWithdraw;
            // Use tight tolerance (50k) to catch missing relayer_fee reimbursement
            expect(actualBalanceChangeWithdraw).to.be.closeTo(expectedBalanceChangeWithdraw, 50000);

            const ceaBalAfter = await provider.connection.getBalance(cea);
            expect(ceaBalAfter).to.equal(0);
        });

        it("should emit FundsAndPayload + from_cea when CEA withdrawal has non-empty payload", async () => {
            const pushAccount = generateSender();
            const cea = getCeaAuthorityPda(pushAccount);

            // 1) Fund CEA via execute
            const txIdFund = generateTxId();
            const universalTxIdFund = generateUniversalTxId();
            const fundAmount = asLamports(1);
            const counterIx = await counterProgram.methods
                .increment(new anchor.BN(0))
                .accounts({ counter: counterPda, authority: counterAuthority.publicKey })
                .instruction();
            const remainingAccounts = instructionAccountsToRemaining(counterIx);
            const fundAccounts = remainingAccounts.map((acc) => ({
                pubkey: acc.pubkey,
                isWritable: acc.isWritable,
            }));

            const { gasFee: gasFeeFund, rentFee: rentFeeFund } = await calculateSolExecuteFees(provider.connection);

            const sigFund = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(fundAmount.toString()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxIdFund),
                    new Uint8Array(txIdFund),
                    counterProgram.programId,
                    new Uint8Array(pushAccount),
                    fundAccounts,
                    counterIx.data,
                    gasFeeFund,
                    rentFeeFund
                ),
            });

            await finalizeUniversalTx({
                instructionId: 2,
                subTxId: txIdFund,
                universalTxId: universalTxIdFund,
                amount: fundAmount,
                pushAccount,
                writableFlags: accountsToWritableFlagsOnly(fundAccounts),
                ixData: Buffer.from(counterIx.data),
                gasFee: new anchor.BN(Number(gasFeeFund)),
                rentFee: new anchor.BN(Number(rentFeeFund)),
                sig: sigFund,
                caller: admin.publicKey,
                destinationProgram: counterProgram.programId,
            })
                .remainingAccounts(remainingAccounts)
                .signers([admin])
                .rpc();

            // 2) Withdraw from CEA with a non-empty payload → FundsAndPayload + from_cea
            const txIdWithdraw = generateTxId();
            const universalTxIdWithdraw = generateUniversalTxId();
            const withdrawDiscr = computeDiscriminator("global:send_universal_tx_to_uea");
            const ceaPayload = Buffer.from([0x42, 0x00, 0x01]); // arbitrary non-empty payload

            // Read CEA balance and calculate fees before building args.
            const ceaBalBeforeP2 = await provider.connection.getBalance(cea);
            const { gasFee: gasFeeWithdraw, rentFee: rentFeeWithdraw } = await calculateSolExecuteFees(provider.connection);
            const ceaDrainAmountP2 = BigInt(ceaBalBeforeP2) + rentFeeWithdraw;

            const withdrawArgs = Buffer.concat([
                Buffer.alloc(32, 0), // token = Pubkey::default() (SOL)
                (() => {
                    const b = Buffer.alloc(8);
                    b.writeBigUInt64LE(ceaDrainAmountP2);
                    return b;
                })(),
                // payload = Vec<u8> (Borsh: 4-byte LE length + bytes)
                (() => {
                    const lenBuf = Buffer.alloc(4);
                    lenBuf.writeUInt32LE(ceaPayload.length, 0);
                    return Buffer.concat([lenBuf, ceaPayload]);
                })(),
                admin.publicKey.toBuffer(), // revert_recipient
            ]);
            const withdrawIxData = Buffer.concat([withdrawDiscr, withdrawArgs]);

            const sigW = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxIdWithdraw),
                    new Uint8Array(txIdWithdraw),
                    gatewayProgram.programId,
                    new Uint8Array(pushAccount),
                    [],
                    withdrawIxData,
                    gasFeeWithdraw,
                    rentFeeWithdraw
                ),
            });

            const tx = await finalizeUniversalTx({
                instructionId: 2,
                subTxId: txIdWithdraw,
                universalTxId: universalTxIdWithdraw,
                amount: new anchor.BN(0),
                pushAccount,
                writableFlags: accountsToWritableFlagsOnly([]),
                ixData: withdrawIxData,
                gasFee: new anchor.BN(Number(gasFeeWithdraw)),
                rentFee: new anchor.BN(Number(rentFeeWithdraw)),
                sig: sigW,
                caller: admin.publicKey,
                destinationProgram: gatewayProgram.programId,
                rateLimitConfig: rateLimitConfigPda,
                tokenRateLimit: nativeSolTokenRateLimitPda,
            })
                .signers([admin])
                .rpc();

            // Verify events — retry getTransaction since local validator can lag
            let txDetails = null;
            for (let attempt = 0; attempt < 10; attempt++) {
                txDetails = await provider.connection.getTransaction(tx, {
                    commitment: "confirmed",
                    maxSupportedTransactionVersion: 0,
                });
                if (txDetails) break;
                await new Promise((r) => setTimeout(r, 500));
            }
            expect(txDetails, "getTransaction returned null after retries").to.exist;

            const eventCoder = new anchor.BorshEventCoder(gatewayProgram.idl);
            const events = (txDetails.meta?.logMessages ?? [])
                .filter((log) => log.includes("Program data:"))
                .map((log) => {
                    try { return eventCoder.decode(log.split("Program data: ")[1]); }
                    catch { return null; }
                })
                .filter((e) => e !== null);

            // UniversalTx: FundsAndPayload + from_cea
            // Note: Anchor TS IDL converts PascalCase event names to camelCase (UniversalTx → universalTx)
            const universalTxEvent = events.find((e) => e.name === "universalTx");
            expect(universalTxEvent, "UniversalTx event not found").to.exist;
            expect(universalTxEvent.data.txType.fundsAndPayload !== undefined, "txType should be FundsAndPayload").to.be.true;
            expect(universalTxEvent.data.fromCea, "from_cea should be true").to.be.true;
            expect(Buffer.from(universalTxEvent.data.payload).toString("hex")).to.equal(ceaPayload.toString("hex"));

            // UniversalTxFinalized MUST also be emitted for CEA→UEA path (dual-event)
            const finalizedEvent = events.find((e) => e.name === "universalTxFinalized");
            expect(finalizedEvent, "UniversalTxFinalized should be emitted for CEA→UEA path").to.exist;
            // target == gateway program id
            expect(finalizedEvent.data.target.toString(), "target should be gateway program id").to.equal(gatewayProgram.programId.toString());
            // token matches (SOL = default pubkey)
            expect(finalizedEvent.data.token.toString(), "token should match").to.equal(new anchor.web3.PublicKey(new Uint8Array(32)).toString());
            // amount matches withdraw_amount (ceaDrainAmountP2)
            expect(finalizedEvent.data.amount.toString(), "amount should be outer amount (0 for CEA→UEA)").to.equal("0");
            // sub_tx_id and universal_tx_id match inputs
            expect(Buffer.from(finalizedEvent.data.subTxId).toString("hex"), "subTxId should match").to.equal(Buffer.from(txIdWithdraw).toString("hex"));
            expect(Buffer.from(finalizedEvent.data.universalTxId).toString("hex"), "universalTxId should match").to.equal(Buffer.from(universalTxIdWithdraw).toString("hex"));
            // push_account matches
            expect(Buffer.from(finalizedEvent.data.pushAccount).toString("hex"), "pushAccount should match").to.equal(Buffer.from(pushAccount).toString("hex"));
            // payload is empty
            expect(Buffer.from(finalizedEvent.data.payload).toString("hex"), "payload should be outer ix_data").to.equal(withdrawIxData.toString("hex"));

            console.log("✅ FundsAndPayload + from_cea=true AND UniversalTxFinalized emitted for CEA→UEA withdrawal with payload");
        });
    });

    describe("CEA → UEA: SPL", () => {
        it("should allow gateway self-call to withdraw SPL from CEA", async () => {
            const pushAccount = generateSender();
            const cea = getCeaAuthorityPda(pushAccount);
            const ceaAta = await getCeaAta(pushAccount, mockUSDT.mint.publicKey);

            // Fund CEA ATA via execute (amount > 0, target = counterProgram)
            const txIdFund = generateTxId();
            const universalTxIdFund = generateUniversalTxId();
            const fundAmount = asTokenAmount(25);

            // Calculate rent_fee for target program (stake account needs 48 bytes)
            const rentFeeLamports = await calculateRentFeeForAccountSize(provider.connection, 48, BigInt(500_000));

            // Calculate gas_fee dynamically (includes CEA ATA rent if needed)
            const ceaAtaExistedBefore = await ceaAtaExists(provider.connection, ceaAta);
            const { gasFee: gasFeeLamports, rentFee: calculatedRentFee } = await calculateSplExecuteFees(provider.connection, ceaAta, rentFeeLamports);

            const rentFeeBn = new anchor.BN(rentFeeLamports.toString());
            const gasFeeBn = new anchor.BN(gasFeeLamports.toString());

            const counterIx = await counterProgram.methods
                .increment(new anchor.BN(0))
                .accounts({ counter: counterPda, authority: counterAuthority.publicKey })
                .instruction();
            const fundAccounts = instructionAccountsToGatewayMetas(counterIx);
            const sigFund = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(fundAmount.toString()),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxIdFund),
                    new Uint8Array(txIdFund),
                    counterProgram.programId,
                    new Uint8Array(pushAccount),
                    fundAccounts,
                    counterIx.data,
                    gasFeeLamports,
                    rentFeeLamports,
                    mockUSDT.mint.publicKey
                ),
            });

            const callerBalanceBeforeFund = await provider.connection.getBalance(admin.publicKey);
            const fundWritableFlagsSpl = accountsToWritableFlagsOnly(fundAccounts);
            await finalizeUniversalTx({
                instructionId: 2,
                subTxId: txIdFund,
                universalTxId: universalTxIdFund,
                amount: fundAmount,
                pushAccount,
                writableFlags: fundWritableFlagsSpl,
                ixData: Buffer.from(counterIx.data),
                gasFee: gasFeeBn,
                rentFee: rentFeeBn,
                sig: sigFund,
                caller: admin.publicKey,
                destinationProgram: counterProgram.programId,
                vaultAta: vaultUsdtAccount,
                ceaAta,
                mint: mockUSDT.mint.publicKey,
                tokenProgram: TOKEN_PROGRAM_ID,
                rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
            })
                .remainingAccounts(instructionAccountsToRemaining(counterIx))
                .signers([admin])
                .rpc();
            // Verify caller received relayer_fee reimbursement
            const callerBalanceAfterFund = await provider.connection.getBalance(admin.publicKey);
            const callerBalanceChangeFund = callerBalanceAfterFund - callerBalanceBeforeFund;
            // Option 1: Relayer pays gateway costs, gets relayer_fee reimbursement
            // Caller pays for:
            // 1. executed_sub_tx account rent (~890k)
            // 2. CEA ATA rent (if it doesn't exist - caller is payer per line 465 in execute.rs) (~2M)
            // 3. Transaction fees (varies by transaction size)
            // Caller receives: relayer_fee = gas_fee - rent_fee as reimbursement
            const actualRentForExecutedTx = await getExecutedTxRent(provider.connection);
            const actualRentForCeaAta = ceaAtaExistedBefore ? 0 : await getTokenAccountRent(provider.connection);
            const relayerFeeFund = Number(gasFeeLamports - rentFeeLamports);
            // Expected: -executed_sub_tx_rent - cea_ata_rent (if created) + relayer_fee - transaction_fees
            const expectedBalanceChangeFund = -actualRentForExecutedTx - actualRentForCeaAta + relayerFeeFund;
            expect(callerBalanceChangeFund).to.be.closeTo(expectedBalanceChangeFund, 100000); // Allow for transaction fees (SPL txs are larger)

            const ceaAtaBefore = await provider.connection.getTokenAccountBalance(ceaAta);
            expect(Number(ceaAtaBefore.value.amount)).to.be.greaterThan(0);

            // Withdraw all SPL from CEA via gateway self-call (target = gateway)
            const txIdWithdraw = generateTxId();
            const universalTxIdWithdraw = generateUniversalTxId();
            const withdrawDiscr = computeDiscriminator("global:send_universal_tx_to_uea");
            const withdrawArgs = Buffer.concat([
                mockUSDT.mint.publicKey.toBuffer(),
                (() => {
                    const b = Buffer.alloc(8);
                    b.writeBigUInt64LE(BigInt(ceaAtaBefore.value.amount)); // full token balance
                    return b;
                })(),
                Buffer.from([0, 0, 0, 0]), // payload = empty Vec<u8> (Borsh: 4-byte LE length = 0)
                admin.publicKey.toBuffer(), // revert_recipient
            ]);
            const withdrawIxData = Buffer.concat([withdrawDiscr, withdrawArgs]);

            // Calculate fees dynamically for withdraw operation (CEA ATA already exists)
            const { gasFee: gasFeeWithdrawSpl, rentFee: rentFeeWithdrawSpl } = await calculateSplExecuteFees(provider.connection, ceaAta);

            const sigW = await signTssMessage({
                instruction: TssInstruction.Execute,
                amount: BigInt(0),
                chainId: (await gatewayProgram.account.tssPda.fetch(tssPda)).chainId,
                additional: buildExecuteAdditionalData(
                    new Uint8Array(universalTxIdWithdraw),
                    new Uint8Array(txIdWithdraw),
                    gatewayProgram.programId,
                    new Uint8Array(pushAccount),
                    [],
                    withdrawIxData,
                    gasFeeWithdrawSpl,
                    rentFeeWithdrawSpl,
                    mockUSDT.mint.publicKey
                ),
            });

            const callerBalanceBeforeWithdrawSpl = await provider.connection.getBalance(admin.publicKey);
            const withdrawWritableFlagsSpl = accountsToWritableFlagsOnly([]);
            const txWithdrawSpl = await finalizeUniversalTx({
                instructionId: 2,
                subTxId: txIdWithdraw,
                universalTxId: universalTxIdWithdraw,
                amount: new anchor.BN(0),
                pushAccount,
                writableFlags: withdrawWritableFlagsSpl,
                ixData: withdrawIxData,
                gasFee: new anchor.BN(Number(gasFeeWithdrawSpl)),
                rentFee: new anchor.BN(Number(rentFeeWithdrawSpl)),
                sig: sigW,
                caller: admin.publicKey,
                destinationProgram: gatewayProgram.programId,
                vaultAta: vaultUsdtAccount,
                ceaAta,
                mint: mockUSDT.mint.publicKey,
                tokenProgram: TOKEN_PROGRAM_ID,
                rateLimitConfig: rateLimitConfigPda,
                tokenRateLimit: usdtTokenRateLimitPda,
                rent: anchor.web3.SYSVAR_RENT_PUBKEY,
                associatedTokenProgram: spl.ASSOCIATED_TOKEN_PROGRAM_ID,
            })
                .signers([admin])
                .rpc();
            // Verify dual-event: UniversalTx(from_cea=true) + UniversalTxFinalized
            let txWithdrawSplDetails = null;
            for (let attempt = 0; attempt < 10; attempt++) {
                txWithdrawSplDetails = await provider.connection.getTransaction(txWithdrawSpl, {
                    commitment: "confirmed",
                    maxSupportedTransactionVersion: 0,
                });
                if (txWithdrawSplDetails) break;
                await new Promise((r) => setTimeout(r, 500));
            }
            expect(txWithdrawSplDetails, "getTransaction returned null after retries").to.exist;

            const eventCoderSpl = new anchor.BorshEventCoder(gatewayProgram.idl);
            const eventsSpl = (txWithdrawSplDetails.meta?.logMessages ?? [])
                .filter((log) => log.includes("Program data:"))
                .map((log) => {
                    try { return eventCoderSpl.decode(log.split("Program data: ")[1]); }
                    catch { return null; }
                })
                .filter((e) => e !== null);

            const universalTxEventSpl = eventsSpl.find((e) => e.name === "universalTx");
            expect(universalTxEventSpl, "UniversalTx should be emitted").to.exist;
            expect(universalTxEventSpl.data.fromCea, "from_cea should be true").to.be.true;

            const finalizedEventSpl = eventsSpl.find((e) => e.name === "universalTxFinalized");
            expect(finalizedEventSpl, "UniversalTxFinalized should be emitted for CEA→UEA SPL path").to.exist;
            expect(finalizedEventSpl.data.target.toString()).to.equal(gatewayProgram.programId.toString());
            expect(finalizedEventSpl.data.token.toString()).to.equal(mockUSDT.mint.publicKey.toString());
            expect(finalizedEventSpl.data.amount.toString()).to.equal("0"); // outer amount = 0 for CEA→UEA
            expect(Buffer.from(finalizedEventSpl.data.subTxId).toString("hex")).to.equal(Buffer.from(txIdWithdraw).toString("hex"));
            expect(Buffer.from(finalizedEventSpl.data.universalTxId).toString("hex")).to.equal(Buffer.from(universalTxIdWithdraw).toString("hex"));
            expect(Buffer.from(finalizedEventSpl.data.pushAccount).toString("hex")).to.equal(Buffer.from(pushAccount).toString("hex"));
            expect(Buffer.from(finalizedEventSpl.data.payload).toString("hex")).to.equal(withdrawIxData.toString("hex"));
            // Verify caller received relayer_fee reimbursement (self-withdraw should also pay the caller)
            const callerBalanceAfterWithdrawSpl = await provider.connection.getBalance(admin.publicKey);
            const callerBalanceChangeWithdrawSpl = callerBalanceAfterWithdrawSpl - callerBalanceBeforeWithdrawSpl;
            // Option 1: Relayer pays gateway costs, gets relayer_fee reimbursement
            // Caller pays for:
            // 1. executed_sub_tx account rent (~890k)
            // 2. Transaction fees (varies by transaction size)
            // Caller receives: relayer_fee = gas_fee - rent_fee (reimbursement for gateway costs)
            // relayer_fee = (rent_fee + executed_sub_tx_rent + compute_buffer) - rent_fee = executed_sub_tx_rent + compute_buffer
            // Reuse actualRentForExecutedTx from above (same test scope)
            const relayerFeeWithdrawSpl = Number(gasFeeWithdrawSpl - rentFeeWithdrawSpl);
            // Expected: -executed_sub_tx_rent + relayer_fee - transaction_fees
            const expectedBalanceChangeWithdrawSpl = -actualRentForExecutedTx + relayerFeeWithdrawSpl;
            expect(callerBalanceChangeWithdrawSpl).to.be.closeTo(expectedBalanceChangeWithdrawSpl, 15000); // Allow for transaction fees

            const ceaAtaAfter = await provider.connection.getTokenAccountBalance(ceaAta);
            expect(Number(ceaAtaAfter.value.amount)).to.equal(0);
        });
    });
});
