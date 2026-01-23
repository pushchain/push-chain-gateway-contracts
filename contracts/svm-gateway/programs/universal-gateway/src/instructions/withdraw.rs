use crate::instructions::tss::validate_message;
use crate::{errors::*, state::*};
use anchor_lang::prelude::*;
use anchor_lang::solana_program::program_pack::Pack;
use anchor_lang::solana_program::system_instruction;
use anchor_spl::token::{self, spl_token, Mint, Token, TokenAccount, Transfer};
use spl_token::state::Account as SplAccount;

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
        init,
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
    universal_tx_id: [u8; 32],
    origin_caller: [u8; 20], // EVM address (20 bytes) from Push Chain
    amount: u64,
    gas_fee: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    // EVM parity: Replay protection via Anchor's init constraint
    // If account already exists, init fails (transaction already executed)
    // If account doesn't exist, init creates it (transaction succeeds)
    // Account existence = transaction executed (atomic transaction ensures this)

    require!(amount > 0, GatewayError::InvalidAmount);
    require!(origin_caller != [0u8; 20], GatewayError::InvalidInput);
    require!(
        ctx.accounts.recipient.key() != Pubkey::default(),
        GatewayError::InvalidInput
    );

    // instruction_id = 1 for SOL withdraw
    let instruction_id: u8 = 1;
    let recipient_bytes = ctx.accounts.recipient.key().to_bytes();
    let mut gas_fee_buf = [0u8; 8];
    gas_fee_buf.copy_from_slice(&gas_fee.to_be_bytes());
    // Include universal_tx_id, txID, origin_caller (EVM address), recipient, and gas_fee in message hash
    let additional: [&[u8]; 5] = [
        &universal_tx_id[..],
        &tx_id[..],
        &origin_caller[..],
        &recipient_bytes[..],
        &gas_fee_buf,
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
        universal_tx_id,
        tx_id,
        origin_caller,
        token: Pubkey::default(),
        to: ctx.accounts.recipient.key(),
        amount,
    });

    // Transfer gas_fee directly to caller
    if gas_fee > 0 {
        let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];
        let fee_transfer_ix = system_instruction::transfer(
            &ctx.accounts.vault.key(),
            &ctx.accounts.caller.key(),
            gas_fee,
        );

        anchor_lang::solana_program::program::invoke_signed(
            &fee_transfer_ix,
            &[
                ctx.accounts.vault.to_account_info(),
                ctx.accounts.caller.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[vault_seeds],
        )?;
    }

    // Account creation via `init` constraint marks txID as executed
    // (atomic transaction ensures account only exists if execution succeeded)

    Ok(())
}

#[derive(Accounts)]
#[instruction(tx_id: [u8; 32])]
pub struct WithdrawTokens<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
    )]
    pub config: Account<'info, Config>,

    /// CHECK: SOL-only PDA, no data
    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    /// CHECK: Vault token account - validated at runtime (owner == vault, mint == token_mint)
    /// Matches deposit flow validation style for consistency
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
        init,
        payer = caller,
        space = ExecutedTx::LEN,
        seeds = [EXECUTED_TX_SEED, &tx_id],
        bump
    )]
    pub executed_tx: Account<'info, ExecutedTx>,

    /// The caller/relayer who pays for the transaction (including executed_tx account creation)
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

