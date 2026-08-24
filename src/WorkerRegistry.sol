// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IWorkerRegistry} from "./interfaces/IWorkerRegistry.sol";
import {Ownable} from "./Ownable.sol";

/// @title WorkerRegistry — GPU worker node registry for the TheaCompute network.
/// @notice Tracks worker registration, supported model tiers, and a reputation
///         score maintained as an exponential moving average (EMA) of job outcomes.
///         The settlement contract reports job results; the staking contract
///         reports slashes.
contract WorkerRegistry is IWorkerRegistry, Ownable {
    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint32 public constant REPUTATION_MAX = 1000;
    uint32 public constant REPUTATION_STARTING = 500;
    uint32 public constant EMA_ALPHA_NUMERATOR = 10;
    uint32 public constant EMA_ALPHA_DENOMINATOR = 100;

    /// @notice Tier bitmask flags. A worker may support any combination.
    uint8 public constant TIER_LITE = 0x01;
    uint8 public constant TIER_STANDARD = 0x02;
    uint8 public constant TIER_PRO = 0x04;
    uint8 public constant TIER_MAX = 0x08;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    struct Worker {
        bool registered;
        bool active;
        uint8 tierMask;
        uint32 reputationScore;
        uint64 jobsCompleted;
        uint64 jobsFailed;
        uint64 registeredAt;
        uint64 lastSeenAt;
        string gpuModel;
    }

    /// @notice Settlement contract allowed to report job completions.
    address public settlement;
    /// @notice Staking contract allowed to report slashes.
    address public staking;

    /// @notice Full worker record by worker address.
    mapping(address => Worker) public workers;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event WorkerRegistered(address indexed worker, uint8 tierMask, string gpuModel);
    event WorkerUpdated(address indexed worker, uint8 tierMask, string gpuModel, bool active);
    event WorkerHeartbeat(address indexed worker, uint64 seenAt);
    /// @notice A job outcome was folded into the worker's reputation EMA.
    event CompletionRecorded(address indexed worker, bool success, uint64 latencyMs, uint32 newReputation);
    event WorkerSlashed(address indexed worker, uint32 newReputation);
    event SettlementSet(address indexed settlement);
    event StakingSet(address indexed staking);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice At least one model tier must be declared.
    error NoTiersDeclared();
    /// @notice Tier mask has bits set beyond the four valid tiers.
    error InvalidTierMask();
    error AlreadyRegistered();
    error NotRegistered();

    // ---------------------------------------------------------------------
    // Admin wiring
    // ---------------------------------------------------------------------

    function setSettlement(address settlement_) external onlyOwner {
        if (settlement_ == address(0)) revert ZeroAddress();
        settlement = settlement_;
        emit SettlementSet(settlement_);
    }

    function setStaking(address staking_) external onlyOwner {
        if (staking_ == address(0)) revert ZeroAddress();
        staking = staking_;
        emit StakingSet(staking_);
    }

    // ---------------------------------------------------------------------
    // Worker lifecycle
    // ---------------------------------------------------------------------

    /// @notice Register the caller as a worker node.
    function registerWorker(uint8 tierMask, string calldata gpuModel) external {
        _validateTierMask(tierMask);

        Worker storage worker = workers[msg.sender];
        if (worker.registered) revert AlreadyRegistered();

        worker.registered = true;
        worker.active = true;
        worker.tierMask = tierMask;
        worker.gpuModel = gpuModel;
        worker.reputationScore = REPUTATION_STARTING;
        worker.registeredAt = uint64(block.timestamp);
        worker.lastSeenAt = uint64(block.timestamp);

        emit WorkerRegistered(msg.sender, tierMask, gpuModel);
    }

    /// @notice Change the caller's supported tiers, GPU model, and active flag.
    function updateWorker(uint8 tierMask, string calldata gpuModel, bool active) external {
        _validateTierMask(tierMask);

        Worker storage worker = workers[msg.sender];
        if (!worker.registered) revert NotRegistered();

        worker.tierMask = tierMask;
        worker.gpuModel = gpuModel;
        worker.active = active;
        worker.lastSeenAt = uint64(block.timestamp);

        emit WorkerUpdated(msg.sender, tierMask, gpuModel, active);
    }

    /// @notice Worker liveness ping. `lastSeenAt` otherwise only moves when a
    ///         job settles, so an idle-but-healthy node looks stale to anything
    ///         reading the registry.
    function heartbeat() external {
        Worker storage worker = workers[msg.sender];
        if (!worker.registered) revert NotRegistered();

        worker.lastSeenAt = uint64(block.timestamp);

        emit WorkerHeartbeat(msg.sender, worker.lastSeenAt);
    }

    // ---------------------------------------------------------------------
    // Peer-contract hooks
    // ---------------------------------------------------------------------

    /// @notice Called by the settlement contract after a job settles.
    ///         On success the job counts toward completions and the reputation
    ///         EMA blends in a job score weighted 35% base, 30% latency,
    ///         25% proof validity, 10% availability. On failure the job counts
    ///         toward failures and the EMA pulls reputation toward zero.
    function recordCompletion(address worker, bool success, uint64 latencyMs) external {
        if (msg.sender != settlement) revert Unauthorized();

        Worker storage record = workers[worker];
        if (!record.registered) revert NotRegistered();

        uint32 oldWeight = EMA_ALPHA_DENOMINATOR - EMA_ALPHA_NUMERATOR;

        if (success) {
            record.jobsCompleted += 1;

            uint32 latencyScore = _latencyScoreFromMs(latencyMs);
            uint32 proofScore = REPUTATION_MAX; // proof verified when success is true
            uint32 jobScore = (
                REPUTATION_MAX * 35 + latencyScore * 30 + proofScore * 25 + REPUTATION_MAX * 10
            ) / 100;

            uint32 newScore =
                (record.reputationScore * oldWeight + jobScore * EMA_ALPHA_NUMERATOR) / EMA_ALPHA_DENOMINATOR;
            record.reputationScore = newScore > REPUTATION_MAX ? REPUTATION_MAX : newScore;
        } else {
            record.jobsFailed += 1;

            // Job score is 0 for a failed job; EMA pulls reputation toward zero.
            record.reputationScore = (record.reputationScore * oldWeight) / EMA_ALPHA_DENOMINATOR;
        }

        // A failed job still proves the node was reachable.
        record.lastSeenAt = uint64(block.timestamp);

        emit CompletionRecorded(worker, success, latencyMs, record.reputationScore);
    }

    /// @notice Called by the staking contract when a slash is applied.
    ///         Reputation drops by 20%; the stake itself is burned in the
    ///         staking contract.
    function applySlash(address worker) external {
        if (msg.sender != staking) revert Unauthorized();

        Worker storage record = workers[worker];
        if (!record.registered) revert NotRegistered();

        record.reputationScore = (record.reputationScore * 80) / 100;

        emit WorkerSlashed(worker, record.reputationScore);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function isRegistered(address worker) external view returns (bool) {
        return workers[worker].registered;
    }

    function isActive(address worker) external view returns (bool) {
        Worker storage record = workers[worker];
        return record.registered && record.active;
    }

    function supportsTier(address worker, uint8 tierMask) external view returns (bool) {
        return workers[worker].tierMask & tierMask != 0;
    }

    function reputation(address worker) external view returns (uint32) {
        return workers[worker].reputationScore;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _validateTierMask(uint8 tierMask) internal pure {
        if (tierMask == 0) revert NoTiersDeclared();
        if (tierMask > 0x0F) revert InvalidTierMask();
    }

    /// @dev Latency at or under 500ms scores full marks; 5000ms or above scores
    ///      zero; in between the score falls linearly.
    function _latencyScoreFromMs(uint64 latencyMs) internal pure returns (uint32) {
        if (latencyMs <= 500) return REPUTATION_MAX;
        if (latencyMs >= 5000) return 0;
        uint64 range = 5000 - 500;
        uint64 over = latencyMs - 500;
        return REPUTATION_MAX - uint32(uint64(REPUTATION_MAX) * over / range);
    }
}
