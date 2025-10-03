use crate::errors::GatewayError;
use crate::instructions::legacy::process_add_funds;
use crate::state::*;
use crate::utils::*;
use anchor_lang::prelude::*;
use anchor_lang::system_program;
use anchor_spl::token::{self, spl_token, Token, Transfer};
use pyth_solana_receiver_sdk::price_update::PriceUpdateV2;

// =========================
//           DEPOSITS
// =========================

/// GAS route (Instant): fund UEA on Push Chain with native SOL; optional payload.
/// Enforces USD caps via Pyth (8 decimals). Emits `TxWithGas`.
pub fn send_tx_with_gas(
    ctx: Context<SendTxWithGas>,
    payload: UniversalPayload,
    revert_instruction: RevertInstructions,
    amount: u64,
) -> Result<()> {
    let config = &ctx.accounts.config;
    let user = &ctx.accounts.user;
    let vault = &ctx.accounts.vault;

    // Check if paused
    require!(!config.paused, GatewayError::Paused);

    // Validate inputs
    require!(
        revert_instruction.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );

    // Use the amount parameter (equivalent to msg.value in ETH)
    let gas_amount = amount;
    require!(gas_amount > 0, GatewayError::InvalidAmount);

    // Check user has enough SOL
    require!(
        ctx.accounts.user.lamports() >= gas_amount,
        GatewayError::InsufficientBalance
    );

    // Check USD caps for gas deposits using Pyth oracle
    check_usd_caps(config, gas_amount, &ctx.accounts.price_update)?;

    // Transfer SOL to vault (like _handleNativeDeposit in ETH)
    let cpi_context = CpiContext::new(
        ctx.accounts.system_program.to_account_info(),
        system_program::Transfer {
            from: user.to_account_info(),
            to: vault.to_account_info(),
        },
    );
    system_program::transfer(cpi_context, gas_amount)?;

    // Calculate payload hash
    let _payload_hash = payload_hash(&payload);

    // Emit UniversalTx event (parity with EVM V0)
    emit!(UniversalTx {
        sender: user.key(),
        recipient: [0u8; 20],     // Zero address for gas funding
        token: Pubkey::default(), // Native SOL
        amount: gas_amount,
        payload: payload_to_bytes(&payload),
        revert_instruction,
        tx_type: TxType::GasAndPayload,
        signature_data: vec![], // Empty for gas-only route
    });

    Ok(())
}

/// FUNDS route (Universal): move funds to Push Chain (no payload).
/// Supports both native SOL and SPL tokens (like ETH Gateway). Emits `TxWithFunds`.
pub fn send_funds(
    ctx: Context<SendFunds>,
    recipient: [u8; 20],
    bridge_token: Pubkey,
    bridge_amount: u64,
    revert_instruction: RevertInstructions,
) -> Result<()> {
    let config = &ctx.accounts.config;
    let user = &ctx.accounts.user;
    let vault = &ctx.accounts.vault;

    // Check if paused
    require!(!config.paused, GatewayError::Paused);

    // Validate inputs
    require!(
        recipient != [0u8; 20], // Check for zero ETH address
        GatewayError::InvalidRecipient
    );
    require!(
        revert_instruction.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(bridge_amount > 0, GatewayError::InvalidAmount);

    // Handle both native SOL and SPL tokens (like ETH Gateway pattern)
    if bridge_token == Pubkey::default() {
        // Native SOL transfer
        require!(
            user.lamports() >= bridge_amount,
            GatewayError::InsufficientBalance
        );

        let cpi_context = CpiContext::new(
            ctx.accounts.system_program.to_account_info(),
            system_program::Transfer {
                from: user.to_account_info(),
                to: vault.to_account_info(),
            },
        );
        system_program::transfer(cpi_context, bridge_amount)?;
    } else {
        // SPL token transfer - Use same pattern as send_tx_with_funds
        let token_whitelist = &ctx.accounts.token_whitelist;
        require!(
            token_whitelist.tokens.contains(&bridge_token),
            GatewayError::TokenNotWhitelisted
        );

        // For SPL tokens, ensure accounts are owned by token program
        // (same pattern as send_tx_with_funds for consistency)
        let user_token_account_info = &ctx.accounts.user_token_account.to_account_info();
        let gateway_token_account_info = &ctx.accounts.gateway_token_account.to_account_info();

        require!(
            user_token_account_info.owner == &spl_token::ID,
            GatewayError::InvalidOwner
        );
        require!(
            gateway_token_account_info.owner == &spl_token::ID,
            GatewayError::InvalidOwner
        );

        // Additional validation will happen in the token::transfer CPI below
        // which will fail if mint doesn't match or accounts are invalid

        let cpi_context = CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            Transfer {
                from: ctx.accounts.user_token_account.to_account_info(),
                to: ctx.accounts.gateway_token_account.to_account_info(),
                authority: user.to_account_info(),
            },
        );
        token::transfer(cpi_context, bridge_amount)?;
    }

    // Emit UniversalTx event (parity with EVM V0)
    emit!(UniversalTx {
        sender: user.key(),
        recipient,
        token: bridge_token, // Pubkey::default() for native SOL, mint address for SPL
        amount: bridge_amount,
        payload: vec![], // Empty for funds-only route
        revert_instruction,
        tx_type: TxType::Funds,
        signature_data: vec![], // Empty for funds-only route
    });

    Ok(())
}

