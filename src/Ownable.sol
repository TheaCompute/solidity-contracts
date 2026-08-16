// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Ownable
/// @notice Two-step ownership handover shared by the TheaCompute contracts.
///         Every contract in the set is admined by the address that deployed it,
///         which leaves the deployer key wired in permanently. This base lets the
///         owner nominate a successor (a multisig ahead of mainnet, say) that has
///         to accept before it takes effect, so a mistyped address cannot strand a
///         contract without an admin.
abstract contract Ownable {
    /// @notice Contract admin. Set to the deployer at construction.
    address public owner;
    /// @notice Nominated successor. Zero unless a handover is in flight.
    address public pendingOwner;

    /// @notice An owner nominated a successor. `newOwner` is zero when a pending
    ///         handover is cancelled.
    event OwnershipTransferStarted(address indexed currentOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice The caller is not the owner (or not the nominated successor).
    error Unauthorized();
    /// @notice A required address argument was the zero address.
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /// @notice Nominate `newOwner`. Ownership does not move until they call
    ///         acceptOwnership, so the current owner stays in control meanwhile.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Drop a pending nomination.
    function cancelOwnershipTransfer() external onlyOwner {
        pendingOwner = address(0);
        emit OwnershipTransferStarted(owner, address(0));
    }

    /// @notice Take ownership. Callable only by the nominated successor.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();

        address previousOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);

        emit OwnershipTransferred(previousOwner, msg.sender);
    }
}
