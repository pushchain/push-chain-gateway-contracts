// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUniversalCore} from "../../src/interfaces/IUniversalCore.sol";
import {IPRC20} from "../../src/interfaces/IPRC20.sol";

/**
 * @title MockPRC20
 * @notice Accurate mock implementation of PRC20 for testing
 * @dev This mock closely follows the real PRC20 implementation from pc-core-2nd
 */
contract MockPRC20 is IPRC20 {
    // ========= Constants =========
    address public immutable UNIVERSAL_EXECUTOR_MODULE = 0x14191Ea54B4c176fCf86f51b0FAc7CB1E71Df7d7;

    // ========= State =========
    string public SOURCE_CHAIN_ID;
    string public SOURCE_TOKEN_ADDRESS;
    
    enum TokenType {
        PC,
        NATIVE,
        ERC20
    }
    
    TokenType public TOKEN_TYPE;
    
    address public UNIVERSAL_CORE;
    uint256 public GAS_LIMIT;
    uint256 public PC_PROTOCOL_FEE;
    
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    
    // ========= Events =========
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(bytes indexed from, address indexed to, uint256 amount);
    event Withdrawal(address indexed from, bytes indexed to, uint256 amount, uint256 gasFee, uint256 protocolFee);
    event UpdatedUniversalCore(address addr);
    event UpdatedGasLimit(uint256 gasLimit);
    event UpdatedProtocolFlatFee(uint256 protocolFlatFee);
    
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        string memory sourceChainId_,
        TokenType tokenType_,
        uint256 gasLimit_,
        uint256 protocolFlatFee_,
        address universalCore_,
        string memory sourceTokenAddress_
    ) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        
        SOURCE_CHAIN_ID = sourceChainId_;
        TOKEN_TYPE = tokenType_;
        GAS_LIMIT = gasLimit_;
        PC_PROTOCOL_FEE = protocolFlatFee_;
        UNIVERSAL_CORE = universalCore_;
        SOURCE_TOKEN_ADDRESS = sourceTokenAddress_;
    }
    
    // ========= View Functions =========
    function name() external view returns (string memory) {
        return _name;
    }
    
    function symbol() external view returns (string memory) {
        return _symbol;
    }
    
    function decimals() external view returns (uint8) {
        return _decimals;
    }
    
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }
    
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
    
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }
    
    // ========= IPRC20 Implementation =========
    function transfer(address recipient, uint256 amount) external returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }
    
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        _transfer(sender, recipient, amount);
        
        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "MockPRC20: insufficient allowance");
        
        unchecked {
            _allowances[sender][msg.sender] = currentAllowance - amount;
        }
        emit Approval(sender, msg.sender, _allowances[sender][msg.sender]);
        
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        require(spender != address(0), "MockPRC20: approve to zero address");
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    function burn(uint256 amount) external returns (bool) {
        _burn(msg.sender, amount);
        return true;
    }
    
    // ========= Bridge Functions =========
    function deposit(address to, uint256 amount) external returns (bool) {
        require(msg.sender == UNIVERSAL_CORE || msg.sender == UNIVERSAL_EXECUTOR_MODULE, 
                "MockPRC20: caller is not authorized");
        
        _mint(to, amount);
        
        emit Deposit(abi.encodePacked(UNIVERSAL_EXECUTOR_MODULE), to, amount);
        return true;
    }
    
    function withdraw(bytes calldata to, uint256 amount) external returns (bool) {
        (address gasToken, uint256 gasFee) = withdrawGasFee();
        
        bool result = IPRC20(gasToken).transferFrom(msg.sender, UNIVERSAL_EXECUTOR_MODULE, gasFee);
        require(result, "MockPRC20: gas fee transfer failed");
        
        _burn(msg.sender, amount);
        emit Withdrawal(msg.sender, to, amount, gasFee, PC_PROTOCOL_FEE);
        return true;
    }
    
    // ========= Gas Fee Functions =========
    function withdrawGasFee() public view returns (address gasToken, uint256 gasFee) {
        gasToken = IUniversalCore(UNIVERSAL_CORE).gasTokenPRC20ByChainId(SOURCE_CHAIN_ID);
        require(gasToken != address(0), "MockPRC20: zero gas token");
        
        uint256 price = IUniversalCore(UNIVERSAL_CORE).gasPriceByChainId(SOURCE_CHAIN_ID);
        require(price != 0, "MockPRC20: zero gas price");
        
        gasFee = price * GAS_LIMIT + PC_PROTOCOL_FEE;
    }
    
    function withdrawGasFeeWithGasLimit(uint256 gasLimit_) external view returns (address gasToken, uint256 gasFee) {
        gasToken = IUniversalCore(UNIVERSAL_CORE).gasTokenPRC20ByChainId(SOURCE_CHAIN_ID);
        require(gasToken != address(0), "MockPRC20: zero gas token");
        
        uint256 price = IUniversalCore(UNIVERSAL_CORE).gasPriceByChainId(SOURCE_CHAIN_ID);
        require(price != 0, "MockPRC20: zero gas price");
        
        gasFee = price * gasLimit_ + PC_PROTOCOL_FEE;
    }
    
    // ========= Admin Functions =========
    function updateUniversalCore(address addr) external {
        require(msg.sender == UNIVERSAL_EXECUTOR_MODULE, "MockPRC20: caller is not UEM");
        require(addr != address(0), "MockPRC20: zero address");
        UNIVERSAL_CORE = addr;
        emit UpdatedUniversalCore(addr);
    }
    
    function updateGasLimit(uint256 gasLimit_) external {
        require(msg.sender == UNIVERSAL_EXECUTOR_MODULE, "MockPRC20: caller is not UEM");
        GAS_LIMIT = gasLimit_;
        emit UpdatedGasLimit(gasLimit_);
    }
    
    function updateProtocolFlatFee(uint256 protocolFlatFee_) external {
        require(msg.sender == UNIVERSAL_EXECUTOR_MODULE, "MockPRC20: caller is not UEM");
        PC_PROTOCOL_FEE = protocolFlatFee_;
        emit UpdatedProtocolFlatFee(protocolFlatFee_);
    }
    
    function setName(string memory newName) external {
        require(msg.sender == UNIVERSAL_EXECUTOR_MODULE, "MockPRC20: caller is not UEM");
        _name = newName;
    }
    
    function setSymbol(string memory newSymbol) external {
        require(msg.sender == UNIVERSAL_EXECUTOR_MODULE, "MockPRC20: caller is not UEM");
        _symbol = newSymbol;
    }
    
    // ========= Internal Functions =========
    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0) && recipient != address(0), "MockPRC20: transfer to/from zero address");
        require(_balances[sender] >= amount, "MockPRC20: insufficient balance");
        
        unchecked {
            _balances[sender] = _balances[sender] - amount;
            _balances[recipient] = _balances[recipient] + amount;
        }
        
        emit Transfer(sender, recipient, amount);
    }
    
    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "MockPRC20: mint to zero address");
        require(amount > 0, "MockPRC20: mint zero amount");
        
        unchecked {
            _totalSupply += amount;
            _balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);
    }
    
    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "MockPRC20: burn from zero address");
        require(amount > 0, "MockPRC20: burn zero amount");
        
        uint256 bal = _balances[account];
        require(bal >= amount, "MockPRC20: burn amount exceeds balance");
        
        unchecked {
            _balances[account] = bal - amount;
            _totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }
    
    // ========= Test Helper Functions =========
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function setBalance(address account, uint256 amount) external {
        _balances[account] = amount;
    }
    
    function setAllowance(address owner, address spender, uint256 amount) external {
        _allowances[owner][spender] = amount;
    }
}
