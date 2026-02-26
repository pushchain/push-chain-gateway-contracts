use crate::errors::GatewayError;
use crate::state::*;
use crate::utils::*;
use anchor_lang::prelude::*;
use anchor_lang::solana_program::program_pack::Pack;
use anchor_lang::system_program;
use anchor_spl::token::{self, spl_token, Token, Transfer};
use pyth_solana_receiver_sdk::price_update::PriceUpdateV2;
use spl_token::state::Account as SplAccount;
// =========================
//           DEPOSITS
// =========================

/// @notice Universal entrypoint (EVM parity): routes native/SPL deposits based on `TxType`.
/// @dev    Single entrypoint for all deposit types with internal routing mechanism.
///         `native_amount` mirrors `msg.value` on EVM chains - represents total native SOL sent.
///         Routes to GAS (instant) or FUNDS (standard) handlers based on derived tx type.
pub fn send_universal_tx(
    mut ctx: Context<SendUniversalTx>,
    req: UniversalTxRequest,
    native_amount: u64,
) -> Result<()> {
    let config = &ctx.accounts.config;
    require!(!config.paused, GatewayError::Paused);
    require!(
        ctx.accounts.user.lamports() >= native_amount,
        GatewayError::InsufficientBalance
    );

    // Collect protocol fee first so all downstream routing sees post-fee native amount.
    let adjusted_native_amount = collect_protocol_fee(&mut ctx, native_amount)?;

    let tx_type = fetch_tx_type(&req, adjusted_native_amount)?;
    route_universal_tx(&mut ctx, req, adjusted_native_amount, tx_type)
}

fn collect_protocol_fee(ctx: &mut Context<SendUniversalTx>, native_amount: u64) -> Result<u64> {
    let fee_lamports = ctx.accounts.fee_vault.protocol_fee_lamports;
    if fee_lamports == 0 {
        return Ok(native_amount);
    }

    require!(
        native_amount >= fee_lamports,
        GatewayError::InsufficientProtocolFee
    );

    // Transfer fee from user → fee_vault (keeps bridge vault strictly 1:1 backed)
    let cpi_ctx = CpiContext::new(
        ctx.accounts.system_program.to_account_info(),
        system_program::Transfer {
            from: ctx.accounts.user.to_account_info(),
            to: ctx.accounts.fee_vault.to_account_info(),
        },
    );
    system_program::transfer(cpi_ctx, fee_lamports)?;

    let adjusted_native_amount = native_amount - fee_lamports;

    emit!(ProtocolFeeCollected {
        payer: ctx.accounts.user.key(),
        amount_lamports: fee_lamports,
        native_amount_before: native_amount,
        native_amount_after: adjusted_native_amount,
    });

    Ok(adjusted_native_amount)
}

/// @notice Internal router: dispatches to GAS or FUNDS handlers based on derived tx_type.
/// @dev    Route 1: GAS | GAS_AND_PAYLOAD → Instant route (fee abstraction)
///         Route 2: FUNDS | FUNDS_AND_PAYLOAD → Standard route (bridge deposits)
/// @dev    GAS routes require req.amount == 0 (funds leg disabled). native_amount represents gas.
///         FUNDS routes require req.amount > 0 (funds leg enabled); native_amount may batch gas.
fn route_universal_tx(
    ctx: &mut Context<SendUniversalTx>,
    req: UniversalTxRequest,
    native_amount: u64,
    tx_type: TxType,
) -> Result<()> {
    match tx_type {
        TxType::Gas | TxType::GasAndPayload => send_tx_with_gas_route(
            ctx,
            tx_type,
            native_amount,
            &req.payload,
            &req.revert_instruction,
            &req.signature_data,
        ),
        TxType::Funds | TxType::FundsAndPayload => {
            send_tx_with_funds_route(ctx, req, native_amount, tx_type)
        }
        _ => Err(error!(GatewayError::InvalidTxType)),
    }
}

