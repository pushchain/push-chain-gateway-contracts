use crate::errors::GatewayError;
use crate::state::*;
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{keccak::hash, secp256k1_recover::secp256k1_recover};

/// Initialize the TSS PDA with ETH address and chain id.
#[derive(Accounts)]
pub struct InitTss<'info> {
    #[account(
        init,
        seeds = [TSS_SEED],
        bump,
        payer = authority,
        space = TssPda::LEN,
    )]
    pub tss_pda: Account<'info, TssPda>,

    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        constraint = config.admin == authority.key() @ GatewayError::Unauthorized
    )]
    pub config: Account<'info, Config>,

    #[account(mut)]
    pub authority: Signer<'info>,

    pub system_program: Program<'info, System>,
}

pub fn init_tss(ctx: Context<InitTss>, tss_eth_address: [u8; 20], chain_id: String) -> Result<()> {
    require!(!chain_id.is_empty(), GatewayError::InvalidInput);
    require!(chain_id.len() <= 64, GatewayError::InvalidInput); // Max 64 bytes for cluster pubkey

    let tss = &mut ctx.accounts.tss_pda;
    tss.tss_eth_address = tss_eth_address;
    tss.chain_id = chain_id;
    tss.nonce = 0;
    tss.authority = ctx.accounts.authority.key();
    tss.bump = ctx.bumps.tss_pda;
    Ok(())
}

/// Update TSS ETH address / chain id (authority-only)
#[derive(Accounts)]
pub struct UpdateTss<'info> {
    #[account(
        mut,
        seeds = [TSS_SEED],
        bump = tss_pda.bump,
        constraint = tss_pda.authority == authority.key(),
    )]
    pub tss_pda: Account<'info, TssPda>,

    pub authority: Signer<'info>,
}

pub fn update_tss(
    ctx: Context<UpdateTss>,
    tss_eth_address: [u8; 20],
    chain_id: String,
) -> Result<()> {
    require!(!chain_id.is_empty(), GatewayError::InvalidInput);
    require!(chain_id.len() <= 64, GatewayError::InvalidInput); // Max 64 bytes for cluster pubkey

    let tss = &mut ctx.accounts.tss_pda;

    // If TSS address changes, reset nonce to 0 for clarity and security
    // (Old signatures won't work anyway due to address mismatch, but resetting is cleaner)
    let address_changed = tss.tss_eth_address != tss_eth_address;

    tss.tss_eth_address = tss_eth_address;
    tss.chain_id = chain_id;

    if address_changed {
        tss.nonce = 0;
    }

    Ok(())
}

/// Reset nonce (authority-only)
#[derive(Accounts)]
pub struct ResetNonce<'info> {
    #[account(
        mut,
        seeds = [TSS_SEED],
        bump = tss_pda.bump,
        constraint = tss_pda.authority == authority.key(),
    )]
    pub tss_pda: Account<'info, TssPda>,

    pub authority: Signer<'info>,
}

pub fn reset_nonce(ctx: Context<ResetNonce>, new_nonce: u64) -> Result<()> {
    ctx.accounts.tss_pda.nonce = new_nonce;
    Ok(())
}

/// Common validator: verify nonce, hash, and ECDSA secp256k1 signature recovers stored ETH address.
/// Used by withdraw, revert, and execute functions - single standard for all TSS-signed messages.
pub fn validate_message(
    tss: &mut Account<TssPda>,
    instruction_id: u8,
    nonce: u64,
    amount: Option<u64>,
    additional_data: &[&[u8]],
    message_hash: &[u8; 32],
    signature: &[u8; 64],
    recovery_id: u8,
) -> Result<()> {
    // Nonce check and update
    require!(nonce == tss.nonce, GatewayError::NonceMismatch);
    tss.nonce = tss
        .nonce
        .checked_add(1)
        .ok_or(GatewayError::NonceMismatch)?;

    // Rebuild message
    let mut buf = Vec::new();
    const PREFIX: &[u8] = b"PUSH_CHAIN_SVM";
    buf.extend_from_slice(PREFIX);
    buf.push(instruction_id);
    buf.extend_from_slice(tss.chain_id.as_bytes()); // Use UTF-8 bytes of chain_id string directly
    buf.extend_from_slice(&nonce.to_be_bytes());
    if let Some(val) = amount {
        buf.extend_from_slice(&val.to_be_bytes());
    }
    for d in additional_data {
        buf.extend_from_slice(d);
    }
    let computed = hash(&buf[..]).to_bytes();
    require!(&computed == message_hash, GatewayError::MessageHashMismatch);

    // Recover address via secp256k1
    let pubkey = secp256k1_recover(message_hash, recovery_id, signature)
        .map_err(|_| GatewayError::TssAuthFailed)?;
    let h = hash(pubkey.to_bytes().as_slice()).to_bytes();
    let address = &h.as_slice()[12..32];
    require!(address == &tss.tss_eth_address, GatewayError::TssAuthFailed);
    Ok(())
}
