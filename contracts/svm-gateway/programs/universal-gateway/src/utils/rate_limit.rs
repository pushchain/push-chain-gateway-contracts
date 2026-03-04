use crate::errors::GatewayError;
use crate::state::{RateLimitConfig, TokenRateLimit};
use anchor_lang::prelude::*;

/// Check block-based USD cap (matching EVM _checkBlockUSDCap)
pub fn check_block_usd_cap(
    rate_limit_config: &mut Account<RateLimitConfig>,
    usd_amount: u128,
) -> Result<()> {
    // If block cap is 0, rate limiting is disabled
    if rate_limit_config.block_usd_cap == 0 {
        return Ok(());
    }

    let clock = Clock::get()?;
    let current_slot = clock.slot;

    // Reset if new slot (matching EVM: block.number != _lastBlockNumber)
    // Note: Multiple transactions can execute in the same slot in Solana.
    // Account serialization ensures writes are atomic, preventing race conditions.
    if current_slot != rate_limit_config.last_slot {
        rate_limit_config.consumed_usd_in_block = 0;
        rate_limit_config.last_slot = current_slot;
    }

    // Check if adding this amount would exceed the cap
    let new_consumed = rate_limit_config
        .consumed_usd_in_block
        .checked_add(usd_amount)
        .ok_or(GatewayError::BlockUsdCapExceeded)?;
    require!(new_consumed <= rate_limit_config.block_usd_cap, GatewayError::BlockUsdCapExceeded);

    // Update consumed amount
    rate_limit_config.consumed_usd_in_block = new_consumed;

    Ok(())
}

/// Consume rate limit for a token (matching EVM _consumeRateLimit)
pub fn consume_rate_limit(
    token_rate_limit: &mut Account<TokenRateLimit>,
    amount: u128,
    epoch_duration_sec: u64,
) -> Result<()> {
    let clock = Clock::get()?;
    let current_epoch = clock.unix_timestamp as u64 / epoch_duration_sec;

    // Reset if new epoch
    if current_epoch > token_rate_limit.epoch_usage.epoch {
        token_rate_limit.epoch_usage.epoch = current_epoch;
        token_rate_limit.epoch_usage.used = 0;
    }

    // Check if adding this amount would exceed the limit
    let new_used = token_rate_limit
        .epoch_usage
        .used
        .checked_add(amount)
        .ok_or(GatewayError::RateLimitExceeded)?;
    require!(new_used <= token_rate_limit.limit_threshold, GatewayError::RateLimitExceeded);

    // Update used amount
    token_rate_limit.epoch_usage.used = new_used;

    Ok(())
}

/// Validate token support and consume rate limit if enabled (EVM v0 parity)
/// @dev Checks if token is supported (limit_threshold > 0) and optionally consumes rate limit
///      if epoch_duration > 0. This consolidates the threshold check used in send_universal_tx routes.
pub fn validate_token_and_consume_rate_limit(
    token_rate_limit: &mut Account<TokenRateLimit>,
    expected_token_mint: Pubkey,
    amount: u128,
    rate_limit_config: &Account<RateLimitConfig>,
) -> Result<()> {
    // Validate token_rate_limit account matches expected token
    require!(
        token_rate_limit.token_mint == expected_token_mint,
        GatewayError::InvalidToken
    );

    // Threshold-based token support check (EVM v0 parity)
    // If limit_threshold == 0, token is not supported
    require!(
        token_rate_limit.limit_threshold > 0,
        GatewayError::NotSupported
    );

    // Epoch-based token rate limit (skip if disabled: epoch_duration == 0)
    let epoch_duration = rate_limit_config.epoch_duration_sec;
    if epoch_duration > 0 {
        consume_rate_limit(token_rate_limit, amount, epoch_duration)?;
    }

    Ok(())
}
