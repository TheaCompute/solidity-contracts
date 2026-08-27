// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IStaking} from "./interfaces/IStaking.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IWorkerRegistry} from "./interfaces/IWorkerRegistry.sol";
import {Ownable} from "./Ownable.sol";

/// @title Staking — $THEA staking with lock-tier weighting for the TheaCompute network.
/// @notice Stakers lock $THEA for 30, 90, or 180 days and earn weighted
///         stake (1.0x / 1.25x / 1.5x) used for governance and reward shares.
///         A stake position may be linked to a worker node; the settlement
///         contract slashes linked stake on dishonest disputes, burning the
///         slashed tokens and notifying the worker registry.
contract Staking is IStaking, Ownable {
    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Minimum stake (18 decimals) to link a worker node.
    uint256 public constant MIN_WORKER_STAKE = 1_000e18;

    uint64 public constant LOCK_30_DAYS = 30 days;
    uint64 public constant LOCK_90_DAYS = 90 days;
    uint64 public constant LOCK_180_DAYS = 180 days;

    uint256 public constant WEIGHT_30D = 1_000;
    uint256 public constant WEIGHT_90D = 1_250;
    uint256 public constant WEIGHT_180D = 1_500;
    uint256 public constant WEIGHT_DENOM = 1_000;

    uint256 public constant BPS_DENOM = 10_000;

    /// @notice Operator allowed to credit USDG rewards. Defaults to the deployer
    ///         and is updatable by the owner, so it can move to the reward crank
    ///         service ahead of mainnet rather than being frozen at a placeholder.
    address public crankOperator;

    /// @notice Slashed $THEA is sent here, removing it from circulation.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    struct StakePosition {
        uint256 amountStaked;
        uint256 weightedStakeAmount;
        uint64 lockDuration;
        uint64 lockedUntil;
        uint64 stakedAt;
        uint64 lastRewardClaimed;
        uint256 pendingRewards;
        address linkedWorkerNode;
    }

    /// @notice Settlement contract allowed to slash linked worker stake.
    address public settlement;
    /// @notice Worker registry notified when a slash is applied.
    address public workerRegistry;

    /// @notice $THEA token (18 decimals) held by this contract while staked.
    IERC20 public immutable crossToken;
    /// @notice USDG token (6 decimals) paid out as staking rewards.
    IERC20 public immutable usdg;

    /// @notice Full stake position by staker address.
    mapping(address => StakePosition) public positions;
    /// @notice Reverse lookup: worker node address to the staker backing it.
    mapping(address => address) public stakerForWorker;

    /// @notice Total weighted stake across all stakers, 18 decimals.
    uint256 public totalWeightedStake;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Staked(
        address indexed staker, uint256 amount, uint32 lockDays, uint64 lockedUntil, uint256 weightedStake
    );
    event Unstaked(address indexed staker, uint256 amountReturned);
    event WorkerLinked(address indexed staker, address indexed worker, uint256 stakedAmount);
    event RewardsCredited(address indexed staker, uint256 usdgAmount);
    event RewardsCreditedBatch(uint256 stakerCount, uint256 totalUsdgAmount);
    event RewardsClaimed(address indexed staker, uint256 usdgAmount);
    event WorkerSlashed(address indexed staker, address indexed worker, uint256 slashAmount, uint256 remainingStake);
    event SettlementSet(address indexed settlement);
    event WorkerRegistrySet(address indexed workerRegistry);
    event CrankOperatorSet(address indexed crankOperator);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice Lock period must be 30, 90, or 180 days.
    error InvalidLockPeriod();
    /// @notice Stake amount must be greater than zero.
    error ZeroAmount();
    /// @notice Worker nodes must stake at least 1,000 $THEA.
    error BelowMinimumWorkerStake();
    /// @notice Tokens are still locked.
    error StillLocked();
    /// @notice No tokens are currently staked.
    error NothingStaked();
    /// @notice Slash size must be at most 10,000 basis points (the whole stake).
    error InvalidSlashBps();
    /// @notice No rewards are pending for this stake account.
    error NoPendingRewards();
    /// @notice This stake position is already linked to a worker node.
    error AlreadyLinked();
    /// @notice New lock period cannot be shorter than the existing lock duration.
    error LockPeriodTooShort();
    /// @notice The worker node is not registered in the worker registry.
    error WorkerNotRegistered();
    error TransferFailed();
    /// @notice creditRewardsBatch was given arrays of different lengths.
    error LengthMismatch();

    constructor(address crossToken_, address usdg_) {
        crankOperator = msg.sender;
        crossToken = IERC20(crossToken_);
        usdg = IERC20(usdg_);
        emit CrankOperatorSet(msg.sender);
    }

    // ---------------------------------------------------------------------
    // Admin wiring
    // ---------------------------------------------------------------------

    function setSettlement(address settlement_) external onlyOwner {
        if (settlement_ == address(0)) revert ZeroAddress();
        settlement = settlement_;
        emit SettlementSet(settlement_);
    }

    function setWorkerRegistry(address workerRegistry_) external onlyOwner {
        if (workerRegistry_ == address(0)) revert ZeroAddress();
        workerRegistry = workerRegistry_;
        emit WorkerRegistrySet(workerRegistry_);
    }

    /// @notice Update the reward crank operator. Owner only.
    function setCrankOperator(address crankOperator_) external onlyOwner {
        if (crankOperator_ == address(0)) revert ZeroAddress();
        crankOperator = crankOperator_;
        emit CrankOperatorSet(crankOperator_);
    }

    // ---------------------------------------------------------------------
    // Staking
    // ---------------------------------------------------------------------

    /// @notice Stake $THEA for a 30-, 90-, or 180-day lock. Additional
    ///         stake may only use a lock at least as long as the current one,
    ///         and re-locks the whole position from now.
    function stake(uint256 amount, uint32 lockDays) external {
        if (amount == 0) revert ZeroAmount();

        uint64 lockDuration;
        uint256 weight;
        if (lockDays == 30) {
            lockDuration = LOCK_30_DAYS;
            weight = WEIGHT_30D;
        } else if (lockDays == 90) {
            lockDuration = LOCK_90_DAYS;
            weight = WEIGHT_90D;
        } else if (lockDays == 180) {
            lockDuration = LOCK_180_DAYS;
            weight = WEIGHT_180D;
        } else {
            revert InvalidLockPeriod();
        }

        if (!crossToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

        StakePosition storage position = positions[msg.sender];

        if (position.amountStaked > 0) {
            if (lockDuration < position.lockDuration) revert LockPeriodTooShort();
            position.amountStaked += amount;
        } else {
            position.amountStaked = amount;
            position.stakedAt = uint64(block.timestamp);
            position.lastRewardClaimed = uint64(block.timestamp);
        }

        position.lockDuration = lockDuration;
        position.lockedUntil = uint64(block.timestamp) + lockDuration;

        uint256 newWeighted = position.amountStaked * weight / WEIGHT_DENOM;
        totalWeightedStake = totalWeightedStake - position.weightedStakeAmount + newWeighted;
        position.weightedStakeAmount = newWeighted;

        emit Staked(msg.sender, amount, lockDays, position.lockedUntil, newWeighted);
    }

    /// @notice Link the caller's stake position to a registered worker node,
    ///         making the stake slashable for that worker's conduct.
    function linkWorker(address worker) external {
        StakePosition storage position = positions[msg.sender];

        if (position.linkedWorkerNode != address(0)) revert AlreadyLinked();
        if (stakerForWorker[worker] != address(0)) revert AlreadyLinked();
        if (position.amountStaked < MIN_WORKER_STAKE) revert BelowMinimumWorkerStake();
        if (worker == address(0) || workerRegistry == address(0)) revert WorkerNotRegistered();
        if (!IWorkerRegistry(workerRegistry).isRegistered(worker)) revert WorkerNotRegistered();

        position.linkedWorkerNode = worker;
        stakerForWorker[worker] = msg.sender;

        emit WorkerLinked(msg.sender, worker, position.amountStaked);
    }

    /// @notice Withdraw the full stake once the lock has expired. Clears any
    ///         worker link. Pending USDG rewards remain claimable.
    function unstake() external {
        StakePosition storage position = positions[msg.sender];

        if (position.amountStaked == 0) revert NothingStaked();
        if (block.timestamp < position.lockedUntil) revert StillLocked();

        uint256 amountToReturn = position.amountStaked;
        address worker = position.linkedWorkerNode;

        totalWeightedStake -= position.weightedStakeAmount;
        position.amountStaked = 0;
        position.weightedStakeAmount = 0;
        position.lockDuration = 0;
        position.lockedUntil = 0;
        position.stakedAt = 0;

        if (worker != address(0)) {
            position.linkedWorkerNode = address(0);
            delete stakerForWorker[worker];
        }

        if (!crossToken.transfer(msg.sender, amountToReturn)) revert TransferFailed();

        emit Unstaked(msg.sender, amountToReturn);
    }

    // ---------------------------------------------------------------------
    // Rewards
    // ---------------------------------------------------------------------

    /// @notice Credit USDG rewards to a staker. Only the crank operator.
    function creditRewards(address staker, uint256 usdgAmount) external {
        if (msg.sender != crankOperator) revert Unauthorized();
        if (usdgAmount == 0) revert ZeroAmount();

        positions[staker].pendingRewards += usdgAmount;

        emit RewardsCredited(staker, usdgAmount);
    }

    /// @notice Credit USDG rewards to many stakers in one transaction, the
    ///         shape the reward crank actually runs in. Only the crank operator.
    /// @return totalCredited the sum of the credited amounts.
    function creditRewardsBatch(address[] calldata stakers, uint256[] calldata usdgAmounts)
        external
        returns (uint256 totalCredited)
    {
        if (msg.sender != crankOperator) revert Unauthorized();
        if (stakers.length != usdgAmounts.length) revert LengthMismatch();

        for (uint256 i = 0; i < stakers.length; i++) {
            uint256 usdgAmount = usdgAmounts[i];
            if (usdgAmount == 0) revert ZeroAmount();

            positions[stakers[i]].pendingRewards += usdgAmount;
            totalCredited += usdgAmount;

            emit RewardsCredited(stakers[i], usdgAmount);
        }

        emit RewardsCreditedBatch(stakers.length, totalCredited);
    }

    /// @notice Claim all pending USDG rewards, paid from this contract's balance.
    function claimRewards() external {
        StakePosition storage position = positions[msg.sender];

        uint256 rewards = position.pendingRewards;
        if (rewards == 0) revert NoPendingRewards();

        position.pendingRewards = 0;
        position.lastRewardClaimed = uint64(block.timestamp);

        if (!usdg.transfer(msg.sender, rewards)) revert TransferFailed();

        emit RewardsClaimed(msg.sender, rewards);
    }

    // ---------------------------------------------------------------------
    // Slashing
    // ---------------------------------------------------------------------

    /// @notice Burn `bps` basis points of the stake linked to `worker` and
    ///         apply the reputation slash in the worker registry. Callable
    ///         only by the settlement contract (dispute slashing).
    function slashWorker(address worker, uint256 bps) external returns (uint256 slashed) {
        if (msg.sender != settlement) revert Unauthorized();
        if (bps > BPS_DENOM) revert InvalidSlashBps();

        address staker = stakerForWorker[worker];
        if (staker == address(0)) staker = worker;

        StakePosition storage position = positions[staker];
        slashed = position.amountStaked * bps / BPS_DENOM;

        if (slashed > 0) {
            position.amountStaked -= slashed;

            uint256 weight = _lockDurationToWeight(position.lockDuration);
            uint256 newWeighted = position.amountStaked * weight / WEIGHT_DENOM;
            totalWeightedStake = totalWeightedStake - position.weightedStakeAmount + newWeighted;
            position.weightedStakeAmount = newWeighted;

            if (!crossToken.transfer(BURN_ADDRESS, slashed)) revert TransferFailed();
        }

        if (workerRegistry != address(0)) {
            IWorkerRegistry(workerRegistry).applySlash(worker);
        }

        emit WorkerSlashed(staker, worker, slashed, position.amountStaked);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function stakedAmount(address account) external view returns (uint256) {
        return positions[account].amountStaked;
    }

    function weightedStake(address account) external view returns (uint256) {
        return positions[account].weightedStakeAmount;
    }

    function linkedWorker(address account) external view returns (address) {
        return positions[account].linkedWorkerNode;
    }

    /// @notice True when the stake backing `account` (a staker, or a worker
    ///         node resolved to its staker) meets the minimum worker stake.
    function meetsWorkerMinimum(address account) external view returns (bool) {
        address staker = stakerForWorker[account];
        if (staker == address(0)) staker = account;
        return positions[staker].amountStaked >= MIN_WORKER_STAKE;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _lockDurationToWeight(uint64 lockDuration) internal pure returns (uint256) {
        if (lockDuration >= LOCK_180_DAYS) return WEIGHT_180D;
        if (lockDuration >= LOCK_90_DAYS) return WEIGHT_90D;
        return WEIGHT_30D;
    }
}
