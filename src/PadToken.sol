// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title PadToken
/// @notice EIP-1167 clone template for every launch token. 1e9 supply, 18 decimals, minted once to the
///         launch's game by the pad. Transfers are locked until graduation, except when the sender is the
///         game or PadLiquidity. The template itself is initialized in its constructor so it can never be used.
contract PadToken {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint8 public constant decimals = 18;

    string public name;
    string public symbol;
    string public imageURL;
    uint256 public totalSupply;
    address public game;
    address public liquidity;
    bool public unlocked;
    bool public initialized;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Unlocked();

    error AlreadyInitialized();
    error Locked();
    error NotLiquidity();

    constructor() {
        initialized = true; // template can never be initialized
    }

    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata imageURL_,
        address game_,
        address liquidity_
    ) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        name = name_;
        symbol = symbol_;
        imageURL = imageURL_;
        game = game_;
        liquidity = liquidity_;
        totalSupply = SUPPLY;
        balanceOf[game_] = SUPPLY;
        emit Transfer(address(0), game_, SUPPLY);
    }

    /// @notice Called by PadLiquidity inside the graduation transaction.
    function unlock() external {
        if (msg.sender != liquidity) revert NotLiquidity();
        unlocked = true;
        emit Unlocked();
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (!unlocked && msg.sender != game && msg.sender != liquidity) revert Locked();
        require(to != address(0), "zero to");
        uint256 bal = balanceOf[from];
        require(bal >= amount, "balance");
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
