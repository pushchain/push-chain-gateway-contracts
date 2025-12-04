use crate::errors::GatewayError;
use crate::instructions::tss::validate_message;
use crate::state::{
    Config, ExecutedTx, GatewayAccountMeta, TssPda, UniversalTxExecuted, EXECUTED_TX_SEED,
    STAGING_SEED, TSS_SEED, VAULT_SEED,
};
use crate::utils::validate_remaining_accounts;
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    instruction::{AccountMeta as SolanaAccountMeta, Instruction},
    program::invoke_signed,
    program_pack::Pack,
    system_instruction,
};
use anchor_spl::token::spl_token::state::Account as SplAccount;
use anchor_spl::{
    associated_token::AssociatedToken,
    token::{self, CloseAccount, Mint, Token, TokenAccount},
};

// =========================
//  EXECUTE_UNIVERSAL_TX (SOL)
// =========================

#[derive(Accounts)]
#[instruction(tx_id: [u8; 32])]
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

    /// Staging authority PDA - holds SOL for this specific tx
    /// This PDA will receive SOL from vault and can sign for target program
    #[account(
        mut,
        seeds = [STAGING_SEED, tx_id.as_ref()],
        bump,
    )]
    pub staging_authority: SystemAccount<'info>,

    #[account(
        mut,
        seeds = [TSS_SEED],
        bump,
    )]
    pub tss_pda: Account<'info, TssPda>,

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
}

pub fn execute_universal_tx(
    ctx: Context<ExecuteUniversalTx>,
    tx_id: [u8; 32],
    origin_caller: [u8; 20],
    amount: u64,
    target_program: Pubkey,
    sender: [u8; 20],
    accounts: Vec<GatewayAccountMeta>,
    ix_data: Vec<u8>,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    let config = &ctx.accounts.config;
    require!(!config.paused, GatewayError::Paused);

    // 1. Build serialized accounts buffer (with length prefix)
    let mut accounts_buf = Vec::new();
    let accounts_count = accounts.len() as u32;
    accounts_buf.extend_from_slice(&accounts_count.to_be_bytes()); // u32 BE length prefix
    for account in &accounts {
        accounts_buf.extend_from_slice(&account.pubkey.to_bytes()); // Pubkey (32 bytes)
        accounts_buf.push(if account.is_writable { 1 } else { 0 }); // is_writable (1 byte)
    }

    // 2. Build serialized ix_data buffer (with length prefix)
    let mut ix_data_buf = Vec::new();
    let ix_data_length = ix_data.len() as u32;
    ix_data_buf.extend_from_slice(&ix_data_length.to_be_bytes()); // u32 BE length prefix
    ix_data_buf.extend_from_slice(&ix_data); // Raw bytes

    // 3. Validate TSS signature and message hash using unified validate_message
    // Format: PREFIX + instruction_id + chain_id + nonce + amount + [tx_id, target_program, sender, accounts_buf, ix_data_buf]
    let additional: [&[u8]; 5] = [
        &tx_id[..],
        &target_program.to_bytes(),
        &sender[..],
        &accounts_buf,
        &ix_data_buf,
    ];
    validate_message(
        &mut ctx.accounts.tss_pda,
        5, // instruction_id for SOL execute
        nonce,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    // 4. Verify target program matches and is executable
    require!(
        ctx.accounts.destination_program.key() == target_program,
        GatewayError::TargetProgramMismatch
    );
    require!(
        ctx.accounts.destination_program.executable,
        GatewayError::InvalidProgram
    );

    // 5. Validate remaining_accounts match signed accounts
    validate_remaining_accounts(&accounts, ctx.remaining_accounts)?;

    // 6. Replay protection - account existence check
    // (init_if_needed will fail if account already exists with different data)
    // For simplicity, we rely on account creation as replay protection
    // Note: Nonce is already updated in validate_message (atomic with verification)

    // 7. Transfer SOL from vault_sol → staging_authority (only if amount > 0)
    // If amount = 0, skip transfer - allows pure function calls without funds
    if amount > 0 {
        let vault_bump = config.vault_bump;
        let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[vault_bump]];

        let transfer_ix = system_instruction::transfer(
            &ctx.accounts.vault_sol.key(),
            &ctx.accounts.staging_authority.key(),
            amount,
        );

        invoke_signed(
            &transfer_ix,
            &[
                ctx.accounts.vault_sol.to_account_info(),
                ctx.accounts.staging_authority.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[vault_seeds],
        )?;
    }

    // 8. Build CPI instruction for target program
    // staging_authority must appear as signer inside CPI
    let staging_key = ctx.accounts.staging_authority.key();
    let cpi_metas: Vec<SolanaAccountMeta> = accounts
        .iter()
        .map(|a| {
            let is_signer = a.pubkey == staging_key;
            if a.is_writable {
                SolanaAccountMeta::new(a.pubkey, is_signer)
            } else {
                SolanaAccountMeta::new_readonly(a.pubkey, is_signer)
            }
        })
        .collect();

    let cpi_ix = Instruction {
        program_id: target_program,
        accounts: cpi_metas,
        data: ix_data.clone(),
    };

    // 9. Invoke target program with staging_authority as signer
    // staging_authority is always available (PDA) even when amount = 0, for signing if needed
    let staging_bump = ctx.bumps.staging_authority;
    let staging_seeds: &[&[u8]] = &[STAGING_SEED, tx_id.as_ref(), &[staging_bump]];

    invoke_signed(&cpi_ix, ctx.remaining_accounts, &[staging_seeds])?;

    // 10. Emit event
    emit!(UniversalTxExecuted {
        tx_id,
        origin_caller,
        target: target_program,
        token: Pubkey::default(), // SOL
        amount,
        payload: ix_data,
    });

    Ok(())
}

// =========================
//  EXECUTE_UNIVERSAL_TX_TOKEN (SPL)
// =========================

#[derive(Accounts)]
#[instruction(tx_id: [u8; 32])]
pub struct ExecuteUniversalTxToken<'info> {
    #[account(mut)]
    pub caller: Signer<'info>,

    #[account(
        seeds = [b"config"],
        bump,
    )]
    pub config: Account<'info, Config>,

    /// Vault authority PDA - owner of all vault ATAs
    #[account(
        seeds = [VAULT_SEED],
        bump = config.vault_bump,
    )]
    /// CHECK: PDA, no data account needed
    pub vault_authority: UncheckedAccount<'info>,

    /// Vault ATA for this mint
    #[account(
        mut,
        constraint = vault_ata.owner == vault_authority.key() @ GatewayError::InvalidOwner,
        constraint = vault_ata.mint == mint.key() @ GatewayError::InvalidMint,
    )]
    pub vault_ata: Account<'info, TokenAccount>,

    /// Staging authority PDA for this tx
    #[account(
        mut,
        seeds = [STAGING_SEED, tx_id.as_ref()],
        bump,
    )]
    /// CHECK: PDA, no data account needed
    pub staging_authority: SystemAccount<'info>,

    /// Staging ATA for this tx+mint
    /// Created per-tx, closed after if empty (rent reclaim)
    /// CHECK: Will be created as ATA(staging_authority, mint)
    #[account(mut)]
    pub staging_ata: UncheckedAccount<'info>,

    /// Token mint
    pub mint: Account<'info, Mint>,

    #[account(
        mut,
        seeds = [TSS_SEED],
        bump,
    )]
    pub tss_pda: Account<'info, TssPda>,

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

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
    pub associated_token_program: Program<'info, AssociatedToken>,
}

