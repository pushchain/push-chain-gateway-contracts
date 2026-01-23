use crate::errors::GatewayError;
use crate::state::{
    Config, EpochUsage, RateLimitConfig, TokenRateLimit, UniversalPayload, FEED_ID, RATE_LIMIT_SEED,
};
use anchor_lang::prelude::*;
use pyth_solana_receiver_sdk::price_update::{get_feed_id_from_hex, PriceUpdateV2};

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct PriceData {
    pub price: i64,        // Raw price from Pyth
    pub exponent: i32,     // Exponent to apply
    pub publish_time: i64, // When the price was published
    pub confidence: u64,   // Price confidence interval
}

pub fn calculate_sol_price(price_update: &Account<PriceUpdateV2>) -> Result<PriceData> {
    let price = price_update
        .get_price_unchecked(&get_feed_id_from_hex(FEED_ID)?) //TODO check time in mainnet
        .map_err(|_| error!(GatewayError::InvalidPrice))?;

    require!(price.price > 0, GatewayError::InvalidPrice);

    Ok(PriceData {
        price: price.price,
        exponent: price.exponent,
        publish_time: price.publish_time,
        confidence: price.conf,
    })
}

// Convert lamports (1e9) to USD using Pyth price (price + exponent)
pub fn lamports_to_usd_amount_i128(lamports: u64, price: &PriceData) -> i128 {
    // Keep same approach as locker (raw integer with exponent)
    let sol_amount_f64 = lamports as f64 / 1_000_000_000.0;
    let price_f64 = price.price as f64;
    (sol_amount_f64 * price_f64).round() as i128
}

// Check USD caps for gas deposits (matching ETH contract logic) with Pyth oracle
pub fn check_usd_caps_with_pyth(
    config: &Config,
    lamports: u64,
    price_data: &PriceData,
) -> Result<()> {
    // Calculate USD equivalent using Pyth price (same logic as locker)
    let sol_amount_f64 = lamports as f64 / 1_000_000_000.0; // Convert lamports to SOL
    let price_f64 = price_data.price as f64;
    let usd_amount_raw = (sol_amount_f64 * price_f64).round() as i128;

    // Convert to 8 decimal precision for config comparison
    // Pyth typically uses -8 exponent, so we need to adjust
    let usd_amount_8dec = if price_data.exponent >= -8 {
        // If exponent is -8 or higher, we need to scale down
        let scale_factor = 10_i128.pow((price_data.exponent + 8) as u32);
        (usd_amount_raw / scale_factor) as u128
    } else {
        // If exponent is lower than -8, we need to scale up
        let scale_factor = 10_i128.pow((-8 - price_data.exponent) as u32);
        (usd_amount_raw * scale_factor) as u128
    };

    require!(
        usd_amount_8dec >= config.min_cap_universal_tx_usd,
        GatewayError::BelowMinCap
    );
    require!(
        usd_amount_8dec <= config.max_cap_universal_tx_usd,
        GatewayError::AboveMaxCap
    );

    Ok(())
}

// Check USD caps for gas deposits - ONLY Pyth, no fallback
pub fn check_usd_caps(
    config: &Config,
    lamports: u64,
    price_update: &Account<PriceUpdateV2>,
) -> Result<()> {
    // Get real-time SOL price from Pyth oracle (exactly like locker)
    let price_data = calculate_sol_price(price_update)?;

    // Use the Pyth function for USD cap check
    check_usd_caps_with_pyth(config, lamports, &price_data)
}

/// Calculate USD amount from SOL amount using price data (matching EVM implementation)
/// @dev Pyth price format: actual_price = price * 10^exponent
///      For SOL/USD: price = 15025000000, exponent = -8 → actual_price = 150.25 USD
///      Result is in 8 decimals (matching EVM's 18 decimals but scaled to 8 for consistency)
///      Formula: USD_8dec = (lamports * price * 10^(exponent + 8)) / 1e9
pub fn calculate_usd_amount(lamports: u64, price_data: &PriceData) -> Result<u128> {
    let lamports_u128 = lamports as u128;
    let price_u128 = price_data.price as u128;

    // Multiply first to preserve precision, then apply exponent adjustment
    // For exponent = -8: we need to multiply by 10^(exponent + 8) = 10^0 = 1
    let product = lamports_u128
        .checked_mul(price_u128)
        .ok_or(GatewayError::InvalidAmount)?;

    // Apply exponent: multiply by 10^(exponent + 8) to get result in 8 decimals
    let exponent_adjustment = (price_data.exponent + 8) as i32;

    let usd_amount = if exponent_adjustment >= 0 {
        product
            .checked_mul(10u128.pow(exponent_adjustment as u32))
            .and_then(|x| x.checked_div(1_000_000_000))
            .ok_or(GatewayError::InvalidAmount)?
    } else {
        product
            .checked_div(10u128.pow((-exponent_adjustment) as u32))
            .and_then(|x| x.checked_div(1_000_000_000))
            .ok_or(GatewayError::InvalidAmount)?
    };

    Ok(usd_amount)
}

