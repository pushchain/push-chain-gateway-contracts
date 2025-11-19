// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title UniversalGateway
 * @notice Universal Gateway for EVM chains.
 *         - Acts as a gateway for all supported external chains to bridge funds and payloads to Push Chain.
 *         - Users of external chains can deposit funds and payloads to Push Chain using the gateway.
 *
 * @dev    - Transaction Types: 4 main types of transactions supported by gateway:
 *         -    1. GAS_TX: Allows users to fund their UEAs ( on Push Chain ) with gas deposits from source chains.
 *         -    2. GAS_AND_PAYLOAD_TX: Allows users to fund their UEAs with gas deposits from source chains and execute payloads through their UEAs on Push Chain.
 *         -    3. FUNDS_TX: Allows users to move large ticket-size funds from to any recipient address on Push Chain.
 *         -    4. FUNDS_AND_PAYLOAD_TX: Allows users to move large ticket-size funds from to any recipient address on Push Chain and execute payloads through their UEAs on Push Chain.
 *         - Note: Check the ./libraries/Types.sol file for more details on transaction types.
 *
 * @dev    - TSS-controlled functionalities:
 *         -    1. TSS-controlled withdraw (native or ERC20).
 *         -    2. Token Support List: allowlist for ERC20 used as gas inputs on gas tx path.
 *         - Note: Fund management and access control is managed by TSS_ROLE.
 *
 * @dev    - Rate-Limit Checks:
 *         -    Universal Gateway includes rate-limit checks for both Fee Abstraction & Universal Transaction Routes.
 *         -    For Fee Abstraction Route ( Low Block Confirmation Requirement ): 
 *               - Includes _checkUSDCaps: USD cap checks for the deposit amount. Must be within MIN_CAP_UNIVERSAL_TX_USD & MAX_CAP_UNIVERSAL_TX_USD.
 *               - Includes _checkBlockUSDCap: Block-based USD cap checks. Must be within BLOCK_USD_CAP.
 *         -    For Universal Transaction Route ( Standard Block Confirmation Requirement ):
 *               - Includes _consumeRateLimit: Consume the per-token epoch rate limit.
 *                     - Every supported token has a per-token epoch limit threshold.
 *                     - New Epoch resets the usage limit threshold of a given token.
 *               - Includes _checkUSDCaps and _checkBlockUSDCap for _sendTxWithGas function called internally.
 *         - Note: Check the ./interfaces/IUniversalGateway.sol file for more details on rate-limit checks.
 * 
 * @dev    - Chainlink Oracle is used for ETH/USD price feed.
 */

