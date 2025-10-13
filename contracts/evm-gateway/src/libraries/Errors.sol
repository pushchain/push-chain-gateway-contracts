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

    // =========================
    //           UniversalGateway ERRORS
    // =========================
    error NotSupported();
    error DepositFailed();
    error WithdrawFailed();
    error InvalidRecipient();
    error RateLimitExceeded();
    error BlockCapLimitExceeded();
    error SlippageExceededOrExpired();
}
