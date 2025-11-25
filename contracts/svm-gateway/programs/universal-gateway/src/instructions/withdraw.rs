use crate::instructions::tss::validate_message;
use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::system_instruction;
use anchor_spl::token::{self, Mint, Token, TokenAccount, Transfer};

// =========================
//        TSS WITHDRAW
// =========================

#[derive(Accounts)]
#[instruction(tx_id: [u8; 32])]
pub struct Withdraw<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
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

    /// Executed transaction tracker (EVM parity: isExecuted[txID])
    /// PDA: [b"executed_tx", tx_id] - account existence = transaction executed
    /// Standard Solana pattern (equivalent to Solidity mapping(bytes32 => bool))
    #[account(
        init_if_needed,
        payer = caller,
        space = ExecutedTx::LEN,
        seeds = [EXECUTED_TX_SEED, &tx_id],
        bump
    )]
    pub executed_tx: Account<'info, ExecutedTx>,

    /// The caller/relayer who pays for the transaction (including executed_tx account creation)
    #[account(mut)]
    pub caller: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn withdraw(
    ctx: Context<Withdraw>,
    tx_id: [u8; 32],
    origin_caller: [u8; 20], // EVM address (20 bytes) from Push Chain
    amount: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    // EVM parity: Replay protection via Anchor's init constraint
    // If account already exists, init fails (transaction already executed)
    // If account doesn't exist, init creates it (marking as executed)

    // Equivalent to `require(!isExecuted[txID], PayloadExecuted)` in EVM
    require!(
        !ctx.accounts.executed_tx.executed,
        GatewayError::PayloadExecuted
    );

    require!(amount > 0, GatewayError::InvalidAmount);
    require!(origin_caller != [0u8; 20], GatewayError::InvalidInput);
    require!(
        ctx.accounts.recipient.key() != Pubkey::default(),
        GatewayError::InvalidInput
    );

    // instruction_id = 1 for SOL withdraw
    let instruction_id: u8 = 1;
    let recipient_bytes = ctx.accounts.recipient.key().to_bytes();
    // Include txID and origin_caller (EVM address) in message hash for security and tracking
    let additional: [&[u8]; 3] = [&tx_id[..], &origin_caller[..], &recipient_bytes[..]];
    validate_message(
        &mut ctx.accounts.tss_pda,
        instruction_id,
        nonce,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    // Transfer funds from vault to recipient
    let seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];
    anchor_lang::solana_program::program::invoke_signed(
        &system_instruction::transfer(ctx.accounts.vault.key, ctx.accounts.recipient.key, amount),
        &[
            ctx.accounts.vault.to_account_info(),
            ctx.accounts.recipient.to_account_info(),
            ctx.accounts.system_program.to_account_info(),
        ],
        &[seeds],
    )?;

    emit!(crate::state::WithdrawToken {
        tx_id,
        origin_caller,
        token: Pubkey::default(),
        to: ctx.accounts.recipient.key(),
        amount,
    });

    // Mark txID as executed only after all checks and transfers succeed
    ctx.accounts.executed_tx.executed = true;

    Ok(())
}

#[derive(Accounts)]
#[instruction(tx_id: [u8; 32])]
pub struct WithdrawFunds<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
    )]
    pub config: Account<'info, Config>,

    #[account(
        constraint = whitelist.tokens.contains(&token_mint.key()) @ GatewayError::TokenNotWhitelisted
    )]
    pub whitelist: Account<'info, TokenWhitelist>,

    /// CHECK: SOL-only PDA, no data
    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    /// CHECK: Token vault ATA, derived from vault PDA and token mint
    #[account(mut)]
    pub token_vault: UncheckedAccount<'info>,

    #[account(
        mut,
        seeds = [TSS_SEED],
        bump = tss_pda.bump,
    )]
    pub tss_pda: Account<'info, TssPda>,

    /// CHECK: Recipient token account
    #[account(mut)]
    pub recipient_token_account: UncheckedAccount<'info>,

    pub token_mint: Account<'info, Mint>,

    /// Executed transaction tracker (EVM parity: isExecuted[txID])
    #[account(
        init_if_needed,
        payer = caller,
        space = ExecutedTx::LEN,
        seeds = [EXECUTED_TX_SEED, &tx_id],
        bump
    )]
    pub executed_tx: Account<'info, ExecutedTx>,

    /// The caller/relayer who pays for the transaction (including executed_tx account creation)
    #[account(mut)]
    pub caller: Signer<'info>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

