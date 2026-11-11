// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/**
 * @title MockERC20
 * @notice Minimal 18-decimal ERC-20 token with open testnet minting for Base Sepolia & Unichain Sepolia demos.
 */
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(uint256 available, uint256 required);
    error InsufficientAllowance(uint256 available, uint256 required);
    error ZeroAddress();

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to_, uint256 amount_) external {
        if (to_ == address(0)) revert ZeroAddress();
        totalSupply += amount_;
        balanceOf[to_] += amount_;
        emit Transfer(address(0), to_, amount_);
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        if (spender_ == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender_] = amount_;
        emit Approval(msg.sender, spender_, amount_);
        return true;
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        _transfer(msg.sender, to_, amount_);
        return true;
    }

    function transferFrom(address from_, address to_, uint256 amount_) external returns (bool) {
        uint256 allowed = allowance[from_][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount_) revert InsufficientAllowance(allowed, amount_);
            unchecked {
                allowance[from_][msg.sender] = allowed - amount_;
            }
        }
        _transfer(from_, to_, amount_);
        return true;
    }

    function _transfer(address from_, address to_, uint256 amount_) internal {
        if (to_ == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from_];
        if (bal < amount_) revert InsufficientBalance(bal, amount_);
        unchecked {
            balanceOf[from_] = bal - amount_;
            balanceOf[to_] += amount_;
        }
        emit Transfer(from_, to_, amount_);
    }
}