import { IWETH } from "./interfaces/IWETH.sol";
import { Errors } from "./libraries/Errors.sol";
import { IUniversalGateway } from "./interfaces/IUniversalGateway.sol";
import { RevertInstructions, 
            UniversalPayload, 
                TX_TYPE, 
                    EpochUsage } from "./libraries/Types.sol";

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { ISwapRouter as ISwapRouterV3 } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ContextUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract UniversalGateway is
    Initializable,
    ContextUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    IUniversalGateway
{
    using SafeERC20 for IERC20;

    bytes32 public constant TSS_ROLE = keccak256("TSS_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    /// @notice The current TSS address for UniversalGateway
    address public TSS_ADDRESS;
    
    /// @notice The Vault contract address
    address public VAULT;

    /// @notice Rate-Limiting CAPS and States
    uint256 public BLOCK_USD_CAP;
    uint256 public epochDurationSec;                            // Epoch duration in seconds.
    uint256 private _lastBlockNumber;                           // Last block number for block-based USD cap checks
    uint256 private _consumedUSDinBlock;                        // Consumed USD in block
    uint256 public MIN_CAP_UNIVERSAL_TX_USD;                    // inclusive lower bound => 1USD = 1e18
    uint256 public MAX_CAP_UNIVERSAL_TX_USD;                    // inclusive upper bound => 10USD = 10e18
    mapping(address => uint256) public tokenToLimitThreshold;   // Per-token epoch limit thresholds.
    mapping(address => EpochUsage) private _usage;              // Current-epoch usage per token (address(0) represents native).

    /// @notice Uniswap V3 factory & router (chain-specific)
    address public WETH;
    ISwapRouterV3 public uniV3Router;                           // Uniswap V3 router.
    IUniswapV3Factory public uniV3Factory;                      // Uniswap V3 factory.
    uint256 public defaultSwapDeadlineSec;                      // Default swap deadline window (industry common ~10 minutes).
    uint24[3] public v3FeeOrder =                               // Fee order for Uniswap V3 router.
        [uint24(500), 
            uint24(3000),
                 uint24(10000)];                               

    /// @notice Chainlink Oracle Configs
    uint256 public chainlinkStalePeriod;                        // Chainlink stale period.
    uint8 public chainlinkEthUsdDecimals;                       // Chainlink ETH/USD decimals.
    AggregatorV3Interface public ethUsdFeed;                    // Chainlink ETH/USD feed.
    uint256 public l2SequencerGracePeriodSec;                   // L2 Sequencer grace period. (e.g., 300 seconds)  
    AggregatorV3Interface public l2SequencerFeed;               // L2 Sequencer uptime feed & grace period for rollups (if set, enforce sequencer up + grace)
    
    /// @notice Map to track if a payload has been executed
    mapping(bytes32 => bool) public isExecuted;

    /**
     * @notice                  Initialize the UniversalGateway contract
     * @param admin             DEFAULT_ADMIN_ROLE holder
     * @param tss               initial TSS address
     * @param vaultAddress      Vault contract address
     * @param minCapUsd         min USD cap (1e18 decimals)
     * @param maxCapUsd         max USD cap (1e18 decimals)
     * @param factory           UniswapV2 factory
     * @param router            UniswapV2 router
     */
    function initialize(
        address admin,
        address tss,
        address vaultAddress,
        uint256 minCapUsd,
        uint256 maxCapUsd,
        address factory,
        address router,
        address _wethAddress
    ) external initializer {
        if (admin == address(0) || tss == address(0) || vaultAddress == address(0) || _wethAddress == address(0)) {
            revert Errors.ZeroAddress();
        }

        __Context_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TSS_ROLE, tss);
        _grantRole(VAULT_ROLE, vaultAddress);

        TSS_ADDRESS = tss;
        VAULT = vaultAddress;
        MIN_CAP_UNIVERSAL_TX_USD = minCapUsd;
        MAX_CAP_UNIVERSAL_TX_USD = maxCapUsd;

        WETH = _wethAddress;
        if (factory != address(0) && router != address(0)) {
            uniV3Factory = IUniswapV3Factory(factory);
            uniV3Router = ISwapRouterV3(router);
        }
        // Default swap deadline window (industry common ~10 minutes)
        defaultSwapDeadlineSec = 10 minutes;
        // Set a sane default for Chainlink staleness (can be tuned by admin)
        chainlinkStalePeriod = 1 hours;
        // Default epoch duration for global funds rate limit (Axelar-style)
        epochDurationSec = 6 hours;
    }

    /// @notice Modifier to check if the caller is the TSS
    modifier onlyTSS() {
        if (!hasRole(TSS_ROLE, _msgSender())) revert Errors.WithdrawFailed();
        _;
    }

    // =========================
    //           ADMIN ACTIONS
    // =========================
    function pause() external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    function unpause() external whenPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice             Allows the admin to set the TSS address
    /// @param newTSS       new TSS address
    function setTSS(address newTSS) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTSS == address(0)) revert Errors.ZeroAddress();
        address old = TSS_ADDRESS;

        // transfer role
        if (hasRole(TSS_ROLE, old)) _revokeRole(TSS_ROLE, old);
        _grantRole(TSS_ROLE, newTSS);

        TSS_ADDRESS = newTSS;
    }
    
    /// @notice             Allows the admin to update the Vault address
    /// @param newVault     new Vault address
    function updateVault(address newVault) external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        if (newVault == address(0)) revert Errors.ZeroAddress();
        address old = VAULT;
        
        // transfer role
        if (hasRole(VAULT_ROLE, old)) _revokeRole(VAULT_ROLE, old);
        _grantRole(VAULT_ROLE, newVault);
        
        VAULT = newVault;
        emit VaultUpdated(old, newVault);
    }

    /// @notice             Allows the admin to set the USD cap ranges
    /// @param minCapUsd    minimum USD cap
    /// @param maxCapUsd    maximum USD cap
    function setCapsUSD(uint256 minCapUsd, uint256 maxCapUsd) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (minCapUsd > maxCapUsd) revert Errors.InvalidCapRange();

        MIN_CAP_UNIVERSAL_TX_USD = minCapUsd;
        MAX_CAP_UNIVERSAL_TX_USD = maxCapUsd;
        emit CapsUpdated(minCapUsd, maxCapUsd);
    }

    /// @notice             Set the per-block USD cap for GAS routes (1e18 = $1). Set to 0 to disable.
    function setBlockUsdCap(uint256 cap1e18) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        BLOCK_USD_CAP = cap1e18;
    }

    /// @notice             Set the default swap deadline window (used when a caller passes deadline = 0)
    /// @param deadlineSec  number of seconds to add to block.timestamp when defaulting the deadline
    function setDefaultSwapDeadline(uint256 deadlineSec) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (deadlineSec == 0) revert Errors.InvalidAmount();
        defaultSwapDeadlineSec = deadlineSec;
    }

    /// @notice             Allows the admin to set the Uniswap V3 factory and router
    /// @param factory      new Uniswap V3 factory address
    /// @param router       new Uniswap V3 router address
    function setRouters(address factory, address router) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (factory == address(0) || router == address(0)) revert Errors.ZeroAddress();
        uniV3Factory = IUniswapV3Factory(factory);
        uniV3Router = ISwapRouterV3(router);
    }

    /// @notice             Set limit thresholds for a batch of tokens (0 disables support for that token)
    /// @param tokens       tokens to set limit thresholds for
    /// @param thresholds   limit thresholds for the tokens
    function setTokenLimitThresholds(address[] calldata tokens, uint256[] calldata thresholds)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (tokens.length != thresholds.length) revert Errors.InvalidInput();
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenToLimitThreshold[tokens[i]] = thresholds[i];
            emit TokenLimitThresholdUpdated(tokens[i], thresholds[i]);
        }
    }

    /// @notice               Update the epoch duration (hard reset schedule)
    /// @param newDurationSec new epoch duration
    function updateEpochDuration(uint256 newDurationSec) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 old = epochDurationSec;
        epochDurationSec = newDurationSec;
        emit EpochDurationUpdated(old, newDurationSec);
    }

    /// @notice             Allows the admin to set the fee order for the Uniswap V3 router
    /// @param a            new fee order
    /// @param b            new fee order
    /// @param c            new fee order
    function setV3FeeOrder(uint24 a, uint24 b, uint24 c) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        v3FeeOrder = [a, b, c];
    }

    /// @notice             Set the Chainlink ETH/USD feed (and cache its decimals)
    /// @param feed         Chainlink ETH/USD feed address
    function setEthUsdFeed(address feed) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        if (feed == address(0)) revert Errors.ZeroAddress();
        AggregatorV3Interface f = AggregatorV3Interface(feed);
        // Will revert if not a contract or not a valid aggregator when decimals() is called by non-aggregator contracts.
        uint8 dec = f.decimals();
        ethUsdFeed = f;
        chainlinkEthUsdDecimals = dec;
    }

    /// @notice                 Configure the maximum allowed data staleness for Chainlink reads
    /// @param stalePeriodSec   if > 0, latestRoundData().updatedAt must be within this many seconds
    function setChainlinkStalePeriod(uint256 stalePeriodSec) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        chainlinkStalePeriod = stalePeriodSec;
    }

    /// @notice             Set (or clear) the Chainlink L2 sequencer uptime feed for rollups
    /// @param feed         Chainlink L2 sequencer uptime feed address
    /// @dev                Set to address(0) on L1s / chains without a sequencer feed.
    function setL2SequencerFeed(address feed) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        l2SequencerFeed = AggregatorV3Interface(feed);
    }

    /// @notice             Configure the grace window after sequencer comes back up
    /// @param gracePeriodSec if > 0, require `block.timestamp - sequencer.updatedAt > gracePeriodSec`
    function setL2SequencerGracePeriod(uint256 gracePeriodSec) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        l2SequencerGracePeriodSec = gracePeriodSec;
    }

    // =========================
    //     sendTxWithGas - Fee Abstraction Route
    // =========================

    /// @inheritdoc IUniversalGateway
    function sendTxWithGas(
        UniversalPayload calldata payload,
        RevertInstructions calldata revertInstruction,
        bytes memory signatureData
    ) external payable nonReentrant whenNotPaused {

        _sendTxWithGas(
            _msgSender(), abi.encode(payload), msg.value, revertInstruction, TX_TYPE.GAS_AND_PAYLOAD, signatureData
        );
    }

    /// @inheritdoc IUniversalGateway
    function sendTxWithGas(
        address tokenIn,
        uint256 amountIn,
        UniversalPayload calldata payload,
        RevertInstructions calldata revertInstruction,
        uint256 amountOutMinETH,
        uint256 deadline,
        bytes memory signatureData
    ) external nonReentrant whenNotPaused {
        if (tokenIn == address(0)) revert Errors.InvalidInput();
        if (amountIn == 0) revert Errors.InvalidAmount();
        if (amountOutMinETH == 0) revert Errors.InvalidAmount();
        if (deadline != 0 && deadline < block.timestamp) revert Errors.SlippageExceededOrExpired();

        // Swap token to native ETH
        uint256 ethOut = swapToNative(tokenIn, amountIn, amountOutMinETH, deadline);

        _sendTxWithGas(
            _msgSender(), abi.encode(payload), ethOut, revertInstruction, TX_TYPE.GAS_AND_PAYLOAD, signatureData
        );
    }

    /// @notice                     Internal helper function to deposit for Instant TX.
    /// @dev                        Handles rate-limit checks for Fee Abstraction Tx Route
    function _sendTxWithGas(
        address _caller,
        bytes memory _payload,
        uint256 _nativeTokenAmount,
        RevertInstructions calldata _revertInstruction,
        TX_TYPE _txType,
        bytes memory _signatureData
    ) internal {
        if (_revertInstruction.fundRecipient == address(0)) revert Errors.InvalidRecipient();

        // performs rate-limit checks and handle deposit
        _checkUSDCaps(_nativeTokenAmount);
        _checkBlockUSDCap(_nativeTokenAmount);
        _handleDeposits(address(0), _nativeTokenAmount);

        emit UniversalTx({
            sender: _caller,
            recipient: address(0),
            token: address(0),
            amount: _nativeTokenAmount,
            payload: _payload,
            revertInstruction: _revertInstruction,
            txType: _txType,
            signatureData: _signatureData
        });
    }

    // =========================
    //       sendTxWithFunds - Universal Transaction Route
    // =========================

    /// @inheritdoc IUniversalGateway
    function sendFunds(
        address recipient,
        address bridgeToken,
        uint256 bridgeAmount,
        RevertInstructions calldata revertInstruction
    ) external payable nonReentrant whenNotPaused {
        if (recipient == address(0)) revert Errors.InvalidRecipient();

        if (bridgeToken == address(0)) {
            if (msg.value != bridgeAmount) revert Errors.InvalidAmount();
            _consumeRateLimit(address(0), bridgeAmount);
            _handleDeposits(address(0), bridgeAmount);
        } else {
            if (msg.value != 0) revert Errors.InvalidAmount();
            _consumeRateLimit(bridgeToken, bridgeAmount);
            _handleDeposits(bridgeToken, bridgeAmount);
        }

        _sendTxWithFunds(
            _msgSender(),
            recipient,
            bridgeToken,
            bridgeAmount,
            bytes(""),              // Empty payload for funds-only bridge
            revertInstruction,
            TX_TYPE.FUNDS,
            bytes("")
        );
    }

    /// @inheritdoc IUniversalGateway
    function sendTxWithFunds(
        address bridgeToken,
        uint256 bridgeAmount,
        UniversalPayload calldata payload,
        RevertInstructions calldata revertInstruction,
        bytes memory signatureData
    ) external payable nonReentrant whenNotPaused {
        if (bridgeAmount == 0) revert Errors.InvalidAmount();
        uint256 gasAmount = msg.value;
        if (gasAmount == 0) revert Errors.InvalidAmount();

        _sendTxWithGas(_msgSender(), bytes(""), gasAmount, revertInstruction, TX_TYPE.GAS, signatureData);

        // performs rate-limit checks and handle deposit
        _consumeRateLimit(bridgeToken, bridgeAmount);
        _handleDeposits(bridgeToken, bridgeAmount);

        _sendTxWithFunds(
            _msgSender(),
            address(0),
            bridgeToken,
            bridgeAmount,
            abi.encode(payload),
            revertInstruction,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            signatureData
        );
    }

    /// @inheritdoc IUniversalGateway
    function sendTxWithFunds(
        address bridgeToken,
        uint256 bridgeAmount,
        address gasToken,
        uint256 gasAmount,
        uint256 amountOutMinETH,
        uint256 deadline,
        UniversalPayload calldata payload,
        RevertInstructions calldata revertInstruction,
        bytes memory signatureData
    ) external nonReentrant whenNotPaused {
        if (bridgeAmount == 0) revert Errors.InvalidAmount();
        if (gasToken == address(0)) revert Errors.InvalidInput();
        if (gasAmount == 0) revert Errors.InvalidAmount();

        // Swap gasToken to native ETH
        uint256 nativeGasAmount = swapToNative(gasToken, gasAmount, amountOutMinETH, deadline);

        _sendTxWithGas(_msgSender(), bytes(""), nativeGasAmount, revertInstruction, TX_TYPE.GAS, signatureData);

        // performs rate-limit checks and handle deposit
        _consumeRateLimit(bridgeToken, bridgeAmount);
        _handleDeposits(bridgeToken, bridgeAmount);
        _sendTxWithFunds(
            _msgSender(),
            address(0),
            bridgeToken,
            bridgeAmount,
            abi.encode(payload),
            revertInstruction,
            TX_TYPE.FUNDS_AND_PAYLOAD,
            signatureData
        );
    }

    /// @notice                     Internal helper function to deposit for Universal TX.
    /// @dev                        Handles rate-limit checks for Universal Transaction Route
    function _sendTxWithFunds(
        address _caller,
        address _recipient,
        address _bridgeToken,
        uint256 _bridgeAmount,
        bytes memory _payload,
        RevertInstructions calldata _revertInstruction,
        TX_TYPE _txType,
        bytes memory _signatureData
    ) internal {
        if (_revertInstruction.fundRecipient == address(0)) revert Errors.InvalidRecipient();
        /// for recipient == address(0), the funds are being moved to UEA of the msg.sender on Push Chain.
        if (_recipient == address(0)) {
            if (_txType != TX_TYPE.FUNDS_AND_PAYLOAD && _txType != TX_TYPE.GAS_AND_PAYLOAD) {
                revert Errors.InvalidTxType();
            }
        }

        emit UniversalTx({
            sender: _caller,
            recipient: _recipient,
            token: _bridgeToken,
            amount: _bridgeAmount,
            payload: _payload,
            revertInstruction: _revertInstruction,
            txType: _txType,
            signatureData: _signatureData
        });
    }

    /// @inheritdoc IUniversalGateway
    function revertUniversalTxToken(
        bytes32 txID,
        address token,
        uint256 amount,
        RevertInstructions calldata revertInstruction
    )
        external
        nonReentrant
        whenNotPaused
        onlyRole(VAULT_ROLE)
    {
        if (isExecuted[txID]) revert Errors.PayloadExecuted();
        
        if (revertInstruction.fundRecipient == address(0)) revert Errors.InvalidRecipient();
        if (amount == 0) revert Errors.InvalidAmount();
        
        isExecuted[txID] = true;
        IERC20(token).safeTransfer(revertInstruction.fundRecipient, amount);
        
        emit RevertUniversalTx(txID, revertInstruction.fundRecipient, token, amount, revertInstruction);
    }
    
    /// @inheritdoc IUniversalGateway
    function revertUniversalTx(
        bytes32 txID,
        uint256 amount,
        RevertInstructions calldata revertInstruction
    )
        external
        payable 
        nonReentrant
        whenNotPaused
        onlyTSS
    {
        if (isExecuted[txID]) revert Errors.PayloadExecuted();
        
        if (revertInstruction.fundRecipient == address(0)) revert Errors.InvalidRecipient();
        if (amount == 0 || msg.value != amount) revert Errors.InvalidAmount();

        isExecuted[txID] = true;
        (bool ok,) = payable(revertInstruction.fundRecipient).call{ value: amount }("");
        if (!ok) revert Errors.WithdrawFailed();
        
        emit RevertUniversalTx(txID, revertInstruction.fundRecipient, address(0), amount, revertInstruction);
    }

    // =========================
    //       GATEWAY Withdraw and Payload Execution Paths
    // =========================

    /// @inheritdoc IUniversalGateway
    function withdraw(
        bytes32 txID,
        address originCaller,
        address to,
        uint256 amount
    ) external payable nonReentrant whenNotPaused onlyTSS {
        if (isExecuted[txID]) revert Errors.PayloadExecuted(); 
        
        if (to == address(0) || originCaller == address(0)) revert Errors.InvalidInput();
        if (amount == 0) revert Errors.InvalidAmount();
        if (msg.value != amount) revert Errors.InvalidAmount();
        
        isExecuted[txID] = true;
        (bool ok,) = payable(to).call{ value: amount }("");
        if (!ok) revert Errors.WithdrawFailed();
        
        emit WithdrawToken(txID, originCaller, address(0), to, amount);
    }

    /// @inheritdoc IUniversalGateway
    function withdrawFunds(
        bytes32 txID,
        address originCaller,
        address token,
        address to,
        uint256 amount
    ) external nonReentrant whenNotPaused onlyRole(VAULT_ROLE) {
        if (isExecuted[txID]) revert Errors.PayloadExecuted(); 
        
        if (to == address(0) || originCaller == address(0)) revert Errors.InvalidInput();
        if (amount == 0) revert Errors.InvalidAmount();
        if (token == address(0)) revert Errors.InvalidInput();
        
        if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();

        isExecuted[txID] = true;
        IERC20(token).safeTransfer(to, amount);
        emit WithdrawToken(txID, originCaller, token, to, amount);
    }

    /// @notice                Executes a Universal Transaction on this chain triggered by TSS after validation on Push Chain.
    /// @dev                   Allows outbound payload execution from Push Chain to external chains.
    ///                        - The tokens used for payload execution, are to be burnt on Push Chain.
    ///                        - approval and reset of approval is handled by the gateway.
    ///                        - tokens are transferred from Vault to Gateway before calling this function
    /// @param txID            unique transaction identifier
    /// @param originCaller    original caller/user on source chain
    /// @param token           token address (ERC20 token)
    /// @param target          target contract address to execute call
    /// @param amount          amount of token to send along
    /// @param payload         calldata to be executed on target
    function executeUniversalTx(
        bytes32 txID,
        address originCaller,
        address token,
        address target,
        uint256 amount,
        bytes calldata payload
    ) external nonReentrant whenNotPaused onlyRole(VAULT_ROLE) {
        if (isExecuted[txID]) revert Errors.PayloadExecuted(); 
        
        if (target == address(0) || originCaller == address(0)) revert Errors.InvalidInput();
        if (amount == 0) revert Errors.InvalidAmount();
        if (token == address(0)) revert Errors.InvalidInput(); // This function is for ERC20 tokens only
        
        if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InvalidAmount();

        isExecuted[txID] = true;

        _resetApproval(token, target);             // reset approval to zero
        _safeApprove(token, target, amount);       // approve target to spend amount
        _executeCall(target, payload, 0);          // execute call with required amount
        _resetApproval(token, target);             // reset approval back to zero
        
        // Return any remaining tokens to the Vault
        uint256 remainingBalance = IERC20(token).balanceOf(address(this));
        if (remainingBalance > 0) {
            IERC20(token).safeTransfer(VAULT, remainingBalance);
        }
        
        emit UniversalTxExecuted(txID, originCaller, target, token, amount, payload);
    }
    
    /// @notice                Executes a Universal Transaction with native tokens on this chain triggered by TSS after validation on Push Chain.
    /// @dev                   Allows outbound payload execution from Push Chain to external chains with native tokens.
    /// @param txID            unique transaction identifier
    /// @param originCaller    original caller/user on source chain
    /// @param target          target contract address to execute call
    /// @param amount          amount of native token to send along
    /// @param payload         calldata to be executed on target
    function executeUniversalTx(
        bytes32 txID,
        address originCaller,
        address target,
        uint256 amount,
        bytes calldata payload
    ) external payable nonReentrant whenNotPaused onlyRole(TSS_ROLE) {
        if (isExecuted[txID]) revert Errors.PayloadExecuted(); 
        
        if (target == address(0) || originCaller == address(0)) revert Errors.InvalidInput();
        if (amount == 0) revert Errors.InvalidAmount();
        if (msg.value != amount) revert Errors.InvalidAmount();

        isExecuted[txID] = true;
        
        _executeCall(target, payload, amount);
        
        emit UniversalTxExecuted(txID, originCaller, target, address(0), amount, payload);
    }

    // =========================
    //      PUBLIC HELPERS
    // =========================

    /// @inheritdoc IUniversalGateway
    function isSupportedToken(address token) public view returns (bool) {
        return tokenToLimitThreshold[token] != 0;
    }

    /// @inheritdoc IUniversalGateway
    function getMinMaxValueForNative() external view returns (uint256 minValue, uint256 maxValue) {
        (uint256 ethUsdPrice,) = getEthUsdPrice(); // ETH price in USD (1e18 scaled)
        minValue = (MIN_CAP_UNIVERSAL_TX_USD * 1e18) / ethUsdPrice;
        maxValue = (MAX_CAP_UNIVERSAL_TX_USD * 1e18) / ethUsdPrice;
    }

    /// @notice                     Returns the ETH/USD price scaled to 1e18 (i.e., USD with 18 decimals).
    /// @dev                        Reads Chainlink AggregatorV3, applies safety checks,
    ///                             then rescales from the feed's native decimals (typically 8) to 1e18.
    ///                             - Output units: price1e18 = USD(1e18) per 1 ETH. Example: if ETH = $4,400, returns 4_400 * 1e18.
    /// @return price1e18           ETH price in USD scaled to 1e18 (USD with 18 decimals)
    /// @return chainlinkDecimals   The decimals of the underlying Chainlink feed (e.g., 8)
    function getEthUsdPrice() public view returns (uint256, uint8) {
        if (address(ethUsdFeed) == address(0)) revert Errors.InvalidInput(); // feed not set

        // Optional L2 sequencer-uptime enforcement for rollups
        if (address(l2SequencerFeed) != address(0)) {
            (
                , // roundId (unused)
                int256 status, // 0 = UP, 1 = DOWN
                ,
                uint256 sequencerUpdatedAt,
                /* uint80 answeredInRound */
            ) = l2SequencerFeed.latestRoundData();

            // Revert if sequencer is DOWN
            if (status == 1) revert Errors.InvalidData();

            // Revert if still within grace period after sequencer came back UP
            if (l2SequencerGracePeriodSec != 0 && block.timestamp - sequencerUpdatedAt <= l2SequencerGracePeriodSec) {
                revert Errors.InvalidData();
            }
        }

        (uint80 roundId, int256 priceInUSD,, uint256 updatedAt, uint80 answeredInRound) = ethUsdFeed.latestRoundData();

        // Basic oracle safety checks
        if (priceInUSD <= 0) revert Errors.InvalidData();
        if (answeredInRound < roundId) revert Errors.InvalidData();
        if (chainlinkStalePeriod != 0 && block.timestamp - updatedAt > chainlinkStalePeriod) {
            revert Errors.InvalidData();
        }

        uint8 dec = chainlinkEthUsdDecimals;
        if (dec == 0) {
            try ethUsdFeed.decimals() returns (uint8 feedDecimals) {
                dec = feedDecimals;
            } catch {
                // If feed doesn't support decimals(), assume standard Chainlink ETH/USD format (8 decimals)
                dec = 8;
            }
        }
        // Scale priceInUSD (decimals = dec) to 1e18
        uint256 scale;
        unchecked {
            // dec is expected to be <= 18 for feeds; if >18, this will underflow so guard:
            if (dec > 18) revert Errors.InvalidData();
            scale = 10 ** uint256(18 - dec);
        }
        return (uint256(priceInUSD) * scale, dec);
    }

    /// @notice             Converts an ETH amount (in wei) to USD with 18 decimals via Chainlink price.
    /// @dev                Uses getEthUsdPrice which returns USD(1e18) per ETH and computes:
    /// @param amountWei    amount of ETH in wei to convert
    /// @return usd1e18     USD value scaled to 1e18
    function quoteEthAmountInUsd1e18(uint256 amountWei) public view returns (uint256 usd1e18) {
        if (amountWei == 0) return 0;
        (uint256 px1e18,) = getEthUsdPrice(); // will validate freshness and positivity
        // Note: amountWei is 1e18-based (wei), price is scaled to 1e18 above.
        usd1e18 = (amountWei * px1e18) / 1e18;
    }

    // =========================
    //       INTERNAL HELPERS
    // =========================

    /// @dev                Check if the amount is within the USD cap range
    ///                     Cap Ranges are defined in the constructor or can be updated by the admin.
    /// @param amount       Amount to check
    function _checkUSDCaps(uint256 amount) public view {
        uint256 usdValue = quoteEthAmountInUsd1e18(amount);
        if (usdValue < MIN_CAP_UNIVERSAL_TX_USD) revert Errors.InvalidAmount();
        if (usdValue > MAX_CAP_UNIVERSAL_TX_USD) revert Errors.InvalidAmount();
    }

    /// @dev                Enforce per-block USD budget for GAS routes using two-scalar accounting.
    ///                     - `BLOCK_USD_CAP` is denominated in USD(1e18). When 0, the feature is disabled.
    ///                     - Resets the window when a new block is observed.
    /// @param amountWei    native amount (in wei) to be accounted against the current block's USD budget
    function _checkBlockUSDCap(uint256 amountWei) public {
        uint256 cap = BLOCK_USD_CAP;
        if (cap == 0) return;

        if (block.number != _lastBlockNumber) {
            _lastBlockNumber = block.number;
            _consumedUSDinBlock = 0;
        }

        uint256 usd1e18 = quoteEthAmountInUsd1e18(amountWei);

        if (usd1e18 > cap) revert Errors.BlockCapLimitExceeded();

        unchecked {
            uint256 newUsed = _consumedUSDinBlock + usd1e18;
            if (newUsed > cap) revert Errors.BlockCapLimitExceeded();
            _consumedUSDinBlock = newUsed;
        }
    }

    /// @dev                Handle deposits of native ETH or ERC20 tokens
    ///                     If token is address(0): Forward native ETH to TSS
    ///                     Otherwise: Lock ERC20 in the Vault contract for bridging
    /// @param token        token address (address(0) for native ETH)
    /// @param amount       amount to deposit
    function _handleDeposits(address token, uint256 amount) internal {
        if (token == address(0)) {
            // Handle native ETH deposit to TSS
            (bool ok,) = payable(TSS_ADDRESS).call{ value: amount }("");
            if (!ok) revert Errors.DepositFailed();
        } else {
            // Handle ERC20 token deposit to Vault
            if (tokenToLimitThreshold[token] == 0) revert Errors.NotSupported();
            IERC20(token).safeTransferFrom(_msgSender(), VAULT, amount);
        }
    }

    // _handleTokenWithdraw function removed as token withdrawals are now handled by the Vault

    /// @dev Safely reset approval to zero before granting any new allowance to target contract.
    function _resetApproval(address token, address spender) internal {
        (bool success, bytes memory returnData) =
            token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
        if (!success) {
            // Some non-standard tokens revert on zero-approval; treat as reset-ok to avoid breaking the flow.
            return;
        }
        // If token returns a boolean, ensure it is true; if no return data, assume success (USDT-style).
        if (returnData.length > 0) {
            bool approved = abi.decode(returnData, (bool));
            if (!approved) revert Errors.InvalidData();
        }
    }

    /// @dev Safely approve ERC20 token spending to a target contract.
    ///      Low-level call must succeed AND (if returns data) decode to true; otherwise revert.
    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory returnData) =
            token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        if (!success) {
            revert Errors.InvalidData(); // approval failed
        }
        if (returnData.length > 0) {
            bool approved = abi.decode(returnData, (bool));
            if (!approved) {
                revert Errors.InvalidData(); // approval failed
            }
        }
    }

    /// @dev Unified helper to execute a low-level call to target
    ///      Call can be executed with native value or ERC20 token. 
    ///      Reverts with Errors.ExecutionFailed() if the call fails (no bubbling).
    function _executeCall(address target, bytes calldata payload, uint256 value) internal returns (bytes memory result) {
        (bool success, bytes memory ret) = target.call{value: value}(payload);
        if (!success) revert Errors.ExecutionFailed();
        return ret;
    }

    /// @dev                Enforce and consume the per-token epoch rate limit. 
    ///                     For a token, if threshold is 0, it is unsupported.
    ///                     epoch.used is reset to 0 when a new epoch starts (no rollover).
    /// @param token        token address to consume rate limit
    /// @param amount       amount of token to consume rate limit
    function _consumeRateLimit(address token, uint256 amount) internal {
        uint256 threshold = tokenToLimitThreshold[token];
        if (threshold == 0) revert Errors.NotSupported();

        uint256 _epochDuration = epochDurationSec;
        if (_epochDuration == 0) revert Errors.InvalidData();

        uint64 current = uint64(block.timestamp / _epochDuration);
        EpochUsage storage e = _usage[token];

        if (e.epoch != current) {
            e.epoch = current;
            e.used = 0;
        }

        unchecked {
            uint256 newUsed = uint256(e.used) + amount; // natural units
            if (newUsed > threshold) revert Errors.RateLimitExceeded();
            e.used = uint192(newUsed);
        }
    }

    /// @notice             Returns both the total token amount used and remaining in the current epoch.
    /// @param token        token address to query (use address(0) for native)
    /// @return used        amount already consumed in the current epoch (in token's natural units)
    /// @return remaining   amount still available to send in this epoch (0 if exceeded or unsupported)
    function currentTokenUsage(address token) external view returns (uint256 used, uint256 remaining) {
        uint256 thr = tokenToLimitThreshold[token];
        if (thr == 0) return (0, 0);

        uint256 _epochDuration = epochDurationSec;
        if (_epochDuration == 0) return (0, 0);

        uint64 current = uint64(block.timestamp / _epochDuration);
        EpochUsage storage e = _usage[token];
        uint256 u = (e.epoch == current) ? uint256(e.used) : 0;

        used = u;
        remaining = u >= thr ? 0 : (thr - u);
    }

    /// @dev                        Swap any ERC20 to the chain's native token via a direct Uniswap v3 pool to WETH.
    ///                             - If tokenIn == WETH: unwrap to native and return.
    ///                             - Else: require a direct tokenIn/WETH v3 pool, swap via exactInputSingle, unwrap, return ETH out.
    ///                             - No price/cap logic here; slippage and deadline are enforced; caps are enforced elsewhere.
    ///                             - If `deadline == 0`, it is replaced with `block.timestamp + defaultSwapDeadlineSec`.
    /// @param tokenIn              ERC-20 being paid as "gas token"
    /// @param amountIn             amount of tokenIn to pull and swap
    /// @param amountOutMinETH      min acceptable native (ETH) out (slippage bound)
    /// @param deadline             swap deadline
    /// @return ethOut              native ETH received
    function swapToNative(address tokenIn, uint256 amountIn, uint256 amountOutMinETH, uint256 deadline)
        internal
        returns (uint256 ethOut)
    {
        if (amountOutMinETH == 0) revert Errors.InvalidAmount();
        // If caller passed 0, use the contract's default window; else enforce it's in the future
        if (deadline == 0) {
            deadline = block.timestamp + defaultSwapDeadlineSec;
        } else if (deadline < block.timestamp) {
            revert Errors.SlippageExceededOrExpired();
        }
        if (address(uniV3Router) == address(0) || address(uniV3Factory) == address(0)) revert Errors.InvalidInput();

        if (tokenIn == WETH) {
            // Fast-path: pull WETH from user and unwrap to native
            IERC20(WETH).safeTransferFrom(_msgSender(), address(this), amountIn);

            uint256 balanceBeforeUnwrap = address(this).balance;
            IWETH(WETH).withdraw(amountIn);
            ethOut = address(this).balance - balanceBeforeUnwrap;

            // Slippage bound still applies for a consistent interface (caller can set to amountIn)
            if (ethOut < amountOutMinETH) revert Errors.SlippageExceededOrExpired();
            return ethOut;
        }
        (IUniswapV3Pool pool, uint24 fee) = _findV3PoolWithNative(tokenIn);

        IERC20(tokenIn).safeTransferFrom(_msgSender(), address(this), amountIn);
        IERC20(tokenIn).safeIncreaseAllowance(address(uniV3Router), amountIn);

        ISwapRouterV3.ExactInputSingleParams memory params = ISwapRouterV3.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: WETH,
            fee: fee,
            recipient: address(this),
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinETH, 
            sqrtPriceLimitX96: 0
        });

        uint256 wethOut = uniV3Router.exactInputSingle(params);

        IERC20(tokenIn).forceApprove(address(uniV3Router), 0);

        uint256 balanceBeforeSwapUnwrap = address(this).balance;
        IWETH(WETH).withdraw(wethOut);
        ethOut = address(this).balance - balanceBeforeSwapUnwrap;

        // Defensive: enforce the bound again after unwrap
        if (ethOut < amountOutMinETH) revert Errors.SlippageExceededOrExpired();
    }

    function _findV3PoolWithNative(address tokenIn) internal view returns (IUniswapV3Pool pool, uint24 fee) {
        if (tokenIn == address(0) || WETH == address(0)) revert Errors.ZeroAddress();
        if (tokenIn == WETH) {
            // Caller should handle the WETH fast-path; we return zeroed pool/fee here.
            return (IUniswapV3Pool(address(0)), 0);
        }

        // Try fee tiers in the configured order
        for (uint256 i = 0; i < v3FeeOrder.length; i++) {
            uint24 tier = v3FeeOrder[i];
            address p = IUniswapV3Factory(uniV3Factory).getPool(tokenIn, WETH, tier);
            if (p != address(0)) {
                return (IUniswapV3Pool(p), tier);
            }
        }
        revert Errors.InvalidInput();
    }


    /// @dev Reject plain ETH; we only accept ETH via explicit deposit functions or WETH unwrapping.
    receive() external payable {
        // Allow WETH unwrapping; block unexpected sends.
        if (msg.sender != WETH) revert Errors.DepositFailed();
    }
}
