use crate::instructions::tss::validate_message;
use crate::utils::{encode_u64_be, pda_spl_transfer, pda_system_transfer, reimburse_relayer_from_fee_vault};
use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_spl::token::{Mint, Token, TokenAccount};

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

    /// Fee vault — relayer gas reimbursement comes from here, not from bridge vault.
    #[account(
        mut,
        seeds = [FEE_VAULT_SEED],
        bump = fee_vault.bump,
    )]
    pub fee_vault: Account<'info, FeeVault>,

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
        revert_instruction.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(
        ctx.accounts.recipient.key() == revert_instruction.fund_recipient,
        GatewayError::InvalidRecipient
    );

    let instruction_id: u8 = 3;
    let gas_fee_buf = encode_u64_be(gas_fee);
    let additional: [&[u8]; 4] = [
        &universal_tx_id,
        &sub_tx_id,
        &revert_instruction.fund_recipient.to_bytes(),
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

    let seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];
    pda_system_transfer(
        &ctx.accounts.vault.to_account_info(),
        &ctx.accounts.recipient.to_account_info(),
        &ctx.accounts.system_program.to_account_info(),
        amount,
        seeds,
    )?;

    emit!(crate::state::RevertUniversalTx {
        universal_tx_id,
        sub_tx_id,
        fund_recipient: revert_instruction.fund_recipient,
        token: Pubkey::default(),
        amount,
        revert_instruction: revert_instruction.clone(),
    });

    reimburse_relayer_from_fee_vault(
        &ctx.accounts.fee_vault,
        &ctx.accounts.caller.to_account_info(),
        sub_tx_id,
        gas_fee,
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

    #[account(mut, token::authority = vault, token::mint = token_mint)]
    pub token_vault: Account<'info, TokenAccount>,

    /// Fee vault — relayer gas reimbursement comes from here, not from bridge vault.
    #[account(
        mut,
        seeds = [FEE_VAULT_SEED],
        bump = fee_vault.bump,
    )]
    pub fee_vault: Account<'info, FeeVault>,

    #[account(
        mut,
        seeds = [TSS_SEED],
        bump = tss_pda.bump,
    )]
    pub tss_pda: Account<'info, TssPda>,

    /// Recipient token account (ATA for fund_recipient + token_mint)
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
        revert_instruction.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(
        ctx.accounts.recipient_token_account.owner == revert_instruction.fund_recipient,
        GatewayError::InvalidRecipient
    );
    require!(
        ctx.accounts.recipient_token_account.mint == ctx.accounts.token_mint.key(),
        GatewayError::InvalidMint
    );

    let instruction_id: u8 = 4;
    let mint_bytes = ctx.accounts.token_mint.key().to_bytes();
    let gas_fee_buf = encode_u64_be(gas_fee);
    let additional: [&[u8]; 5] = [
        &universal_tx_id,
        &sub_tx_id,
        &mint_bytes,
        &revert_instruction.fund_recipient.to_bytes(),
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

    let seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];
    pda_spl_transfer(
        &ctx.accounts.token_vault.to_account_info(),
        &ctx.accounts.recipient_token_account.to_account_info(),
        &ctx.accounts.vault.to_account_info(),
        amount,
        seeds,
    )?;

    emit!(crate::state::RevertUniversalTx {
        universal_tx_id,
        sub_tx_id,
        fund_recipient: revert_instruction.fund_recipient,
        token: ctx.accounts.token_mint.key(),
        amount,
        revert_instruction: revert_instruction.clone(),
    });

    reimburse_relayer_from_fee_vault(
        &ctx.accounts.fee_vault,
        &ctx.accounts.caller.to_account_info(),
        sub_tx_id,
        gas_fee,
    )?;

    Ok(())
}
