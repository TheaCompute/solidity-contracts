// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {JobRouter} from "../src/JobRouter.sol";
import {Ownable} from "../src/Ownable.sol";
import {IJobEscrow} from "../src/interfaces/IJobEscrow.sol";
import {IWorkerRegistry} from "../src/interfaces/IWorkerRegistry.sol";

/// @dev Minimal escrow mock: just enough IJobEscrow surface for the router
///      to read status, client, credits, tier, and expiry.
contract MockJobEscrow is IJobEscrow {
    /// @dev Mirrors JobEscrow.JOB_TIMEOUT_SECONDS for expiry bookkeeping.
    uint64 public constant JOB_TIMEOUT_SECONDS = 120;

    struct Escrow {
        address client;
        uint256 credits;
        ModelTier tier;
        uint64 lockedAt;
        EscrowStatus status;
    }

    mapping(bytes32 => Escrow) internal escrows;

    function lockEscrow(bytes32 jobId, address client, ModelTier tier) external {
        uint256 credits;
        if (tier == ModelTier.Lite) credits = 2;
        else if (tier == ModelTier.Standard) credits = 8;
        else if (tier == ModelTier.Pro) credits = 18;
        else credits = 40;

        escrows[jobId] = Escrow({
            client: client,
            credits: credits,
            tier: tier,
            lockedAt: uint64(block.timestamp),
            status: EscrowStatus.Locked
        });
    }

    function setStatus(bytes32 jobId, EscrowStatus status) external {
        escrows[jobId].status = status;
    }

    function creditBalance(address) external pure returns (uint256) {
        return 0;
    }

    function escrowStatus(bytes32 jobId) external view returns (EscrowStatus) {
        return escrows[jobId].status;
    }

    function escrowClient(bytes32 jobId) external view returns (address) {
        return escrows[jobId].client;
    }

    function escrowCredits(bytes32 jobId) external view returns (uint256) {
        return escrows[jobId].credits;
    }

    function escrowLockedAt(bytes32 jobId) external view returns (uint64) {
        return escrows[jobId].lockedAt;
    }

    function escrowTier(bytes32 jobId) external view returns (ModelTier) {
        return escrows[jobId].tier;
    }

    function escrowExpiresAt(bytes32 jobId) external view returns (uint64) {
        return escrows[jobId].lockedAt + JOB_TIMEOUT_SECONDS;
    }

    function settleEscrow(bytes32, address, uint256) external {}

    function refundEscrow(bytes32) external {}
}

/// @dev Minimal worker registry mock exposing the activity and tier checks
///      the router relies on.
contract MockWorkerRegistry is IWorkerRegistry {
    struct Worker {
        bool registered;
        bool active;
        uint8 tierMask;
    }

    mapping(address => Worker) internal workers;

    function setWorker(address worker, bool active, uint8 tierMask) external {
        workers[worker] = Worker({registered: true, active: active, tierMask: tierMask});
    }

    function registerWorker(uint8 tierMask, string calldata) external {
        workers[msg.sender] = Worker({registered: true, active: true, tierMask: tierMask});
    }

    function updateWorker(uint8 tierMask, string calldata, bool active) external {
        workers[msg.sender].tierMask = tierMask;
        workers[msg.sender].active = active;
    }

    function recordCompletion(address, bool, uint64) external {}

    function applySlash(address) external {}

    function isRegistered(address worker) external view returns (bool) {
        return workers[worker].registered;
    }

    function isActive(address worker) external view returns (bool) {
        return workers[worker].active;
    }

    function supportsTier(address worker, uint8 tierMask) external view returns (bool) {
        return (workers[worker].tierMask & tierMask) == tierMask;
    }

    function reputation(address) external pure returns (uint32) {
        return 500;
    }
}

