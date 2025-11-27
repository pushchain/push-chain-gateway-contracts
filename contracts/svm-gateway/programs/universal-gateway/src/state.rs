use anchor_lang::prelude::*;

// PDA seeds
pub const CONFIG_SEED: &[u8] = b"config";
pub const VAULT_SEED: &[u8] = b"vault";
pub const WHITELIST_SEED: &[u8] = b"whitelist";
pub const TSS_SEED: &[u8] = b"tsspda";
pub const RATE_LIMIT_CONFIG_SEED: &[u8] = b"rate_limit_config";
pub const RATE_LIMIT_SEED: &[u8] = b"rate_limit";
pub const EXECUTED_TX_SEED: &[u8] = b"executed_tx";

// Price feed ID (Pyth SOL/USD), same as locker for now
pub const FEED_ID: &str = "ef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d";

/// Transaction types matching the EVM Universal Gateway `TX_TYPE`.
/// Kept 1:1 for relayer/event parity with the EVM implementation.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum TxType {
    /// GAS-only route; funds instant UEA gas on Push Chain. No payload execution or high-value movement.
    Gas,
    /// GAS + PAYLOAD route (instant). Low-value movement with caps. Executes payload via UEA.
    GasAndPayload,
    /// High-value FUNDS-only bridge (no payload). Requires longer finality.
    Funds,
    /// FUNDS + PAYLOAD bridge. Requires longer finality. No strict caps for funds (gas caps still apply).
    FundsAndPayload,
}

/// Epoch usage tracking for rate limiting (matching EVM EpochUsage struct)
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct EpochUsage {
    pub epoch: u64, // epoch index = block.timestamp / epochDurationSec
    pub used: u128, // amount consumed in this epoch (token's natural units)
}

/// Verification types for payload execution (parity with EVM).
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum VerificationType {
    SignedVerification,
    UniversalTxVerification,
}

/// Universal payload for cross-chain execution (parity with EVM `UniversalPayload`).
/// Serialized and hashed for event parity with EVM (payload bytes/hash).
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct UniversalPayload {
    pub to: [u8; 20], // Ethereum address (20 bytes)
    pub value: u64,
    pub data: Vec<u8>,
    pub gas_limit: u64,
    pub max_fee_per_gas: u64,
    pub max_priority_fee_per_gas: u64,
    pub nonce: u64,
    pub deadline: i64,
    pub v_type: VerificationType,
}

/// Revert instructions for failed transactions (parity with EVM `RevertInstructions`).
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct RevertInstructions {
    pub fund_recipient: Pubkey,
    pub revert_msg: Vec<u8>,
}

/// Universal transaction request (parity with EVM `UniversalTxRequest`).
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct UniversalTxRequest {
    pub recipient: [u8; 20], // [0u8; 20] => credit to UEA on Push
    pub token: Pubkey,       // Pubkey::default() => native SOL
    pub amount: u64,         // native or SPL amount for bridging - Funds
    pub payload: Vec<u8>,    // serialized payload (may be empty)
    pub revert_instruction: RevertInstructions,
    pub signature_data: Vec<u8>,
}

/// Gateway configuration state (authorities, caps, oracle).
/// PDA: `[b"config"]`. Holds USD caps (8 decimals) for gas-route deposits and oracle config.
#[account]
pub struct Config {
    pub admin: Pubkey,
    pub tss_address: Pubkey, // Not used - TODO: Remove
    pub pauser: Pubkey,
    pub min_cap_universal_tx_usd: u128, // 1e8 = $1 (Pyth format)
    pub max_cap_universal_tx_usd: u128, // 1e8 = $10 (Pyth format)
    pub paused: bool,
    pub bump: u8,
    pub vault_bump: u8,
    // Pyth oracle configuration
    pub pyth_price_feed: Pubkey,        // Pyth SOL/USD price feed
    pub pyth_confidence_threshold: u64, // Confidence threshold for price validation
}

impl Config {
    // discriminator + fields + padding
    // 8 + 32 + 32 + 32 + 16 + 16 + 1 + 1 + 1 + 32 + 8 + 100
    pub const LEN: usize = 8 + 32 + 32 + 32 + 16 + 16 + 1 + 1 + 1 + 32 + 8 + 100;
}

/// SPL token whitelist state.
/// PDA: `[b"whitelist"]`. Simple list of supported SPL mints.
#[account]
pub struct TokenWhitelist {
    pub tokens: Vec<Pubkey>,
    pub bump: u8,
}

impl TokenWhitelist {
    pub const LEN: usize = 8 + 4 + (32 * 50) + 1 + 100; // discriminator + vec length + 50 tokens max + bump + padding
}

