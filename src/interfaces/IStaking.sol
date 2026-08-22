// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IStaking {
    /// @notice Raw staked $THEA (18 decimals) for an account.
    function stakedAmount(address account) external view returns (uint256);

    /// @notice Stake weighted by lock-tier multiplier (30d=1.0x, 90d=1.25x, 180d=1.5x), 18 decimals.
    function weightedStake(address account) external view returns (uint256);

    /// @notice Total weighted stake across all stakers, 18 decimals.
    function totalWeightedStake() external view returns (uint256);

    /// @notice The worker address a stake position is linked to (address(0) when unlinked).
    function linkedWorker(address account) external view returns (address);

    /// @notice Burn `bps` basis points of the stake linked to `worker`.
    ///         Callable only by the settlement contract (dispute slashing).
    function slashWorker(address worker, uint256 bps) external returns (uint256 slashed);

    /// @notice True when the account's stake meets the minimum worker stake (1,000 $THEA).
    function meetsWorkerMinimum(address account) external view returns (bool);
}
