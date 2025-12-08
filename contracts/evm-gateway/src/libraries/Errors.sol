// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library Errors {
    // =========================
    //           Common ERRORS
    // =========================
    error ZeroAddress();
    error InvalidData();
    error InvalidInput();
    error InvalidAmount();
    error InvalidTxType();
    error InvalidCapRange();
    error PayloadExecuted();

    // =========================
    //           UniversalGateway ERRORS
    // =========================
    error NotSupported();
    error DepositFailed();
    error WithdrawFailed();
    error ExecutionFailed();
    error InvalidRecipient();
    error RateLimitExceeded();
    error BlockCapLimitExceeded();
    error SlippageExceededOrExpired();
    error TokenNotSupported();
    error TokenBurnFailed(address token, uint256 amount);
    error GasFeeTransferFailed(address token, address from, uint256 amount);
    error RefundFailed(address recipient, uint256 amount);
}