pub fn withdraw_funds(
    ctx: Context<WithdrawFunds>,
    tx_id: [u8; 32],
    origin_caller: [u8; 20], // EVM address (20 bytes) from Push Chain
    amount: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    // EVM parity: Replay protection via Anchor's init constraint
    // If account already exists, init fails (transaction already executed)
    // If account doesn't exist, init creates it (marking as executed)

    // Equivalent to `require(!isExecuted[txID], PayloadExecuted)` in EVM
    require!(
        !ctx.accounts.executed_tx.executed,
        GatewayError::PayloadExecuted
    );

    require!(amount > 0, GatewayError::InvalidAmount);
    require!(origin_caller != [0u8; 20], GatewayError::InvalidInput);

    // instruction_id = 2 for SPL withdraw
    let instruction_id: u8 = 2;
    let mut mint_bytes = [0u8; 32];
    mint_bytes.copy_from_slice(&ctx.accounts.token_mint.key().to_bytes());
    let recipient_bytes = ctx.accounts.recipient_token_account.key().to_bytes();
    // Include txID, origin_caller (EVM address), mint AND recipient in message hash
    let additional: [&[u8]; 4] = [
        &tx_id[..],
        &origin_caller[..],
        &mint_bytes[..],
        &recipient_bytes[..],
    ];
    validate_message(
        &mut ctx.accounts.tss_pda,
        instruction_id,
        nonce,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    // Note: Recipient ATA must be created off-chain by the client
    // This is standard practice in Solana programs

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

    // ATA creation is handled off-chain by the client (standard practice)

    emit!(crate::state::WithdrawToken {
        tx_id,
        origin_caller,
        token: ctx.accounts.token_mint.key(),
        to: ctx.accounts.recipient_token_account.key(),
        amount,
    });

    // Mark txID as executed only after all checks and transfers succeed
    ctx.accounts.executed_tx.executed = true;

    Ok(())
}

// SPL Token withdraw instruction
// Legacy signer-based SPL withdraw removed; use TSS-verified variants below

// =========================
//   TSS REVERT WITHDRAW FUNCTIONS - FIXED WITH REAL TSS
// =========================

/// Revert withdraw for SOL (TSS-verified) - FIXED
#[derive(Accounts)]
#[instruction(tx_id: [u8; 32])]
pub struct RevertUniversalTx<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
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

    /// Executed transaction tracker (EVM parity: isExecuted[txID])
    #[account(
        init_if_needed,
        payer = caller,
        space = ExecutedTx::LEN,
        seeds = [EXECUTED_TX_SEED, &tx_id],
        bump
    )]
    pub executed_tx: Account<'info, ExecutedTx>,

    /// The caller/relayer who pays for the transaction (including executed_tx account creation)
    #[account(mut)]
    pub caller: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn revert_universal_tx(
    ctx: Context<RevertUniversalTx>,
    tx_id: [u8; 32],
    amount: u64,
    revert_instruction: RevertInstructions,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    // EVM parity: Replay protection via Anchor's init constraint
    // If account already exists, init fails (transaction already executed)
    // If account doesn't exist, init creates it (marking as executed)

    // Equivalent to `require(!isExecuted[txID], PayloadExecuted)` in EVM
    require!(
        !ctx.accounts.executed_tx.executed,
        GatewayError::PayloadExecuted
    );

    require!(amount > 0, GatewayError::InvalidAmount);
    require!(
        revert_instruction.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    // Hardening: the passed recipient account must match the fund_recipient
    require!(
        ctx.accounts.recipient.key() == revert_instruction.fund_recipient,
        GatewayError::InvalidRecipient
    );

    // instruction_id = 3 for SOL revert withdraw (different from regular withdraw)
    let instruction_id: u8 = 3;
    let recipient_bytes = revert_instruction.fund_recipient.to_bytes();
    // Include txID and recipient in message hash (NO originCaller in revert functions per EVM)
    let additional: [&[u8]; 2] = [&tx_id[..], &recipient_bytes[..]];
    validate_message(
        &mut ctx.accounts.tss_pda,
        instruction_id,
        nonce,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    // Transfer SOL from vault to revert recipient
    let seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];
    anchor_lang::solana_program::program::invoke_signed(
        &system_instruction::transfer(
            &ctx.accounts.vault.key(),
            &revert_instruction.fund_recipient,
            amount,
        ),
        &[
            ctx.accounts.vault.to_account_info(),
            ctx.accounts.recipient.to_account_info(),
            ctx.accounts.system_program.to_account_info(),
        ],
        &[seeds],
    )?;

    // Emit revert withdraw event (EVM parity: RevertUniversalTx)
    emit!(crate::state::RevertUniversalTx {
        tx_id,
        fund_recipient: revert_instruction.fund_recipient,
        token: Pubkey::default(),
        amount,
        revert_instruction: revert_instruction.clone(),
    });

    // Mark txID as executed only after all checks and transfers succeed
    ctx.accounts.executed_tx.executed = true;

    Ok(())
}

/// Revert withdraw for SPL tokens (TSS-verified) - FIXED
#[derive(Accounts)]
#[instruction(tx_id: [u8; 32])]
pub struct RevertUniversalTxToken<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
    )]
    pub config: Account<'info, Config>,

    #[account(
        constraint = whitelist.tokens.contains(&token_mint.key()) @ GatewayError::TokenNotWhitelisted
    )]
    pub whitelist: Account<'info, TokenWhitelist>,

    /// CHECK: SOL-only PDA, no data - FIXED: Added vault account
    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    /// CHECK: Token vault ATA, derived from vault PDA and token mint
    #[account(mut)]
    pub token_vault: UncheckedAccount<'info>,

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

    /// Executed transaction tracker (EVM parity: isExecuted[txID])
    #[account(
        init_if_needed,
        payer = caller,
        space = ExecutedTx::LEN,
        seeds = [EXECUTED_TX_SEED, &tx_id],
        bump
    )]
    pub executed_tx: Account<'info, ExecutedTx>,

    /// The caller/relayer who pays for the transaction (including executed_tx account creation)
    #[account(mut)]
    pub caller: Signer<'info>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

