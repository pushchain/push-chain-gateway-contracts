use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount};

declare_id!("BkpW1WBEsUw1q3NGewePPVTWvc1AS6GLukgpfSQivd5L");

#[program]
pub mod test_counter {
    use super::*;

    /// Initialize a counter account
    pub fn initialize(ctx: Context<Initialize>, initial_value: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;
        counter.value = initial_value;
        counter.authority = ctx.accounts.authority.key();
        msg!("Counter initialized with value: {}", initial_value);
        Ok(())
    }

    /// Increment counter (can be called via CPI from gateway)
    pub fn increment(ctx: Context<UpdateCounter>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;
        counter.value = counter
            .value
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;
        msg!(
            "Counter incremented by {}, new value: {}",
            amount,
            counter.value
        );

        emit!(CounterUpdated {
            counter: counter.key(),
            old_value: counter.value.saturating_sub(amount),
            new_value: counter.value,
            operation: "increment".to_string(),
        });

        Ok(())
    }

    /// Decrement counter (can be called via CPI from gateway)
    pub fn decrement(ctx: Context<UpdateCounter>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;
        counter.value = counter
            .value
            .checked_sub(amount)
            .ok_or(CounterError::Underflow)?;
        msg!(
            "Counter decremented by {}, new value: {}",
            amount,
            counter.value
        );

        emit!(CounterUpdated {
            counter: counter.key(),
            old_value: counter.value.saturating_add(amount),
            new_value: counter.value,
            operation: "decrement".to_string(),
        });

        Ok(())
    }

    /// Receive SOL and increment counter
    /// This simulates a program that receives SOL via execute_universal_tx
    /// The staging_authority already has SOL transferred from gateway
    pub fn receive_sol(ctx: Context<ReceiveSol>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;

        // Transfer SOL from staging_authority to recipient
        anchor_lang::solana_program::program::invoke(
            &anchor_lang::solana_program::system_instruction::transfer(
                ctx.accounts.staging_authority.key,
                ctx.accounts.recipient.key,
                amount,
            ),
            &[
                ctx.accounts.staging_authority.to_account_info(),
                ctx.accounts.recipient.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
        )?;

        // Increment counter by amount received
        counter.value = counter
            .value
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        msg!(
            "Received {} lamports, counter incremented to: {}",
            amount,
            counter.value
        );

        emit!(CounterUpdated {
            counter: counter.key(),
            old_value: counter.value.saturating_sub(amount),
            new_value: counter.value,
            operation: "receive_sol".to_string(),
        });

        Ok(())
    }

    /// Receive SPL tokens and increment counter by amount received
    /// This simulates a program that receives SPL tokens via execute_universal_tx_token
    pub fn receive_spl(ctx: Context<ReceiveSpl>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;

        // Transfer tokens from staging_ata to recipient_ata
        // staging_ata is owned by staging_authority (gateway's per-tx PDA)
        token::transfer(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                token::Transfer {
                    from: ctx.accounts.staging_ata.to_account_info(),
                    to: ctx.accounts.recipient_ata.to_account_info(),
                    authority: ctx.accounts.staging_authority.to_account_info(),
                },
            ),
            amount,
        )?;

        // Increment counter by amount received
        counter.value = counter
            .value
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        msg!(
            "Received {} tokens, counter incremented to: {}",
            amount,
            counter.value
        );

        emit!(CounterUpdated {
            counter: counter.key(),
            old_value: counter.value.saturating_sub(amount),
            new_value: counter.value,
            operation: "receive_spl".to_string(),
        });

        Ok(())
    }
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = authority,
        space = 8 + Counter::LEN,
    )]
    pub counter: Account<'info, Counter>,

    #[account(mut)]
    pub authority: Signer<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UpdateCounter<'info> {
    #[account(
        mut,
        has_one = authority @ CounterError::Unauthorized,
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: Can be staging_authority from gateway or any other signer
    pub authority: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct ReceiveSol<'info> {
    #[account(mut)]
    pub counter: Account<'info, Counter>,

    /// CHECK: Recipient account that will receive SOL
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,

    /// CHECK: Staging authority from gateway (will have SOL, signs via invoke_signed)
    #[account(mut)]
    pub staging_authority: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ReceiveSpl<'info> {
    #[account(mut)]
    pub counter: Account<'info, Counter>,

    /// CHECK: Staging ATA from gateway (will have tokens)
    #[account(mut)]
    pub staging_ata: Account<'info, TokenAccount>,

    /// CHECK: Recipient ATA (will receive tokens)
    #[account(mut)]
    pub recipient_ata: Account<'info, TokenAccount>,

    /// CHECK: Staging authority from gateway (signs for staging_ata)
    pub staging_authority: Signer<'info>,

    pub token_program: Program<'info, Token>,
}

#[account]
pub struct Counter {
    pub value: u64,
    pub authority: Pubkey,
}

impl Counter {
    pub const LEN: usize = 8 + 8 + 32; // discriminator + u64 + Pubkey
}

#[event]
pub struct CounterUpdated {
    pub counter: Pubkey,
    pub old_value: u64,
    pub new_value: u64,
    pub operation: String,
}

#[error_code]
pub enum CounterError {
    #[msg("Counter overflow")]
    Overflow,
    #[msg("Counter underflow")]
    Underflow,
    #[msg("Unauthorized")]
    Unauthorized,
}
