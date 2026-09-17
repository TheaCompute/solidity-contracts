// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "./interfaces/IERC20.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {Ownable} from "./Ownable.sol";

/// @title RewardDistributor
/// @notice USDG-funded reward epochs for $THEA stakers. The owner opens
///         an epoch by depositing USDG together with a total weighted-stake
///         snapshot; each staker then claims a pro-rata share once per epoch.
contract RewardDistributor is Ownable {
    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Stakers with less weighted stake than this would not receive a
    ///         meaningful payout from a single epoch and cannot claim.
    uint256 public constant MIN_STAKE_TO_CLAIM = 1_000e18;

    /// @notice How long an epoch stays claimable before the owner may recover
    ///         whatever is left. USDG from stakers who never claimed would
    ///         otherwise sit in this contract forever.
    uint64 public constant SWEEP_DELAY = 30 days;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct Epoch {
        uint64 epochId;
        uint256 usdgDeposited;
        uint256 totalStakeSnapshot;
        uint64 startedAt;
    }

    struct ClaimRecord {
        address staker;
        uint64 epochId;
        uint256 amountClaimed;
        uint64 claimedAt;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    IERC20 public immutable usdg;
    IStaking public staking;

    uint64 public currentEpoch;
    uint256 public totalDistributed;

    mapping(uint64 => Epoch) internal _epochs;
    mapping(uint64 => mapping(address => ClaimRecord)) internal _claims;

    /// @notice USDG already claimed out of an epoch.
    mapping(uint64 => uint256) public claimedInEpoch;
    /// @notice Epochs whose remainder has been swept back to the treasury.
    mapping(uint64 => bool) public epochSwept;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event EpochStarted(uint64 indexed epochId, uint256 usdgDeposited, uint256 totalStakeSnapshot);
    event RewardClaimed(uint64 indexed epochId, address indexed staker, uint256 usdgAmount);
    event UnclaimedSwept(uint64 indexed epochId, address indexed to, uint256 usdgAmount);
    event StakingSet(address indexed staking);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAmount();
    error ZeroStakeSnapshot();
    error EpochMismatch();
    error EpochNotFound();
    error NoStake();
    error RewardTooSmall();
    error AlreadyClaimed();
    error TransferFailed();
    /// @notice The epoch is still inside its claim window.
    error SweepTooEarly();
    /// @notice This epoch has already been swept.
    error AlreadySwept();
    /// @notice Every unit of this epoch was claimed; there is nothing to sweep.
    error NothingToSweep();

    constructor(address usdg_) {
        usdg = IERC20(usdg_);
    }

    // ---------------------------------------------------------------------
    // Owner wiring
    // ---------------------------------------------------------------------

    /// @notice Wires the staking contract used for claim weights.
    function setStaking(address staking_) external onlyOwner {
        if (staking_ == address(0)) revert ZeroAddress();
        staking = IStaking(staking_);
        emit StakingSet(staking_);
    }

    // ---------------------------------------------------------------------
    // Epochs
    // ---------------------------------------------------------------------

    /// @notice Called by the owner once per reward cycle. Pulls USDG from the
    ///         caller into the distributor and opens a new epoch that stakers
    ///         can claim against. Epoch IDs must be strictly sequential.
    function startEpoch(uint64 epochId, uint256 usdgAmount, uint256 totalStakeSnapshot) external onlyOwner {
        if (usdgAmount == 0) revert ZeroAmount();
        if (totalStakeSnapshot == 0) revert ZeroStakeSnapshot();
        if (epochId != currentEpoch + 1) revert EpochMismatch();

        if (!usdg.transferFrom(msg.sender, address(this), usdgAmount)) revert TransferFailed();

        currentEpoch = epochId;
        totalDistributed += usdgAmount;

        _epochs[epochId] = Epoch({
            epochId: epochId,
            usdgDeposited: usdgAmount,
            totalStakeSnapshot: totalStakeSnapshot,
            startedAt: uint64(block.timestamp)
        });

        emit EpochStarted(epochId, usdgAmount, totalStakeSnapshot);
    }

    /// @notice Any staker calls this once per epoch to receive their pro-rata
    ///         share: weightedStake * usdgDeposited / totalStakeSnapshot.
    function claimReward(uint64 epochId) external {
        Epoch storage epoch = _epochs[epochId];
        if (epoch.usdgDeposited == 0) revert EpochNotFound();
        if (epochSwept[epochId]) revert AlreadySwept();

        uint256 weighted = staking.weightedStake(msg.sender);
        if (weighted < MIN_STAKE_TO_CLAIM) revert NoStake();

        ClaimRecord storage claim = _claims[epochId][msg.sender];
        if (claim.claimedAt != 0) revert AlreadyClaimed();

        uint256 stakerUsdg = (weighted * epoch.usdgDeposited) / epoch.totalStakeSnapshot;
        if (stakerUsdg == 0) revert RewardTooSmall();

        claim.staker = msg.sender;
        claim.epochId = epochId;
        claim.amountClaimed = stakerUsdg;
        claim.claimedAt = uint64(block.timestamp);
        claimedInEpoch[epochId] += stakerUsdg;

        if (!usdg.transfer(msg.sender, stakerUsdg)) revert TransferFailed();

        emit RewardClaimed(epochId, msg.sender, stakerUsdg);
    }

    /// @notice Recover the USDG left in an epoch once its claim window has run
    ///         out, and close the epoch to further claims. Owner only. The
    ///         swept amount comes back off `totalDistributed`, which then
    ///         reflects what stakers actually received.
    /// @return amount the USDG swept back to `to`.
    function sweepUnclaimed(uint64 epochId, address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();

        Epoch storage epoch = _epochs[epochId];
        if (epoch.usdgDeposited == 0) revert EpochNotFound();
        if (epochSwept[epochId]) revert AlreadySwept();
        if (block.timestamp < epoch.startedAt + SWEEP_DELAY) revert SweepTooEarly();

        amount = epoch.usdgDeposited - claimedInEpoch[epochId];
        if (amount == 0) revert NothingToSweep();

        epochSwept[epochId] = true;
        totalDistributed -= amount;

        if (!usdg.transfer(to, amount)) revert TransferFailed();

        emit UnclaimedSwept(epochId, to, amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getEpoch(uint64 epochId) external view returns (Epoch memory) {
        return _epochs[epochId];
    }

    function getClaimRecord(uint64 epochId, address staker) external view returns (ClaimRecord memory) {
        return _claims[epochId][staker];
    }

    /// @notice USDG still unclaimed in an epoch.
    function unclaimedInEpoch(uint64 epochId) external view returns (uint256) {
        if (epochSwept[epochId]) return 0;
        return _epochs[epochId].usdgDeposited - claimedInEpoch[epochId];
    }
}
