use crate::errors::GatewayError;
use crate::instructions::tss::validate_message;
use crate::state::{
    Config, ExecutedTx, GatewayAccountMeta, RevertInstructions, TssPda, TxType, UniversalTx,
    UniversalTxExecuted, CEA_SEED, EXECUTED_TX_SEED, TSS_SEED, VAULT_SEED,
};
use crate::utils::validate_remaining_accounts;
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    hash::hash,
    instruction::{AccountMeta as SolanaAccountMeta, Instruction},
    program::invoke_signed,
    program_pack::Pack,
    system_instruction,
    sysvar::rent as rent_sysvar,
};
use anchor_spl::associated_token::spl_associated_token_account;
use anchor_spl::token::{spl_token, Mint, Token};
use spl_token::state::Account as SplAccount;

// =========================
//  UNIFIED EXECUTE_UNIVERSAL_TX
// =========================

#[derive(Accounts)]
#[instruction(tx_id: [u8; 32], universal_tx_id: [u8; 32], amount: u64, target_program: Pubkey, sender: [u8; 20], writable_flags: Vec<u8>, ix_data: Vec<u8>, gas_fee: u64, rent_fee: u64, signature: [u8; 64], recovery_id: u8, message_hash: [u8; 32], nonce: u64, token: Pubkey)]
pub struct ExecuteUniversalTx<'info> {
    #[account(mut)]
    pub caller: Signer<'info>,

    #[account(
        seeds = [b"config"],
        bump,
    )]
    pub config: Account<'info, Config>,

    /// Vault SOL PDA - holds all bridged SOL
    #[account(
        mut,
        seeds = [VAULT_SEED],
        bump = config.vault_bump,
    )]
    pub vault_sol: SystemAccount<'info>,

    /// CEA (Chain Executor Account) - persistent identity per Push Chain user
    /// This PDA represents the user on Solana and can sign for target programs
    /// Auto-created by Solana on first transfer, persists across transactions
    #[account(
        mut,
        seeds = [CEA_SEED, sender.as_ref()],
        bump,
    )]
    pub cea_authority: SystemAccount<'info>,

    #[account(
        mut,
        seeds = [TSS_SEED],
        bump,
    )]
    pub tss_pda: Account<'info, TssPda>,

    /// Executed transaction tracker (replay protection)
    /// Relayer pays for this account creation and gets reimbursed via gas_fee
    #[account(
        init,
        payer = caller,
        space = ExecutedTx::LEN,
        seeds = [EXECUTED_TX_SEED, tx_id.as_ref()],
        bump
    )]
    pub executed_tx: Account<'info, ExecutedTx>,

    /// CHECK: Target program (validated against signed message)
    pub destination_program: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,

    // --- Optional SPL accounts (required when token != Pubkey::default()) ---
    /// CHECK: Vault ATA for this mint
    #[account(mut)]
    pub vault_ata: Option<UncheckedAccount<'info>>,

    /// CHECK: CEA ATA (created if missing via manual CPI)
    #[account(mut)]
    pub cea_ata: Option<UncheckedAccount<'info>>,

    pub mint: Option<Account<'info, Mint>>,

    pub token_program: Option<Program<'info, Token>>,

    /// CHECK: Rent sysvar (validated at runtime)
    pub rent: Option<UncheckedAccount<'info>>,
}

