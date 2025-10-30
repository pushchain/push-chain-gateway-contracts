// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { RevertInstructions, UniversalPayload, TX_TYPE } from "../libraries/Types.sol";

interface IUniversalGateway {
    // =========================
    //           EVENTS
    // =========================

    /// @notice         Universal tx deposit (gas funding). Emits for both gas refil and funds+payload movement.
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
    /// @notice         Universal tx execution event. Emits for outbound transactions from Push Chain to external chains
    event UniversalTxExecuted(
        bytes32 indexed txID,
        address indexed originCaller,
        address indexed target,
        address token,
        uint256 amount,
        bytes data
    );

    /// @notice         Vault updated event
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    /// @notice         Withdraw token event
    event WithdrawToken(bytes32 indexed txID, address indexed originCaller, address indexed token, address to, uint256 amount);
    /// @notice         Revert withdraw event
    event RevertUniversalTx(address indexed to, address indexed token, uint256 amount, RevertInstructions revertInstruction);
    /// @notice         Caps updated event
    event CapsUpdated(uint256 minCapUsd, uint256 maxCapUsd);
    /// @notice         Rate-limit / config events
    event EpochDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event TokenLimitThresholdUpdated(address indexed token, uint256 newThreshold);

    // =========================
    //           Public Helpers 
    // =========================
    /// @notice             Checks if a token is supported by the gateway.
    /// @param token        Token address to check
    /// @return             True if the token is supported, false otherwise
    function isSupportedToken(address token) external view returns (bool);

    /// @notice             Computes the minimum and maximum deposit amounts in native ETH (wei) implied by the USD caps.
    /// @dev                Uses the current ETH/USD price from {getEthUsdPrice}.
    /// @return minValue    Minimum native amount (in wei) allowed by MIN_CAP_UNIVERSAL_TX_USD
    /// @return maxValue    Maximum native amount (in wei) allowed by MAX_CAP_UNIVERSAL_TX_USD
    function getMinMaxValueForNative() external view returns (uint256 minValue, uint256 maxValue);

    
    // =========================
    //     sendTxWithGas - Fee Abstraction Route
    // =========================

    /// @notice                 Allows initiating a TX for funding UEAs or quick executions of payloads on Push Chain.
    /// @dev                    Supports 2 TX types:
    ///                             a. GAS.
    ///                             b. GAS_AND_PAYLOAD.
    /// @dev                    TX initiated via fee abstraction route requires lower block confirmations for execution on Push Chain.
    ///                         Thus, the deposit amount is subject to USD cap checks that is strictly enforced with MIN_CAP_UNIVERSAL_TX_USD & MAX_CAP_UNIVERSAL_TX_USD.
    ///                         Gas for this transaction must be paid in the NATIVE token of the source chain.
    ///
    /// @dev                    Rate Limit Checks: 
    ///                            a. Includes _checkUSDCaps: USD cap checks for the deposit amount. Must be within MIN_CAP_UNIVERSAL_TX_USD & MAX_CAP_UNIVERSAL_TX_USD.
    ///                            b. Includes _checkBlockUSDCap: Block-based USD cap checks. Must be within BLOCK_USD_CAP.
    ///
    /// @param payload          Universal payload to execute on Push Chain
    /// @param revertCFG        Revert settings
    /// @param signatureData    Signature data
    function sendTxWithGas(
        UniversalPayload calldata payload,
        RevertInstructions calldata revertCFG,
        bytes memory signatureData
    ) external payable;

    /// @notice                 Allows initiating a TX for funding UEAs or quick executions of payloads on Push Chain with any supported Token.
    /// @dev                    Allows users to use any token to fund or execute a payload on Push Chain.
    ///                         The deposited token is swapped to native ETH using Uniswap v3.
    ///                         Supports 2 TX types:
    ///                             a. GAS.
    ///                             b. GAS_AND_PAYLOAD.
    /// @dev                    TX initiated via fee abstraction route requires lower block confirmations for execution on Push Chain.
    ///                         Thus, the deposit amount is subject to USD cap checks that is strictly enforced with MIN_CAP_UNIVERSAL_TX_USD & MAX_CAP_UNIVERSAL_TX_USD.
    ///                         Gas for this transaction can be paid in any token with a valid pool with the native token on AMM.
    ///
    /// @dev                    Rate Limit Checks: 
    ///                            a. _checkUSDCaps: USD cap checks for the deposit amount. Must be within MIN_CAP_UNIVERSAL_TX_USD & MAX_CAP_UNIVERSAL_TX_USD.
    ///                            b. _checkBlockUSDCap: Block-based USD cap checks. Must be within BLOCK_USD_CAP.
    ///
    /// @param tokenIn          Token address to swap from
    /// @param amountIn         Amount of token to swap
    /// @param payload          Universal payload to execute on Push Chain
    /// @param revertCFG        Revert settings
    /// @param amountOutMinETH  Minimum ETH expected (slippage protection)
    /// @param deadline         Swap deadline
    /// @param signatureData    Signature data
    function sendTxWithGas(
        address tokenIn,
        uint256 amountIn,
        UniversalPayload calldata payload,
        RevertInstructions calldata revertCFG,
        uint256 amountOutMinETH,
        uint256 deadline,
        bytes memory signatureData
    ) external;