/// FUNDS+PAYLOAD route (Universal): bridge SPL/native + execute payload.
/// Gas amount uses USD caps; emits `TxWithGas` then `TxWithFunds`.
pub fn send_tx_with_funds(
    ctx: Context<SendTxWithFunds>,
    bridge_token: Pubkey,
    bridge_amount: u64,
    payload: UniversalPayload,
    revert_instruction: RevertInstructions,
    gas_amount: u64,
    signature_data: Vec<u8>,
) -> Result<()> {
    let config = &ctx.accounts.config;
    let user = &ctx.accounts.user;
    let vault = &ctx.accounts.vault;

    // Check if paused
    require!(!config.paused, GatewayError::Paused);

    // Validate inputs
    require!(bridge_amount > 0, GatewayError::InvalidAmount);
    require!(
        revert_instruction.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );

    require!(gas_amount > 0, GatewayError::InvalidAmount);
    check_usd_caps(config, gas_amount, &ctx.accounts.price_update)?;

    // For native SOL bridge, validate user has enough SOL for both gas and bridge upfront
    if bridge_token == Pubkey::default() {
        require!(
            ctx.accounts.user.lamports() >= bridge_amount + gas_amount,
            GatewayError::InsufficientBalance
        );
    }
    // For SPL tokens, only need SOL for gas (validated in process_add_funds)

    // Use legacy add_funds logic for gas deposits (like ETH Gateway V0)
    // This matches the ETH V0 pattern: _addFunds(bytes32(0), gasAmount)
    let gas_transaction_hash = [0u8; 32];

    // Instead of trying to build AddFunds struct, just call the logic directly
    process_add_funds(
        &ctx.accounts.config,
        &ctx.accounts.vault.to_account_info(), // Convert SystemAccount to AccountInfo
        &ctx.accounts.user,
        &ctx.accounts.price_update,
        &ctx.accounts.system_program,
        gas_amount,
        gas_transaction_hash,
    )?;

    // Handle bridge deposit
    if bridge_token == Pubkey::default() {
        // Native SOL bridge - gas already deducted via process_add_funds() above
        require!(
            ctx.accounts.user.lamports() >= bridge_amount,
            GatewayError::InsufficientBalance
        );

        let cpi_context = CpiContext::new(
            ctx.accounts.system_program.to_account_info(),
            system_program::Transfer {
                from: user.to_account_info(),
                to: vault.to_account_info(),
            },
        );
        system_program::transfer(cpi_context, bridge_amount)?;
    } else {
        // SPL token bridge - gas already deducted via process_add_funds() above
        // No additional SOL balance check needed since only SPL tokens are being transferred

        // Check if token is whitelisted
        let token_whitelist = &ctx.accounts.token_whitelist;
        require!(
            token_whitelist.tokens.contains(&bridge_token),
            GatewayError::TokenNotWhitelisted
        );

        // For SPL tokens, validate basic account ownership - detailed validation
        // happens in the transfer CPI which will fail if accounts are invalid
        let user_token_account_info = &ctx.accounts.user_token_account.to_account_info();
        let gateway_token_account_info = &ctx.accounts.gateway_token_account.to_account_info();

        // Basic validation: ensure accounts are owned by token program
        require!(
            user_token_account_info.owner == &spl_token::ID,
            GatewayError::InvalidOwner
        );
        require!(
            gateway_token_account_info.owner == &spl_token::ID,
            GatewayError::InvalidOwner
        );

        // Additional validation will happen in the token::transfer CPI below
        // which will fail if mint doesn't match or accounts are invalid

        // Transfer SPL tokens to gateway vault
        let cpi_context = CpiContext::new(
            ctx.accounts.token_program.to_account_info(),
            Transfer {
                from: ctx.accounts.user_token_account.to_account_info(),
                to: ctx.accounts.gateway_token_account.to_account_info(),
                authority: user.to_account_info(),
            },
        );
        token::transfer(cpi_context, bridge_amount)?;
    }

    // Calculate payload hash
    let _payload_hash = payload_hash(&payload);

    // Emit UniversalTx event for bridge + payload (parity with EVM V0)
    emit!(UniversalTx {
        sender: user.key(),
        recipient: [0u8; 20], // EVM zero address for payload execution
        token: bridge_token,
        amount: bridge_amount,
        payload: payload_to_bytes(&payload),
        revert_instruction,
        tx_type: TxType::FundsAndPayload,
        signature_data, // Use the provided signature data
    });

    Ok(())
}

