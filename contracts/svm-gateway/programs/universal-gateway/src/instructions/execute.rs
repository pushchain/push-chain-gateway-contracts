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
//  UNIFIED WITHDRAW_AND_EXECUTE
// =========================

#[derive(Accounts)]
#[instruction(instruction_id: u8, tx_id: [u8; 32], universal_tx_id: [u8; 32], amount: u64, sender: [u8; 20], writable_flags: Vec<u8>, ix_data: Vec<u8>, gas_fee: u64, rent_fee: u64, signature: [u8; 64], recovery_id: u8, message_hash: [u8; 32], nonce: u64)]
pub struct WithdrawAndExecute<'info> {
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

    pub system_program: Program<'info, System>,
    /// CHECK: Target program for execute mode
    /// Pass system program id for withdraw, it's ignored
    pub destination_program: UncheckedAccount<'info>,

    // --- Optional SPL accounts

    /// CHECK: Recipient wallet for withdraw mode
    #[account(mut)]
    pub recipient: Option<UncheckedAccount<'info>>,

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

    /// CHECK: Associated token program (validated at runtime)
    pub associated_token_program: Option<UncheckedAccount<'info>>,

    // --- Optional recipient ATA (required for SPL withdraw mode) ---
    /// CHECK: Recipient ATA for SPL withdraw (CEA ATA → recipient ATA)
    #[account(mut)]
    pub recipient_ata: Option<UncheckedAccount<'info>>,
}

pub fn withdraw_and_execute(
    ctx: Context<WithdrawAndExecute>,
    instruction_id: u8,
    tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    amount: u64,
    sender: [u8; 20],
    writable_flags: Vec<u8>,
    ix_data: Vec<u8>,
    gas_fee: u64,
    rent_fee: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    let config = &ctx.accounts.config;
    require!(!config.paused, GatewayError::Paused);

    // Phase 1: Use validation helpers
    let is_withdraw = validate_instruction_id(instruction_id)?;
    let (token, is_native) = derive_token_and_mode(&ctx)?;
    validate_account_presence(&ctx, is_native)?;
    let target = validate_mode_accounts_and_derive_target(&ctx, is_withdraw)?;
    validate_mode_specific_params(
        &ctx,
        is_withdraw,
        is_native,
        amount,
        sender,
        &writable_flags,
        &ix_data,
        rent_fee,
        gas_fee,
    )?;

    // Phase 2: Build mode-specific TSS hash and validate
    // Store accounts for execute mode (avoids duplicate reconstruction)
    let execute_accounts = if is_withdraw {
        build_and_validate_tss_withdraw(
            &mut ctx.accounts.tss_pda,
            universal_tx_id,
            tx_id,
            sender,
            token,
            target,
            gas_fee,
            amount,
            &message_hash,
            &signature,
            recovery_id,
            nonce,
        )?;
        None
    } else {
        let accounts = build_and_validate_tss_execute(
            &mut ctx.accounts.tss_pda,
            ctx.remaining_accounts,
            universal_tx_id,
            tx_id,
            sender,
            target,
            token,
            &writable_flags,
            &ix_data,
            gas_fee,
            rent_fee,
            amount,
            &message_hash,
            &signature,
            recovery_id,
            nonce,
        )?;

        // Verify target program is executable (execute mode only)
        require!(
            ctx.accounts.destination_program.executable,
            GatewayError::InvalidProgram
        );

        Some(accounts)
    };

    // Calculate vault seeds once (used for all vault transfers)
    let vault_bump = config.vault_bump;
    let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[vault_bump]];

    // Transfer rent_fee to CEA (no-op for withdraw since rent_fee=0)
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

    // Transfer amount vault → CEA (SOL or SPL)
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
        // Phase 3: SPL token transfer using helper
        process_spl_vault_to_cea_transfer(&ctx, token, amount, &[vault_seeds])?;
    }

    // Transfer relayer_fee (gas_fee - rent_fee) to caller
    let relayer_fee = gas_fee
        .checked_sub(rent_fee)
        .ok_or(GatewayError::InvalidAmount)?;

    crate::utils::transfer_gas_fee_to_caller(
        &ctx.accounts.vault_sol.to_account_info(),
        &ctx.accounts.caller.to_account_info(),
        &ctx.accounts.system_program.to_account_info(),
        relayer_fee,
        config.vault_bump,
    )?;

    // Branch: withdraw vs execute
    let cea_bump = ctx.bumps.cea_authority;
    let cea_seeds: &[&[u8]] = &[CEA_SEED, sender.as_ref(), &[cea_bump]];

    if is_withdraw {
        // Withdraw: CEA → target (SOL) or CEA ATA → recipient ATA (SPL)
        internal_withdraw(&ctx, amount, token, cea_seeds)?;
    } else {
        // Execute: use accounts from TSS validation (Phase 2: no duplicate reconstruction)
        let cea_key = ctx.accounts.cea_authority.key();
        let accounts = execute_accounts.unwrap();

        // Check if target is gateway itself (for CEA withdrawals)
        if target == *ctx.program_id {
            return handle_cea_withdrawal(
                &ctx,
                tx_id,
                universal_tx_id,
                sender,
                &ix_data,
                cea_seeds,
            );
        }

        // Build CPI instruction for target program
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

        let cpi_ix = Instruction {
            program_id: target,
            accounts: cpi_metas,
            data: ix_data.clone(),
        };

        invoke_signed(&cpi_ix, ctx.remaining_accounts, &[cea_seeds])?;
    }

    // Emit execution event
    emit!(UniversalTxExecuted {
        tx_id,
        universal_tx_id,
        sender,
        target,
        token,
        amount,
        payload: ix_data,
    });

    Ok(())
}

