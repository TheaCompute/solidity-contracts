// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title $THEA — governance and staking token for the TheaCompute network.
/// @notice Fixed supply of 1,000,000,000 tokens minted at deployment. No inflation.
contract TheaComputeToken {
    string public constant name = "TheaCompute";
    string public constant symbol = "$THEA";
    uint8 public constant decimals = 18;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    uint256 public immutable totalSupply = TOTAL_SUPPLY;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // --- EIP-2612 permit ---
    /// @notice keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
    bytes32 public constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    /// @notice Per-owner nonce consumed by each permit, guarding against replay.
    mapping(address => uint256) public nonces;

    uint256 internal immutable INITIAL_CHAIN_ID;
    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();
    /// @notice The permit deadline has already passed.
    error PermitExpired();
    /// @notice The permit signature did not recover to the owner.
    error InvalidSigner();

    constructor(address treasury) {
        balanceOf[treasury] = TOTAL_SUPPLY;
        emit Transfer(address(0), treasury, TOTAL_SUPPLY);

        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();
    }

    function transfer(address to, uint256 value) external returns (bool) {
        return _transfer(msg.sender, to, value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - value;
        }
        return _transfer(from, to, value);
    }

    function _transfer(address from, address to, uint256 value) internal returns (bool) {
        uint256 balance = balanceOf[from];
        if (balance < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = balance - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
        return true;
    }

    // ---------------------------------------------------------------------
    // EIP-2612 permit: approve via signature, no prior transaction needed.
    // ---------------------------------------------------------------------

    /// @notice Set `allowance[owner][spender] = value` from an off-chain
    ///         signature, letting an approval and its follow-up call (stake,
    ///         transferFrom, ...) land in a single transaction.
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert PermitExpired();

        // nonces[owner]++ can never realistically overflow.
        unchecked {
            bytes32 digest = keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
                )
            );
            address recovered = ecrecover(digest, v, r, s);
            if (recovered == address(0) || recovered != owner) revert InvalidSigner();
        }

        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    /// @notice EIP-712 domain separator, recomputed if the chain forks so
    ///         signatures stay bound to the active chain id.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : _computeDomainSeparator();
    }

    function _computeDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }
}