pub fn execute_universal_tx(
    ctx: Context<ExecuteUniversalTx>,
    tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    amount: u64,
    target_program: Pubkey,
    sender: [u8; 20],
    writable_flags: Vec<u8>, // Bitpacked writable flags (1 bit per account, MSB first)
    ix_data: Vec<u8>,
    gas_fee: u64,
    rent_fee: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
    token: Pubkey,
) -> Result<()> {
    let config = &ctx.accounts.config;
    require!(!config.paused, GatewayError::Paused);

    let is_native = token == Pubkey::default();

    // Validate account count and flags length match
    let accounts_count = ctx.remaining_accounts.len();
    let expected_writable_flags_len = (accounts_count + 7) / 8; // Ceiling division
    require!(
        writable_flags.len() == expected_writable_flags_len,
        GatewayError::InvalidAccount
    );

    // 1. Reconstruct accounts from remaining_accounts by position
    // Position i in remaining_accounts maps to bit i in writable_flags
    let mut accounts = Vec::new();
    for (i, acc_info) in ctx.remaining_accounts.iter().enumerate() {
        // Decode writable flag from bitpacked flags
        let byte_idx = i / 8;
        let bit_idx = 7 - (i % 8); // MSB first
        let is_writable = (writable_flags[byte_idx] >> bit_idx) & 1 == 1;

        accounts.push(GatewayAccountMeta {
            pubkey: *acc_info.key,
            is_writable,
        });
    }

    // 2. Validate remaining_accounts (pubkeys, writable flags, and NO outer signers)
    validate_remaining_accounts(&accounts, ctx.remaining_accounts)?;

    let cea_key = ctx.accounts.cea_authority.key();

    // 3. Build serialized accounts buffer (with length prefix) for TSS validation
    // Format: [u32 BE: count] + [32 bytes: pubkey, 1 byte: is_writable] * count
    // This MUST match the format used in buildExecuteAdditionalData (off-chain)
    let mut accounts_buf = Vec::new();
    let accounts_count = accounts_count as u32;
    accounts_buf.extend_from_slice(&accounts_count.to_be_bytes()); // u32 BE length prefix
    for account in &accounts {
        accounts_buf.extend_from_slice(&account.pubkey.to_bytes()); // Pubkey (32 bytes)
        accounts_buf.push(if account.is_writable { 1 } else { 0 }); // is_writable (1 byte)
    }

    // 3. Build serialized ix_data buffer (with length prefix)
    let mut ix_data_buf = Vec::new();
    let ix_data_length = ix_data.len() as u32;
    ix_data_buf.extend_from_slice(&ix_data_length.to_be_bytes()); // u32 BE length prefix
    ix_data_buf.extend_from_slice(&ix_data); // Raw bytes

    // 4. Validate TSS signature and message hash using unified validate_message
    // Format: PREFIX + instruction_id + chain_id + nonce + amount + [universal_tx_id, tx_id, target_program, sender, accounts_buf, ix_data_buf, gas_fee, rent_fee, token]
    let mut gas_fee_buf = [0u8; 8];
    gas_fee_buf.copy_from_slice(&gas_fee.to_be_bytes());
    let mut rent_fee_buf = [0u8; 8];
    rent_fee_buf.copy_from_slice(&rent_fee.to_be_bytes());
    let token_bytes = token.to_bytes();

    let additional: [&[u8]; 9] = [
        &universal_tx_id[..],
        &tx_id[..],
        &target_program.to_bytes(),
        &sender[..],
        &accounts_buf,
        &ix_data_buf,
        &gas_fee_buf,
        &rent_fee_buf,
        &token_bytes,
    ];
    validate_message(
        &mut ctx.accounts.tss_pda,
        5, // unified instruction_id for execute
        nonce,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    // 5. Verify target program matches and is executable
    require!(
        ctx.accounts.destination_program.key() == target_program,
        GatewayError::TargetProgramMismatch
    );
    require!(
        ctx.accounts.destination_program.executable,
        GatewayError::InvalidProgram
    );

    // Note: Account validation is done in step 2 (validate_remaining_accounts)
    // TSS signature enforces: account count, pubkeys, and is_writable flags
    // Outer signer check is done in validate_remaining_accounts (rejects any is_signer == true)

    // 6. Validate rent_fee <= gas_fee (rent_fee is a subset of gas_fee)
    require!(rent_fee <= gas_fee, GatewayError::InvalidAmount);

    // 7. Calculate vault seeds once (used for all vault transfers)
    let vault_bump = config.vault_bump;
    let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[vault_bump]];

    // 8. Transfer rent_fee to CEA (for target contract rent)
    if rent_fee > 0 {
        let rent_transfer_ix = system_instruction::transfer(
            &ctx.accounts.vault_sol.key(),
            &ctx.accounts.cea_authority.key(),
            rent_fee,
        );

        invoke_signed(
            &rent_transfer_ix,
            &[
                ctx.accounts.vault_sol.to_account_info(),
                ctx.accounts.cea_authority.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[vault_seeds],
        )?;
    }

    // 9. Transfer amount to CEA
    if is_native {
        // SOL transfer
        if amount > 0 {
            let amount_transfer_ix = system_instruction::transfer(
                &ctx.accounts.vault_sol.key(),
                &ctx.accounts.cea_authority.key(),
                amount,
            );

            invoke_signed(
                &amount_transfer_ix,
                &[
                    ctx.accounts.vault_sol.to_account_info(),
                    ctx.accounts.cea_authority.to_account_info(),
                    ctx.accounts.system_program.to_account_info(),
                ],
                &[vault_seeds],
            )?;
        }
    } else {
        // SPL token transfer: validate and unwrap optional accounts
        let vault_ata = ctx
            .accounts
            .vault_ata
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let cea_ata = ctx
            .accounts
            .cea_ata
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let token_mint = ctx
            .accounts
            .mint
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let token_program = ctx
            .accounts
            .token_program
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let rent_account = ctx
            .accounts
            .rent
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;

        // Validate token parameter matches mint account
        require!(token == token_mint.key(), GatewayError::InvalidMint);

        // Validate program IDs
        require!(
            token_program.key() == spl_token::ID,
            GatewayError::InvalidAccount
        );
        require!(
            rent_account.key() == rent_sysvar::ID,
            GatewayError::InvalidAccount
        );

        // SECURITY: Validate vault_ata is owned by vault and matches mint
        let vault_ata_data = vault_ata.try_borrow_data()?.to_vec();
        let parsed_vault_ata = SplAccount::unpack(&vault_ata_data)
            .map_err(|_| error!(GatewayError::InvalidAccount))?;
        require!(
            parsed_vault_ata.owner == ctx.accounts.vault_sol.key(),
            GatewayError::InvalidOwner
        );
        require!(
            parsed_vault_ata.mint == token_mint.key(),
            GatewayError::InvalidMint
        );

        // Derive expected CEA ATA and validate
        let expected_cea_ata = spl_associated_token_account::get_associated_token_address(
            &ctx.accounts.cea_authority.key(),
            &token_mint.key(),
        );
        require!(
            cea_ata.key() == expected_cea_ata,
            GatewayError::InvalidAccount
        );

        // Create CEA ATA if it doesn't exist
        let cea_ata_info = cea_ata.to_account_info();
        if cea_ata_info.data_is_empty() {
            // CPI create_associated_token_account (caller pays)
            // Account order: payer, associated_token_account, owner, mint, system_program, token_program, rent
            let create_ata_ix =
                spl_associated_token_account::instruction::create_associated_token_account(
                    &ctx.accounts.caller.key(),
                    &ctx.accounts.cea_authority.key(),
                    &token_mint.key(),
                    &spl_token::ID,
                );
            invoke_signed(
                &create_ata_ix,
                &[
                    ctx.accounts.caller.to_account_info(),
                    cea_ata.to_account_info(),
                    ctx.accounts.cea_authority.to_account_info(),
                    token_mint.to_account_info(),
                    ctx.accounts.system_program.to_account_info(),
                    token_program.to_account_info(),
                    rent_account.to_account_info(),
                ],
                &[],
            )?;
        }
        // Validate existing CEA ATA: mint + owner
        let cea_ata_data = cea_ata.try_borrow_data()?.to_vec();
        let parsed_cea_ata = SplAccount::unpack(&cea_ata_data)
            .map_err(|_| error!(GatewayError::InvalidAccount))?;
        require!(
            parsed_cea_ata.mint == token_mint.key(),
            GatewayError::InvalidMint
        );
        require!(
            parsed_cea_ata.owner == ctx.accounts.cea_authority.key(),
            GatewayError::InvalidOwner
        );

        // Transfer tokens from vault_ata → cea_ata
        if amount > 0 {
            let transfer_ix = spl_token::instruction::transfer(
                &spl_token::ID,
                &vault_ata.key(),
                &cea_ata.key(),
                &ctx.accounts.vault_sol.key(),
                &[],
                amount,
            )?;

            invoke_signed(
                &transfer_ix,
                &[
                    vault_ata.to_account_info(),
                    cea_ata.to_account_info(),
                    ctx.accounts.vault_sol.to_account_info(),
                ],
                &[vault_seeds],
            )?;
        }
    }

    // 10. Transfer relayer_fee (gas_fee - rent_fee) to caller BEFORE self-call check
    // This ensures the caller gets paid even for self-withdraw operations.
    // Relayer pays: executed_tx rent (~890k) + compute fees
    // Relayer receives: relayer_fee = gas_fee - rent_fee (reimbursement for gateway costs)
    // Vault total payout: rent_fee (to CEA) + relayer_fee (to caller) = gas_fee (matches user burn)
    let relayer_fee = gas_fee
        .checked_sub(rent_fee)
        .ok_or(GatewayError::InvalidAmount)?;

    if relayer_fee > 0 {
        let fee_transfer_ix = system_instruction::transfer(
            &ctx.accounts.vault_sol.key(),
            &ctx.accounts.caller.key(),
            relayer_fee,
        );

        invoke_signed(
            &fee_transfer_ix,
            &[
                ctx.accounts.vault_sol.to_account_info(),
                ctx.accounts.caller.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[vault_seeds],
        )?;
    }

    // 11. Build CPI instruction for target program
    // cea_authority must appear as signer inside CPI
    let cpi_metas: Vec<SolanaAccountMeta> = accounts
        .iter()
        .map(|a| {
            let is_signer = a.pubkey == cea_key;
            if a.is_writable {
                SolanaAccountMeta::new(a.pubkey, is_signer)
            } else {
                SolanaAccountMeta::new_readonly(a.pubkey, is_signer)
            }
        })
        .collect();

    // 12. Check if target is gateway itself (for CEA withdrawals)
    let cea_bump = ctx.bumps.cea_authority;
    let cea_seeds: &[&[u8]] = &[CEA_SEED, sender.as_ref(), &[cea_bump]];

    if target_program == *ctx.program_id {
        // Gateway self-call: interpret ix_data as a normal gateway instruction
        // and handle CEA withdrawal in-place (no CPI).
        return handle_cea_withdrawal(
            &ctx,
            tx_id,
            universal_tx_id,
            sender,
            &ix_data,
            cea_seeds,
            token,
        );
    }

    let cpi_ix = Instruction {
        program_id: target_program,
        accounts: cpi_metas,
        data: ix_data.clone(),
    };

    // 13. Invoke target program with cea_authority as signer
    // Note: Solana runtime automatically includes the program account (from cpi_ix.program_id) in the transaction
    invoke_signed(&cpi_ix, ctx.remaining_accounts, &[cea_seeds])?;

    // Note: CEA balances persist (no auto-drain) - matches EVM CEA behavior
    // Users can withdraw via withdrawFundsFromCea() when needed

    // 14. Emit execution event
    emit!(UniversalTxExecuted {
        tx_id,
        universal_tx_id,
        sender,
        target: target_program,
        token,
        amount,
        payload: ix_data,
    });

    Ok(())
}

// ============================================
//    CEA WITHDRAWAL HANDLER (UNIFIED)
// ============================================

/// Args for CEA withdrawal when target_program == gateway itself.
/// Layout: [8-byte discriminator][borsh(WithdrawFromCeaArgs)].
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct WithdrawFromCeaArgs {
    pub token: Pubkey, // Pubkey::default() for SOL; mint for SPL
    pub amount: u64,   // 0 => withdraw full balance
}

/// Handle withdrawal from CEA when target_program == gateway itself
fn handle_cea_withdrawal(
    ctx: &Context<ExecuteUniversalTx>,
    tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    sender: [u8; 20],
    ix_data: &[u8],
    cea_seeds: &[&[u8]],
    token: Pubkey,
) -> Result<()> {
    // ix_data must be at least 8 bytes for the Anchor-style discriminator
    require!(ix_data.len() >= 8, GatewayError::InvalidInput);

    // First 8 bytes = discriminator for "global:withdraw_from_cea"
    let discr = &ix_data[..8];
    let expected = hash(b"global:withdraw_from_cea").to_bytes();
    require!(discr == &expected[..8], GatewayError::InvalidInput);

    // Remaining bytes are Borsh-encoded args
    let args = WithdrawFromCeaArgs::try_from_slice(&ix_data[8..])
        .map_err(|_| error!(GatewayError::InvalidInput))?;
    require!(args.token == token, GatewayError::InvalidMint);
    if args.token == Pubkey::default() {
        // Handle SOL withdrawal
        let cea_balance = ctx.accounts.cea_authority.lamports();
        let withdraw_amount = if args.amount == 0 {
            cea_balance
        } else {
            require!(
                args.amount <= cea_balance,
                GatewayError::InsufficientBalance
            );
            args.amount
        };

        if withdraw_amount > 0 {
            // Transfer from CEA to vault
            let transfer_ix = system_instruction::transfer(
                &ctx.accounts.cea_authority.key(),
                &ctx.accounts.vault_sol.key(),
                withdraw_amount,
            );

            invoke_signed(
                &transfer_ix,
                &[
                    ctx.accounts.cea_authority.to_account_info(),
                    ctx.accounts.vault_sol.to_account_info(),
                    ctx.accounts.system_program.to_account_info(),
                ],
                &[cea_seeds],
            )?;

            // Emit FUNDS event to unlock funds on Push Chain
            emit!(UniversalTx {
                sender: ctx.accounts.cea_authority.key(),
                recipient: sender,
                token: Pubkey::default(),
                amount: withdraw_amount,
                payload: vec![],
                revert_instruction: RevertInstructions {
                    fund_recipient: ctx.accounts.cea_authority.key(),
                    revert_msg: vec![],
                },
                tx_type: TxType::Funds,
                signature_data: vec![],
            });
        }
    } else {
        // Handle SPL withdrawal
        let vault_ata = ctx
            .accounts
            .vault_ata
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let cea_ata = ctx
            .accounts
            .cea_ata
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let token_mint = ctx
            .accounts
            .mint
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let _token_program = ctx
            .accounts
            .token_program
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;

        require!(args.token == token_mint.key(), GatewayError::InvalidMint);

        // Check CEA ATA balance
        let cea_ata_data = cea_ata.try_borrow_data()?.to_vec();
        let parsed_cea_ata =
            SplAccount::unpack(&cea_ata_data).map_err(|_| error!(GatewayError::InvalidAccount))?;
        let cea_balance = parsed_cea_ata.amount;

        let withdraw_amount = if args.amount == 0 {
            cea_balance
        } else {
            require!(
                args.amount <= cea_balance,
                GatewayError::InsufficientBalance
            );
            args.amount
        };

        if withdraw_amount > 0 {
            // Transfer from CEA ATA to vault ATA
            let transfer_ix = spl_token::instruction::transfer(
                &spl_token::ID,
                &cea_ata.key(),
                &vault_ata.key(),
                &ctx.accounts.cea_authority.key(),
                &[],
                withdraw_amount,
            )?;

            invoke_signed(
                &transfer_ix,
                &[
                    cea_ata.to_account_info(),
                    vault_ata.to_account_info(),
                    ctx.accounts.cea_authority.to_account_info(),
                ],
                &[cea_seeds],
            )?;

            // Emit FUNDS event to unlock funds on Push Chain
            emit!(UniversalTx {
                sender: ctx.accounts.cea_authority.key(),
                recipient: sender,
                token: token_mint.key(),
                amount: withdraw_amount,
                payload: vec![],
                revert_instruction: RevertInstructions {
                    fund_recipient: ctx.accounts.cea_authority.key(),
                    revert_msg: vec![],
                },
                tx_type: TxType::Funds,
                signature_data: vec![],
            });
        }
    }

    // Emit execution event
    emit!(UniversalTxExecuted {
        tx_id,
        universal_tx_id,
        sender,
        target: *ctx.program_id,
        token,
        amount: 0, // Withdrawal doesn't have an amount in execute context
        payload: vec![],
    });

    Ok(())
}
