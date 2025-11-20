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

    let tx_type = fetchTxType(&req, native_amount)?;
    route_universal_tx(&mut ctx, req, native_amount, tx_type)
}

/// GAS route (Instant): fund UEA on Push Chain with native SOL; optional payload.
/// Enforces USD caps via Pyth (8 decimals). Emits `TxWithGas`.
pub fn send_tx_with_gas(
    ctx: Context<SendTxWithGas>,
    payload: UniversalPayload,
    revert_instruction: RevertInstructions,
    amount: u64,
    signature_data: Vec<u8>,
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

    // Note: Rate limiting is available as an optional feature
    // To enable rate limiting, deploy the rate limit config account and pass it as remaining_accounts
    // For now, we'll skip rate limiting to maintain backward compatibility

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
        signature_data, // Use the provided signature data
    });

    Ok(())
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

#[allow(non_snake_case)]
fn fetchTxType(req: &UniversalTxRequest, native_amount: u64) -> Result<TxType> {
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
        });

        return Ok(());
    }

    require!(
        ctx.accounts.user.lamports() >= gas_amount,
        GatewayError::InsufficientBalance
    );

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
        // FUNDS-only must not carry a payload
        require!(req.payload.is_empty(), GatewayError::InvalidInput);
    }
    if tx_type == TxType::FundsAndPayload {
        // FUNDS_AND_PAYLOAD must have non-empty payload
        require!(!req.payload.is_empty(), GatewayError::InvalidInput);
    }

    match tx_type {
        TxType::Funds => {
            if req.token == Pubkey::default() {
                // Case 1.1: Token to bridge is Native SOL → Pubkey::default()
                require!(native_amount == req.amount, GatewayError::InvalidAmount);

                // Epoch-based token rate limit (skip if disabled: epoch_duration == 0 or limit_threshold == 0)
                let epoch_duration = ctx.accounts.rate_limit_config.epoch_duration_sec;
                require!(
                    ctx.accounts.token_rate_limit.token_mint == Pubkey::default(),
                    GatewayError::InvalidToken
                );
                if epoch_duration > 0 && ctx.accounts.token_rate_limit.limit_threshold > 0 {
                    consume_rate_limit(
                        &mut ctx.accounts.token_rate_limit,
                        req.amount as u128,
                        epoch_duration,
                    )?;
                }

                // Transfer SOL
                let cpi_ctx = CpiContext::new(
                    ctx.accounts.system_program.to_account_info(),
                    system_program::Transfer {
                        from: ctx.accounts.user.to_account_info(),
                        to: ctx.accounts.vault.to_account_info(),
                    },
                );
                system_program::transfer(cpi_ctx, req.amount)?;
            } else {
                // Case 1.2: Token to bridge is SPL Token → req.token
                require!(native_amount == 0, GatewayError::InvalidAmount);

                // Epoch-based token rate limit (skip if disabled: epoch_duration == 0 or limit_threshold == 0)
                let epoch_duration = ctx.accounts.rate_limit_config.epoch_duration_sec;
                require!(
                    ctx.accounts.token_rate_limit.token_mint == req.token,
                    GatewayError::InvalidToken
                );
                if epoch_duration > 0 && ctx.accounts.token_rate_limit.limit_threshold > 0 {
                    consume_rate_limit(
                        &mut ctx.accounts.token_rate_limit,
                        req.amount as u128,
                        epoch_duration,
                    )?;
                }

                // Check whitelist
                let token_whitelist_data = ctx.accounts.token_whitelist.try_borrow_data()?;
                let token_whitelist =
                    TokenWhitelist::try_deserialize(&mut &token_whitelist_data[..])?;
                require!(
                    token_whitelist.tokens.contains(&req.token),
                    GatewayError::TokenNotWhitelisted
                );

                // Transfer SPL
                let user_token_info = ctx.accounts.user_token_account.to_account_info();
                let gateway_token_info = ctx.accounts.gateway_token_account.to_account_info();
                require!(
                    user_token_info.owner == &spl_token::ID,
                    GatewayError::InvalidOwner
                );
                require!(
                    gateway_token_info.owner == &spl_token::ID,
                    GatewayError::InvalidOwner
                );

                let cpi_ctx = CpiContext::new(
                    ctx.accounts.token_program.to_account_info(),
                    Transfer {
                        from: user_token_info,
                        to: gateway_token_info,
                        authority: ctx.accounts.user.to_account_info(),
                    },
                );
                token::transfer(cpi_ctx, req.amount)?;
            }
        }
        TxType::FundsAndPayload => {
            if req.token == Pubkey::default() {
                // Case 2.2: Batching of Gas + Funds_and_Payload (native_amount > 0): with token == native_token
                // User refills UEA's gas and also bridges native token.
                // Split Needed: Native token is split between gasAmount and bridge amount (native_amount >= req.amount)
                // Note: If native_amount == 0, this will revert via the require below (Case 2.1 requires SPL token)
                require!(native_amount >= req.amount, GatewayError::InvalidAmount);
                let gas_amount = native_amount.saturating_sub(req.amount);

                // Send Gas to caller's UEA via instant route (if gas_amount > 0)
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

                // Epoch-based token rate limit for funds (skip if disabled: epoch_duration == 0 or limit_threshold == 0)
                let epoch_duration = ctx.accounts.rate_limit_config.epoch_duration_sec;
                require!(
                    ctx.accounts.token_rate_limit.token_mint == Pubkey::default(),
                    GatewayError::InvalidToken
                );
                if epoch_duration > 0 && ctx.accounts.token_rate_limit.limit_threshold > 0 {
                    consume_rate_limit(
                        &mut ctx.accounts.token_rate_limit,
                        req.amount as u128,
                        epoch_duration,
                    )?;
                }

                // Transfer funds
                let cpi_ctx = CpiContext::new(
                    ctx.accounts.system_program.to_account_info(),
                    system_program::Transfer {
                        from: ctx.accounts.user.to_account_info(),
                        to: ctx.accounts.vault.to_account_info(),
                    },
                );
                system_program::transfer(cpi_ctx, req.amount)?;
            } else {
                // Case 2.1: No Batching (native_amount == 0): user already has UEA with gas on Push Chain
                // User can directly move req.amount for req.token to Push Chain (SPL token only for Case 2.1)
                // Case 2.3: Batching of Gas + Funds_and_Payload (native_amount > 0): with token != native_token
                // User refills UEA's gas and also bridges SPL token.
                // No Split Needed: gasAmount is used via native_token, and bridgeAmount is used via SPL token.
                if native_amount > 0 {
                    // Send Gas to caller's UEA via instant route
                    send_tx_with_gas_route(
                        ctx,
                        TxType::Gas,
                        native_amount,
                        &[],
                        &req.revert_instruction,
                        &req.signature_data,
                    )?;
                }

                // Epoch-based token rate limit for SPL (skip if disabled: epoch_duration == 0 or limit_threshold == 0)
                let epoch_duration = ctx.accounts.rate_limit_config.epoch_duration_sec;
                require!(
                    ctx.accounts.token_rate_limit.token_mint == req.token,
                    GatewayError::InvalidToken
                );
                if epoch_duration > 0 && ctx.accounts.token_rate_limit.limit_threshold > 0 {
                    consume_rate_limit(
                        &mut ctx.accounts.token_rate_limit,
                        req.amount as u128,
                        epoch_duration,
                    )?;
                }

                // Check whitelist
                let token_whitelist_data = ctx.accounts.token_whitelist.try_borrow_data()?;
                let token_whitelist =
                    TokenWhitelist::try_deserialize(&mut &token_whitelist_data[..])?;
                require!(
                    token_whitelist.tokens.contains(&req.token),
                    GatewayError::TokenNotWhitelisted
                );

                // Transfer SPL
                let user_token_info = ctx.accounts.user_token_account.to_account_info();
                let gateway_token_info = ctx.accounts.gateway_token_account.to_account_info();
                require!(
                    user_token_info.owner == &spl_token::ID,
                    GatewayError::InvalidOwner
                );
                require!(
                    gateway_token_info.owner == &spl_token::ID,
                    GatewayError::InvalidOwner
                );

                let cpi_ctx = CpiContext::new(
                    ctx.accounts.token_program.to_account_info(),
                    Transfer {
                        from: user_token_info,
                        to: gateway_token_info,
                        authority: ctx.accounts.user.to_account_info(),
                    },
                );
                token::transfer(cpi_ctx, req.amount)?;
            }
        }
        _ => return Err(error!(GatewayError::InvalidTxType)),
    }

    // Emit event
    emit!(UniversalTx {
        sender: ctx.accounts.user.key(),
        recipient: req.recipient,
        token: req.token,
        amount: req.amount,
        payload: req.payload,
        revert_instruction: req.revert_instruction,
        tx_type,
        signature_data: req.signature_data,
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

        // Note: Epoch-based rate limiting for SPL tokens would be implemented here
        // For now, we're focusing on block-based USD cap limiting for SOL deposits
        // SPL token rate limiting can be added in a future iteration with proper account handling

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

    // Note: Rate limiting is available as an optional feature
    // To enable rate limiting, deploy the rate limit config account and pass it as remaining_accounts
    // For now, we'll skip rate limiting to maintain backward compatibility

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

        // Note: Epoch-based rate limiting for SPL tokens would be implemented here
        // For now, we're focusing on block-based USD cap limiting for SOL deposits
        // SPL token rate limiting can be added in a future iteration with proper account handling

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
pub struct SendUniversalTx<'info> {
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

    /// CHECK: Token whitelist PDA validated and deserialized at runtime for SPL transfers.
    #[account(mut)]
    pub token_whitelist: UncheckedAccount<'info>,

    /// CHECK: Only required for SPL token routes; validated at runtime.
    /// For native SOL routes, pass vault account as dummy (not used).
    #[account(mut)]
    pub user_token_account: UncheckedAccount<'info>,

    /// CHECK: Only required for SPL token routes; validated at runtime.
    /// For native SOL routes, pass vault account as dummy (not used).
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
