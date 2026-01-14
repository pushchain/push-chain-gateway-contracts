use crate::errors::GatewayError;
use crate::instructions::tss::validate_message;
use crate::state::{
    Config, ExecutedTx, GatewayAccountMeta, RevertInstructions, TssPda, TxType, UniversalTx,
    UniversalTxExecuted, CEA_SEED, EXECUTED_TX_SEED, TSS_SEED, VAULT_SEED,
};
use crate::utils::validate_remaining_accounts;
use anchor_lang::prelude::*;
use anchor_lang::solana_program::{
    hash::hash,
    instruction::{AccountMeta as SolanaAccountMeta, Instruction},
    program::invoke_signed,
    program_pack::Pack,
    system_instruction,
};
use anchor_spl::token::spl_token::state::Account as SplAccount;
use anchor_spl::{
    associated_token::AssociatedToken,
    token::{self, CloseAccount, Mint, Token, TokenAccount},
};

// =========================
//  EXECUTE_UNIVERSAL_TX (SOL)
// =========================

#[derive(Accounts)]
#[instruction(tx_id: [u8; 32], universal_tx_id: [u8; 32], amount: u64, target_program: Pubkey, sender: [u8; 20])]
pub struct ExecuteUniversalTx<'info> {
    #[account(mut)]
    pub caller: Signer<'info>,

    #[account(
        seeds = [b"config"],
        bump,
    )]
    pub config: Account<'info, Config>,

    /// Vault SOL PDA - holds all bridged SOL
    #[account(
        mut,
        seeds = [VAULT_SEED],
        bump = config.vault_bump,
    )]
    pub vault_sol: SystemAccount<'info>,

    /// CEA (Chain Executor Account) - persistent identity per Push Chain user
    /// This PDA represents the user on Solana and can sign for target programs
    /// Auto-created by Solana on first transfer, persists across transactions
    #[account(
        mut,
        seeds = [CEA_SEED, sender.as_ref()],
        bump,
    )]
    pub cea_authority: SystemAccount<'info>,

    #[account(
        mut,
        seeds = [TSS_SEED],
        bump,
    )]
    pub tss_pda: Account<'info, TssPda>,

    /// Executed transaction tracker (replay protection)
    /// Relayer pays for this account creation and gets reimbursed via gas_fee
    #[account(
        init,
        payer = caller,
        space = ExecutedTx::LEN,
        seeds = [EXECUTED_TX_SEED, tx_id.as_ref()],
        bump
    )]
    pub executed_tx: Account<'info, ExecutedTx>,

    /// CHECK: Target program (validated against signed message)
    pub destination_program: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

