use anchor_lang::prelude::*;

pub mod errors;
pub mod instructions;
pub mod state;
pub mod utils;

use instructions::*;

declare_id!("CFVSincHYbETh2k7w6u1ENEkjbSLtveRCEBupKidw2VS");

#[program]
pub mod universal_gateway {
    use super::*;

    // =========================
    //           DEPOSITS
    // =========================

    /// @notice Universal transaction entrypoint with internal routing (EVM parity).
    /// @dev    Native amount parameter mirrors `msg.value` on EVM chains.
    ///         All routing (gas / funds / batching) is handled inside the deposit module.
    pub fn send_universal_tx(
        ctx: Context<SendUniversalTx>,
        req: UniversalTxRequest,
        native_amount: u64,
    ) -> Result<()> {
        instructions::deposit::send_universal_tx(ctx, req, native_amount)
    }

    // =========================
    //        WITHDRAWALS
    // =========================

    // =========================
    //           ADMIN
    // =========================

    /// @notice Initialize the gateway
    pub fn initialize(
        ctx: Context<Initialize>,
        admin: Pubkey,
        pauser: Pubkey,
        tss: Pubkey,
        min_cap_usd: u128,
        max_cap_usd: u128,
        pyth_price_feed: Pubkey,
    ) -> Result<()> {
        instructions::initialize::initialize(
            ctx,
            admin,
            pauser,
            tss,
            min_cap_usd,
            max_cap_usd,
            pyth_price_feed,
        )
    }

    /// @notice Pause the gateway
    pub fn pause(ctx: Context<PauseAction>) -> Result<()> {
        instructions::admin::pause(ctx)
    }

    /// @notice Unpause the gateway
    pub fn unpause(ctx: Context<PauseAction>) -> Result<()> {
        instructions::admin::unpause(ctx)
    }

    /// @notice Set USD caps
    pub fn set_caps_usd(ctx: Context<AdminAction>, min_cap: u128, max_cap: u128) -> Result<()> {
        instructions::admin::set_caps_usd(ctx, min_cap, max_cap)
    }

    /// @notice Whitelist a token
    pub fn whitelist_token(ctx: Context<WhitelistAction>, token: Pubkey) -> Result<()> {
        instructions::admin::whitelist_token(ctx, token)
    }

    /// @notice Remove token from whitelist
    pub fn remove_whitelist_token(ctx: Context<WhitelistAction>, token: Pubkey) -> Result<()> {
        instructions::admin::remove_whitelist_token(ctx, token)
    }

    /// @notice Set Pyth price feed
    pub fn set_pyth_price_feed(ctx: Context<AdminAction>, price_feed: Pubkey) -> Result<()> {
        instructions::admin::set_pyth_price_feed(ctx, price_feed)
    }

    /// @notice Set Pyth confidence threshold
    pub fn set_pyth_confidence_threshold(ctx: Context<AdminAction>, threshold: u64) -> Result<()> {
        instructions::admin::set_pyth_confidence_threshold(ctx, threshold)
    }

    // =========================
    //        RATE LIMITING
    // =========================

    /// @notice Set block-based USD cap for rate limiting
    pub fn set_block_usd_cap(
        ctx: Context<RateLimitConfigAction>,
        block_usd_cap: u128,
    ) -> Result<()> {
        instructions::admin::set_block_usd_cap(ctx, block_usd_cap)
    }

    /// @notice Update epoch duration for rate limiting
    pub fn update_epoch_duration(
        ctx: Context<RateLimitConfigAction>,
        epoch_duration_sec: u64,
    ) -> Result<()> {
        instructions::admin::update_epoch_duration(ctx, epoch_duration_sec)
    }

    /// @notice Set token-specific rate limit threshold
    /// @dev For batch operations, call this function multiple times in a single transaction.
    ///      This is the Solana-idiomatic approach and provides better type safety than using remaining_accounts.
    pub fn set_token_rate_limit(
        ctx: Context<TokenRateLimitAction>,
        limit_threshold: u128,
    ) -> Result<()> {
        instructions::admin::set_token_rate_limit(ctx, limit_threshold)
    }

