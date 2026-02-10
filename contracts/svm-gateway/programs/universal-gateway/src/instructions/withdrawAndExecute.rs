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
    sysvar::rent as rent_sysvar,
};
use anchor_spl::associated_token::spl_associated_token_account;
use anchor_spl::token::{spl_token, Mint, Token};
use spl_token::state::Account as SplAccount;

// =========================
//  UNIFIED WITHDRAW_AND_EXECUTE
// =========================

#[derive(Accounts)]
#[instruction(instruction_id: u8, tx_id: [u8; 32], universal_tx_id: [u8; 32], amount: u64, sender: [u8; 20], writable_flags: Vec<u8>, ix_data: Vec<u8>, gas_fee: u64, rent_fee: u64, signature: [u8; 64], recovery_id: u8, message_hash: [u8; 32], nonce: u64)]
pub struct WithdrawAndExecute<'info> {
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

    pub system_program: Program<'info, System>,
    /// CHECK: Target program for execute mode
    /// Pass system program id for withdraw, it's ignored
    pub destination_program: UncheckedAccount<'info>,

    // --- Optional SPL accounts

    /// CHECK: Recipient wallet for withdraw mode
    #[account(mut)]
    pub recipient: Option<UncheckedAccount<'info>>,

    /// CHECK: Vault ATA for this mint
    #[account(mut)]
    pub vault_ata: Option<UncheckedAccount<'info>>,

    /// CHECK: CEA ATA (created if missing via manual CPI)
    #[account(mut)]
    pub cea_ata: Option<UncheckedAccount<'info>>,

    pub mint: Option<Account<'info, Mint>>,

    pub token_program: Option<Program<'info, Token>>,

    /// CHECK: Rent sysvar (validated at runtime)
    pub rent: Option<UncheckedAccount<'info>>,

    /// CHECK: Associated token program (validated at runtime)
    pub associated_token_program: Option<UncheckedAccount<'info>>,

    // --- Optional recipient ATA (required for SPL withdraw mode) ---
    /// CHECK: Recipient ATA for SPL withdraw (CEA ATA → recipient ATA)
    #[account(mut)]
    pub recipient_ata: Option<UncheckedAccount<'info>>,
}