pub fn execute_universal_tx(
    ctx: Context<ExecuteUniversalTx>,
    tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    amount: u64,
    target_program: Pubkey,
    sender: [u8; 20],
    accounts: Vec<GatewayAccountMeta>,
    ix_data: Vec<u8>,
    gas_fee: u64,
    rent_fee: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    let config = &ctx.accounts.config;
    require!(!config.paused, GatewayError::Paused);

    // 1. Validate remaining_accounts match accounts parameter
    validate_remaining_accounts(&accounts, ctx.remaining_accounts)?;

    let cea_key = ctx.accounts.cea_authority.key();

    // 2. Build serialized accounts buffer (with length prefix) for TSS validation
    // Format: [u32 BE: count] + [32 bytes: pubkey, 1 byte: is_writable] * count
    // This MUST match the format used in buildExecuteAdditionalData (off-chain)
    let mut accounts_buf = Vec::new();
    let accounts_count = accounts.len() as u32;
    accounts_buf.extend_from_slice(&accounts_count.to_be_bytes()); // u32 BE length prefix
    for account in &accounts {
        accounts_buf.extend_from_slice(&account.pubkey.to_bytes()); // Pubkey (32 bytes)
        accounts_buf.push(if account.is_writable { 1 } else { 0 }); // is_writable (1 byte)
    }

    // 3. Build serialized ix_data buffer (with length prefix)
    let mut ix_data_buf = Vec::new();
    let ix_data_length = ix_data.len() as u32;
    ix_data_buf.extend_from_slice(&ix_data_length.to_be_bytes()); // u32 BE length prefix
    ix_data_buf.extend_from_slice(&ix_data); // Raw bytes

    // 4. Validate TSS signature and message hash using unified validate_message
    // Format: PREFIX + instruction_id + chain_id + nonce + amount + [universal_tx_id, tx_id, target_program, sender, accounts_buf, ix_data_buf, gas_fee, rent_fee]
    let mut gas_fee_buf = [0u8; 8];
    gas_fee_buf.copy_from_slice(&gas_fee.to_be_bytes());
    let mut rent_fee_buf = [0u8; 8];
    rent_fee_buf.copy_from_slice(&rent_fee.to_be_bytes());

    let additional: [&[u8]; 8] = [
        &universal_tx_id[..],
        &tx_id[..],
        &target_program.to_bytes(),
        &sender[..],
        &accounts_buf,
        &ix_data_buf,
        &gas_fee_buf,
        &rent_fee_buf,
    ];
    validate_message(
        &mut ctx.accounts.tss_pda,
        5, // instruction_id for SOL execute
        nonce,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    // 5. Verify target program matches and is executable
    require!(
        ctx.accounts.destination_program.key() == target_program,
        GatewayError::TargetProgramMismatch
    );
    require!(
        ctx.accounts.destination_program.executable,
        GatewayError::InvalidProgram
    );

    // Note: Account validation is done during derivation (step 1)
    // TSS signature enforces: account count, pubkeys, and is_writable flags
    // Outer signer check is done during derivation

    // 6. Replay protection - account existence check
    // (init_if_needed will fail if account already exists with different data)
    // For simplicity, we rely on account creation as replay protection
    // Note: Nonce is already updated in validate_message (atomic with verification)

    // 7. Validate rent_fee <= gas_fee (rent_fee is a subset of gas_fee)
    // User burns gas_fee on Push Chain, which is split into rent_fee (for CEA) and relayer_fee (for caller)
    require!(rent_fee <= gas_fee, GatewayError::InvalidAmount);

    // 8. Transfer rent_fee to CEA (for target contract rent)
    // This SOL is from gas_fee burned on Push Chain, allocated for target program rent
    let vault_bump = config.vault_bump;
    let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[vault_bump]];

    if rent_fee > 0 {
        let rent_transfer_ix = system_instruction::transfer(
            &ctx.accounts.vault_sol.key(),
            &ctx.accounts.cea_authority.key(),
            rent_fee,
        );

        invoke_signed(
            &rent_transfer_ix,
            &[
                ctx.accounts.vault_sol.to_account_info(),
                ctx.accounts.cea_authority.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[vault_seeds],
        )?;
    }

    // 9. Transfer amount to CEA (main transfer)
    if amount > 0 {
        let amount_transfer_ix = system_instruction::transfer(
            &ctx.accounts.vault_sol.key(),
            &ctx.accounts.cea_authority.key(),
            amount,
        );

        invoke_signed(
            &amount_transfer_ix,
            &[
                ctx.accounts.vault_sol.to_account_info(),
                ctx.accounts.cea_authority.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[vault_seeds],
        )?;
    }

    // 10. Transfer relayer_fee (gas_fee - rent_fee) to caller BEFORE self-call check
    // This ensures the caller gets paid even for self-withdraw operations.
    // Relayer pays: executed_tx rent (~890k) + CEA ATA rent if created (~2M) + compute fees
    // Relayer receives: relayer_fee = gas_fee - rent_fee (reimbursement for gateway costs)
    // Vault total payout: rent_fee (to CEA) + relayer_fee (to caller) = gas_fee (matches user burn)
    let relayer_fee = gas_fee
        .checked_sub(rent_fee)
        .ok_or(GatewayError::InvalidAmount)?;

    if relayer_fee > 0 {
        let vault_bump = config.vault_bump;
        let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[vault_bump]];

        let fee_transfer_ix = system_instruction::transfer(
            &ctx.accounts.vault_sol.key(),
            &ctx.accounts.caller.key(),
            relayer_fee,
        );

        invoke_signed(
            &fee_transfer_ix,
            &[
                ctx.accounts.vault_sol.to_account_info(),
                ctx.accounts.caller.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[vault_seeds],
        )?;
    }

    // 11. Build CPI instruction for target program
    // cea_authority must appear as signer inside CPI
    let cpi_metas: Vec<SolanaAccountMeta> = accounts
        .iter()
        .map(|a| {
            let is_signer = a.pubkey == cea_key;
            if a.is_writable {
                SolanaAccountMeta::new(a.pubkey, is_signer)
            } else {
                SolanaAccountMeta::new_readonly(a.pubkey, is_signer)
            }
        })
        .collect();

    // 12. Check if target is gateway itself (for CEA withdrawals)
    let cea_bump = ctx.bumps.cea_authority;
    let cea_seeds: &[&[u8]] = &[CEA_SEED, sender.as_ref(), &[cea_bump]];

    if target_program == *ctx.program_id {
        // Gateway self-call: interpret ix_data as a normal gateway instruction
        // and handle CEA withdrawal in-place (no CPI).
        return handle_cea_withdrawal(&ctx, tx_id, universal_tx_id, sender, &ix_data, cea_seeds);
    }

    let cpi_ix = Instruction {
        program_id: target_program,
        accounts: cpi_metas,
        data: ix_data.clone(),
    };

    // 13. Invoke target program with cea_authority as signer
    invoke_signed(&cpi_ix, ctx.remaining_accounts, &[cea_seeds])?;

    // Note: CEA balances persist (no auto-drain) - matches EVM CEA behavior
    // Users can withdraw via withdrawFundsFromCea() when needed

    // 13. Emit execution event
    emit!(UniversalTxExecuted {
        universal_tx_id,
        tx_id,
        sender,
        target: target_program,
        token: Pubkey::default(), // SOL
        amount,
        payload: ix_data,
    });

    Ok(())
}

// =========================
//  EXECUTE_UNIVERSAL_TX_TOKEN (SPL)
// =========================

#[derive(Accounts)]
#[instruction(tx_id: [u8; 32], universal_tx_id: [u8; 32], amount: u64, target_program: Pubkey, sender: [u8; 20])]
pub struct ExecuteUniversalTxToken<'info> {
    #[account(mut)]
    pub caller: Signer<'info>,

    #[account(
        seeds = [b"config"],
        bump,
    )]
    pub config: Account<'info, Config>,

    /// Vault authority PDA - owner of all vault ATAs
    #[account(
        seeds = [VAULT_SEED],
        bump = config.vault_bump,
    )]
    /// CHECK: PDA, no data account needed
    pub vault_authority: UncheckedAccount<'info>,

    /// Vault ATA for this mint
    #[account(
        mut,
        constraint = vault_ata.owner == vault_authority.key() @ GatewayError::InvalidOwner,
        constraint = vault_ata.mint == mint.key() @ GatewayError::InvalidMint,
    )]
    pub vault_ata: Account<'info, TokenAccount>,

    /// CEA (Chain Executor Account) - persistent identity per Push Chain user
    /// This PDA represents the user on Solana and can sign for target programs
    #[account(
        mut,
        seeds = [CEA_SEED, sender.as_ref()],
        bump,
    )]
    /// CHECK: PDA, no data account needed
    pub cea_authority: SystemAccount<'info>,

    /// CEA ATA for this user+mint
    /// Created per-tx, closed after (rent reclaim)
    /// CHECK: Will be created as ATA(cea_authority, mint)
    #[account(mut)]
    pub cea_ata: UncheckedAccount<'info>,

    /// Token mint
    pub mint: Account<'info, Mint>,

    #[account(
        mut,
        seeds = [TSS_SEED],
        bump,
    )]
    pub tss_pda: Account<'info, TssPda>,

    /// Vault SOL PDA (needed for rent_fee transfer to CEA and gas_fee reimbursement to relayer)
    #[account(
        mut,
        seeds = [VAULT_SEED],
        bump = config.vault_bump,
    )]
    pub vault_sol: SystemAccount<'info>,

    /// Executed transaction tracker (replay protection)
    /// Relayer pays for this account creation and gets reimbursed via gas_fee
    #[account(
        init,
        payer = caller,
        space = ExecutedTx::LEN,
        seeds = [EXECUTED_TX_SEED, tx_id.as_ref()],
        bump
    )]
    pub executed_tx: Account<'info, ExecutedTx>,

    /// CHECK: Target program (validated against signed message)
    pub destination_program: UncheckedAccount<'info>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
    pub associated_token_program: Program<'info, AssociatedToken>,
}