fn fetch_tx_type(req: &UniversalTxRequest, native_amount: u64) -> Result<TxType> {
    let has_payload = !req.payload.is_empty();
    let has_funds = req.amount > 0;
    let funds_is_native = req.token == Pubkey::default();
    let has_native_value = native_amount > 0;

    if !has_funds {
        if has_payload {
            return Ok(TxType::GasAndPayload);
        }
        require!(has_native_value, GatewayError::InvalidInput);
        return Ok(TxType::Gas);
    }

    if has_payload {
        if funds_is_native {
            require!(native_amount >= req.amount, GatewayError::InvalidAmount);
        }

        return Ok(TxType::FundsAndPayload);
    }

    // FUNDS with no payload
    if funds_is_native {
        require!(native_amount == req.amount, GatewayError::InvalidAmount);
    } else {
        require!(!has_native_value, GatewayError::InvalidAmount);
    }

    Ok(TxType::Funds)
}

/// @notice Internal helper function to deposit for Instant TX (GAS route).
/// @dev    Handles rate-limit checks for Fee Abstraction Tx Route.
///         - Validates revert instruction recipient
///         - Validates payload: GAS must have empty payload, GAS_AND_PAYLOAD must have non-empty payload
///         - Supports payload-only execution (gas_amount == 0) for EVM V0 parity
///         - Enforces USD caps ($1-$10) and block-based USD cap via Pyth oracle
///         - Transfers native SOL to vault (recipient as Pubkey::default() → UEA)
fn send_tx_with_gas_route(
    ctx: &mut Context<SendUniversalTx>,
    tx_type: TxType,
    gas_amount: u64,
    payload: &[u8],
    revert_instruction: &RevertInstructions,
    signature_data: &[u8],
) -> Result<()> {
    // Validate tx_type
    require!(
        matches!(tx_type, TxType::Gas | TxType::GasAndPayload),
        GatewayError::InvalidTxType
    );

    // NOTE: Payload validation removed for testnet (matching EVM V0)
    // V0 has these validations commented out (lines 1271-1277)
    // if tx_type == TxType::GasAndPayload {
    //     require!(!payload.is_empty(), GatewayError::InvalidInput);
    // }
    // if tx_type == TxType::Gas {
    //     require!(payload.is_empty(), GatewayError::InvalidInput);
    // }

    require!(
        revert_instruction.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );

    // Payload-only execution (gas_amount == 0) - EVM V0 parity
    // User already has UEA with gas on Push Chain, just execute payload
    if gas_amount == 0 {
        require!(
            matches!(tx_type, TxType::GasAndPayload | TxType::FundsAndPayload),
            GatewayError::InvalidAmount
        );

        emit!(UniversalTx {
            sender: ctx.accounts.user.key(),
            recipient: [0u8; 20],
            token: Pubkey::default(),
            amount: 0,
            payload: payload.to_vec(),
            revert_instruction: revert_instruction.clone(),
            tx_type,
            signature_data: signature_data.to_vec(),
            from_cea: false,
        });

        return Ok(());
    }

    // Performs rate-limit checks and handle deposit
    // USD caps: min $1, max $10 (enforced via Pyth oracle)
    check_usd_caps(&ctx.accounts.config, gas_amount, &ctx.accounts.price_update)?;
    let price_data = calculate_sol_price(&ctx.accounts.price_update)?;
    let usd_amount = calculate_usd_amount(gas_amount, &price_data)?;
    // Block-based USD cap: per-slot limit (disabled if block_usd_cap == 0)
    check_block_usd_cap(&mut ctx.accounts.rate_limit_config, usd_amount)?;

    // Transfer native SOL to vault (like _handleNativeDeposit in ETH)
    let cpi_ctx = CpiContext::new(
        ctx.accounts.system_program.to_account_info(),
        system_program::Transfer {
            from: ctx.accounts.user.to_account_info(),
            to: ctx.accounts.vault.to_account_info(),
        },
    );
    system_program::transfer(cpi_ctx, gas_amount)?;

    // Emit UniversalTx event (recipient as Pubkey::default() → UEA)
    emit!(UniversalTx {
        sender: ctx.accounts.user.key(),
        recipient: [0u8; 20],
        token: Pubkey::default(),
        amount: gas_amount,
        payload: payload.to_vec(),
        revert_instruction: revert_instruction.clone(),
        tx_type,
        signature_data: signature_data.to_vec(),
        from_cea: false,
    });

    Ok(())
}

