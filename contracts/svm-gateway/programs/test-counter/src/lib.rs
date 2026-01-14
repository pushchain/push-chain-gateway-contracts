use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount};

declare_id!("4mpHkerNsaJPp35fyT5bkoXxuEBczGq6HUKTtrzFcptx");

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

    /// Stake SOL - tracks staked amount in Stake PDA (CEA holds actual SOL)
    /// This tests CEA identity preservation (same authority = same stake PDA)
    pub fn stake_sol(ctx: Context<StakeSol>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;
        let stake = &mut ctx.accounts.stake;

        // Initialize or update stake account (just tracking, CEA holds the SOL)
        stake.authority = ctx.accounts.authority.key();
        stake.amount = stake
            .amount
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        // Increment counter
        counter.value = counter
            .value
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        msg!(
            "Staked {} SOL (tracked), total stake: {}",
            amount,
            stake.amount
        );
        Ok(())
    }

    /// Unstake SOL - returns tracked SOL back to authority (no-op since CEA already holds it)
    /// In real scenario, this would verify and transfer, but for testing we just track
    pub fn unstake_sol(ctx: Context<UnstakeSol>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;
        let stake = &mut ctx.accounts.stake;

        require!(stake.amount >= amount, CounterError::InsufficientStake);

        // Decrement stake tracking
        stake.amount = stake
            .amount
            .checked_sub(amount)
            .ok_or(CounterError::Underflow)?;

        // Increment counter
        counter.value = counter
            .value
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        msg!(
            "Unstaked {} SOL (tracked), remaining stake: {}",
            amount,
            stake.amount
        );
        Ok(())
    }

    /// Receive SOL and increment counter (for non-CEA tests)
    pub fn receive_sol(ctx: Context<ReceiveSol>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;

        // Transfer SOL from cea_authority to recipient
        anchor_lang::solana_program::program::invoke(
            &anchor_lang::solana_program::system_instruction::transfer(
                ctx.accounts.cea_authority.key,
                ctx.accounts.recipient.key,
                amount,
            ),
            &[
                ctx.accounts.cea_authority.to_account_info(),
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
        Ok(())
    }

    /// Stake SPL tokens - tracks staked amount (tokens stay in CEA ATA)
    pub fn stake_spl(ctx: Context<StakeSpl>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;
        let stake = &mut ctx.accounts.stake;

        // Initialize or update stake account (just tracking, CEA ATA holds tokens)
        stake.authority = ctx.accounts.authority.key();
        stake.amount = stake
            .amount
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        // Increment counter
        counter.value = counter
            .value
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        msg!(
            "Staked {} SPL tokens (tracked), total stake: {}",
            amount,
            stake.amount
        );
        Ok(())
    }

    /// Unstake SPL tokens - returns tracked tokens back to authority
    pub fn unstake_spl(ctx: Context<UnstakeSpl>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;
        let stake = &mut ctx.accounts.stake;

        require!(stake.amount >= amount, CounterError::InsufficientStake);

        // Decrement stake tracking
        stake.amount = stake
            .amount
            .checked_sub(amount)
            .ok_or(CounterError::Underflow)?;

        // Increment counter
        counter.value = counter
            .value
            .checked_add(amount)
            .ok_or(CounterError::Overflow)?;

        msg!(
            "Unstaked {} SPL tokens (tracked), remaining stake: {}",
            amount,
            stake.amount
        );
        Ok(())
    }

    /// Receive SPL tokens and increment counter (for non-CEA tests)
    pub fn receive_spl(ctx: Context<ReceiveSpl>, amount: u64) -> Result<()> {
        let counter = &mut ctx.accounts.counter;

        // Transfer tokens from cea_ata to recipient_ata
        token::transfer(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                token::Transfer {
                    from: ctx.accounts.cea_ata.to_account_info(),
                    to: ctx.accounts.recipient_ata.to_account_info(),
                    authority: ctx.accounts.cea_authority.to_account_info(),
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
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(
        init,
        payer = authority,
        space = 8 + Counter::LEN,
        seeds = [b"counter"],
        bump
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
        seeds = [b"counter"],
        bump,
        has_one = authority @ CounterError::Unauthorized,
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: Can be cea_authority from gateway or any other signer
    pub authority: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct StakeSol<'info> {
    #[account(
        mut,
        seeds = [b"counter"],
        bump
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: Authority (CEA from gateway)
    #[account(mut)]
    pub authority: UncheckedAccount<'info>,

    #[account(
        init_if_needed,
        payer = authority,
        space = 8 + Stake::LEN,
        seeds = [b"stake", authority.key().as_ref()],
        bump
    )]
    pub stake: Account<'info, Stake>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UnstakeSol<'info> {
    #[account(
        mut,
        seeds = [b"counter"],
        bump
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: Authority (CEA from gateway)
    #[account(mut)]
    pub authority: UncheckedAccount<'info>,

    #[account(
        mut,
        seeds = [b"stake", authority.key().as_ref()],
        bump,
        has_one = authority @ CounterError::Unauthorized
    )]
    pub stake: Account<'info, Stake>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct StakeSpl<'info> {
    #[account(
        mut,
        seeds = [b"counter"],
        bump
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: Authority (CEA from gateway)
    #[account(mut)]
    pub authority: UncheckedAccount<'info>,

    #[account(
        init_if_needed,
        payer = authority,
        space = 8 + Stake::LEN,
        seeds = [b"stake", authority.key().as_ref()],
        bump
    )]
    pub stake: Account<'info, Stake>,

    pub mint: Account<'info, anchor_spl::token::Mint>,

    #[account(mut)]
    pub authority_ata: Account<'info, TokenAccount>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct UnstakeSpl<'info> {
    #[account(
        mut,
        seeds = [b"counter"],
        bump
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: Authority (CEA from gateway)
    pub authority: UncheckedAccount<'info>,

    #[account(
        mut,
        seeds = [b"stake", authority.key().as_ref()],
        bump,
        has_one = authority @ CounterError::Unauthorized
    )]
    pub stake: Account<'info, Stake>,

    pub mint: Account<'info, anchor_spl::token::Mint>,

    #[account(mut)]
    pub authority_ata: Account<'info, TokenAccount>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ReceiveSol<'info> {
    #[account(
        mut,
        seeds = [b"counter"],
        bump
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: Recipient account that will receive SOL
    #[account(mut)]
    pub recipient: UncheckedAccount<'info>,

    /// CHECK: CEA authority from gateway (will have SOL, signs via invoke_signed)
    #[account(mut)]
    pub cea_authority: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ReceiveSpl<'info> {
    #[account(
        mut,
        seeds = [b"counter"],
        bump
    )]
    pub counter: Account<'info, Counter>,

    /// CHECK: CEA ATA from gateway (will have tokens)
    #[account(mut)]
    pub cea_ata: Account<'info, TokenAccount>,

    /// CHECK: Recipient ATA (will receive tokens)
    #[account(mut)]
    pub recipient_ata: Account<'info, TokenAccount>,

    /// CHECK: CEA authority from gateway (signs for cea_ata)
    pub cea_authority: Signer<'info>,

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

#[account]
pub struct Stake {
    pub authority: Pubkey,
    pub amount: u64,
}

impl Stake {
    pub const LEN: usize = 32 + 8; // Pubkey + u64
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
    #[msg("Insufficient stake")]
    InsufficientStake,
}
