use crate::instructions::tss::validate_message;
use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::program_pack::Pack;
use anchor_lang::solana_program::system_instruction;
use anchor_spl::token::{self, spl_token, Mint, Token, TokenAccount, Transfer};
use spl_token::state::Account as SplAccount;

// =========================
//   TSS REVERT WITHDRAW FUNCTIONS
// =========================

/// Revert withdraw for SOL (TSS-verified)
#[derive(Accounts)]
#[instruction(sub_tx_id: [u8; 32])]
pub struct RevertUniversalTx<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::Paused,
    )]
    pub config: Account<'info, Config>,

    /// CHECK: SOL-only PDA, no data
    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    #[account(
        mut,
        seeds = [TSS_SEED],
        bump = tss_pda.bump,
    )]
    pub tss_pda: Account<'info, TssPda>,

    /// CHECK: Recipient address
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,

    /// Executed transaction tracker (EVM parity: isExecuted[subTxID])
    #[account(
        init,
        payer = caller,
        space = ExecutedSubTx::LEN,
        seeds = [EXECUTED_SUB_TX_SEED, &sub_tx_id],
        bump
    )]
    pub executed_sub_tx: Account<'info, ExecutedSubTx>,

    /// The caller/relayer who pays for the transaction (including executed_sub_tx account creation)
    #[account(mut)]
    pub caller: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn revert_universal_tx(
    ctx: Context<RevertUniversalTx>,
    sub_tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    amount: u64,
    revert_instruction: RevertInstructions,
    gas_fee: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
) -> Result<()> {
    require!(amount > 0, GatewayError::InvalidAmount);
    require!(
        revert_instruction.revert_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(
        ctx.accounts.recipient.key() == revert_instruction.revert_recipient,
        GatewayError::InvalidRecipient
    );

    let instruction_id: u8 = 3;
    let recipient_bytes = revert_instruction.revert_recipient.to_bytes();
    let mut gas_fee_buf = [0u8; 8];
    gas_fee_buf.copy_from_slice(&gas_fee.to_be_bytes());
    let additional: [&[u8]; 4] = [&sub_tx_id[..], &universal_tx_id[..], &recipient_bytes[..], &gas_fee_buf];
    validate_message(
        &mut ctx.accounts.tss_pda,
        instruction_id,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    let seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];
    anchor_lang::solana_program::program::invoke_signed(
        &system_instruction::transfer(
            &ctx.accounts.vault.key(),
            &revert_instruction.revert_recipient,
            amount,
        ),
        &[
            ctx.accounts.vault.to_account_info(),
            ctx.accounts.recipient.to_account_info(),
            ctx.accounts.system_program.to_account_info(),
        ],
        &[seeds],
    )?;

    emit!(crate::state::RevertUniversalTx {
        sub_tx_id,
        universal_tx_id,
        revert_recipient: revert_instruction.revert_recipient,
        token: Pubkey::default(),
        amount,
        revert_instruction: revert_instruction.clone(),
    });

    // Transfer gas fee to caller (relayer reimbursement)
    crate::utils::transfer_gas_fee_to_caller(
        &ctx.accounts.vault.to_account_info(),
        &ctx.accounts.caller.to_account_info(),
        &ctx.accounts.system_program.to_account_info(),
        gas_fee,
        ctx.accounts.config.vault_bump,
    )?;

    Ok(())
}

/// Revert withdraw for SPL tokens (TSS-verified)
#[derive(Accounts)]
#[instruction(sub_tx_id: [u8; 32])]
pub struct RevertUniversalTxToken<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::Paused,
    )]
    pub config: Account<'info, Config>,

    /// CHECK: SOL-only PDA, no data
    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    /// CHECK: Vault token account - validated at runtime (owner == vault, mint == token_mint)
    #[account(mut)]
    pub token_vault: UncheckedAccount<'info>,

    #[account(
        mut,
        seeds = [TSS_SEED],
        bump = tss_pda.bump,
    )]
    pub tss_pda: Account<'info, TssPda>,

    /// Recipient token account (ATA for revert_recipient + token_mint)
    #[account(mut)]
    pub recipient_token_account: Account<'info, TokenAccount>,

    pub token_mint: Account<'info, Mint>,

    /// Executed transaction tracker (EVM parity: isExecuted[subTxID])
    #[account(
        init,
        payer = caller,
        space = ExecutedSubTx::LEN,
        seeds = [EXECUTED_SUB_TX_SEED, &sub_tx_id],
        bump
    )]
    pub executed_sub_tx: Account<'info, ExecutedSubTx>,

    /// The caller/relayer who pays for the transaction (including executed_sub_tx account creation)
    #[account(mut)]
    pub caller: Signer<'info>,

    /// Vault SOL PDA (needed for gas_fee transfer to caller)
    #[account(
        mut,
        seeds = [VAULT_SEED],
        bump = config.vault_bump,
    )]
    pub vault_sol: SystemAccount<'info>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

