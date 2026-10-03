// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Settlement} from "../src/Settlement.sol";
import {JobEscrow} from "../src/JobEscrow.sol";
import {IJobEscrow} from "../src/interfaces/IJobEscrow.sol";
import {Ownable} from "../src/Ownable.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

/// @notice Minimal job board stub exposing only the posting getter Settlement reads.
contract JobRouterStub {
    struct Posting {
        address client;
        uint8 tier;
        uint8 status;
        uint64 createdAt;
        uint64 expiresAt;
        address assignedWorker;
    }

    mapping(bytes32 => Posting) public postings;

    function assign(bytes32 jobId, address worker) external {
        postings[jobId] = Posting(address(0), 0, 2, 0, 0, worker);
    }
}

/// @notice Minimal worker registry stub exposing only what Settlement calls.
contract WorkerRegistryStub {
    struct WorkerState {
        bool registered;
        bool active;
        uint8 tierMask;
    }

    mapping(address => WorkerState) public workerState;

    address public lastCompletionWorker;
    bool public lastCompletionSuccess;
    uint64 public lastCompletionLatencyMs;
    uint256 public completionCount;

    function setWorker(address worker, bool registered, bool active, uint8 tierMask) external {
        workerState[worker] = WorkerState(registered, active, tierMask);
    }

    function isRegistered(address worker) external view returns (bool) {
        return workerState[worker].registered;
    }

    function isActive(address worker) external view returns (bool) {
        return workerState[worker].active;
    }

    function supportsTier(address worker, uint8 tierMask) external view returns (bool) {
        return workerState[worker].tierMask & tierMask != 0;
    }

    function recordCompletion(address worker, bool success, uint64 latencyMs) external {
        lastCompletionWorker = worker;
        lastCompletionSuccess = success;
        lastCompletionLatencyMs = latencyMs;
        completionCount++;
    }
}

/// @notice Minimal staking stub exposing only what Settlement calls.
contract StakingStub {
    mapping(address => bool) public minimumMet;
    uint256 public slashReturn;
    address public lastSlashedWorker;
    uint256 public lastSlashBps;
    uint256 public slashCount;

    function setMeetsMinimum(address account, bool met) external {
        minimumMet[account] = met;
    }

    function setSlashReturn(uint256 value) external {
        slashReturn = value;
    }

    function meetsWorkerMinimum(address account) external view returns (bool) {
        return minimumMet[account];
    }

    function slashWorker(address worker, uint256 bps) external returns (uint256) {
        lastSlashedWorker = worker;
        lastSlashBps = bps;
        slashCount++;
        return slashReturn;
    }
}

