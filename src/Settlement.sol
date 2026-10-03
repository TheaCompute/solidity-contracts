// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IJobEscrow} from "./interfaces/IJobEscrow.sol";
import {IJobRouter} from "./interfaces/IJobRouter.sol";
import {IWorkerRegistry} from "./interfaces/IWorkerRegistry.sol";
import {IStaking} from "./interfaces/IStaking.sol";
import {Ownable} from "./Ownable.sol";

/// @title Settlement
/// @notice Verifies worker proof submissions and releases escrowed USDG.
///         Payout is immediate on proof submission; a 60-second dispute window
///         runs afterwards, during which the client may open a dispute. The
///         arbitrator resolves disputes, slashing 5% of a dishonest worker's stake.
contract Settlement is Ownable {
    uint256 public constant WORKER_BPS_BASE = 7_500;
    uint256 public constant WORKER_BPS_STAKED = 8_500;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Minimum $THEA stake (18 decimals) for the boosted payout split.
    uint256 public constant MIN_STAKE_FOR_BONUS = 1_000e18;
    uint64 public constant DISPUTE_WINDOW_SECONDS = 60;
    /// @notice USDG units per credit, mirroring JobEscrow.USDG_PER_CREDIT.
    uint256 public constant USDG_PER_CREDIT = 10_000;
    /// @notice Basis points of stake burned from a dishonest worker (5%).
    uint256 public constant SLASH_BPS = 500;

    /// @notice Dispute arbitrator. Defaults to the deployer and is updatable by
    ///         the owner, so it can be moved to a multisig ahead of mainnet
    ///         instead of being frozen at a placeholder address.
    address public arbitrator;

    struct ProofRecord {
        address worker;
        bytes32 outputHash;
        uint256 workerPayout;
        uint256 treasuryPayout;
        uint64 settledAt;
        uint64 disputeWindowCloses;
        bool disputed;
        bool resolved;
        bytes32 clientHash;
        address disputedBy;
    }

    IJobEscrow public jobEscrow;
    IWorkerRegistry public workerRegistry;
    IStaking public staking;
    /// @notice Optional job board. When wired, a job the router has already
    ///         assigned can only be settled by the worker holding that
    ///         assignment. Left unset, any qualified worker may submit.
    IJobRouter public jobRouter;

    mapping(bytes32 => ProofRecord) public proofRecords;

    /// @notice Full proof record for a job as a struct (convenience view).
    function proofRecord(bytes32 jobId) external view returns (ProofRecord memory) {
        return proofRecords[jobId];
    }

    /// @notice Whether the client can still open a dispute on this job.
    function isDisputeWindowOpen(bytes32 jobId) external view returns (bool) {
        ProofRecord storage record = proofRecords[jobId];
        return record.settledAt != 0 && !record.disputed && uint64(block.timestamp) <= record.disputeWindowCloses;
    }

    event JobSettled(
        bytes32 indexed jobId,
        address indexed worker,
        uint256 workerPayout,
        uint256 treasuryPayout,
        bytes32 outputHash,
        uint64 latencyMs,
        bool staked
    );
    event DisputeOpened(bytes32 indexed jobId, address indexed disputedBy, bytes32 workerHash, bytes32 clientHash);
    event DisputeResolved(bytes32 indexed jobId, bool workerDishonest, uint256 slashAmount);
    event JobEscrowSet(address indexed jobEscrow);
    event WorkerRegistrySet(address indexed workerRegistry);
    event StakingSet(address indexed staking);
    event JobRouterSet(address indexed jobRouter);
    event ArbitratorSet(address indexed arbitrator);

    error InvalidEscrowStatus();
    error JobExpired();
    error WorkerNotRegistered();
    error WorkerNotActive();
    error TierNotSupported();
    error ProofAlreadySubmitted();
    error ProofNotFound();
    error DisputeWindowClosed();
    error AlreadyDisputed();
    error HashesMatch();
    error NotDisputed();
    error AlreadyResolved();
    error NotJobOwner();
    /// @notice The router assigned this job to a different worker.
    error NotAssignedWorker();

    constructor() {
        arbitrator = msg.sender;
        emit ArbitratorSet(msg.sender);
    }

    function setJobEscrow(address jobEscrow_) external onlyOwner {
        if (jobEscrow_ == address(0)) revert ZeroAddress();
        jobEscrow = IJobEscrow(jobEscrow_);
        emit JobEscrowSet(jobEscrow_);
    }

    function setWorkerRegistry(address workerRegistry_) external onlyOwner {
        if (workerRegistry_ == address(0)) revert ZeroAddress();
        workerRegistry = IWorkerRegistry(workerRegistry_);
        emit WorkerRegistrySet(workerRegistry_);
    }

    function setStaking(address staking_) external onlyOwner {
        if (staking_ == address(0)) revert ZeroAddress();
        staking = IStaking(staking_);
        emit StakingSet(staking_);
    }

    /// @notice Wire the job board so settlement respects on-chain assignments.
    ///         Owner only. Pass address(0) to go back to open settlement.
    function setJobRouter(address jobRouter_) external onlyOwner {
        jobRouter = IJobRouter(jobRouter_);
        emit JobRouterSet(jobRouter_);
    }

    /// @notice Update the dispute arbitrator. Owner only.
    function setArbitrator(address arbitrator_) external onlyOwner {
        if (arbitrator_ == address(0)) revert ZeroAddress();
        arbitrator = arbitrator_;
        emit ArbitratorSet(arbitrator_);
    }

    /// @notice Submit a completed job's output proof. Caller must be the worker.
    ///         Releases the escrow immediately (worker share now, treasury share
    ///         accrues in the escrow contract) and opens the dispute window.
    function submitProof(bytes32 jobId, bytes32 outputHash, uint64 latencyMs) external {
        if (proofRecords[jobId].settledAt != 0) revert ProofAlreadySubmitted();

        if (jobEscrow.escrowStatus(jobId) != IJobEscrow.EscrowStatus.Locked) revert InvalidEscrowStatus();
        if (uint64(block.timestamp) >= jobEscrow.escrowExpiresAt(jobId)) revert JobExpired();

        address worker = msg.sender;
        if (!workerRegistry.isRegistered(worker)) revert WorkerNotRegistered();
        if (!workerRegistry.isActive(worker)) revert WorkerNotActive();
        _requireAssignment(jobId, worker);

        IJobEscrow.ModelTier tier = jobEscrow.escrowTier(jobId);
        uint8 tierMask = uint8(1 << uint8(tier));
        if (!workerRegistry.supportsTier(worker, tierMask)) revert TierNotSupported();

        uint256 totalUsdg = jobEscrow.escrowCredits(jobId) * USDG_PER_CREDIT;
        bool staked = staking.meetsWorkerMinimum(worker);
        uint256 workerBps = staked ? WORKER_BPS_STAKED : WORKER_BPS_BASE;
        uint256 workerPayout = (totalUsdg * workerBps) / BPS_DENOMINATOR;
        uint256 treasuryPayout = totalUsdg - workerPayout;

        // Immediate payout: the escrow releases funds now; the dispute window
        // runs after the fact and a dishonest verdict is punished by slashing.
        jobEscrow.settleEscrow(jobId, worker, workerBps);
        workerRegistry.recordCompletion(worker, true, latencyMs);

        uint64 nowTs = uint64(block.timestamp);
        proofRecords[jobId] = ProofRecord({
            worker: worker,
            outputHash: outputHash,
            workerPayout: workerPayout,
            treasuryPayout: treasuryPayout,
            settledAt: nowTs,
            disputeWindowCloses: nowTs + DISPUTE_WINDOW_SECONDS,
            disputed: false,
            resolved: false,
            clientHash: bytes32(0),
            disputedBy: address(0)
        });

        emit JobSettled(jobId, worker, workerPayout, treasuryPayout, outputHash, latencyMs, staked);
    }

    /// @notice Open a dispute within the window. Caller must be the job's client
    ///         and must present a hash that differs from the worker's output hash.
    function openDispute(bytes32 jobId, bytes32 clientHash) external {
        ProofRecord storage record = proofRecords[jobId];
        if (record.settledAt == 0) revert ProofNotFound();
        if (jobEscrow.escrowClient(jobId) != msg.sender) revert NotJobOwner();
        if (record.disputed) revert AlreadyDisputed();
        if (uint64(block.timestamp) > record.disputeWindowCloses) revert DisputeWindowClosed();
        if (record.outputHash == clientHash) revert HashesMatch();

        record.disputed = true;
        record.clientHash = clientHash;
        record.disputedBy = msg.sender;

        emit DisputeOpened(jobId, msg.sender, record.outputHash, clientHash);
    }

    /// @notice Resolve an open dispute. Arbitrator only. A dishonest verdict burns
    ///         SLASH_BPS (5%) of the worker's stake; an honest verdict changes nothing,
    ///         since the payout was already released on proof submission.
    function resolveDispute(bytes32 jobId, bool workerDishonest) external {
        if (msg.sender != arbitrator) revert Unauthorized();

        ProofRecord storage record = proofRecords[jobId];
        if (record.settledAt == 0) revert ProofNotFound();
        if (!record.disputed) revert NotDisputed();
        if (record.resolved) revert AlreadyResolved();

        record.resolved = true;

        uint256 slashAmount = 0;
        if (workerDishonest) {
            slashAmount = staking.slashWorker(record.worker, SLASH_BPS);
        }

        emit DisputeResolved(jobId, workerDishonest, slashAmount);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Without this check any active worker supporting the tier can front
    ///      run the worker that claimed the job on the router and take the
    ///      payout for work it never did. Jobs dispatched off-chain have no
    ///      posting and stay unrestricted.
    function _requireAssignment(bytes32 jobId, address worker) internal view {
        if (address(jobRouter) == address(0)) return;

        (,,,,, address assignedWorker) = jobRouter.postings(jobId);
        if (assignedWorker != address(0) && assignedWorker != worker) revert NotAssignedWorker();
    }
}
