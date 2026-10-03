// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IJobEscrow} from "./interfaces/IJobEscrow.sol";
import {IWorkerRegistry} from "./interfaces/IWorkerRegistry.sol";
import {Ownable} from "./Ownable.sol";

/// @title JobRouter
/// @notice On-chain job board for the TheaCompute network. Clients publish a
///         posting after locking escrow; workers atomically reserve open jobs
///         they are qualified to serve.
contract JobRouter is Ownable {
    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Tier bit flags matching the worker registry conventions.
    uint8 public constant TIER_LITE = 0x01;
    uint8 public constant TIER_STANDARD = 0x02;
    uint8 public constant TIER_PRO = 0x04;
    uint8 public constant TIER_MAX = 0x08;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum PostingStatus {
        None,
        Open,
        Assigned,
        Cancelled
    }

    struct JobPosting {
        address client;
        IJobEscrow.ModelTier tier;
        PostingStatus status;
        uint64 createdAt;
        uint64 expiresAt;
        address assignedWorker;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    IJobEscrow public jobEscrow;
    IWorkerRegistry public workerRegistry;

    mapping(bytes32 => JobPosting) public postings;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event JobPosted(
        bytes32 indexed jobId,
        address indexed client,
        IJobEscrow.ModelTier tier,
        uint64 expiresAt
    );
    event JobClaimed(bytes32 indexed jobId, address indexed worker);
    event JobCancelled(bytes32 indexed jobId, address indexed client);
    event JobEscrowSet(address indexed jobEscrow);
    event WorkerRegistrySet(address indexed workerRegistry);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice A posting already exists for this job ID.
    error PostingAlreadyExists();
    /// @notice Job posting is not open for claiming or cancellation.
    error JobNotOpen();
    /// @notice The job escrow is not in Locked status.
    error EscrowNotLocked();
    /// @notice You are not the owner of this escrow.
    error NotEscrowOwner();
    /// @notice Worker is not currently active.
    error WorkerNotActive();
    /// @notice Worker does not support the tier required by this job.
    error TierNotSupported();
    /// @notice The job posting has already expired.
    error JobExpired();

    // ---------------------------------------------------------------------
    // Admin wiring
    // ---------------------------------------------------------------------

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

    // ---------------------------------------------------------------------
    // Job lifecycle
    // ---------------------------------------------------------------------

    /// @notice Client calls this after locking escrow to publish the job
    ///         on-chain. The posting inherits the tier and expiry from the
    ///         escrow so workers can filter by capability without querying
    ///         the escrow contract separately.
    function postJob(bytes32 jobId) external {
        if (postings[jobId].status != PostingStatus.None) revert PostingAlreadyExists();
        if (jobEscrow.escrowStatus(jobId) != IJobEscrow.EscrowStatus.Locked) {
            revert EscrowNotLocked();
        }
        if (jobEscrow.escrowClient(jobId) != msg.sender) revert NotEscrowOwner();

        IJobEscrow.ModelTier tier = jobEscrow.escrowTier(jobId);
        uint64 expiresAt = jobEscrow.escrowExpiresAt(jobId);

        postings[jobId] = JobPosting({
            client: msg.sender,
            tier: tier,
            status: PostingStatus.Open,
            createdAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            assignedWorker: address(0)
        });

        emit JobPosted(jobId, msg.sender, tier, expiresAt);
    }

    /// @notice Worker calls this to atomically reserve an open job. Only
    ///         workers whose declared tiers cover the job's requirement can
    ///         claim it.
    function claimJob(bytes32 jobId) external {
        JobPosting storage posting = postings[jobId];
        if (posting.status != PostingStatus.Open) revert JobNotOpen();
        if (block.timestamp >= posting.expiresAt) revert JobExpired();

        if (!workerRegistry.isActive(msg.sender)) revert WorkerNotActive();

        uint8 tierMask = tierToMask(posting.tier);
        if (!workerRegistry.supportsTier(msg.sender, tierMask)) revert TierNotSupported();

        posting.status = PostingStatus.Assigned;
        posting.assignedWorker = msg.sender;

        emit JobClaimed(jobId, msg.sender);
    }

    /// @notice Client cancels an open posting before it is claimed. Does not
    ///         refund the escrow — the client must call refundEscrow on the
    ///         escrow contract separately once the job times out.
    function cancelPosting(bytes32 jobId) external {
        JobPosting storage posting = postings[jobId];
        if (posting.client != msg.sender) revert Unauthorized();
        if (posting.status != PostingStatus.Open) revert JobNotOpen();

        posting.status = PostingStatus.Cancelled;

        emit JobCancelled(jobId, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @notice Whether a posting is open and has not expired, so worker
    ///         nodes can skip dead jobs without simulating claimJob.
    function isClaimable(bytes32 jobId) external view returns (bool) {
        JobPosting storage posting = postings[jobId];
        return posting.status == PostingStatus.Open && block.timestamp < posting.expiresAt;
    }

    /// @notice Maps a model tier to its worker registry capability bit.
    function tierToMask(IJobEscrow.ModelTier tier) public pure returns (uint8) {
        return uint8(1) << uint8(tier);
    }
}