// =========================
//        ACCOUNT STRUCTS
// =========================

#[derive(Accounts)]
pub struct SendTxWithGas<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        seeds = [VAULT_SEED],
        bump = config.vault_bump,
    )]
    pub vault: SystemAccount<'info>,

    #[account(mut)]
    pub user: Signer<'info>,

    // Pyth price update account for USD cap validation
    pub price_update: Account<'info, PriceUpdateV2>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct SendFunds<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        seeds = [VAULT_SEED],
        bump = config.vault_bump,
    )]
    pub vault: SystemAccount<'info>,

    #[account(
        seeds = [WHITELIST_SEED],
        bump,
    )]
    pub token_whitelist: Account<'info, TokenWhitelist>,

    /// CHECK: For native SOL, this can be any account. For SPL tokens, must be valid token account.
    #[account(mut)]
    pub user_token_account: UncheckedAccount<'info>,

    /// CHECK: For native SOL, this can be any account. For SPL tokens, must be valid token account.
    #[account(mut)]
    pub gateway_token_account: UncheckedAccount<'info>,

    #[account(mut)]
    pub user: Signer<'info>,

    /// CHECK: Can be either a token mint (for SPL) or Pubkey::default() (for native SOL)
    pub bridge_token: UncheckedAccount<'info>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct SendTxWithFunds<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
    )]
    pub config: Account<'info, Config>,

    #[account(
        mut,
        seeds = [VAULT_SEED],
        bump = config.vault_bump,
    )]
    pub vault: SystemAccount<'info>,

    #[account(
        seeds = [WHITELIST_SEED],
        bump,
    )]
    pub token_whitelist: Account<'info, TokenWhitelist>,

    /// CHECK: For native SOL, this can be any account. For SPL tokens, must be valid token account.
    #[account(mut)]
    pub user_token_account: UncheckedAccount<'info>,

    /// CHECK: For native SOL, this can be any account. For SPL tokens, must be valid token account.
    #[account(mut)]
    pub gateway_token_account: UncheckedAccount<'info>,

    #[account(mut)]
    pub user: Signer<'info>,

    // Pyth price update account for USD cap validation
    pub price_update: Account<'info, PriceUpdateV2>,

    /// CHECK: Can be either a token mint (for SPL) or Pubkey::default() (for native SOL)
    pub bridge_token: UncheckedAccount<'info>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}