pub fn execute_universal_tx_token(
    ctx: Context<ExecuteUniversalTxToken>,
    tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    amount: u64,
    target_program: Pubkey,
    sender: [u8; 20],
    accounts: Vec<GatewayAccountMeta>,
    ix_data: Vec<u8>,
    gas_fee: u64,
    rent_fee: u64,
    signature: [u8; 64],
    recovery_id: u8,
    message_hash: [u8; 32],
    nonce: u64,
) -> Result<()> {
    let config = &ctx.accounts.config;
    require!(!config.paused, GatewayError::Paused);

    // 1. Validate remaining_accounts match accounts parameter
    validate_remaining_accounts(&accounts, ctx.remaining_accounts)?;

    let cea_key = ctx.accounts.cea_authority.key();

    // 2. Build serialized accounts buffer (with length prefix) for TSS validation
    // Format: [u32 BE: count] + [32 bytes: pubkey, 1 byte: is_writable] * count
    // This MUST match the format used in buildExecuteAdditionalData (off-chain)
    let mut accounts_buf = Vec::new();
    let accounts_count = accounts.len() as u32;
    accounts_buf.extend_from_slice(&accounts_count.to_be_bytes()); // u32 BE length prefix
    for account in &accounts {
        accounts_buf.extend_from_slice(&account.pubkey.to_bytes()); // Pubkey (32 bytes)
        accounts_buf.push(if account.is_writable { 1 } else { 0 }); // is_writable (1 byte)
    }

    // 3. Build serialized ix_data buffer (with length prefix)
    let mut ix_data_buf = Vec::new();
    let ix_data_length = ix_data.len() as u32;
    ix_data_buf.extend_from_slice(&ix_data_length.to_be_bytes()); // u32 BE length prefix
    ix_data_buf.extend_from_slice(&ix_data); // Raw bytes

    // 4. Validate TSS signature and message hash using unified validate_message
    // Format: PREFIX + instruction_id + chain_id + nonce + amount + [universal_tx_id, tx_id, target_program, sender, accounts_buf, ix_data_buf, gas_fee, rent_fee]
    let mut gas_fee_buf = [0u8; 8];
    gas_fee_buf.copy_from_slice(&gas_fee.to_be_bytes());
    let mut rent_fee_buf = [0u8; 8];
    rent_fee_buf.copy_from_slice(&rent_fee.to_be_bytes());

    let additional: [&[u8]; 8] = [
        &universal_tx_id[..],
        &tx_id[..],
        &target_program.to_bytes(),
        &sender[..],
        &accounts_buf,
        &ix_data_buf,
        &gas_fee_buf,
        &rent_fee_buf,
    ];
    validate_message(
        &mut ctx.accounts.tss_pda,
        6, // instruction_id for SPL execute
        nonce,
        Some(amount),
        &additional,
        &message_hash,
        &signature,
        recovery_id,
    )?;

    // 5. Verify target program matches and is executable
    require!(
        ctx.accounts.destination_program.key() == target_program,
        GatewayError::TargetProgramMismatch
    );
    require!(
        ctx.accounts.destination_program.executable,
        GatewayError::InvalidProgram
    );

    // Note: Account validation is done during derivation (step 1)
    // TSS signature enforces: account count, pubkeys, and is_writable flags
    // Outer signer check is done during derivation
    // Nonce is already updated in validate_message (atomic with verification)

    // 6. Validate rent_fee <= gas_fee (rent_fee is a subset of gas_fee)
    // User burns gas_fee on Push Chain, which is split into rent_fee (for CEA) and relayer_fee (for caller)
    require!(rent_fee <= gas_fee, GatewayError::InvalidAmount);

    // 7. Transfer rent_fee (SOL) from vault to CEA (for target contract rent)
    // This is always in SOL, regardless of token type.
    if rent_fee > 0 {
        let vault_bump = config.vault_bump;
        let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[vault_bump]];

        let rent_transfer_ix = system_instruction::transfer(
            &ctx.accounts.vault_sol.key(),
            &ctx.accounts.cea_authority.key(),
            rent_fee,
        );

        invoke_signed(
            &rent_transfer_ix,
            &[
                ctx.accounts.vault_sol.to_account_info(),
                ctx.accounts.cea_authority.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[vault_seeds],
        )?;
    }

    // 8. Create cea_ata if needed (required for any SPL operation, even if amount = 0)
    // For example, unstake operations need CEA ATA to receive tokens even when amount = 0
    if ctx.accounts.cea_ata.data_is_empty() {
        // Manually create ATA using associated token program
        // ATA address = findProgramAddress([authority, TOKEN_PROGRAM_ID, mint], ASSOCIATED_TOKEN_PROGRAM_ID)
        let create_ata_ix = anchor_lang::solana_program::instruction::Instruction {
            program_id: anchor_spl::associated_token::ID,
            accounts: vec![
                SolanaAccountMeta::new(ctx.accounts.caller.key(), true),
                SolanaAccountMeta::new(ctx.accounts.cea_ata.key(), false),
                SolanaAccountMeta::new_readonly(ctx.accounts.cea_authority.key(), false),
                SolanaAccountMeta::new_readonly(ctx.accounts.mint.key(), false),
                SolanaAccountMeta::new_readonly(ctx.accounts.system_program.key(), false),
                SolanaAccountMeta::new_readonly(ctx.accounts.token_program.key(), false),
                SolanaAccountMeta::new_readonly(ctx.accounts.rent.key(), false),
                SolanaAccountMeta::new_readonly(ctx.accounts.associated_token_program.key(), false),
            ],
            data: vec![0], // Create instruction discriminator
        };

        anchor_lang::solana_program::program::invoke(
            &create_ata_ix,
            &[
                ctx.accounts.caller.to_account_info(),
                ctx.accounts.cea_ata.to_account_info(),
                ctx.accounts.cea_authority.to_account_info(),
                ctx.accounts.mint.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
                ctx.accounts.token_program.to_account_info(),
                ctx.accounts.rent.to_account_info(),
                ctx.accounts.associated_token_program.to_account_info(),
            ],
        )?;
    }

    // SECURITY: Ensure provided cea_ata really belongs to cea_authority + mint
    {
        let cea_account_data = ctx.accounts.cea_ata.try_borrow_data()?;
        let cea_account = SplAccount::unpack(&cea_account_data)
            .map_err(|_| error!(GatewayError::InvalidAccount))?;
        require!(
            cea_account.owner == ctx.accounts.cea_authority.key(),
            GatewayError::InvalidOwner
        );
        require!(
            cea_account.mint == ctx.accounts.mint.key(),
            GatewayError::InvalidMint
        );
    }

    // 9. Handle token operations only if amount > 0
    // If amount = 0, skip token transfer - allows operations like unstake without vault transfer
    if amount > 0 {
        // Transfer tokens from vault_ata → cea_ata
        let vault_bump = config.vault_bump;
        let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[vault_bump]];

        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                token::Transfer {
                    from: ctx.accounts.vault_ata.to_account_info(),
                    to: ctx.accounts.cea_ata.to_account_info(),
                    authority: ctx.accounts.vault_authority.to_account_info(),
                },
                &[vault_seeds],
            ),
            amount,
        )?;
    }

    // 10. Transfer relayer_fee (gas_fee - rent_fee) to caller BEFORE self-call check
    // This ensures the caller gets paid even for self-withdraw operations.
    // Relayer pays: executed_tx rent (~890k) + CEA ATA rent if created (~2M) + compute fees
    // Relayer receives: relayer_fee = gas_fee - rent_fee (reimbursement for gateway costs)
    // Vault total payout: rent_fee (to CEA) + relayer_fee (to caller) = gas_fee (matches user burn)
    let relayer_fee = gas_fee
        .checked_sub(rent_fee)
        .ok_or(GatewayError::InvalidAmount)?;

    if relayer_fee > 0 {
        let vault_bump = config.vault_bump;
        let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[vault_bump]];

        let fee_transfer_ix = system_instruction::transfer(
            &ctx.accounts.vault_sol.key(),
            &ctx.accounts.caller.key(),
            relayer_fee,
        );

        invoke_signed(
            &fee_transfer_ix,
            &[
                ctx.accounts.vault_sol.to_account_info(),
                ctx.accounts.caller.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[vault_seeds],
        )?;
    }

    // 11. Build CPI instruction for target program
    let cpi_metas: Vec<SolanaAccountMeta> = accounts
        .iter()
        .map(|a| {
            let is_signer = a.pubkey == cea_key;
            if a.is_writable {
                SolanaAccountMeta::new(a.pubkey, is_signer)
            } else {
                SolanaAccountMeta::new_readonly(a.pubkey, is_signer)
            }
        })
        .collect();

    // 12. Check if target is gateway itself (for CEA withdrawals)
    let cea_bump = ctx.bumps.cea_authority;
    let cea_seeds: &[&[u8]] = &[CEA_SEED, sender.as_ref(), &[cea_bump]];

    if target_program == *ctx.program_id {
        // Gateway self-call: interpret ix_data as a normal gateway instruction
        // and handle CEA withdrawal in-place (no CPI).
        return handle_cea_withdrawal_token(
            &ctx,
            tx_id,
            universal_tx_id,
            sender,
            &ix_data,
            cea_seeds,
        );
    }

    let cpi_ix = Instruction {
        program_id: target_program,
        accounts: cpi_metas,
        data: ix_data.clone(),
    };

    // 13. Invoke target program with cea_authority as signer
    invoke_signed(&cpi_ix, ctx.remaining_accounts, &[cea_seeds])?;

    // Note: CEA ATA and SOL balances persist (no auto-drain, no closing) - matches EVM CEA behavior
    // Users can withdraw via withdrawFundsFromCea() when needed

    // 13. Emit execution event
    emit!(UniversalTxExecuted {
        universal_tx_id,
        tx_id,
        sender,
        target: target_program,
        token: ctx.accounts.mint.key(),
        amount,
        payload: ix_data,
    });

    Ok(())
}