/// @notice Internal helper function to deposit for Standard TX (FUNDS route).
/// @dev    Handles bridge deposits with optional gas batching.
///         Case 1: TX_TYPE = FUNDS
///           - Case 1.1: Native SOL funds → req.token == Pubkey::default()
///           - Case 1.2: SPL token funds → req.token != Pubkey::default()
///         Case 2: TX_TYPE = FUNDS_AND_PAYLOAD
///           - Case 2.1: No batching (native_amount == 0) → user already has UEA with gas
///           - Case 2.2: Batching with native SOL → split: gasAmount = native_amount - req.amount
///           - Case 2.3: Batching with SPL + native gas → gasAmount = native_amount, bridgeAmount = req.amount
fn send_tx_with_funds_route(
    ctx: &mut Context<SendUniversalTx>,
    req: UniversalTxRequest,
    native_amount: u64,
    tx_type: TxType,
) -> Result<()> {
    require!(
        req.revert_instruction.fund_recipient != Pubkey::default(),
        GatewayError::InvalidRecipient
    );
    require!(req.amount > 0, GatewayError::InvalidAmount);

    // Payload validation (matching EVM Temp lines 978-984)
    if tx_type == TxType::Funds {
        require!(req.payload.is_empty(), GatewayError::InvalidInput);
    }
    if tx_type == TxType::FundsAndPayload {
        require!(!req.payload.is_empty(), GatewayError::InvalidInput);
    }

    match tx_type {
        TxType::Funds => {
            if req.token == Pubkey::default() {
                // Case 1.1: Native SOL
                require!(native_amount == req.amount, GatewayError::InvalidAmount);
                validate_token_and_consume_rate_limit(
                    &mut ctx.accounts.token_rate_limit,
                    Pubkey::default(),
                    req.amount as u128,
                    &ctx.accounts.rate_limit_config,
                )?;
                let cpi_ctx = CpiContext::new(
                    ctx.accounts.system_program.to_account_info(),
                    system_program::Transfer {
                        from: ctx.accounts.user.to_account_info(),
                        to: ctx.accounts.vault.to_account_info(),
                    },
                );
                system_program::transfer(cpi_ctx, req.amount)?;
            } else {
                // Case 1.2: SPL token
                require!(native_amount == 0, GatewayError::InvalidAmount);
                validate_token_and_consume_rate_limit(
                    &mut ctx.accounts.token_rate_limit,
                    req.token,
                    req.amount as u128,
                    &ctx.accounts.rate_limit_config,
                )?;
                deposit_spl_to_vault(ctx, req.token, req.amount)?;
            }
        }
        TxType::FundsAndPayload => {
            if req.token == Pubkey::default() {
                // Case 2.2: Native SOL bridge + optional gas split
                // Split Needed: Native token is split between gasAmount and bridge amount (native_amount >= req.amount)
                // Note: If native_amount == 0, this will revert via the require below (Case 2.1 requires SPL token)
                require!(native_amount >= req.amount, GatewayError::InvalidAmount);
                let gas_amount = native_amount.saturating_sub(req.amount);
                if gas_amount > 0 {
                    send_tx_with_gas_route(
                        ctx,
                        TxType::Gas,
                        gas_amount,
                        &[],
                        &req.revert_instruction,
                        &req.signature_data,
                    )?;
                }
                validate_token_and_consume_rate_limit(
                    &mut ctx.accounts.token_rate_limit,
                    Pubkey::default(),
                    req.amount as u128,
                    &ctx.accounts.rate_limit_config,
                )?;
                let cpi_ctx = CpiContext::new(
                    ctx.accounts.system_program.to_account_info(),
                    system_program::Transfer {
                        from: ctx.accounts.user.to_account_info(),
                        to: ctx.accounts.vault.to_account_info(),
                    },
                );
                system_program::transfer(cpi_ctx, req.amount)?;
            } else {
                // Case 2.1/2.3: SPL bridge (+ optional native gas)
                // No Split Needed: gasAmount is used via native_token, and bridgeAmount is used via SPL token.
                if native_amount > 0 {
                    send_tx_with_gas_route(
                        ctx,
                        TxType::Gas,
                        native_amount,
                        &[],
                        &req.revert_instruction,
                        &req.signature_data,
                    )?;
                }
                validate_token_and_consume_rate_limit(
                    &mut ctx.accounts.token_rate_limit,
                    req.token,
                    req.amount as u128,
                    &ctx.accounts.rate_limit_config,
                )?;
                deposit_spl_to_vault(ctx, req.token, req.amount)?;
            }
        }
        _ => return Err(error!(GatewayError::InvalidTxType)),
    }

    // FUNDS carries a specific recipient; FundsAndPayload targets UEA on Push Chain (zero address)
    let recipient = if tx_type == TxType::Funds { req.recipient } else { [0u8; 20] };
    emit!(UniversalTx {
        sender: ctx.accounts.user.key(),
        recipient,
        token: req.token,
        amount: req.amount,
        payload: req.payload,
        revert_instruction: req.revert_instruction,
        tx_type,
        signature_data: req.signature_data,
        from_cea: false,
    });

    Ok(())
}

