use anchor_lang::prelude::*;

pub mod errors;
pub mod instructions;
pub mod state;
pub mod utils;

use instructions::*;

declare_id!("DJoFYDpgbTfxbXBv1QYhYGc9FK4J5FUKpYXAfSkHryXp");

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

    // =========================
    //    FINALIZE UNIVERSAL TX
    // =========================
    /// @notice Unified outbound entrypoint: withdraw (mode 1) or execute (mode 2)
    /// @param instruction_id 1=withdraw (vault→CEA→recipient), 2=execute (vault→CEA→CPI)
    pub fn finalize_universal_tx(
        ctx: Context<FinalizeUniversalTx>,
        instruction_id: u8,
        sub_tx_id: [u8; 32],
        universal_tx_id: [u8; 32],
        amount: u64,
        push_account: [u8; 20],
        writable_flags: Vec<u8>,
        ix_data: Vec<u8>,
        gas_fee: u64,
        rent_fee: u64,
        signature: [u8; 64],
        recovery_id: u8,
        message_hash: [u8; 32],
    ) -> Result<()> {
        instructions::execute::finalize_universal_tx(
            ctx,
            instruction_id,
            sub_tx_id,
            universal_tx_id,
            amount,
            push_account,
            writable_flags,
            ix_data,
            gas_fee,
            rent_fee,
            signature,
            recovery_id,
            message_hash,
        )
    }

    // =========================
    //        REVERT
    // =========================
    /// @notice TSS-verified revert withdraw for SOL (EVM parity: `revertUniversalTx`)
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
        instructions::revert::revert_universal_tx(
            ctx,
            sub_tx_id,
            universal_tx_id,
            amount,
            revert_instruction,
            gas_fee,
            signature,
            recovery_id,
            message_hash,
        )
    }

    /// @notice TSS-verified revert withdraw for SPL tokens (EVM parity: `revertUniversalTxToken`)
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
        instructions::revert::revert_universal_tx_token(
            ctx,
            sub_tx_id,
            universal_tx_id,
            amount,
            revert_instruction,
            gas_fee,
            signature,
            recovery_id,
            message_hash,
        )
    }

    // =========================
    //         UTILS
    // =========================
    /// @notice View function for SOL price (locker-compatible)
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
    AdminAction, PauseAction, RateLimitConfigAction, TokenRateLimitAction,
};
pub use instructions::deposit::SendUniversalTx;
pub use instructions::execute::FinalizeUniversalTx;
pub use instructions::initialize::Initialize;
pub use instructions::revert::{
    RevertUniversalTx, RevertUniversalTxToken,
};
pub use utils::PriceData;

pub use state::{
    // Events
    CapsUpdated,
    Config,
    ExecutedSubTx,
    GatewayAccountMeta,
    RevertInstructions,
    TSSAddressUpdated,
    TxType,
    UniversalPayload,
    UniversalTx,
    UniversalTxFinalized,
    UniversalTxRequest,
    VerificationType,
    CONFIG_SEED,
    EXECUTED_SUB_TX_SEED,
    FEED_ID,
    VAULT_SEED,
};