pub fn withdraw_and_execute(
    ctx: Context<WithdrawAndExecute>,
    instruction_id: u8,
    tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    amount: u64,
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
    let config = &ctx.accounts.config;
    require!(!config.paused, GatewayError::Paused);

    // Validate instruction_id: 1=withdraw, 2=execute
    require!(
        instruction_id == 1 || instruction_id == 2,
        GatewayError::InvalidInstruction
    );
    let is_withdraw = instruction_id == 1;

    // Derive token from mint account: if mint.is_some() → SPL, else → SOL
    let is_native = ctx.accounts.mint.is_none();
    let token = if is_native {
        Pubkey::default()
    } else {
        ctx.accounts.mint.as_ref().unwrap().key()
    };

    // Enforce SPL/SOL account presence
    if is_native {
        require!(
            ctx.accounts.vault_ata.is_none() &&
            ctx.accounts.cea_ata.is_none() &&
            ctx.accounts.mint.is_none() &&
            ctx.accounts.token_program.is_none() &&
            ctx.accounts.rent.is_none() &&
            ctx.accounts.associated_token_program.is_none(),
            GatewayError::InvalidAccount
        );
    } else {
        require!(
            ctx.accounts.vault_ata.is_some() &&
            ctx.accounts.cea_ata.is_some() &&
            ctx.accounts.mint.is_some() &&
            ctx.accounts.token_program.is_some() &&
            ctx.accounts.rent.is_some() &&
            ctx.accounts.associated_token_program.is_some(),
            GatewayError::InvalidAccount
        );
    }

    // Enforce mode-specific accounts: exactly one of destination_program or recipient
    if is_withdraw {
        require!(ctx.accounts.recipient.is_some(), GatewayError::InvalidAccount);
    } else {
        require!(ctx.accounts.recipient.is_none(), GatewayError::InvalidAccount);
    }
    
    // Derive target from the mode-specific account
    let target = if is_withdraw {
        ctx.accounts.recipient.as_ref().unwrap().key()
    } else {
        ctx.accounts.destination_program.key()
    };

    // Mode-specific validation
    if is_withdraw {
        // Withdraw mode validations
        require!(amount > 0, GatewayError::InvalidAmount);
        require!(sender != [0u8; 20], GatewayError::InvalidInput);
        require!(writable_flags.is_empty(), GatewayError::InvalidInput);
        require!(ix_data.is_empty(), GatewayError::InvalidInput);
        require!(rent_fee == 0, GatewayError::InvalidInput);
        // SPL withdraw requires recipient_ata
        if !is_native {
            require!(
                ctx.accounts.recipient_ata.is_some(),
                GatewayError::InvalidAccount
            );
        }
        // Execute mode fields on remaining_accounts must be empty
        require!(
            ctx.remaining_accounts.is_empty(),
            GatewayError::InvalidInput
        );
    } else {
        // Execute mode validations
        require!(
            ctx.accounts.recipient_ata.is_none(),
            GatewayError::InvalidInput
        );

        // Validate account count and flags length match
        let accounts_count = ctx.remaining_accounts.len();
        let expected_writable_flags_len = (accounts_count + 7) / 8;
        require!(
            writable_flags.len() == expected_writable_flags_len,
            GatewayError::InvalidAccount
        );

        // Validate rent_fee <= gas_fee
        require!(rent_fee <= gas_fee, GatewayError::InvalidAmount);
    }

    // Build mode-specific TSS hash and validate
    let token_bytes = token.to_bytes();
    let mut gas_fee_buf = [0u8; 8];
    gas_fee_buf.copy_from_slice(&gas_fee.to_be_bytes());

    if is_withdraw {
        // Withdraw TSS hash: [universal_tx_id, tx_id, sender, token, target, gas_fee]
        let target_bytes = target.to_bytes();
        let additional: [&[u8]; 6] = [
            &universal_tx_id[..],
            &tx_id[..],
            &sender[..],
            &token_bytes[..],
            &target_bytes[..],
            &gas_fee_buf,
        ];
        validate_message(
            &mut ctx.accounts.tss_pda,
            1, // instruction_id for withdraw
            nonce,
            Some(amount),
            &additional,
            &message_hash,
            &signature,
            recovery_id,
        )?;
    } else {
        // Execute TSS hash: [universal_tx_id, tx_id, target, sender, accounts_buf, ix_data_buf, gas_fee, rent_fee, token]

        // 1. Reconstruct accounts from remaining_accounts
        let mut accounts = Vec::new();
        for (i, acc_info) in ctx.remaining_accounts.iter().enumerate() {
            let byte_idx = i / 8;
            let bit_idx = 7 - (i % 8);
            let is_writable = (writable_flags[byte_idx] >> bit_idx) & 1 == 1;
            accounts.push(GatewayAccountMeta {
                pubkey: *acc_info.key,
                is_writable,
            });
        }

        // 2. Validate remaining_accounts
        validate_remaining_accounts(&accounts, ctx.remaining_accounts)?;

        // 3. Build serialized accounts buffer
        let mut accounts_buf = Vec::new();
        let accounts_count = ctx.remaining_accounts.len() as u32;
        accounts_buf.extend_from_slice(&accounts_count.to_be_bytes());
        for account in &accounts {
            accounts_buf.extend_from_slice(&account.pubkey.to_bytes());
            accounts_buf.push(if account.is_writable { 1 } else { 0 });
        }

        // 4. Build serialized ix_data buffer
        let mut ix_data_buf = Vec::new();
        let ix_data_length = ix_data.len() as u32;
        ix_data_buf.extend_from_slice(&ix_data_length.to_be_bytes());
        ix_data_buf.extend_from_slice(&ix_data);

        let mut rent_fee_buf = [0u8; 8];
        rent_fee_buf.copy_from_slice(&rent_fee.to_be_bytes());

        let additional: [&[u8]; 9] = [
            &universal_tx_id[..],
            &tx_id[..],
            &target.to_bytes(),
            &sender[..],
            &accounts_buf,
            &ix_data_buf,
            &gas_fee_buf,
            &rent_fee_buf,
            &token_bytes,
        ];
        validate_message(
            &mut ctx.accounts.tss_pda,
            2, // instruction_id for execute
            nonce,
            Some(amount),
            &additional,
            &message_hash,
            &signature,
            recovery_id,
        )?;

        // Verify target program is executable (execute mode only)
        require!(
            ctx.accounts.destination_program.executable,
            GatewayError::InvalidProgram
        );
    }

    // Calculate vault seeds once (used for all vault transfers)
    let vault_bump = config.vault_bump;
    let vault_seeds: &[&[u8]] = &[VAULT_SEED, &[vault_bump]];

    // Transfer rent_fee to CEA (no-op for withdraw since rent_fee=0)
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

    // Transfer amount vault → CEA (SOL or SPL)
    if is_native {
        // SOL transfer
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
    } else {
        // SPL token transfer: validate and unwrap optional accounts
        let vault_ata = ctx
            .accounts
            .vault_ata
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let cea_ata = ctx
            .accounts
            .cea_ata
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let token_mint = ctx
            .accounts
            .mint
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let token_program = ctx
            .accounts
            .token_program
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let rent_account = ctx
            .accounts
            .rent
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let ata_program = ctx
            .accounts
            .associated_token_program
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;

        // Validate token parameter matches mint account
        require!(token == token_mint.key(), GatewayError::InvalidMint);

        // Validate program IDs
        require!(
            token_program.key() == spl_token::ID,
            GatewayError::InvalidAccount
        );
        require!(
            ata_program.key() == spl_associated_token_account::ID,
            GatewayError::InvalidAccount
        );
        require!(
            rent_account.key() == rent_sysvar::ID,
            GatewayError::InvalidAccount
        );

        // SECURITY: Validate vault_ata is owned by vault and matches mint
        let vault_ata_data = vault_ata.try_borrow_data()?.to_vec();
        let parsed_vault_ata = SplAccount::unpack(&vault_ata_data)
            .map_err(|_| error!(GatewayError::InvalidAccount))?;
        require!(
            parsed_vault_ata.owner == ctx.accounts.vault_sol.key(),
            GatewayError::InvalidOwner
        );
        require!(
            parsed_vault_ata.mint == token_mint.key(),
            GatewayError::InvalidMint
        );

        // Derive expected CEA ATA and validate
        let expected_cea_ata = spl_associated_token_account::get_associated_token_address(
            &ctx.accounts.cea_authority.key(),
            &token_mint.key(),
        );
        require!(
            cea_ata.key() == expected_cea_ata,
            GatewayError::InvalidAccount
        );

        // Create CEA ATA if it doesn't exist
        let cea_ata_info = cea_ata.to_account_info();
        if cea_ata_info.data_is_empty() {
            let create_ata_ix =
                spl_associated_token_account::instruction::create_associated_token_account(
                    &ctx.accounts.caller.key(),
                    &ctx.accounts.cea_authority.key(),
                    &token_mint.key(),
                    &spl_token::ID,
                );
            invoke_signed(
                &create_ata_ix,
                &[
                    ctx.accounts.caller.to_account_info(),
                    cea_ata.to_account_info(),
                    ctx.accounts.cea_authority.to_account_info(),
                    token_mint.to_account_info(),
                    ctx.accounts.system_program.to_account_info(),
                    token_program.to_account_info(),
                    ata_program.to_account_info(),
                    rent_account.to_account_info(),
                ],
                &[],
            )?;
        }
        // Validate existing CEA ATA: mint + owner
        let cea_ata_data = cea_ata.try_borrow_data()?.to_vec();
        let parsed_cea_ata = SplAccount::unpack(&cea_ata_data)
            .map_err(|_| error!(GatewayError::InvalidAccount))?;
        require!(
            parsed_cea_ata.mint == token_mint.key(),
            GatewayError::InvalidMint
        );
        require!(
            parsed_cea_ata.owner == ctx.accounts.cea_authority.key(),
            GatewayError::InvalidOwner
        );

        // Transfer tokens from vault_ata → cea_ata
        if amount > 0 {
            let transfer_ix = spl_token::instruction::transfer(
                &spl_token::ID,
                &vault_ata.key(),
                &cea_ata.key(),
                &ctx.accounts.vault_sol.key(),
                &[],
                amount,
            )?;

            invoke_signed(
                &transfer_ix,
                &[
                    vault_ata.to_account_info(),
                    cea_ata.to_account_info(),
                    ctx.accounts.vault_sol.to_account_info(),
                ],
                &[vault_seeds],
            )?;
        }
    }

    // Transfer relayer_fee (gas_fee - rent_fee) to caller
    let relayer_fee = gas_fee
        .checked_sub(rent_fee)
        .ok_or(GatewayError::InvalidAmount)?;

    if relayer_fee > 0 {
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

    // Branch: withdraw vs execute
    let cea_bump = ctx.bumps.cea_authority;
    let cea_seeds: &[&[u8]] = &[CEA_SEED, sender.as_ref(), &[cea_bump]];

    if is_withdraw {
        // Withdraw: CEA → target (SOL) or CEA ATA → recipient ATA (SPL)
        internal_withdraw(&ctx, amount, token, cea_seeds)?;
    } else {
        // Execute: reconstruct accounts and CPI
        let cea_key = ctx.accounts.cea_authority.key();

        // Reconstruct accounts (same as in TSS validation above)
        let mut accounts = Vec::new();
        for (i, acc_info) in ctx.remaining_accounts.iter().enumerate() {
            let byte_idx = i / 8;
            let bit_idx = 7 - (i % 8);
            let is_writable = (writable_flags[byte_idx] >> bit_idx) & 1 == 1;
            accounts.push(GatewayAccountMeta {
                pubkey: *acc_info.key,
                is_writable,
            });
        }

        // Check if target is gateway itself (for CEA withdrawals)
        if target == *ctx.program_id {
            return handle_cea_withdrawal(
                &ctx,
                tx_id,
                universal_tx_id,
                sender,
                &ix_data,
                cea_seeds,
            );
        }

        // Build CPI instruction for target program
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

        let cpi_ix = Instruction {
            program_id: target,
            accounts: cpi_metas,
            data: ix_data.clone(),
        };

        invoke_signed(&cpi_ix, ctx.remaining_accounts, &[cea_seeds])?;
    }

    // Emit execution event
    emit!(UniversalTxExecuted {
        tx_id,
        universal_tx_id,
        sender,
        target,
        token,
        amount,
        payload: ix_data,
    });

    Ok(())
}

// ============================================
//    INTERNAL WITHDRAW HELPER
// ============================================

/// Transfer funds from CEA to recipient (withdraw mode)
/// SOL: system_instruction::transfer CEA → target
/// SPL: spl_token::transfer CEA ATA → recipient ATA
fn internal_withdraw(
    ctx: &Context<WithdrawAndExecute>,
    amount: u64,
    token: Pubkey,
    cea_seeds: &[&[u8]],
) -> Result<()> {
    let recipient = ctx.accounts.recipient.as_ref()
        .ok_or(error!(GatewayError::InvalidAccount))?;
    let target = recipient.key();
    let is_native = token == Pubkey::default();

    if is_native {
        // SOL: CEA → target
        if amount > 0 {
            let transfer_ix = system_instruction::transfer(
                &ctx.accounts.cea_authority.key(),
                &target,
                amount,
            );

            invoke_signed(
                &transfer_ix,
                &[
                    ctx.accounts.cea_authority.to_account_info(),
                    recipient.to_account_info(),
                    ctx.accounts.system_program.to_account_info(),
                ],
                &[cea_seeds],
            )?;
        }
    } else {
        // SPL: CEA ATA → recipient ATA
        let cea_ata = ctx
            .accounts
            .cea_ata
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let recipient_ata = ctx
            .accounts
            .recipient_ata
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let token_mint = ctx
            .accounts
            .mint
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;

        // Validate recipient_ata: derivation matches (target, mint), owner, mint
        let expected_recipient_ata = spl_associated_token_account::get_associated_token_address(
            &target,
            &token_mint.key(),
        );
        require!(
            recipient_ata.key() == expected_recipient_ata,
            GatewayError::InvalidAccount
        );

        // Validate recipient_ata data: owner + mint
        let recipient_ata_data = recipient_ata.try_borrow_data()?.to_vec();
        let parsed_recipient_ata = SplAccount::unpack(&recipient_ata_data)
            .map_err(|_| error!(GatewayError::InvalidAccount))?;
        require!(
            parsed_recipient_ata.owner == target,
            GatewayError::InvalidOwner
        );
        require!(
            parsed_recipient_ata.mint == token_mint.key(),
            GatewayError::InvalidMint
        );

        // Transfer from CEA ATA → recipient ATA
        if amount > 0 {
            let transfer_ix = spl_token::instruction::transfer(
                &spl_token::ID,
                &cea_ata.key(),
                &recipient_ata.key(),
                &ctx.accounts.cea_authority.key(),
                &[],
                amount,
            )?;

            invoke_signed(
                &transfer_ix,
                &[
                    cea_ata.to_account_info(),
                    recipient_ata.to_account_info(),
                    ctx.accounts.cea_authority.to_account_info(),
                ],
                &[cea_seeds],
            )?;
        }
    }

    Ok(())
}

// ============================================
//    CEA WITHDRAWAL HANDLER (UNIFIED)
// ============================================

/// Args for CEA withdrawal when target_program == gateway itself.
/// Layout: [8-byte discriminator][borsh(WithdrawFromCeaArgs)].
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct WithdrawFromCeaArgs {
    pub token: Pubkey, // Pubkey::default() for SOL; mint for SPL
    pub amount: u64,   // 0 => withdraw full balance
}

/// Handle withdrawal from CEA when target_program == gateway itself
fn handle_cea_withdrawal(
    ctx: &Context<WithdrawAndExecute>,
    tx_id: [u8; 32],
    universal_tx_id: [u8; 32],
    sender: [u8; 20],
    ix_data: &[u8],
    cea_seeds: &[&[u8]],
) -> Result<()> {
    // Derive token from mint account (must match parent function's derivation)
    let token = if ctx.accounts.mint.is_none() {
        Pubkey::default()
    } else {
        ctx.accounts.mint.as_ref().unwrap().key()
    };

    // ix_data must be at least 8 bytes for the Anchor-style discriminator
    require!(ix_data.len() >= 8, GatewayError::InvalidInput);

    // First 8 bytes = discriminator for "global:withdraw_from_cea"
    let discr = &ix_data[..8];
    let expected = hash(b"global:withdraw_from_cea").to_bytes();
    require!(discr == &expected[..8], GatewayError::InvalidInput);

    // Remaining bytes are Borsh-encoded args
    let args = WithdrawFromCeaArgs::try_from_slice(&ix_data[8..])
        .map_err(|_| error!(GatewayError::InvalidInput))?;

    // Validate args.token matches derived token
    require!(args.token == token, GatewayError::InvalidMint);
    if args.token == Pubkey::default() {
        // Handle SOL withdrawal
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
        // Handle SPL withdrawal
        let vault_ata = ctx
            .accounts
            .vault_ata
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let cea_ata = ctx
            .accounts
            .cea_ata
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let token_mint = ctx
            .accounts
            .mint
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;
        let _token_program = ctx
            .accounts
            .token_program
            .as_ref()
            .ok_or(error!(GatewayError::InvalidAccount))?;

        require!(args.token == token_mint.key(), GatewayError::InvalidMint);

        // Check CEA ATA balance
        let cea_ata_data = cea_ata.try_borrow_data()?.to_vec();
        let parsed_cea_ata =
            SplAccount::unpack(&cea_ata_data).map_err(|_| error!(GatewayError::InvalidAccount))?;
        let cea_balance = parsed_cea_ata.amount;

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
            let transfer_ix = spl_token::instruction::transfer(
                &spl_token::ID,
                &cea_ata.key(),
                &vault_ata.key(),
                &ctx.accounts.cea_authority.key(),
                &[],
                withdraw_amount,
            )?;

            invoke_signed(
                &transfer_ix,
                &[
                    cea_ata.to_account_info(),
                    vault_ata.to_account_info(),
                    ctx.accounts.cea_authority.to_account_info(),
                ],
                &[cea_seeds],
            )?;

            // Emit FUNDS event to unlock funds on Push Chain
            emit!(UniversalTx {
                sender: ctx.accounts.cea_authority.key(),
                recipient: sender,
                token: token_mint.key(),
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
    }

    // Emit execution event
    emit!(UniversalTxExecuted {
        tx_id,
        universal_tx_id,
        sender,
        target: *ctx.program_id,
        token,
        amount: 0, // Withdrawal doesn't have an amount in execute context
        payload: vec![],
    });

    Ok(())
}