/// Transfer SPL tokens from user's token account to the vault's ATA.
/// SECURITY: validates vault ownership and mint before transferring.
fn deposit_spl_to_vault(ctx: &Context<SendUniversalTx>, token: Pubkey, amount: u64) -> Result<()> {
    let user_token_info = ctx.accounts.user_token_account.to_account_info();
    require!(user_token_info.owner == &spl_token::ID, GatewayError::InvalidOwner);

    // SECURITY: Validate gateway_token_account is the vault's ATA for this token.
    // This prevents users from providing their own token account and stealing funds.
    let data = ctx.accounts.gateway_token_account.try_borrow_data()?.to_vec();
    let parsed = SplAccount::unpack(&data).map_err(|_| error!(GatewayError::InvalidAccount))?;
    require!(parsed.owner == ctx.accounts.vault.key(), GatewayError::InvalidOwner);
    require!(parsed.mint == token, GatewayError::InvalidMint);

    let cpi_ctx = CpiContext::new(
        ctx.accounts.token_program.to_account_info(),
        Transfer {
            from: user_token_info,
            to: ctx.accounts.gateway_token_account.to_account_info(),
            authority: ctx.accounts.user.to_account_info(),
        },
    );
    token::transfer(cpi_ctx, amount)
}

// =========================
//        ACCOUNT STRUCTS
// =========================

#[derive(Accounts)]
pub struct SendUniversalTx<'info> {
    #[account(
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

    /// Fee vault: receives the flat protocol fee per inbound tx.
    /// Separate from bridge vault to preserve the 1:1 bridge invariant.
    #[account(
        mut,
        seeds = [FEE_VAULT_SEED],
        bump = fee_vault.bump,
    )]
    pub fee_vault: Account<'info, FeeVault>,

    /// CHECK: Only required for SPL token routes; validated at runtime.
    /// For native SOL routes, pass vault account as dummy (not used).
    /// TODO use Optional Account instead 
    #[account(mut)]
    pub user_token_account: UncheckedAccount<'info>,

    /// CHECK: Only required for SPL token routes; validated at runtime.
    /// For native SOL routes, pass vault account as dummy (not used).
    /// TODO use Optional Account instead 
    #[account(mut)]
    pub gateway_token_account: UncheckedAccount<'info>,

    #[account(mut)]
    pub user: Signer<'info>,

    pub price_update: Account<'info, PriceUpdateV2>,

    /// Rate limit config - REQUIRED for universal entrypoint
    #[account(
        mut,
        seeds = [RATE_LIMIT_CONFIG_SEED],
        bump,
    )]
    pub rate_limit_config: Account<'info, RateLimitConfig>,

    /// Token rate limit - REQUIRED for universal entrypoint
    /// NOTE: For native SOL, use Pubkey::default() as the token_mint when deriving this PDA
    #[account(mut)]
    pub token_rate_limit: Account<'info, TokenRateLimit>,

    pub token_program: Program<'info, Token>,

    pub system_program: Program<'info, System>,
}
