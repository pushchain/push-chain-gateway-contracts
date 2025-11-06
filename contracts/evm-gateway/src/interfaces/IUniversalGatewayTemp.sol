// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    RevertInstructions,
    UniversalPayload,
    TX_TYPE,
    UniversalTxRequest,
    UniversalTxRequestToken
} from "../libraries/Types.sol";

interface IUniversalGatewayTemp {
    // =========================
    //           EVENTS
    // =========================

    /// @notice                      Caps updated event
    /// @param minCapUsd             Minimum cap in USD
    /// @param maxCapUsd             Maximum cap in USD
    event CapsUpdated(uint256 minCapUsd, uint256 maxCapUsd);

    /// @notice                      Rate-limit / config events
    /// @param oldDuration           Previous epoch duration: Duration of the epoch before the update.
    /// @param newDuration           New epoch duration: Duration of the epoch after the update.
    event EpochDurationUpdated(uint256 oldDuration, uint256 newDuration);

    /// @notice                     Token limit threshold updated event
    /// @param token                Token address
    /// @param newThreshold         New threshold
    event TokenLimitThresholdUpdated(address indexed token, uint256 newThreshold);

    /// @notice                     Checks if a token is supported by the gateway.
    /// @param token                Token address to check
    /// @return                     True if the token is supported, false otherwise
    function isSupportedToken(address token) external view returns (bool);

    /// @notice                     Computes the minimum and maximum deposit amounts in native ETH (wei) implied by the USD caps.
    /// @dev                        Uses the current ETH/USD price from {getEthUsdPrice}.
    /// @return minValue            Minimum native amount (in wei) allowed by MIN_CAP_UNIVERSAL_TX_USD
    /// @return maxValue            Maximum native amount (in wei) allowed by MAX_CAP_UNIVERSAL_TX_USD
    function getMinMaxValueForNative() external view returns (uint256 minValue, uint256 maxValue);

    /// @notice                     Universal transaction event that originates from external chain.
    /// @param sender               Sender of the tx on external chain
    /// @param recipient            Recipient address on Push Chain: for address(0), recipient = sender's UEA on Push Chain.
    /// @param token                Token address being sent
    /// @param amount               Amount of token being sent
    /// @param payload              Payload for arbitrary call on Push Chain: for funds-only tx, payload is empty.
    /// @param revertInstruction    Revert settings configuration
    /// @param txType               Transaction type: TX_TYPE enum
    /// @param signatureData        Signature data: for signedVerification, signatureData is the signature of the sender.
    event UniversalTx(
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        bytes payload,
        RevertInstructions revertInstruction,
        TX_TYPE txType,
        bytes signatureData
    );

    /// @notice                     Universal tx execution event that is executed on External Chains.
    /// @param txID                 Unique transaction identifier
    /// @param originCaller         Original caller/user on source chain ( Push Chain)
    /// @param target               Target contract address to execute call
    /// @param token                Token address being sent
    /// @param amount               Amount of token being sent
    /// @param data                 Calldata to be executed on target contract on external chain
    event UniversalTxExecuted(
        bytes32 indexed txID,
        address indexed originCaller,
        address indexed target,
        address token,
        uint256 amount,
        bytes data
    );

    /// @notice                      Vault updated event
    /// @param oldVault              Previous Vault address
    /// @param newVault              New Vault address
    event VaultUpdated(address indexed oldVault, address indexed newVault);

    /// @notice         W           Withdraw token event
    /// @param txID                 Unique transaction identifier
    /// @param originCaller         Original caller/user on source chain ( Push Chain)
    /// @param token                Token address being sent
    /// @param to                   Recipient address on Push Chain
    /// @param amount               Amount of token being sent
    event WithdrawToken(
        bytes32 indexed txID, address indexed originCaller, address indexed token, address to, uint256 amount
    );

    /// @notice                     Revert withdraw event: For withdrwals/actions during a revert
    /// @param to                   Recipient address on external chain
    /// @param token                Token address being reverted
    /// @param amount               Amount of token being reverted
    /// @param revertInstruction    Revert settings configuration
    event RevertUniversalTx(
        address indexed to, address indexed token, uint256 amount, RevertInstructions revertInstruction
    );

    // =========================
    //       sendUniversalTx
    // =========================
    function sendUniversalTx(UniversalTxRequest calldata req) external payable;

    /// @notice Withdraw functions (TSS-only)

    /// @notice             Revert universal transaction with tokens to the recipient specified in revertInstruction
    /// @param token        token address to revert
    /// @param amount       amount of token to revert
    /// @param revertCFG    revert settings
    function revertUniversalTxToken(address token, uint256 amount, RevertInstructions calldata revertCFG) external;

    /// @notice             Revert native tokens to the recipient specified in revertInstruction
    /// @param amount       amount of native token to revert
    /// @param revertCFG    revert settings
    function revertUniversalTx(uint256 amount, RevertInstructions calldata revertCFG) external payable;

    // =========================
    //       Withdraw and Payload Execution Paths
    // =========================

    /// @notice             Withdraw token from the gateway
    /// @param txID         unique transaction identifier
    /// @param originCaller original caller/user on source chain
    /// @param token        token address (ERC20 token)
    /// @param to           recipient address
    /// @param amount       amount of token to withdraw
    function withdrawToken(bytes32 txID, address originCaller, address token, address to, uint256 amount) external;

    /// @notice             Executes a Universal Transaction on this chain triggered by Vault after validation on Push Chain.
    /// @param txID         unique transaction identifier
    /// @param originCaller original caller/user on source chain
    /// @param token        token address (ERC20 token)
    /// @param target       target contract address to execute call
    /// @param amount       amount of token to send along
    /// @param payload      calldata to be executed on target
    function executeUniversalTx(
        bytes32 txID,
        address originCaller,
        address token,
        address target,
        uint256 amount,
        bytes calldata payload
    ) external;

    /// @notice             Executes a Universal Transaction with native tokens on this chain triggered by TSS after validation on Push Chain.
    /// @param txID         unique transaction identifier
    /// @param originCaller original caller/user on source chain
    /// @param target       target contract address to execute call
    /// @param amount       amount of native token to send along
    /// @param payload      calldata to be executed on target
    function executeUniversalTx(
        bytes32 txID,
        address originCaller,
        address target,
        uint256 amount,
        bytes calldata payload
    ) external payable;
}