// ============================================
//    CEA WITHDRAWAL HANDLERS
// ============================================

/// Args for CEA withdrawal when target_program == gateway itself.
/// Layout: [8-byte discriminator][borsh(WithdrawFromCeaArgs)].
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct WithdrawFromCeaArgs {
    pub token: Pubkey, // Pubkey::default() for SOL; mint for SPL
    pub amount: u64,   // 0 => withdraw full balance
}

/// Handle withdrawal from CEA (SOL) when target_program == gateway itself
fn handle_cea_withdrawal(
    ctx: &Context<ExecuteUniversalTx>,
    tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    sender: [u8; 20],
    ix_data: &[u8],
    cea_seeds: &[&[u8]],
) -> Result<()> {
    // ix_data must be at least 8 bytes for the Anchor-style discriminator
    require!(ix_data.len() >= 8, GatewayError::InvalidInput);

    // First 8 bytes = discriminator for "global:withdraw_from_cea"
    let discr = &ix_data[..8];
    let expected = hash(b"global:withdraw_from_cea").to_bytes();
    require!(discr == &expected[..8], GatewayError::InvalidInput);

    // Remaining bytes are Borsh-encoded args
    let args = WithdrawFromCeaArgs::try_from_slice(&ix_data[8..])
        .map_err(|_| error!(GatewayError::InvalidInput))?;

    // Handle SOL withdrawal: token must be default (native)
    if args.token == Pubkey::default() {
        let cea_balance = ctx.accounts.cea_authority.lamports();
        let withdraw_amount = if args.amount == 0 {
            cea_balance
        } else {
            require!(
                args.amount <= cea_balance,
                GatewayError::InsufficientBalance
            );
            args.amount
        };

        if withdraw_amount > 0 {
            // Transfer from CEA to vault
            let config = &ctx.accounts.config;
            let vault_bump = config.vault_bump;
            let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[vault_bump]];

            let transfer_ix = system_instruction::transfer(
                &ctx.accounts.cea_authority.key(),
                &ctx.accounts.vault_sol.key(),
                withdraw_amount,
            );

            invoke_signed(
                &transfer_ix,
                &[
                    ctx.accounts.cea_authority.to_account_info(),
                    ctx.accounts.vault_sol.to_account_info(),
                    ctx.accounts.system_program.to_account_info(),
                ],
                &[cea_seeds],
            )?;

            // Emit FUNDS event to unlock funds on Push Chain
            emit!(UniversalTx {
                sender: ctx.accounts.cea_authority.key(),
                recipient: sender,
                token: Pubkey::default(),
                amount: withdraw_amount,
                payload: vec![],
                revert_instruction: RevertInstructions {
                    fund_recipient: ctx.accounts.cea_authority.key(),
                    revert_msg: vec![],
                },
                tx_type: TxType::Funds,
                signature_data: vec![],
            });
        }
    } else {
        // For SOL execute, SPL withdrawals are invalid in this path
        return Err(error!(GatewayError::InvalidToken)); // SOL withdrawal only for execute_universal_tx
    }

    // Emit execution event
    emit!(UniversalTxExecuted {
        universal_tx_id,
        tx_id,
        sender,
        target: *ctx.program_id,
        token: Pubkey::default(),
        amount: 0, // Withdrawal doesn't have an amount in execute context
        payload: vec![],
    });

    Ok(())
}