pub fn revert_universal_tx_token(
    ctx: Context<RevertUniversalTxToken>,
    sub_tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    amount: u64,
    revert_instruction: RevertInstructions,
    gas_fee: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
) -> Result<()> {
    require!(amount > 0, GatewayError::InvalidAmount);
    require!(
        revert_instruction.revert_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(
        ctx.accounts.recipient_token_account.owner == revert_instruction.revert_recipient,
        GatewayError::InvalidRecipient
    );
    require!(
        ctx.accounts.recipient_token_account.mint == ctx.accounts.token_mint.key(),
        GatewayError::InvalidMint
    );

    let instruction_id: u8 = 4;
    let mut mint_bytes = [0u8; 32];
    mint_bytes.copy_from_slice(&ctx.accounts.token_mint.key().to_bytes());
    let recipient_bytes = revert_instruction.revert_recipient.to_bytes();
    let mut gas_fee_buf = [0u8; 8];
    gas_fee_buf.copy_from_slice(&gas_fee.to_be_bytes());
    let additional: [&[u8]; 5] = [
        &sub_tx_id[..],
        &universal_tx_id[..],
        &mint_bytes[..],
        &recipient_bytes[..],
        &gas_fee_buf,
    ];
    validate_message(
        &mut ctx.accounts.tss_pda,
        instruction_id,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    // SECURITY: Validate token_vault is owned by vault and matches token_mint
    let data = ctx.accounts.token_vault.try_borrow_data()?.to_vec();
    let parsed = SplAccount::unpack(&data).map_err(|_| error!(GatewayError::InvalidAccount))?;
    require!(
        parsed.owner == ctx.accounts.vault.key(),
        GatewayError::InvalidOwner
    );
    require!(
        parsed.mint == ctx.accounts.token_mint.key(),
        GatewayError::InvalidMint
    );

    let seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];

    let cpi_accounts = Transfer {
        from: ctx.accounts.token_vault.to_account_info(),
        to: ctx.accounts.recipient_token_account.to_account_info(),
        authority: ctx.accounts.vault.to_account_info(),
    };

    let cpi_program = ctx.accounts.token_program.to_account_info();
    let seeds_array = [seeds];
    let cpi_ctx = CpiContext::new_with_signer(cpi_program, cpi_accounts, &seeds_array);

    token::transfer(cpi_ctx, amount)?;

    emit!(crate::state::RevertUniversalTx {
        sub_tx_id,
        universal_tx_id,
        revert_recipient: revert_instruction.revert_recipient,
        token: ctx.accounts.token_mint.key(),
        amount,
        revert_instruction: revert_instruction.clone(),
    });

    // Transfer gas fee to caller (relayer reimbursement)
    crate::utils::transfer_gas_fee_to_caller(
        &ctx.accounts.vault_sol.to_account_info(),
        &ctx.accounts.caller.to_account_info(),
        &ctx.accounts.system_program.to_account_info(),
        gas_fee,
        ctx.accounts.config.vault_bump,
    )?;

    Ok(())
}