// Calculate payload hash (matching ETH contract keccak256(abi.encode(payload)))
pub fn payload_hash(payload: &UniversalPayload) -> [u8; 32] {
    // Use Solana's sha256 to hash the serialized payload (closest to keccak256)
    let serialized = payload.try_to_vec().unwrap_or_default();
    anchor_lang::solana_program::hash::hash(&serialized).to_bytes()
}

// Convert payload to bytes (matching ETH contract)
pub fn payload_to_bytes(payload: &UniversalPayload) -> Vec<u8> {
    payload.try_to_vec().unwrap_or_default()
}

// =========================
// RATE LIMITING FUNCTIONS
// =========================

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
    require!(
        rate_limit_config.consumed_usd_in_block + usd_amount <= rate_limit_config.block_usd_cap,
        GatewayError::BlockUsdCapExceeded
    );

    // Update consumed amount
    rate_limit_config.consumed_usd_in_block += usd_amount;

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
    require!(
        token_rate_limit.epoch_usage.used + amount <= token_rate_limit.limit_threshold,
        GatewayError::RateLimitExceeded
    );

    // Update used amount
    token_rate_limit.epoch_usage.used += amount;

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

/// Get or create rate limit config account (backward compatible)
pub fn get_or_create_rate_limit_config<'info>(
    accounts: &'info [AccountInfo<'info>],
    program_id: &Pubkey,
) -> Result<Option<Account<'info, RateLimitConfig>>> {
    let (rate_limit_config_pda, _bump) =
        Pubkey::find_program_address(&[crate::state::RATE_LIMIT_CONFIG_SEED], program_id);

    // Find the rate limit config account in the accounts list
    let rate_limit_config_account = accounts
        .iter()
        .find(|account| account.key() == rate_limit_config_pda);

    match rate_limit_config_account {
        Some(account) => {
            if account.data_is_empty() {
                // Account doesn't exist, rate limiting is disabled
                Ok(None)
            } else {
                // Account exists, load it
                Ok(Some(Account::<RateLimitConfig>::try_from(account)?))
            }
        }
        None => {
            // Account not provided, rate limiting is disabled
            Ok(None)
        }
    }
}

/// Get or create token rate limit account (matching EVM pattern)
pub fn get_or_create_token_rate_limit<'info>(
    token_mint: Pubkey,
    limit_threshold: u128,
    accounts: &'info [AccountInfo<'info>],
    program_id: &Pubkey,
) -> Result<Account<'info, TokenRateLimit>> {
    let (rate_limit_pda, bump) =
        Pubkey::find_program_address(&[RATE_LIMIT_SEED, token_mint.as_ref()], program_id);

    // Find the rate limit account in the accounts list
    let rate_limit_account = accounts
        .iter()
        .find(|account| account.key() == rate_limit_pda)
        .ok_or(GatewayError::InvalidAccount)?;

    // Check if account exists and is initialized
    if rate_limit_account.data_is_empty() {
        // Account doesn't exist, create it
        let mut rate_limit = Account::<TokenRateLimit>::try_from(rate_limit_account)?;
        rate_limit.token_mint = token_mint;
        rate_limit.limit_threshold = limit_threshold;
        rate_limit.epoch_usage = EpochUsage { epoch: 0, used: 0 };
        rate_limit.bump = bump;
        Ok(rate_limit)
    } else {
        // Account exists, load it
        Account::<TokenRateLimit>::try_from(rate_limit_account)
    }
}

/// Get token rate limit account if it exists (optional, for backward compatibility)
pub fn get_token_rate_limit_optional<'info>(
    token_mint: Pubkey,
    accounts: &'info [AccountInfo<'info>],
    program_id: &Pubkey,
) -> Result<Option<Account<'info, TokenRateLimit>>> {
    let (rate_limit_pda, _bump) =
        Pubkey::find_program_address(&[RATE_LIMIT_SEED, token_mint.as_ref()], program_id);

    // Find the rate limit account in the accounts list
    let rate_limit_account = accounts
        .iter()
        .find(|account| account.key() == rate_limit_pda);

    match rate_limit_account {
        Some(account) => {
            if account.data_is_empty() {
                // Account doesn't exist, rate limiting is disabled for this token
                Ok(None)
            } else {
                // Account exists, load it
                Ok(Some(Account::<TokenRateLimit>::try_from(account)?))
            }
        }
        None => {
            // Account not provided, rate limiting is disabled for this token
            Ok(None)
        }
    }
}