    // =========================
    //       sendTxWithFunds - Universal Transaction Route
    // =========================

    /// @notice                 Allows initiating a TX for movement of high value funds from source chain to Push Chain.
    /// @dev                    Doesn't support arbitrary execution payload via UEAs. Only allows movement of funds.
    ///                         The tokens moved must be supported by the gateway.
    ///                         Supports only Universal TX type with high value funds, i.e., high block confirmations are required.
    ///                         Supports the TX type - FUNDS.
    ///
    /// @dev                    Rate Limit Checks: 
    ///                            a. _consumeRateLimit: Consume the per-token epoch rate limit.
    ///                                 - Every supported token has a per-token epoch limit threshold.
    ///                                 - New Epoch resets the usage limit threshold of a given token.
    ///
    /// @param recipient        Recipient address
    /// @param bridgeToken      Token address to bridge
    /// @param bridgeAmount     Amount of token to bridge
    /// @param revertCFG        Revert settings
    function sendFunds(
        address recipient,
        address bridgeToken,
        uint256 bridgeAmount,
        RevertInstructions calldata revertCFG
    ) external payable;

    /// @notice                 Allows initiating a TX for movement of funds and payload from source chain to Push Chain.
    /// @dev                    Supports arbitrary execution payload via UEAs.
    ///                         The tokens moved must be supported by the gateway.
    ///                         Supports the TX type - FUNDS_AND_PAYLOAD.
    ///                         Gas for this transaction must be paid in the NATIVE token of the source chain.
    ///                         Note: Recipient for such TXs are always the user's UEA on Push Chain. Hence, no recipient address is needed.
    ///
    /// @dev                    Rate Limit Checks: 
    ///                            a. _consumeRateLimit: Consume the per-token epoch rate limit.
    ///                                 - Every supported token has a per-token epoch limit threshold.
    ///                                 - New Epoch resets the usage limit threshold of a given token.
    ///                            b. Includes _checkUSDCaps and _checkBlockUSDCap for _sendTxWithGas function called internally.
    ///
    /// @param bridgeToken      Token address to bridge
    /// @param bridgeAmount     Amount of token to bridge
    /// @param payload          Universal payload to execute on Push Chain
    /// @param revertCFG        Revert settings
    /// @param signatureData    Signature data
    function sendTxWithFunds(
        address bridgeToken,
        uint256 bridgeAmount,
        UniversalPayload calldata payload,
        RevertInstructions calldata revertCFG,
        bytes memory signatureData
    ) external payable;

    /// @notice                 Allows initiating a TX for movement of funds and payload from source chain to Push Chain.
    ///                         Similar to sendTxWithFunds(), but with a token as gas input.
    /// @dev                    The gas token is swapped to native ETH using Uniswap v3.
    ///                         The tokens moved must be supported by the gateway.
    ///                         Supports the TX type - FUNDS_AND_PAYLOAD.
    ///                         Gas for this transaction can be paid in any token with a valid pool with the native token on AMM.
    ///                         Imposes strict check for USD cap for the deposit amount. 
    /// @dev                    The route emits two different events:
    ///                             a. TxWithGas - for gas funding - no payload is moved.
    ///                                   allows user to fund their UEA, which will be used for execution of payload.
    ///                             b. TxWithFunds - for funds and payload movement from source chain to Push Chain.
    ///
    ///                         Note: Recipient for such TXs are always the user's UEA. Hence, no recipient address is needed.
    ///
    /// @dev                    Rate Limit Checks: 
    ///                            a. _consumeRateLimit: Consume the per-token epoch rate limit.
    ///                                 - Every supported token has a per-token epoch limit threshold.
    ///                                 - New Epoch resets the usage limit threshold of a given token.
    ///                            b. Includes _checkUSDCaps and _checkBlockUSDCap for _sendTxWithGas function called internally.
    ///
    /// @param bridgeToken      Token address to bridge
    /// @param bridgeAmount     Amount of token to bridge
    /// @param gasToken         Token address to swap from
    /// @param gasAmount        Amount of token to swap
    /// @param amountOutMinETH  Minimum ETH expected (slippage protection)
    /// @param deadline         Swap deadline
    /// @param payload          Universal payload to execute on Push Chain
    /// @param revertCFG        Revert settings
    /// @param signatureData    Signature data
    function sendTxWithFunds(
        address bridgeToken,
        uint256 bridgeAmount,
        address gasToken,
        uint256 gasAmount,
        uint256 amountOutMinETH,
        uint256 deadline,
        UniversalPayload calldata payload,
        RevertInstructions calldata revertCFG,
        bytes memory signatureData
    ) external;

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