// ============================================
//    INTERNAL WITHDRAW HELPER
// ============================================

/// Transfer funds from CEA to recipient (withdraw mode)
/// SOL: system_instruction::transfer CEA → target
/// SPL: spl_token::transfer CEA ATA → recipient ATA
fn internal_withdraw(
    ctx: &Context<WithdrawAndExecute>,
    amount: u64,
    token: Pubkey,
    cea_seeds: &[&[u8]],
) -> Result<()> {
    let recipient = ctx.accounts.recipient.as_ref()
        .ok_or(error!(GatewayError::InvalidAccount))?;
    let target = recipient.key();
    let is_native = token == Pubkey::default();

    // If recipient == CEA, vault→CEA already happened (lines 214-237)
    // No need for second transfer CEA→CEA (user just wants funds in their CEA)
    if target == ctx.accounts.cea_authority.key() {
        return Ok(());
    }

    if is_native {
        // SOL: CEA → target
        if amount > 0 {
            let transfer_ix = system_instruction::transfer(
                &ctx.accounts.cea_authority.key(),
                &target,
                amount,
            );

            invoke_signed(
                &transfer_ix,
                &[
                    ctx.accounts.cea_authority.to_account_info(),
                    recipient.to_account_info(),
                    ctx.accounts.system_program.to_account_info(),
                ],
                &[cea_seeds],
            )?;
        }
    } else {
        // SPL: CEA ATA → recipient ATA
        let cea_ata = ctx
            .accounts
            .cea_ata
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let recipient_ata = ctx
            .accounts
            .recipient_ata
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let token_mint = ctx
            .accounts
            .mint
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;

        // Validate recipient_ata: derivation matches (target, mint), owner, mint
        let expected_recipient_ata = spl_associated_token_account::get_associated_token_address(
            &target,
            &token_mint.key(),
        );
        require!(
            recipient_ata.key() == expected_recipient_ata,
            GatewayError::InvalidAccount
        );

        // Validate recipient_ata data: owner + mint
        let recipient_ata_data = recipient_ata.try_borrow_data()?.to_vec();
        let parsed_recipient_ata = SplAccount::unpack(&recipient_ata_data)
            .map_err(|_| error!(GatewayError::InvalidAccount))?;
        require!(
            parsed_recipient_ata.owner == target,
            GatewayError::InvalidOwner
        );
        require!(
            parsed_recipient_ata.mint == token_mint.key(),
            GatewayError::InvalidMint
        );

        // Transfer from CEA ATA → recipient ATA
        if amount > 0 {
            let transfer_ix = spl_token::instruction::transfer(
                &spl_token::ID,
                &cea_ata.key(),
                &recipient_ata.key(),
                &ctx.accounts.cea_authority.key(),
                &[],
                amount,
            )?;

            invoke_signed(
                &transfer_ix,
                &[
                    cea_ata.to_account_info(),
                    recipient_ata.to_account_info(),
                    ctx.accounts.cea_authority.to_account_info(),
                ],
                &[cea_seeds],
            )?;
        }
    }

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
    ctx: &Context<WithdrawAndExecute>,
    tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    sender: [u8; 20],
    ix_data: &[u8],
    cea_seeds: &[&[u8]],
) -> Result<()> {
    // Derive token from mint account (must match parent function's derivation)
    let token = if ctx.accounts.mint.is_none() {
        Pubkey::default()
    } else {
        ctx.accounts.mint.as_ref().unwrap().key()
    };

    // ix_data must be at least 8 bytes for the Anchor-style discriminator
    require!(ix_data.len() >= 8, GatewayError::InvalidInput);

    // First 8 bytes = discriminator for "global:withdraw_from_cea"
    let discr = &ix_data[..8];
    let expected = hash(b"global:withdraw_from_cea").to_bytes();
    require!(discr == &expected[..8], GatewayError::InvalidInput);

    // Remaining bytes are Borsh-encoded args
    let args = WithdrawFromCeaArgs::try_from_slice(&ix_data[8..])
        .map_err(|_| error!(GatewayError::InvalidInput))?;

    // Validate args.token matches derived token
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
        // Handle SPL withdrawal (not using helper - different subset of accounts)
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
        let mint = ctx
            .accounts
            .mint
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;

        require!(args.token == mint.key(), GatewayError::InvalidMint);

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
                token: mint.key(),
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

// ============================================
//    VALIDATION HELPERS (PHASE 1)
// ============================================

/// Validate instruction_id is 1 (withdraw) or 2 (execute)
fn validate_instruction_id(instruction_id: u8) -> Result<bool> {
    require!(
        instruction_id == 1 || instruction_id == 2,
        GatewayError::InvalidInstruction
    );
    Ok(instruction_id == 1)
}

/// Derive token from mint account and determine if native SOL
fn derive_token_and_mode(ctx: &Context<WithdrawAndExecute>) -> Result<(Pubkey, bool)> {
    let is_native = ctx.accounts.mint.is_none();
    let token = if is_native {
        Pubkey::default()
    } else {
        ctx.accounts.mint.as_ref().unwrap().key()
    };
    Ok((token, is_native))
}

/// Enforce SPL/SOL account presence based on token type
fn validate_account_presence(ctx: &Context<WithdrawAndExecute>, is_native: bool) -> Result<()> {
    if is_native {
        require!(
            ctx.accounts.vault_ata.is_none() &&
            ctx.accounts.cea_ata.is_none() &&
            ctx.accounts.mint.is_none() &&
            ctx.accounts.token_program.is_none() &&
            ctx.accounts.rent.is_none() &&
            ctx.accounts.associated_token_program.is_none(),
            GatewayError::InvalidAccount
        );
    } else {
        require!(
            ctx.accounts.vault_ata.is_some() &&
            ctx.accounts.cea_ata.is_some() &&
            ctx.accounts.mint.is_some() &&
            ctx.accounts.token_program.is_some() &&
            ctx.accounts.rent.is_some() &&
            ctx.accounts.associated_token_program.is_some(),
            GatewayError::InvalidAccount
        );
    }
    Ok(())
}

/// Validate mode-specific accounts and derive target
fn validate_mode_accounts_and_derive_target(
    ctx: &Context<WithdrawAndExecute>,
    is_withdraw: bool,
) -> Result<Pubkey> {
    if is_withdraw {
        require!(ctx.accounts.recipient.is_some(), GatewayError::InvalidAccount);
        Ok(ctx.accounts.recipient.as_ref().unwrap().key())
    } else {
        require!(ctx.accounts.recipient.is_none(), GatewayError::InvalidAccount);
        Ok(ctx.accounts.destination_program.key())
    }
}

/// Validate mode-specific parameters
fn validate_mode_specific_params(
    ctx: &Context<WithdrawAndExecute>,
    is_withdraw: bool,
    is_native: bool,
    amount: u64,
    sender: [u8; 20],
    writable_flags: &[u8],
    ix_data: &[u8],
    rent_fee: u64,
    gas_fee: u64,
) -> Result<()> {
    if is_withdraw {
        // Withdraw mode validations
        require!(amount > 0, GatewayError::InvalidAmount);
        require!(sender != [0u8; 20], GatewayError::InvalidInput);
        require!(writable_flags.is_empty(), GatewayError::InvalidInput);
        require!(ix_data.is_empty(), GatewayError::InvalidInput);
        require!(rent_fee == 0, GatewayError::InvalidInput);

        // SPL withdraw requires recipient_ata
        if !is_native {
            require!(
                ctx.accounts.recipient_ata.is_some(),
                GatewayError::InvalidAccount
            );
        }

        // Execute mode fields on remaining_accounts must be empty
        require!(
            ctx.remaining_accounts.is_empty(),
            GatewayError::InvalidInput
        );
    } else {
        // Execute mode validations
        require!(
            ctx.accounts.recipient_ata.is_none(),
            GatewayError::InvalidInput
        );

        // Validate account count and flags length match
        let accounts_count = ctx.remaining_accounts.len();
        let expected_writable_flags_len = (accounts_count + 7) / 8;
        require!(
            writable_flags.len() == expected_writable_flags_len,
            GatewayError::InvalidAccount
        );

        // Validate rent_fee <= gas_fee
        require!(rent_fee <= gas_fee, GatewayError::InvalidAmount);
    }
    Ok(())
}

// ============================================
//    TSS VALIDATION HELPERS (PHASE 2)
// ============================================

/// Reconstruct GatewayAccountMeta from remaining_accounts and writable_flags
fn reconstruct_accounts_from_flags<'info>(
    remaining_accounts: &[AccountInfo<'info>],
    writable_flags: &[u8],
) -> Vec<GatewayAccountMeta> {
    let mut accounts = Vec::new();
    for (i, acc_info) in remaining_accounts.iter().enumerate() {
        let byte_idx = i / 8;
        let bit_idx = 7 - (i % 8);
        let is_writable = (writable_flags[byte_idx] >> bit_idx) & 1 == 1;
        accounts.push(GatewayAccountMeta {
            pubkey: *acc_info.key,
            is_writable,
        });
    }
    accounts
}

/// Build and validate TSS signature for withdraw mode (instruction_id=1)
///
/// TSS Message Format (common fields first):
/// 1. tx_id (32 bytes)
/// 2. universal_tx_id (32 bytes)
/// 3. sender (20 bytes)
/// 4. token (32 bytes)
/// 5. gas_fee (u64 BE)
/// 6. target (32 bytes) - withdraw specific
fn build_and_validate_tss_withdraw(
    tss_pda: &mut Account<TssPda>,
    universal_tx_id: [u8; 32],
    tx_id: [u8; 32],
    sender: [u8; 20],
    token: Pubkey,
    target: Pubkey,
    gas_fee: u64,
    amount: u64,
    message_hash: &[u8; 32],
    signature: &[u8; 64],
    recovery_id: u8,
    nonce: u64,
) -> Result<()> {
    let token_bytes = token.to_bytes();
    let target_bytes = target.to_bytes();
    let mut gas_fee_buf = [0u8; 8];
    gas_fee_buf.copy_from_slice(&gas_fee.to_be_bytes());

    // New ordering: common fields first, then mode-specific
    let additional: [&[u8]; 6] = [
        &tx_id[..],            // 0 - common (matches function param order)
        &universal_tx_id[..],  // 1 - common
        &sender[..],           // 2 - common
        &token_bytes[..],      // 3 - common
        &gas_fee_buf,          // 4 - common
        &target_bytes[..],     // 5 - withdraw specific (recipient)
    ];

    validate_message(
        tss_pda,
        1, // instruction_id for withdraw
        nonce,
        Some(amount),
        &additional,
        message_hash,
        signature,
        recovery_id,
    )
}

/// Build and validate TSS signature for execute mode (instruction_id=2)
///
/// TSS Message Format (common fields first):
/// 1. tx_id (32 bytes)
/// 2. universal_tx_id (32 bytes)
/// 3. sender (20 bytes)
/// 4. token (32 bytes)
/// 5. gas_fee (u64 BE)
/// 6. target_program (32 bytes) - execute specific
/// 7. accounts_buf (variable) - execute specific
/// 8. ix_data_buf (variable) - execute specific
/// 9. rent_fee (u64 BE) - execute specific
fn build_and_validate_tss_execute<'info>(
    tss_pda: &mut Account<TssPda>,
    remaining_accounts: &[AccountInfo<'info>],
    universal_tx_id: [u8; 32],
    tx_id: [u8; 32],
    sender: [u8; 20],
    target: Pubkey,
    token: Pubkey,
    writable_flags: &[u8],
    ix_data: &[u8],
    gas_fee: u64,
    rent_fee: u64,
    amount: u64,
    message_hash: &[u8; 32],
    signature: &[u8; 64],
    recovery_id: u8,
    nonce: u64,
) -> Result<Vec<GatewayAccountMeta>> {
    // 1. Reconstruct accounts from remaining_accounts
    let accounts = reconstruct_accounts_from_flags(remaining_accounts, writable_flags);

    // 2. Validate remaining_accounts
    validate_remaining_accounts(&accounts, remaining_accounts)?;

    // 3. Build serialized accounts buffer
    let mut accounts_buf = Vec::new();
    let accounts_count = remaining_accounts.len() as u32;
    accounts_buf.extend_from_slice(&accounts_count.to_be_bytes());
    for account in &accounts {
        accounts_buf.extend_from_slice(&account.pubkey.to_bytes());
        accounts_buf.push(if account.is_writable { 1 } else { 0 });
    }

    // 4. Build serialized ix_data buffer
    let mut ix_data_buf = Vec::new();
    let ix_data_length = ix_data.len() as u32;
    ix_data_buf.extend_from_slice(&ix_data_length.to_be_bytes());
    ix_data_buf.extend_from_slice(ix_data);

    let token_bytes = token.to_bytes();
    let mut gas_fee_buf = [0u8; 8];
    gas_fee_buf.copy_from_slice(&gas_fee.to_be_bytes());
    let mut rent_fee_buf = [0u8; 8];
    rent_fee_buf.copy_from_slice(&rent_fee.to_be_bytes());

    // New ordering: common fields first, then mode-specific
    // This matches withdraw format for common fields
    let additional: [&[u8]; 9] = [
        &tx_id[..],            // 0 - common (matches function param order)
        &universal_tx_id[..],  // 1 - common
        &sender[..],           // 2 - common
        &token_bytes,          // 3 - common
        &gas_fee_buf,          // 4 - common
        &target.to_bytes(),    // 5 - execute specific (target program)
        &accounts_buf,         // 6 - execute specific
        &ix_data_buf,          // 7 - execute specific
        &rent_fee_buf,         // 8 - execute specific
    ];

    validate_message(
        tss_pda,
        2, // instruction_id for execute
        nonce,
        Some(amount),
        &additional,
        message_hash,
        signature,
        recovery_id,
    )?;

    Ok(accounts)
}

// ============================================
//    SPL ACCOUNT HELPERS (PHASE 3)
// ============================================

/// Validate and process SPL token transfer from vault to CEA
fn process_spl_vault_to_cea_transfer<'info>(
    ctx: &Context<WithdrawAndExecute<'info>>,
    token: Pubkey,
    amount: u64,
    vault_seeds: &[&[&[u8]]],
) -> Result<()> {
    // Unpack and validate SPL accounts
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
    let mint = ctx
        .accounts
        .mint
        .as_ref()
        .ok_or(error!(GatewayError::InvalidAccount))?;
    let token_program = ctx
        .accounts
        .token_program
        .as_ref()
        .ok_or(error!(GatewayError::InvalidAccount))?;
    let rent = ctx
        .accounts
        .rent
        .as_ref()
        .ok_or(error!(GatewayError::InvalidAccount))?;
    let ata_program = ctx
        .accounts
        .associated_token_program
        .as_ref()
        .ok_or(error!(GatewayError::InvalidAccount))?;

    // Validate program IDs
    require!(
        token_program.key() == spl_token::ID,
        GatewayError::InvalidAccount
    );
    require!(
        ata_program.key() == spl_associated_token_account::ID,
        GatewayError::InvalidAccount
    );
    require!(
        rent.key() == rent_sysvar::ID,
        GatewayError::InvalidAccount
    );

    // Validate token parameter matches mint
    require!(token == mint.key(), GatewayError::InvalidMint);

    // SECURITY: Validate vault_ata ownership and mint
    let vault_ata_data = vault_ata.try_borrow_data()?.to_vec();
    let parsed_vault_ata = SplAccount::unpack(&vault_ata_data)
        .map_err(|_| error!(GatewayError::InvalidAccount))?;
    require!(
        parsed_vault_ata.owner == ctx.accounts.vault_sol.key(),
        GatewayError::InvalidOwner
    );
    require!(
        parsed_vault_ata.mint == mint.key(),
        GatewayError::InvalidMint
    );

    // Derive expected CEA ATA and validate
    let expected_cea_ata = spl_associated_token_account::get_associated_token_address(
        &ctx.accounts.cea_authority.key(),
        &mint.key(),
    );
    require!(
        cea_ata.key() == expected_cea_ata,
        GatewayError::InvalidAccount
    );

    // Create CEA ATA if it doesn't exist
    let cea_ata_info = cea_ata.to_account_info();
    if cea_ata_info.data_is_empty() {
        let create_ata_ix =
            spl_associated_token_account::instruction::create_associated_token_account(
                &ctx.accounts.caller.key(),
                &ctx.accounts.cea_authority.key(),
                &mint.key(),
                &spl_token::ID,
            );
        invoke_signed(
            &create_ata_ix,
            &[
                ctx.accounts.caller.to_account_info(),
                cea_ata.to_account_info(),
                ctx.accounts.cea_authority.to_account_info(),
                mint.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
                token_program.to_account_info(),
                ata_program.to_account_info(),
                rent.to_account_info(),
            ],
            &[],
        )?;
    }

    // Validate existing CEA ATA: mint + owner
    let cea_ata_data = cea_ata.try_borrow_data()?.to_vec();
    let parsed_cea_ata = SplAccount::unpack(&cea_ata_data)
        .map_err(|_| error!(GatewayError::InvalidAccount))?;
    require!(
        parsed_cea_ata.mint == mint.key(),
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
            vault_seeds,
        )?;
    }

    Ok(())
}