    // =========================
    //             TSS
    // =========================
    pub fn init_tss(
        ctx: Context<InitTss>,
        tss_eth_address: [u8; 20],
        chain_id: String,
    ) -> Result<()> {
        instructions::tss::init_tss(ctx, tss_eth_address, chain_id)
    }

    pub fn update_tss(
        ctx: Context<UpdateTss>,
        tss_eth_address: [u8; 20],
        chain_id: String,
    ) -> Result<()> {
        instructions::tss::update_tss(ctx, tss_eth_address, chain_id)
    }

    pub fn reset_nonce(ctx: Context<ResetNonce>, new_nonce: u64) -> Result<()> {
        instructions::tss::reset_nonce(ctx, new_nonce)
    }

    // =========================
    //        WITHDRAW
    // =========================
    /// @notice TSS-verified withdraw of native SOL (EVM parity: `withdraw`)
    /// @param tx_id Transaction ID for tracking
    /// @param universal_tx_id Universal transaction ID from source chain
    /// @param origin_caller Original caller on source chain (EVM address, 20 bytes)
    pub fn withdraw(
        ctx: Context<Withdraw>,
        tx_id: [u8; 32],
        universal_tx_id: [u8; 32],
        origin_caller: [u8; 20],
        amount: u64,
        gas_fee: u64,
        signature: [u8; 64],
        recovery_id: u8,
        message_hash: [u8; 32],
        nonce: u64,
    ) -> Result<()> {
        instructions::withdraw::withdraw(
            ctx,
            tx_id,
            universal_tx_id,
            origin_caller,
            amount,
            gas_fee,
            signature,
            recovery_id,
            message_hash,
            nonce,
        )
    }

    /// @notice TSS-verified withdraw of SPL tokens (EVM parity: `withdrawTokens`)
    /// @param tx_id Transaction ID for tracking
    /// @param universal_tx_id Universal transaction ID from source chain
    /// @param origin_caller Original caller on source chain (EVM address, 20 bytes)
    pub fn withdraw_tokens(
        ctx: Context<WithdrawTokens>,
        tx_id: [u8; 32],
        universal_tx_id: [u8; 32],
        origin_caller: [u8; 20],
        amount: u64,
        gas_fee: u64,
        signature: [u8; 64],
        recovery_id: u8,
        message_hash: [u8; 32],
        nonce: u64,
    ) -> Result<()> {
        instructions::withdraw::withdraw_tokens(
            ctx,
            tx_id,
            universal_tx_id,
            origin_caller,
            amount,
            gas_fee,
            signature,
            recovery_id,
            message_hash,
            nonce,
        )
    }