/// Handle withdrawal from CEA (SPL) when target_program == gateway itself
fn handle_cea_withdrawal_token(
    ctx: &Context<ExecuteUniversalTxToken>,
    tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    sender: [u8; 20],
    ix_data: &[u8],
    cea_seeds: &[&[u8]],
) -> Result<()> {
    // ix_data must be at least 8 bytes for the Anchor-style discriminator
    require!(ix_data.len() >= 8, GatewayError::InvalidInput);

    // First 8 bytes = discriminator for "global:withdraw_from_cea"
    let discr = &ix_data[..8];
    let expected = hash(b"global:withdraw_from_cea").to_bytes();
    require!(discr == &expected[..8], GatewayError::InvalidInput);

    // Remaining bytes are Borsh-encoded args
    let args = WithdrawFromCeaArgs::try_from_slice(&ix_data[8..])
        .map_err(|_| error!(GatewayError::InvalidInput))?;

    require!(
        args.token == ctx.accounts.mint.key(),
        GatewayError::InvalidMint
    );

    // Check CEA ATA balance
    if ctx.accounts.cea_ata.data_is_empty() {
        return Err(error!(GatewayError::InsufficientBalance));
    }

    let cea_ata_data = ctx.accounts.cea_ata.try_borrow_data()?;
    let mut cea_slice: &[u8] = &cea_ata_data;
    let cea_ata_account = TokenAccount::try_deserialize(&mut cea_slice)?;
    let cea_balance = cea_ata_account.amount;
    drop(cea_ata_data);

    let withdraw_amount = if args.amount == 0 {
        cea_balance
    } else {
        require!(
            args.amount <= cea_balance,
            GatewayError::InsufficientBalance
        );
        args.amount
    };

    if withdraw_amount > 0 {
        // Transfer from CEA ATA to vault ATA
        let config = &ctx.accounts.config;
        let vault_bump = config.vault_bump;
        let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[vault_bump]];

        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                token::Transfer {
                    from: ctx.accounts.cea_ata.to_account_info(),
                    to: ctx.accounts.vault_ata.to_account_info(),
                    authority: ctx.accounts.cea_authority.to_account_info(),
                },
                &[cea_seeds],
            ),
            withdraw_amount,
        )?;

        // Emit FUNDS event to unlock funds on Push Chain
        emit!(UniversalTx {
            sender: ctx.accounts.cea_authority.key(),
            recipient: sender,
            token: ctx.accounts.mint.key(),
            amount: withdraw_amount,
            payload: vec![],
            revert_instruction: RevertInstructions {
                fund_recipient: ctx.accounts.cea_authority.key(),
                revert_msg: vec![],
            },
            tx_type: TxType::Funds,
            signature_data: vec![],
        });
    }

    // Emit execution event
    emit!(UniversalTxExecuted {
        universal_tx_id,
        tx_id,
        sender,
        target: *ctx.program_id,
        token: ctx.accounts.mint.key(),
        amount: 0, // Withdrawal doesn't have an amount in execute context
        payload: vec![],
    });

    Ok(())
}