contract JobRouterTest is Test {
    JobRouter internal router;
    MockJobEscrow internal escrow;
    MockWorkerRegistry internal registry;

    address internal client;
    address internal workerOwner;

    uint8 internal constant TIER_LITE = 0x01;
    uint8 internal constant TIER_STANDARD = 0x02;

    event JobPosted(
        bytes32 indexed jobId,
        address indexed client,
        IJobEscrow.ModelTier tier,
        uint64 expiresAt
    );
    event JobClaimed(bytes32 indexed jobId, address indexed worker);
    event JobCancelled(bytes32 indexed jobId, address indexed client);

    function setUp() public {
        client = makeAddr("client");
        workerOwner = makeAddr("workerOwner");

        router = new JobRouter();
        escrow = new MockJobEscrow();
        registry = new MockWorkerRegistry();

        router.setJobEscrow(address(escrow));
        router.setWorkerRegistry(address(registry));

        registry.setWorker(workerOwner, true, TIER_STANDARD);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _lockAndPost(bytes32 jobId) internal {
        escrow.lockEscrow(jobId, client, IJobEscrow.ModelTier.Standard);
        vm.prank(client);
        router.postJob(jobId);
    }

    function _posting(bytes32 jobId) internal view returns (JobRouter.JobPosting memory p) {
        (
            p.client,
            p.tier,
            p.status,
            p.createdAt,
            p.expiresAt,
            p.assignedWorker
        ) = router.postings(jobId);
    }

    // ---------------------------------------------------------------------
    // postJob
    // ---------------------------------------------------------------------

    function test_postJob_afterEscrowLocked() public {
        bytes32 jobId = keccak256("job-post-1");
        escrow.lockEscrow(jobId, client, IJobEscrow.ModelTier.Standard);

        uint64 expectedExpiry = uint64(block.timestamp) + escrow.JOB_TIMEOUT_SECONDS();

        vm.expectEmit(true, true, false, true);
        emit JobPosted(jobId, client, IJobEscrow.ModelTier.Standard, expectedExpiry);

        vm.prank(client);
        router.postJob(jobId);

        JobRouter.JobPosting memory posting = _posting(jobId);
        assertEq(posting.client, client);
        assertTrue(posting.status == JobRouter.PostingStatus.Open);
        assertTrue(posting.tier == IJobEscrow.ModelTier.Standard);
        assertEq(posting.assignedWorker, address(0));
        assertEq(posting.createdAt, uint64(block.timestamp));
        assertEq(posting.expiresAt, expectedExpiry);
    }

    function test_postJob_readsTierFromEscrow() public {
        bytes32 jobId = keccak256("job-post-max");
        escrow.lockEscrow(jobId, client, IJobEscrow.ModelTier.Max);

        vm.prank(client);
        router.postJob(jobId);

        JobRouter.JobPosting memory posting = _posting(jobId);
        assertTrue(posting.tier == IJobEscrow.ModelTier.Max);
    }

    function test_postJob_revertsWhenNotEscrowOwner() public {
        bytes32 jobId = keccak256("job-post-2");
        escrow.lockEscrow(jobId, client, IJobEscrow.ModelTier.Standard);

        address imposter = makeAddr("imposter");
        vm.prank(imposter);
        vm.expectRevert(JobRouter.NotEscrowOwner.selector);
        router.postJob(jobId);
    }

    function test_postJob_revertsWhenEscrowNotLocked() public {
        bytes32 jobId = keccak256("job-post-3");

        vm.prank(client);
        vm.expectRevert(JobRouter.EscrowNotLocked.selector);
        router.postJob(jobId);
    }

    function test_postJob_revertsWhenEscrowAlreadySettled() public {
        bytes32 jobId = keccak256("job-post-4");
        escrow.lockEscrow(jobId, client, IJobEscrow.ModelTier.Standard);
        escrow.setStatus(jobId, IJobEscrow.EscrowStatus.Settled);

        vm.prank(client);
        vm.expectRevert(JobRouter.EscrowNotLocked.selector);
        router.postJob(jobId);
    }

    function test_postJob_revertsWhenAlreadyPosted() public {
        bytes32 jobId = keccak256("job-post-5");
        _lockAndPost(jobId);

        vm.prank(client);
        vm.expectRevert(JobRouter.PostingAlreadyExists.selector);
        router.postJob(jobId);
    }

    // ---------------------------------------------------------------------
    // claimJob
    // ---------------------------------------------------------------------

    function test_claimJob_allowsQualifiedWorker() public {
        bytes32 jobId = keccak256("job-claim-1");
        _lockAndPost(jobId);

        vm.expectEmit(true, true, false, true);
        emit JobClaimed(jobId, workerOwner);

        vm.prank(workerOwner);
        router.claimJob(jobId);

        JobRouter.JobPosting memory posting = _posting(jobId);
        assertTrue(posting.status == JobRouter.PostingStatus.Assigned);
        assertEq(posting.assignedWorker, workerOwner);
    }

    function test_claimJob_rejectsAlreadyAssignedJob() public {
        bytes32 jobId = keccak256("job-claim-2");
        _lockAndPost(jobId);

        vm.prank(workerOwner);
        router.claimJob(jobId);

        address lateWorker = makeAddr("lateWorker");
        registry.setWorker(lateWorker, true, TIER_STANDARD);

        vm.prank(lateWorker);
        vm.expectRevert(JobRouter.JobNotOpen.selector);
        router.claimJob(jobId);
    }

    function test_claimJob_rejectsUnpostedJob() public {
        bytes32 jobId = keccak256("job-claim-3");

        vm.prank(workerOwner);
        vm.expectRevert(JobRouter.JobNotOpen.selector);
        router.claimJob(jobId);
    }

    function test_claimJob_rejectsExpiredJob() public {
        bytes32 jobId = keccak256("job-claim-4");
        _lockAndPost(jobId);

        vm.warp(block.timestamp + escrow.JOB_TIMEOUT_SECONDS());

        vm.prank(workerOwner);
        vm.expectRevert(JobRouter.JobExpired.selector);
        router.claimJob(jobId);
    }

    function test_claimJob_rejectsInactiveWorker() public {
        bytes32 jobId = keccak256("job-claim-5");
        _lockAndPost(jobId);

        address dormantWorker = makeAddr("dormantWorker");
        registry.setWorker(dormantWorker, false, TIER_STANDARD);

        vm.prank(dormantWorker);
        vm.expectRevert(JobRouter.WorkerNotActive.selector);
        router.claimJob(jobId);
    }

    function test_claimJob_rejectsUnsupportedTier() public {
        bytes32 jobId = keccak256("job-claim-6");
        _lockAndPost(jobId); // Standard tier job

        address liteWorker = makeAddr("liteWorker");
        registry.setWorker(liteWorker, true, TIER_LITE);

        vm.prank(liteWorker);
        vm.expectRevert(JobRouter.TierNotSupported.selector);
        router.claimJob(jobId);
    }

    // ---------------------------------------------------------------------
    // cancelPosting
    // ---------------------------------------------------------------------

    function test_cancelPosting_allowsClientToCancelOpenPosting() public {
        bytes32 jobId = keccak256("job-cancel-1");
        _lockAndPost(jobId);

        vm.expectEmit(true, true, false, true);
        emit JobCancelled(jobId, client);

        vm.prank(client);
        router.cancelPosting(jobId);

        JobRouter.JobPosting memory posting = _posting(jobId);
        assertTrue(posting.status == JobRouter.PostingStatus.Cancelled);
    }

    function test_cancelPosting_rejectsNonOwner() public {
        bytes32 jobId = keccak256("job-cancel-2");
        _lockAndPost(jobId);

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        router.cancelPosting(jobId);
    }

    function test_cancelPosting_rejectsAssignedJob() public {
        bytes32 jobId = keccak256("job-cancel-3");
        _lockAndPost(jobId);

        vm.prank(workerOwner);
        router.claimJob(jobId);

        vm.prank(client);
        vm.expectRevert(JobRouter.JobNotOpen.selector);
        router.cancelPosting(jobId);
    }

    // ---------------------------------------------------------------------
    // Admin wiring
    // ---------------------------------------------------------------------

    function test_setJobEscrow_rejectsNonOwner() public {
        address stranger = makeAddr("stranger2");
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        router.setJobEscrow(address(escrow));
    }

    function test_setWorkerRegistry_rejectsNonOwner() public {
        address stranger = makeAddr("stranger3");
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        router.setWorkerRegistry(address(registry));
    }
}
