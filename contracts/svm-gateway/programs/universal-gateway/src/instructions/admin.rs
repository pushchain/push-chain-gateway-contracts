use crate::{errors::*, state::*};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct AdminAction<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
        constraint = config.admin == admin.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    pub admin: Signer<'info>,
}

#[derive(Accounts)]
pub struct PauseAction<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = config.pauser == pauser.key() || config.admin == pauser.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    pub pauser: Signer<'info>,
}

pub fn pause(ctx: Context<PauseAction>) -> Result<()> {
    ctx.accounts.config.paused = true;
    Ok(())
}

pub fn unpause(ctx: Context<PauseAction>) -> Result<()> {
    ctx.accounts.config.paused = false;
    Ok(())
}

pub fn set_tss_address(ctx: Context<AdminAction>, new_tss: Pubkey) -> Result<()> {
    require!(new_tss != Pubkey::default(), GatewayError::ZeroAddress);
    ctx.accounts.config.tss_address = new_tss;
    Ok(())
}

pub fn set_caps_usd(ctx: Context<AdminAction>, min_cap_usd: u128, max_cap_usd: u128) -> Result<()> {
    require!(min_cap_usd <= max_cap_usd, GatewayError::InvalidCapRange);
    let config = &mut ctx.accounts.config;
    config.min_cap_universal_tx_usd = min_cap_usd;
    config.max_cap_universal_tx_usd = max_cap_usd;

    // Emit caps updated event
    emit!(crate::state::CapsUpdated {
        min_cap_usd,
        max_cap_usd,
    });

    Ok(())
}

#[derive(Accounts)]
pub struct WhitelistAction<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
        constraint = config.admin == admin.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    #[account(
        init_if_needed,
        payer = admin,
        space = TokenWhitelist::LEN,
        seeds = [WHITELIST_SEED],
        bump
    )]
    pub whitelist: Account<'info, TokenWhitelist>,

    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

pub fn whitelist_token(ctx: Context<WhitelistAction>, token: Pubkey) -> Result<()> {
    require!(token != Pubkey::default(), GatewayError::ZeroAddress);

    let whitelist = &mut ctx.accounts.whitelist;

    // Check if token is already whitelisted
    if whitelist.tokens.contains(&token) {
        return Err(GatewayError::TokenAlreadyWhitelisted.into());
    }

    // Add token to whitelist
    whitelist.tokens.push(token);

    Ok(())
}

pub fn remove_whitelist_token(ctx: Context<WhitelistAction>, token: Pubkey) -> Result<()> {
    require!(token != Pubkey::default(), GatewayError::ZeroAddress);

    let whitelist = &mut ctx.accounts.whitelist;

    // Find and remove token from whitelist
    if let Some(pos) = whitelist.tokens.iter().position(|&x| x == token) {
        whitelist.tokens.remove(pos);
    } else {
        return Err(GatewayError::TokenNotWhitelisted.into());
    }

    Ok(())
}

// Pyth oracle configuration functions
pub fn set_pyth_price_feed(ctx: Context<AdminAction>, price_feed: Pubkey) -> Result<()> {
    require!(price_feed != Pubkey::default(), GatewayError::ZeroAddress);
    ctx.accounts.config.pyth_price_feed = price_feed;
    Ok(())
}

pub fn set_pyth_confidence_threshold(ctx: Context<AdminAction>, threshold: u64) -> Result<()> {
    require!(threshold > 0, GatewayError::InvalidAmount);
    ctx.accounts.config.pyth_confidence_threshold = threshold;
    Ok(())
}

// =========================
// RATE LIMITING ADMIN FUNCTIONS
// =========================

/// Set block-based USD cap for rate limiting (matching EVM setBlockUsdCap)
#[derive(Accounts)]
pub struct RateLimitConfigAction<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
        constraint = config.admin == admin.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    #[account(
        init_if_needed,
        payer = admin,
        space = RateLimitConfig::LEN,
        seeds = [RATE_LIMIT_CONFIG_SEED],
        bump
    )]
    pub rate_limit_config: Account<'info, RateLimitConfig>,

    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

pub fn set_block_usd_cap(ctx: Context<RateLimitConfigAction>, block_usd_cap: u128) -> Result<()> {
    let rate_limit_config = &mut ctx.accounts.rate_limit_config;
    rate_limit_config.block_usd_cap = block_usd_cap;
    rate_limit_config.bump = ctx.bumps.rate_limit_config;

    // Emit event
    emit!(BlockUsdCapUpdated { block_usd_cap });

    Ok(())
}

/// Update epoch duration for rate limiting (matching EVM updateEpochDuration)
/// @param epoch_duration_sec Epoch duration in seconds. Set to 0 to disable epoch-based rate limiting.
pub fn update_epoch_duration(
    ctx: Context<RateLimitConfigAction>,
    epoch_duration_sec: u64,
) -> Result<()> {
    // Allow 0 to disable epoch-based rate limiting
    let rate_limit_config = &mut ctx.accounts.rate_limit_config;
    rate_limit_config.epoch_duration_sec = epoch_duration_sec;
    rate_limit_config.bump = ctx.bumps.rate_limit_config;

    // Emit event
    emit!(EpochDurationUpdated { epoch_duration_sec });

    Ok(())
}

/// Set token-specific rate limit threshold (matching EVM setTokenToLimitThreshold)
#[derive(Accounts)]
pub struct TokenRateLimitAction<'info> {
    #[account(
        mut,
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = !config.paused @ GatewayError::PausedError,
        constraint = config.admin == admin.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    #[account(
        init_if_needed,
        payer = admin,
        space = TokenRateLimit::LEN,
        seeds = [RATE_LIMIT_SEED, token_mint.key().as_ref()],
        bump
    )]
    pub token_rate_limit: Account<'info, TokenRateLimit>,

    /// CHECK: Token mint address
    pub token_mint: UncheckedAccount<'info>,

    #[account(mut)]
    pub admin: Signer<'info>,
    pub system_program: Program<'info, System>,
}

/// Set token-specific rate limit threshold (matching EVM setTokenToLimitThreshold)
/// @param limit_threshold Max amount per epoch (token's natural units). Set to 0 to disable rate limiting for this token.
pub fn set_token_rate_limit(
    ctx: Context<TokenRateLimitAction>,
    limit_threshold: u128,
) -> Result<()> {
    // Allow limit_threshold = 0 to disable rate limiting (matching EVM behavior)
    let token_rate_limit = &mut ctx.accounts.token_rate_limit;
    token_rate_limit.token_mint = ctx.accounts.token_mint.key();
    token_rate_limit.limit_threshold = limit_threshold;
    token_rate_limit.epoch_usage = EpochUsage { epoch: 0, used: 0 };

    // Emit event
    emit!(TokenRateLimitUpdated {
        token_mint: ctx.accounts.token_mint.key(),
        limit_threshold,
    });

    Ok(())
}