    // =========================
    //        REVERT
    // =========================
    /// @notice TSS-verified revert withdraw for SOL (EVM parity: `revertUniversalTx`)
    /// @param tx_id Transaction ID for tracking
    /// @param universal_tx_id Universal transaction ID from source chain
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
        instructions::withdraw::revert_universal_tx(
            ctx,
            tx_id,
            universal_tx_id,
            amount,
            revert_instruction,
            gas_fee,
            signature,
            recovery_id,
            message_hash,
            nonce,
        )
    }

    /// @notice TSS-verified revert withdraw for SPL tokens (EVM parity: `revertUniversalTxToken`)
    /// @param tx_id Transaction ID for tracking
    /// @param universal_tx_id Universal transaction ID from source chain
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
        instructions::withdraw::revert_universal_tx_token(
            ctx,
            tx_id,
            universal_tx_id,
            amount,
            revert_instruction,
            gas_fee,
            signature,
            recovery_id,
            message_hash,
            nonce,
        )
    }

    // =========================
    //        EXECUTE
    // =========================
    /// @notice TSS-verified execute arbitrary Solana instruction with SOL
    /// @param tx_id Transaction ID from Push chain event
    /// @param universal_tx_id Universal transaction ID from source chain
    /// @param amount Amount of SOL to transfer to cea authority
    /// @param target_program Target Solana program to invoke
    /// @param sender EVM sender address (same as origin_caller in EVM)
    /// @param accounts Ordered list of accounts for target program
    /// @param ix_data Instruction data for target program
    pub fn execute_universal_tx(
        ctx: Context<ExecuteUniversalTx>,
        tx_id: [u8; 32],
        universal_tx_id: [u8; 32],
        amount: u64,
        target_program: Pubkey,
        sender: [u8; 20],
        writable_flags: Vec<u8>,
        ix_data: Vec<u8>,
        gas_fee: u64,
        rent_fee: u64,
        signature: [u8; 64],
        recovery_id: u8,
        message_hash: [u8; 32],
        nonce: u64,
    ) -> Result<()> {
        instructions::execute::execute_universal_tx(
            ctx,
            tx_id,
            universal_tx_id,
            amount,
            target_program,
            sender,
            writable_flags,
            ix_data,
            gas_fee,
            rent_fee,
            signature,
            recovery_id,
            message_hash,
            nonce,
        )
    }

    /// @notice TSS-verified execute arbitrary Solana instruction with SPL tokens
    /// @param tx_id Transaction ID from Push chain event
    /// @param universal_tx_id Universal transaction ID from source chain
    /// @param amount Amount of SPL tokens to transfer to cea ATA
    /// @param target_program Target Solana program to invoke
    /// @param sender EVM sender address (same as origin_caller in EVM)
    /// @param accounts Ordered list of accounts for target program
    /// @param ix_data Instruction data for target program
    pub fn execute_universal_tx_token(
        ctx: Context<ExecuteUniversalTxToken>,
        tx_id: [u8; 32],
        universal_tx_id: [u8; 32],
        amount: u64,
        target_program: Pubkey,
        sender: [u8; 20],
        writable_flags: Vec<u8>,
        ix_data: Vec<u8>,
        gas_fee: u64,
        rent_fee: u64,
        signature: [u8; 64],
        recovery_id: u8,
        message_hash: [u8; 32],
        nonce: u64,
    ) -> Result<()> {
        instructions::execute::execute_universal_tx_token(
            ctx,
            tx_id,
            universal_tx_id,
            amount,
            target_program,
            sender,
            writable_flags,
            ix_data,
            gas_fee,
            rent_fee,
            signature,
            recovery_id,
            message_hash,
            nonce,
        )
    }

    // =========================
    //         UTILS
    // =========================
    /// @notice View function for SOL price (locker-compatible)
    /// @dev    Anyone can fetch SOL price in USD
    pub fn get_sol_price(ctx: Context<GetSolPrice>) -> Result<PriceData> {
        utils::get_sol_price(&ctx.accounts.price_update)
    }
}

/// Accounts for get_sol_price view function
#[derive(Accounts)]
pub struct GetSolPrice<'info> {
    pub price_update: Account<'info, pyth_solana_receiver_sdk::price_update::PriceUpdateV2>,
}

// Re-export account structs and types
pub use instructions::admin::{
    AdminAction, PauseAction, RateLimitConfigAction, TokenRateLimitAction, WhitelistAction,
};
pub use instructions::deposit::SendUniversalTx;
pub use instructions::execute::{ExecuteUniversalTx, ExecuteUniversalTxToken};
pub use instructions::initialize::Initialize;
pub use instructions::withdraw::{
    RevertUniversalTx, RevertUniversalTxToken, Withdraw, WithdrawTokens,
};
pub use utils::PriceData;

pub use state::{
    // Events
    CapsUpdated,
    Config,
    ExecuteMessage,
    ExecutedTx,
    GatewayAccountMeta,
    RevertInstructions,
    TSSAddressUpdated,
    TokenWhitelist,
    TxType,
    UniversalPayload,
    UniversalTx,
    UniversalTxExecuted,
    UniversalTxRequest,
    VerificationType,
    WithdrawToken,
    CONFIG_SEED,
    EXECUTED_TX_SEED,
    FEED_ID,
    VAULT_SEED,
    WHITELIST_SEED,
};