pub fn withdraw_tokens(
    ctx: Context<WithdrawTokens>,
    tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    origin_caller: [u8; 20], // EVM address (20 bytes) from Push Chain
    amount: u64,
    gas_fee: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    // EVM parity: Replay protection via Anchor's init constraint
    // If account already exists, init fails (transaction already executed)
    // If account doesn't exist, init creates it (transaction succeeds)
    // Account existence = transaction executed (atomic transaction ensures this)

    require!(amount > 0, GatewayError::InvalidAmount);
    require!(origin_caller != [0u8; 20], GatewayError::InvalidInput);

    // instruction_id = 2 for SPL withdraw
    let instruction_id: u8 = 2;
    let mut mint_bytes = [0u8; 32];
    mint_bytes.copy_from_slice(&ctx.accounts.token_mint.key().to_bytes());
    let recipient_bytes = ctx.accounts.recipient_token_account.key().to_bytes();
    let mut gas_fee_buf = [0u8; 8];
    gas_fee_buf.copy_from_slice(&gas_fee.to_be_bytes());
    // Include universal_tx_id, txID, origin_caller (EVM address), mint, recipient, and gas_fee in message hash
    let additional: [&[u8]; 6] = [
        &universal_tx_id[..],
        &tx_id[..],
        &origin_caller[..],
        &mint_bytes[..],
        &recipient_bytes[..],
        &gas_fee_buf,
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

    // SECURITY: Validate token_vault is owned by vault and matches token_mint
    // Matches deposit flow validation style (lines 262-275 in deposit.rs)
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
        universal_tx_id,
        tx_id,
        origin_caller,
        token: ctx.accounts.token_mint.key(),
        to: ctx.accounts.recipient_token_account.key(),
        amount,
    });

    // Transfer gas_fee directly to caller
    if gas_fee > 0 {
        let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];
        let fee_transfer_ix = system_instruction::transfer(
            &ctx.accounts.vault_sol.key(),
            &ctx.accounts.caller.key(),
            gas_fee,
        );

        anchor_lang::solana_program::program::invoke_signed(
            &fee_transfer_ix,
            &[
                ctx.accounts.vault_sol.to_account_info(),
                ctx.accounts.caller.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[vault_seeds],
        )?;
    }

    // Account creation via `init` constraint marks txID as executed
    // (atomic transaction ensures account only exists if execution succeeded)

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
        init,
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
    universal_tx_id: [u8; 32],
    amount: u64,
    revert_instruction: RevertInstructions,
    gas_fee: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    // EVM parity: Replay protection via Anchor's init constraint
    // If account already exists, init fails (transaction already executed)
    // If account doesn't exist, init creates it (transaction succeeds)
    // Account existence = transaction executed (atomic transaction ensures this)

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
    let mut gas_fee_buf = [0u8; 8];
    gas_fee_buf.copy_from_slice(&gas_fee.to_be_bytes());
    // Include universal_tx_id, txID, recipient, and gas_fee in message hash (NO originCaller in revert functions per EVM)
    let additional: [&[u8]; 4] = [
        &universal_tx_id[..],
        &tx_id[..],
        &recipient_bytes[..],
        &gas_fee_buf,
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
        universal_tx_id,
        tx_id,
        fund_recipient: revert_instruction.fund_recipient,
        token: Pubkey::default(),
        amount,
        revert_instruction: revert_instruction.clone(),
    });

    // Transfer gas_fee directly to caller
    if gas_fee > 0 {
        let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];
        let fee_transfer_ix = system_instruction::transfer(
            &ctx.accounts.vault.key(),
            &ctx.accounts.caller.key(),
            gas_fee,
        );

        anchor_lang::solana_program::program::invoke_signed(
            &fee_transfer_ix,
            &[
                ctx.accounts.vault.to_account_info(),
                ctx.accounts.caller.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[vault_seeds],
        )?;
    }

    // Account creation via `init` constraint marks txID as executed
    // (atomic transaction ensures account only exists if execution succeeded)

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

    /// CHECK: SOL-only PDA, no data
    #[account(mut, seeds = [VAULT_SEED], bump = config.vault_bump)]
    pub vault: UncheckedAccount<'info>,

    /// CHECK: Vault token account - validated at runtime (owner == vault, mint == token_mint)
    /// Matches deposit flow validation style for consistency
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
        init,
        payer = caller,
        space = ExecutedTx::LEN,
        seeds = [EXECUTED_TX_SEED, &tx_id],
        bump
    )]
    pub executed_tx: Account<'info, ExecutedTx>,

    /// The caller/relayer who pays for the transaction (including executed_tx account creation)
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
    tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    amount: u64,
    revert_instruction: RevertInstructions,
    gas_fee: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    // EVM parity: Replay protection via Anchor's init constraint
    // If account already exists, init fails (transaction already executed)
    // If account doesn't exist, init creates it (transaction succeeds)
    // Account existence = transaction executed (atomic transaction ensures this)

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
    let mut gas_fee_buf = [0u8; 8];
    gas_fee_buf.copy_from_slice(&gas_fee.to_be_bytes());
    // Include universal_tx_id, txID, mint, recipient, and gas_fee in message hash (NO originCaller in revert functions per EVM)
    let additional: [&[u8]; 5] = [
        &universal_tx_id[..],
        &tx_id[..],
        &mint_bytes[..],
        &recipient_bytes[..],
        &gas_fee_buf,
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

    // SECURITY: Validate token_vault is owned by vault and matches token_mint
    // Matches deposit flow validation style (lines 262-275 in deposit.rs)
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
        universal_tx_id,
        tx_id,
        fund_recipient: revert_instruction.fund_recipient,
        token: ctx.accounts.token_mint.key(),
        amount,
        revert_instruction: revert_instruction.clone(),
    });

    // Transfer gas_fee directly to caller
    if gas_fee > 0 {
        let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[ctx.accounts.config.vault_bump]];
        let fee_transfer_ix = system_instruction::transfer(
            &ctx.accounts.vault_sol.key(),
            &ctx.accounts.caller.key(),
            gas_fee,
        );

        anchor_lang::solana_program::program::invoke_signed(
            &fee_transfer_ix,
            &[
                ctx.accounts.vault_sol.to_account_info(),
                ctx.accounts.caller.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[vault_seeds],
        )?;
    }

    // Account creation via `init` constraint marks txID as executed
    // (atomic transaction ensures account only exists if execution succeeded)

    Ok(())
}
