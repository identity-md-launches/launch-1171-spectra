// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Spectra (SPECTRA)
/// @notice A fixed-supply ERC-20. The whole supply, 1,000,000,000 SPECTRA with 18 decimals, is minted
///         once to the deployer in the constructor. There is no owner, no minter, no pause, no
///         blacklist and no fee: every transfer moves exactly the amount asked for, and the supply
///         can never grow.
/// @dev Self-contained on purpose: no inherited library and no external library calls, so the
///      bytecode has no link placeholders and the behaviour is fully visible in this one file.
///      Holders may burn their own tokens, which only ever shrinks the supply.
contract SpectraToken {
    // ---------------------------------------------------------------------------------------------
    // ERC-20 metadata
    // ---------------------------------------------------------------------------------------------

    string public constant name = "Spectra";
    string public constant symbol = "SPECTRA";
    uint8 public constant decimals = 18;

    /// @notice The full supply in minor units: 1,000,000,000 * 10^18.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    // ---------------------------------------------------------------------------------------------
    // ERC-20 state
    // ---------------------------------------------------------------------------------------------

    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    // ---------------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice A transfer or approval named the zero address where a real account is required.
    error ZeroAddress();
    /// @notice `account` tried to move `needed` but holds only `available`.
    error InsufficientBalance(address account, uint256 available, uint256 needed);
    /// @notice `spender` tried to spend `needed` of `owner`'s tokens but is allowed only `available`.
    error InsufficientAllowance(address owner, address spender, uint256 available, uint256 needed);

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @notice Mints the entire supply to the deployer. Nothing can mint afterwards.
    constructor() {
        totalSupply = INITIAL_SUPPLY;
        balanceOf[msg.sender] = INITIAL_SUPPLY;
        emit Transfer(address(0), msg.sender, INITIAL_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-20
    // ---------------------------------------------------------------------------------------------

    /// @notice Moves `amount` from the caller to `to`.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Lets `spender` move up to `amount` of the caller's tokens. Overwrites any prior value.
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Moves `amount` from `from` to `to` using the caller's allowance. An allowance of
    ///         `type(uint256).max` is treated as unlimited and is not decremented.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Burning: only ever shrinks the supply, and only from the caller's own balance or allowance.
    // ---------------------------------------------------------------------------------------------

    /// @notice Destroys `amount` of the caller's tokens.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Destroys `amount` of `from`'s tokens using the caller's allowance. Without an
    ///         allowance granted by `from` this reverts, so nobody can burn a holder's tokens
    ///         against their will.
    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            balanceOf[from] = fromBalance - amount;
            // Total supply is bounded, so a balance can never overflow.
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        if (spender == address(0)) revert ZeroAddress();
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 current = allowance[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance(owner, spender, current, amount);
        unchecked {
            allowance[owner][spender] = current - amount;
        }
        emit Approval(owner, spender, current - amount);
    }

    function _burn(address from, uint256 amount) internal {
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            balanceOf[from] = fromBalance - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }
}