pub fn execute_universal_tx_token(
    ctx: Context<ExecuteUniversalTxToken>,
    tx_id: [u8; 32],
    origin_caller: [u8; 20],
    amount: u64,
    target_program: Pubkey,
    sender: [u8; 20],
    accounts: Vec<GatewayAccountMeta>,
    ix_data: Vec<u8>,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    let config = &ctx.accounts.config;
    require!(!config.paused, GatewayError::Paused);

    // 1. Build serialized accounts buffer (with length prefix)
    let mut accounts_buf = Vec::new();
    let accounts_count = accounts.len() as u32;
    accounts_buf.extend_from_slice(&accounts_count.to_be_bytes()); // u32 BE length prefix
    for account in &accounts {
        accounts_buf.extend_from_slice(&account.pubkey.to_bytes()); // Pubkey (32 bytes)
        accounts_buf.push(if account.is_writable { 1 } else { 0 }); // is_writable (1 byte)
    }

    // 2. Build serialized ix_data buffer (with length prefix)
    let mut ix_data_buf = Vec::new();
    let ix_data_length = ix_data.len() as u32;
    ix_data_buf.extend_from_slice(&ix_data_length.to_be_bytes()); // u32 BE length prefix
    ix_data_buf.extend_from_slice(&ix_data); // Raw bytes

    // 3. Validate TSS signature and message hash using unified validate_message
    // Format: PREFIX + instruction_id + chain_id + nonce + amount + [tx_id, target_program, sender, accounts_buf, ix_data_buf]
    let additional: [&[u8]; 5] = [
        &tx_id[..],
        &target_program.to_bytes(),
        &sender[..],
        &accounts_buf,
        &ix_data_buf,
    ];
    validate_message(
        &mut ctx.accounts.tss_pda,
        6, // instruction_id for SPL execute
        nonce,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    // 4. Verify target program matches and is executable
    require!(
        ctx.accounts.destination_program.key() == target_program,
        GatewayError::TargetProgramMismatch
    );
    require!(
        ctx.accounts.destination_program.executable,
        GatewayError::InvalidProgram
    );

    // 5. Validate remaining_accounts match signed accounts
    validate_remaining_accounts(&accounts, ctx.remaining_accounts)?;

    // Note: Nonce is already updated in validate_message (atomic with verification)

    // 5. Handle token operations only if amount > 0
    // If amount = 0, skip all token operations - allows pure function calls without funds
    if amount > 0 {
        // Create staging_ata if needed
        // Check if staging_ata is uninitialized (data length == 0)
        if ctx.accounts.staging_ata.data_is_empty() {
            // Manually create ATA using system program
            // ATA address = findProgramAddress([authority, TOKEN_PROGRAM_ID, mint], ASSOCIATED_TOKEN_PROGRAM_ID)
            let create_ata_ix = anchor_lang::solana_program::instruction::Instruction {
                program_id: anchor_spl::associated_token::ID,
                accounts: vec![
                    SolanaAccountMeta::new(ctx.accounts.caller.key(), true),
                    SolanaAccountMeta::new(ctx.accounts.staging_ata.key(), false),
                    SolanaAccountMeta::new_readonly(ctx.accounts.staging_authority.key(), false),
                    SolanaAccountMeta::new_readonly(ctx.accounts.mint.key(), false),
                    SolanaAccountMeta::new_readonly(ctx.accounts.system_program.key(), false),
                    SolanaAccountMeta::new_readonly(ctx.accounts.token_program.key(), false),
                    SolanaAccountMeta::new_readonly(ctx.accounts.rent.key(), false),
                    SolanaAccountMeta::new_readonly(
                        ctx.accounts.associated_token_program.key(),
                        false,
                    ),
                ],
                data: vec![0], // Create instruction discriminator
            };

            anchor_lang::solana_program::program::invoke(
                &create_ata_ix,
                &[
                    ctx.accounts.caller.to_account_info(),
                    ctx.accounts.staging_ata.to_account_info(),
                    ctx.accounts.staging_authority.to_account_info(),
                    ctx.accounts.mint.to_account_info(),
                    ctx.accounts.system_program.to_account_info(),
                    ctx.accounts.token_program.to_account_info(),
                    ctx.accounts.rent.to_account_info(),
                    ctx.accounts.associated_token_program.to_account_info(),
                ],
            )?;
        }

        // SECURITY: Ensure provided staging_ata really belongs to staging_authority + mint
        {
            let staging_account_data = ctx.accounts.staging_ata.try_borrow_data()?;
            let staging_account = SplAccount::unpack(&staging_account_data)
                .map_err(|_| error!(GatewayError::InvalidAccount))?;
            require!(
                staging_account.owner == ctx.accounts.staging_authority.key(),
                GatewayError::InvalidOwner
            );
            require!(
                staging_account.mint == ctx.accounts.mint.key(),
                GatewayError::InvalidMint
            );
        }

        // Transfer tokens from vault_ata → staging_ata
        let vault_bump = config.vault_bump;
        let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[vault_bump]];

        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                token::Transfer {
                    from: ctx.accounts.vault_ata.to_account_info(),
                    to: ctx.accounts.staging_ata.to_account_info(),
                    authority: ctx.accounts.vault_authority.to_account_info(),
                },
                &[vault_seeds],
            ),
            amount,
        )?;
    }

    // 6. Build CPI instruction for target program
    let staging_key = ctx.accounts.staging_authority.key();
    let cpi_metas: Vec<SolanaAccountMeta> = accounts
        .iter()
        .map(|a| {
            let is_signer = a.pubkey == staging_key;
            if a.is_writable {
                SolanaAccountMeta::new(a.pubkey, is_signer)
            } else {
                SolanaAccountMeta::new_readonly(a.pubkey, is_signer)
            }
        })
        .collect();

    let cpi_ix = Instruction {
        program_id: target_program,
        accounts: cpi_metas,
        data: ix_data.clone(),
    };

    // 7. Invoke target program with staging_authority as signer
    // staging_authority is always available (PDA) even when amount = 0, for signing if needed
    let staging_bump = ctx.bumps.staging_authority;
    let staging_seeds: &[&[u8]] = &[STAGING_SEED, tx_id.as_ref(), &[staging_bump]];

    invoke_signed(&cpi_ix, ctx.remaining_accounts, &[staging_seeds])?;

    // 8. Return remaining tokens (if any) to vault and close staging_ata (rent reclaim)
    // Only needed if we created staging_ata (amount > 0)
    if amount > 0 {
        let staging_ata_data = ctx.accounts.staging_ata.try_borrow_data()?;
        let mut staging_slice: &[u8] = &staging_ata_data;
        let staging_ata_account = TokenAccount::try_deserialize(&mut staging_slice)?;
        let remaining = staging_ata_account.amount;
        drop(staging_ata_data); // Release borrow before CPI

        if remaining > 0 {
            token::transfer(
                CpiContext::new_with_signer(
                    ctx.accounts.token_program.to_account_info(),
                    token::Transfer {
                        from: ctx.accounts.staging_ata.to_account_info(),
                        to: ctx.accounts.vault_ata.to_account_info(),
                        authority: ctx.accounts.staging_authority.to_account_info(),
                    },
                    &[staging_seeds],
                ),
                remaining,
            )?;
        }

        token::close_account(CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            CloseAccount {
                account: ctx.accounts.staging_ata.to_account_info(),
                destination: ctx.accounts.caller.to_account_info(), // Rent back to caller
                authority: ctx.accounts.staging_authority.to_account_info(),
            },
            &[staging_seeds],
        ))?;
    }

    // 9. Emit event
    emit!(UniversalTxExecuted {
        tx_id,
        origin_caller,
        target: target_program,
        token: ctx.accounts.mint.key(),
        amount,
        payload: ix_data,
    });

    Ok(())
}
