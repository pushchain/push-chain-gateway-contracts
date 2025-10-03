use anchor_lang::prelude::*;

// PDA seeds
pub const CONFIG_SEED: &[u8] = b"config";
pub const VAULT_SEED: &[u8] = b"vault";
pub const WHITELIST_SEED: &[u8] = b"whitelist";
pub const TSS_SEED: &[u8] = b"tss";

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

/// Gateway configuration state (authorities, caps, oracle).
/// PDA: `[b"config"]`. Holds USD caps (8 decimals) for gas-route deposits and oracle config.
#[account]
pub struct Config {
    pub admin: Pubkey,
    pub tss_address: Pubkey,
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

/// TSS state PDA for ECDSA verification (Ethereum-style secp256k1).
/// Stores 20-byte ETH address, chain id, and replay-protection nonce.
#[account]
pub struct TssPda {
    pub tss_eth_address: [u8; 20],
    pub chain_id: u64,
    pub nonce: u64,
    pub authority: Pubkey,
    pub bump: u8,
}

impl TssPda {
    pub const LEN: usize = 8 + 20 + 8 + 8 + 32 + 1;
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

/// Withdraw event (parity with EVM `WithdrawFunds`).
#[event]
pub struct WithdrawFunds {
    pub recipient: Pubkey,
    pub amount: u64,
    pub token: Pubkey,
}

#[event]
pub struct TSSAddressUpdated {
    pub old_tss: Pubkey,
    pub new_tss: Pubkey,
}

#[event]
pub struct TokenWhitelisted {
    pub token_address: Pubkey,
}

#[event]
pub struct TokenRemovedFromWhitelist {
    pub token_address: Pubkey,
}

#[event]
pub struct CapsUpdated {
    pub min_cap_usd: u128,
    pub max_cap_usd: u128,
}

// Keep legacy if referenced; prefer TxWithGas above