pub fn revert_universal_tx_token(
    ctx: Context<RevertUniversalTxToken>,
    tx_id: [u8; 32],
    amount: u64,
    revert_instruction: RevertInstructions,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    // EVM parity: Replay protection via Anchor's init constraint
    // If account already exists, init fails (transaction already executed)
    // If account doesn't exist, init creates it (marking as executed)

    // Equivalent to `require(!isExecuted[txID], PayloadExecuted)` in EVM
    require!(
        !ctx.accounts.executed_tx.executed,
        GatewayError::PayloadExecuted
    );

    require!(amount > 0, GatewayError::InvalidAmount);
    require!(
        revert_instruction.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    // Hardening: ensure the recipient token account really belongs to the fund_recipient
    require!(
        ctx.accounts.recipient_token_account.owner == revert_instruction.fund_recipient,
        GatewayError::InvalidRecipient
    );
    // And that it is for the correct mint
    require!(
        ctx.accounts.recipient_token_account.mint == ctx.accounts.token_mint.key(),
        GatewayError::InvalidMint
    );

    // instruction_id = 4 for SPL revert withdraw (different from regular SPL withdraw)
    let instruction_id: u8 = 4;
    let mut mint_bytes = [0u8; 32];
    mint_bytes.copy_from_slice(&ctx.accounts.token_mint.key().to_bytes());
    let recipient_bytes = revert_instruction.fund_recipient.to_bytes();
    // Include txID, mint AND recipient in message hash (NO originCaller in revert functions per EVM)
    let additional: [&[u8]; 3] = [&tx_id[..], &mint_bytes[..], &recipient_bytes[..]];
    validate_message(
        &mut ctx.accounts.tss_pda,
        instruction_id,
        nonce,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    // FIXED: Use vault PDA as authority with correct seeds
    let seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];

    let cpi_accounts = Transfer {
        from: ctx.accounts.token_vault.to_account_info(),
        to: ctx.accounts.recipient_token_account.to_account_info(),
        authority: ctx.accounts.vault.to_account_info(), // FIXED: vault as authority
    };

    let cpi_program = ctx.accounts.token_program.to_account_info();
    let seeds_array = [seeds];
    let cpi_ctx = CpiContext::new_with_signer(cpi_program, cpi_accounts, &seeds_array);

    token::transfer(cpi_ctx, amount)?;

    // Emit revert withdraw event (EVM parity: RevertUniversalTx)
    emit!(crate::state::RevertUniversalTx {
        tx_id,
        fund_recipient: revert_instruction.fund_recipient,
        token: ctx.accounts.token_mint.key(),
        amount,
        revert_instruction: revert_instruction.clone(),
    });

    // Mark txID as executed only after all checks and transfers succeed
    ctx.accounts.executed_tx.executed = true;

    Ok(())
}