/// Rate limiting configuration (separate account for backward compatibility)
/// PDA: `[b"rate_limit_config"]`. Stores global rate limiting settings.
#[account]
pub struct RateLimitConfig {
    pub block_usd_cap: u128,     // Per-block USD cap (8 decimals). 0 disables.
    pub epoch_duration_sec: u64, // Epoch duration in seconds for rate limiting
    pub last_slot: u64,          // Last slot for block-based cap tracking
    pub consumed_usd_in_block: u128, // USD consumed in current block
    pub bump: u8,
}

impl RateLimitConfig {
    pub const LEN: usize = 8 + 16 + 8 + 8 + 16 + 1 + 100; // discriminator + fields + bump + padding
}

/// Token-specific rate limiting state (matching EVM implementation)
/// PDA: `[b"rate_limit", token_mint]`. Tracks epoch-based usage per token.
#[account]
pub struct TokenRateLimit {
    pub token_mint: Pubkey,      // The SPL token mint
    pub limit_threshold: u128,   // Max amount per epoch (token's natural units)
    pub epoch_usage: EpochUsage, // Current epoch usage tracking
    pub bump: u8,
}

impl TokenRateLimit {
    pub const LEN: usize = 8 + 32 + 16 + 8 + 16 + 1 + 100; // discriminator + token_mint + limit_threshold + epoch + used + bump + padding
}

/// TSS state PDA for ECDSA verification (Ethereum-style secp256k1).
/// Stores 20-byte ETH address, chain id (Solana cluster pubkey as String), and replay-protection nonce.
#[account]
pub struct TssPda {
    pub tss_eth_address: [u8; 20],
    pub chain_id: String, // Solana cluster pubkey (e.g., "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d" for mainnet)
    pub nonce: u64,
    pub authority: Pubkey,
    pub bump: u8,
}

impl TssPda {
    // discriminator (8) + tss_eth_address (20) + chain_id String (4 + 64 max) + nonce (8) + authority (32) + bump (1)
    // String: 4 bytes length prefix + up to 64 bytes for cluster pubkey (base58, max ~44 chars, but allow buffer)
    pub const LEN: usize = 8 + 20 + 4 + 64 + 8 + 32 + 1;
}

/// Executed transaction tracker (parity with EVM `isExecuted[txID]` mapping).
/// PDA: `[b"executed_tx", tx_id]`.
/// Account existence = transaction executed (replay protection via `init` constraint).
#[account]
pub struct ExecutedTx {}

impl ExecutedTx {
    // discriminator (8) only - account existence is the flag
    pub const LEN: usize = 8;
}

/// Universal transaction event (parity with EVM V0 `UniversalTx`).
/// Single event for both gas funding and funds movement.
#[event]
pub struct UniversalTx {
    pub sender: Pubkey,
    pub recipient: [u8; 20], // Ethereum address (20 bytes)
    pub token: Pubkey,       // Bridge token (Pubkey::default() for native SOL)
    pub amount: u64,         // Bridge amount (not gas amount)
    pub payload: Vec<u8>,    // Payload data
    pub revert_instruction: RevertInstructions,
    pub tx_type: TxType,
    pub signature_data: Vec<u8>,
}

/// Withdraw event (parity with EVM `WithdrawToken`).
#[event]
pub struct WithdrawToken {
    pub tx_id: [u8; 32],         // Transaction ID
    pub origin_caller: [u8; 20], // Original caller on source chain (EVM address)
    pub token: Pubkey,           // Token address (Pubkey::default() for native SOL)
    pub to: Pubkey,              // Recipient address
    pub amount: u64,             // Amount
}

/// Revert withdraw event (parity with EVM `RevertUniversalTx`).
#[event]
pub struct RevertUniversalTx {
    pub tx_id: [u8; 32],        // Transaction ID
    pub fund_recipient: Pubkey, // Recipient of reverted funds
    pub token: Pubkey,          // Token address (Pubkey::default() for native SOL)
    pub amount: u64,            // Amount
    pub revert_instruction: RevertInstructions,
}

#[event]
pub struct TSSAddressUpdated {
    pub old_tss: Pubkey,
    pub new_tss: Pubkey,
}

#[event]
pub struct CapsUpdated {
    pub min_cap_usd: u128,
    pub max_cap_usd: u128,
}

// Rate limiting events
#[event]
pub struct BlockUsdCapUpdated {
    pub block_usd_cap: u128,
}

#[event]
pub struct EpochDurationUpdated {
    pub epoch_duration_sec: u64,
}

#[event]
pub struct TokenRateLimitUpdated {
    pub token_mint: Pubkey,
    pub limit_threshold: u128,
}

// Keep legacy if referenced; prefer TxWithGas above