/// @notice Tests for the Settlement contract.
///
/// Covers: successful proof submission with immediate payout at both splits
/// (staked 85% and unstaked 75%), dispute opening within the window, dispute
/// rejection after the window closes, hash-match rejection, double-dispute
/// rejection, arbitrator-only resolution, and dishonest-worker slashing.
contract SettlementTest is Test {
    uint64 constant DISPUTE_WINDOW_SECONDS = 60;
    uint64 constant JOB_TIMEOUT_SECONDS = 120;
    uint8 constant TIER_MASK_ALL = 0x0F;

    MockUSDG usdg;
    JobEscrow escrow;
    Settlement settlement;
    WorkerRegistryStub registry;
    StakingStub staking;

    address client = makeAddr("client");
    address worker = makeAddr("worker");
    address stranger = makeAddr("stranger");

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

    function setUp() public {
        usdg = new MockUSDG();
        escrow = new JobEscrow(address(usdg));
        settlement = new Settlement();
        registry = new WorkerRegistryStub();
        staking = new StakingStub();

        escrow.setSettlement(address(settlement));
        settlement.setJobEscrow(address(escrow));
        settlement.setWorkerRegistry(address(registry));
        settlement.setStaking(address(staking));

        registry.setWorker(worker, true, true, TIER_MASK_ALL);

        // Fund the client with 50 USDG worth of credits.
        usdg.mint(client, 50_000_000);
        vm.startPrank(client);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(50_000_000);
        vm.stopPrank();
    }

    function _lockJob(bytes32 jobId, IJobEscrow.ModelTier tier) internal {
        vm.prank(client);
        escrow.lockEscrow(jobId, tier);
    }

    function _submitProof(bytes32 jobId, bytes32 outputHash, uint64 latencyMs) internal {
        vm.prank(worker);
        settlement.submitProof(jobId, outputHash, latencyMs);
    }

    function _settledLiteJob(bytes32 jobId, bytes32 outputHash) internal {
        _lockJob(jobId, IJobEscrow.ModelTier.Lite);
        _submitProof(jobId, outputHash, 350);
    }

    function _proofRecord(bytes32 jobId) internal view returns (Settlement.ProofRecord memory) {
        return settlement.proofRecord(jobId);
    }

    // ------------------------------------------------------------------
    // Proof submission and payout split
    // ------------------------------------------------------------------

    function test_SubmitProofUnstakedSplit() public {
        bytes32 jobId = bytes32(uint256(3));
        bytes32 outputHash = keccak256("output");
        _lockJob(jobId, IJobEscrow.ModelTier.Lite);

        _submitProof(jobId, outputHash, 350);

        // Lite job costs 2 credits = 20,000 USDG units total.
        // Unstaked: worker gets 75% = 15,000, treasury gets 25% = 5,000.
        Settlement.ProofRecord memory record = _proofRecord(jobId);
        assertFalse(record.disputed);
        assertEq(record.worker, worker);
        assertEq(record.outputHash, outputHash);
        assertEq(record.workerPayout, 15_000);
        assertEq(record.treasuryPayout, 5_000);
        assertEq(record.settledAt, uint64(block.timestamp));
        assertEq(record.disputeWindowCloses, uint64(block.timestamp) + DISPUTE_WINDOW_SECONDS);

        // Payout is immediate: worker USDG is out the door before the dispute window runs.
        assertEq(usdg.balanceOf(worker), 15_000);
        assertEq(escrow.treasuryBalance(), 5_000);
        assertEq(uint8(escrow.escrowStatus(jobId)), uint8(IJobEscrow.EscrowStatus.Settled));

        // The registry heard about the successful completion.
        assertEq(registry.lastCompletionWorker(), worker);
        assertTrue(registry.lastCompletionSuccess());
        assertEq(registry.lastCompletionLatencyMs(), 350);
        assertEq(registry.completionCount(), 1);
    }

    function test_SubmitProofStakedSplit() public {
        staking.setMeetsMinimum(worker, true);
        bytes32 jobId = bytes32(uint256(4));
        _lockJob(jobId, IJobEscrow.ModelTier.Lite);

        _submitProof(jobId, keccak256("output"), 250);

        // Staked: worker gets 85% = 17,000, treasury gets 15% = 3,000.
        Settlement.ProofRecord memory record = _proofRecord(jobId);
        assertEq(record.workerPayout, 17_000);
        assertEq(record.treasuryPayout, 3_000);
        assertEq(usdg.balanceOf(worker), 17_000);
        assertEq(escrow.treasuryBalance(), 3_000);
    }

    function test_SubmitProofEmitsJobSettled() public {
        bytes32 jobId = bytes32(uint256(5));
        bytes32 outputHash = keccak256("output");
        _lockJob(jobId, IJobEscrow.ModelTier.Lite);

        vm.expectEmit(true, true, false, true);
        emit JobSettled(jobId, worker, 15_000, 5_000, outputHash, 350, false);
        _submitProof(jobId, outputHash, 350);
    }

    function test_RevertWhen_SubmitProofEscrowNotLocked() public {
        vm.prank(worker);
        vm.expectRevert(Settlement.InvalidEscrowStatus.selector);
        settlement.submitProof(bytes32(uint256(6)), keccak256("output"), 100);
    }

    function test_RevertWhen_SubmitProofJobExpired() public {
        bytes32 jobId = bytes32(uint256(7));
        _lockJob(jobId, IJobEscrow.ModelTier.Lite);

        vm.warp(block.timestamp + JOB_TIMEOUT_SECONDS);
        vm.prank(worker);
        vm.expectRevert(Settlement.JobExpired.selector);
        settlement.submitProof(jobId, keccak256("output"), 100);
    }

    function test_RevertWhen_SubmitProofWorkerNotRegistered() public {
        bytes32 jobId = bytes32(uint256(8));
        _lockJob(jobId, IJobEscrow.ModelTier.Lite);

        vm.prank(stranger);
        vm.expectRevert(Settlement.WorkerNotRegistered.selector);
        settlement.submitProof(jobId, keccak256("output"), 100);
    }

    function test_RevertWhen_SubmitProofWorkerNotActive() public {
        registry.setWorker(worker, true, false, TIER_MASK_ALL);
        bytes32 jobId = bytes32(uint256(9));
        _lockJob(jobId, IJobEscrow.ModelTier.Lite);

        vm.prank(worker);
        vm.expectRevert(Settlement.WorkerNotActive.selector);
        settlement.submitProof(jobId, keccak256("output"), 100);
    }

    function test_RevertWhen_SubmitProofTierNotSupported() public {
        // Worker supports only the Lite tier (mask 0x01); the job is Pro.
        registry.setWorker(worker, true, true, 0x01);
        bytes32 jobId = bytes32(uint256(10));
        _lockJob(jobId, IJobEscrow.ModelTier.Pro);

        vm.prank(worker);
        vm.expectRevert(Settlement.TierNotSupported.selector);
        settlement.submitProof(jobId, keccak256("output"), 100);
    }

    function test_RevertWhen_SubmitProofTwice() public {
        bytes32 jobId = bytes32(uint256(11));
        _settledLiteJob(jobId, keccak256("output"));

        vm.prank(worker);
        vm.expectRevert(Settlement.ProofAlreadySubmitted.selector);
        settlement.submitProof(jobId, keccak256("other"), 100);
    }

    // ------------------------------------------------------------------
    // Disputes
    // ------------------------------------------------------------------

    function test_OpenDisputeWithinWindow() public {
        bytes32 jobId = bytes32(uint256(3));
        bytes32 outputHash = keccak256("output");
        _settledLiteJob(jobId, outputHash);

        bytes32 clientHash = keccak256("client-saw-something-else");
        vm.expectEmit(true, true, false, true);
        emit DisputeOpened(jobId, client, outputHash, clientHash);
        vm.prank(client);
        settlement.openDispute(jobId, clientHash);

        Settlement.ProofRecord memory record = _proofRecord(jobId);
        assertTrue(record.disputed);
        assertEq(record.clientHash, clientHash);
        assertEq(record.disputedBy, client);
    }

    function test_OpenDisputeAtWindowBoundary() public {
        bytes32 jobId = bytes32(uint256(12));
        _settledLiteJob(jobId, keccak256("output"));

        // The window is inclusive of its closing second.
        vm.warp(block.timestamp + DISPUTE_WINDOW_SECONDS);
        vm.prank(client);
        settlement.openDispute(jobId, keccak256("different"));

        assertTrue(_proofRecord(jobId).disputed);
    }

    function test_RevertWhen_SecondDispute() public {
        bytes32 jobId = bytes32(uint256(3));
        _settledLiteJob(jobId, keccak256("output"));

        vm.prank(client);
        settlement.openDispute(jobId, keccak256("first"));

        vm.prank(client);
        vm.expectRevert(Settlement.AlreadyDisputed.selector);
        settlement.openDispute(jobId, keccak256("second"));
    }

    function test_RevertWhen_DisputeHashesMatch() public {
        bytes32 jobId = bytes32(uint256(4));
        bytes32 outputHash = keccak256("output");
        _settledLiteJob(jobId, outputHash);

        vm.prank(client);
        vm.expectRevert(Settlement.HashesMatch.selector);
        settlement.openDispute(jobId, outputHash);
    }

    function test_RevertWhen_DisputeAfterWindowCloses() public {
        bytes32 jobId = bytes32(uint256(13));
        _settledLiteJob(jobId, keccak256("output"));

        vm.warp(block.timestamp + DISPUTE_WINDOW_SECONDS + 1);
        vm.prank(client);
        vm.expectRevert(Settlement.DisputeWindowClosed.selector);
        settlement.openDispute(jobId, keccak256("different"));
    }

    function test_RevertWhen_DisputeByNonClient() public {
        bytes32 jobId = bytes32(uint256(14));
        _settledLiteJob(jobId, keccak256("output"));

        vm.prank(stranger);
        vm.expectRevert(Settlement.NotJobOwner.selector);
        settlement.openDispute(jobId, keccak256("different"));
    }

    function test_RevertWhen_DisputeWithoutProof() public {
        vm.prank(client);
        vm.expectRevert(Settlement.ProofNotFound.selector);
        settlement.openDispute(bytes32(uint256(15)), keccak256("different"));
    }

    // ------------------------------------------------------------------
    // Dispute resolution
    // ------------------------------------------------------------------

    function _disputedJob(bytes32 jobId) internal {
        _settledLiteJob(jobId, keccak256("output"));
        vm.prank(client);
        settlement.openDispute(jobId, keccak256("different"));
    }

    function test_ResolveDisputeHonestWorker() public {
        bytes32 jobId = bytes32(uint256(20));
        _disputedJob(jobId);

        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(jobId, false, 0);
        vm.prank(settlement.arbitrator());
        settlement.resolveDispute(jobId, false);

        // Honest verdict: no slash. Payout already happened at submission time.
        assertEq(staking.slashCount(), 0);
        assertTrue(_proofRecord(jobId).resolved);
        assertEq(usdg.balanceOf(worker), 15_000);
    }

    function test_ResolveDisputeDishonestWorkerSlashes() public {
        bytes32 jobId = bytes32(uint256(21));
        _disputedJob(jobId);
        staking.setSlashReturn(50e18);

        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(jobId, true, 50e18);
        vm.prank(settlement.arbitrator());
        settlement.resolveDispute(jobId, true);

        // Dishonest verdict: 5% (500 bps) of the worker's stake is slashed.
        assertEq(staking.slashCount(), 1);
        assertEq(staking.lastSlashedWorker(), worker);
        assertEq(staking.lastSlashBps(), 500);
    }

    function test_RevertWhen_ResolveByNonArbitrator() public {
        bytes32 jobId = bytes32(uint256(22));
        _disputedJob(jobId);

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        settlement.resolveDispute(jobId, true);
    }

    function test_RevertWhen_ResolveUndisputedJob() public {
        bytes32 jobId = bytes32(uint256(23));
        _settledLiteJob(jobId, keccak256("output"));

        vm.prank(settlement.arbitrator());
        vm.expectRevert(Settlement.NotDisputed.selector);
        settlement.resolveDispute(jobId, true);
    }

    function test_RevertWhen_ResolveTwice() public {
        bytes32 jobId = bytes32(uint256(24));
        _disputedJob(jobId);

        vm.prank(settlement.arbitrator());
        settlement.resolveDispute(jobId, true);

        vm.prank(settlement.arbitrator());
        vm.expectRevert(Settlement.AlreadyResolved.selector);
        settlement.resolveDispute(jobId, false);
    }

    // ------------------------------------------------------------------
    // Admin wiring
    // ------------------------------------------------------------------

    function test_RevertWhen_SettersCalledByNonOwner() public {
        vm.startPrank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        settlement.setJobEscrow(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        settlement.setWorkerRegistry(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        settlement.setStaking(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        settlement.setJobRouter(stranger);
        vm.stopPrank();
    }

    function test_RevertWhen_SettersGivenZeroAddress() public {
        vm.expectRevert(Ownable.ZeroAddress.selector);
        settlement.setJobEscrow(address(0));
        vm.expectRevert(Ownable.ZeroAddress.selector);
        settlement.setWorkerRegistry(address(0));
        vm.expectRevert(Ownable.ZeroAddress.selector);
        settlement.setStaking(address(0));

        // The wiring set in setUp survives the rejected calls.
        assertEq(address(settlement.jobEscrow()), address(escrow));
        assertEq(address(settlement.workerRegistry()), address(registry));
        assertEq(address(settlement.staking()), address(staking));
    }

    function test_OwnershipHandoverMovesAdminRights() public {
        address multisig = makeAddr("multisig");

        settlement.transferOwnership(multisig);
        vm.prank(multisig);
        settlement.acceptOwnership();

        assertEq(settlement.owner(), multisig);

        vm.prank(multisig);
        settlement.setArbitrator(multisig);
        assertEq(settlement.arbitrator(), multisig);

        vm.expectRevert(Ownable.Unauthorized.selector);
        settlement.setArbitrator(address(this));
    }

    // ------------------------------------------------------------------
    // Router assignment
    // ------------------------------------------------------------------

    function test_AssignedWorkerCanSettle() public {
        JobRouterStub router = new JobRouterStub();
        settlement.setJobRouter(address(router));

        bytes32 jobId = bytes32(uint256(30));
        _lockJob(jobId, IJobEscrow.ModelTier.Lite);
        router.assign(jobId, worker);

        _submitProof(jobId, keccak256("output"), 350);

        assertEq(_proofRecord(jobId).worker, worker);
    }

    function test_RevertWhen_SettlingAJobAssignedToAnotherWorker() public {
        JobRouterStub router = new JobRouterStub();
        settlement.setJobRouter(address(router));

        address poacher = makeAddr("poacher");
        registry.setWorker(poacher, true, true, TIER_MASK_ALL);

        bytes32 jobId = bytes32(uint256(31));
        _lockJob(jobId, IJobEscrow.ModelTier.Lite);
        router.assign(jobId, worker);

        vm.prank(poacher);
        vm.expectRevert(Settlement.NotAssignedWorker.selector);
        settlement.submitProof(jobId, keccak256("output"), 350);

        assertEq(usdg.balanceOf(poacher), 0);
    }

    function test_UnpostedJobsSettleWithoutAnAssignment() public {
        JobRouterStub router = new JobRouterStub();
        settlement.setJobRouter(address(router));

        // No posting for this job: it was dispatched off-chain, so any
        // qualified worker may still settle it.
        bytes32 jobId = bytes32(uint256(32));
        _settledLiteJob(jobId, keccak256("output"));

        assertEq(_proofRecord(jobId).worker, worker);
    }

    function test_DisputeWindowOpenUntilItClosesOrIsUsed() public {
        bytes32 jobId = bytes32(uint256(40));
        assertFalse(settlement.isDisputeWindowOpen(jobId));

        _settledLiteJob(jobId, keccak256("output"));
        assertTrue(settlement.isDisputeWindowOpen(jobId));

        vm.prank(client);
        settlement.openDispute(jobId, keccak256("client"));
        assertFalse(settlement.isDisputeWindowOpen(jobId));
    }

    function test_DisputeWindowClosesAfterTimeout() public {
        bytes32 jobId = bytes32(uint256(41));
        _settledLiteJob(jobId, keccak256("output"));

        vm.warp(block.timestamp + DISPUTE_WINDOW_SECONDS + 1);
        assertFalse(settlement.isDisputeWindowOpen(jobId));
    }
}
