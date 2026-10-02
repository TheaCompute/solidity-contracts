// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * Tests for the WorkerRegistry contract.
 *
 * Covers: worker registration, tier updates, active/offline toggle,
 * reputation EMA updates on completion and failure, slash execution,
 * authorization gates, and all error paths.
 */
import {Test} from "forge-std/Test.sol";
import {WorkerRegistry} from "../src/WorkerRegistry.sol";
import {Ownable} from "../src/Ownable.sol";

contract WorkerRegistryTest is Test {
    WorkerRegistry internal registry;

    address internal settlement = makeAddr("settlement");
    address internal stakingContract = makeAddr("stakingContract");
    address internal workerNode = makeAddr("workerNode");
    address internal stranger = makeAddr("stranger");

    uint8 internal constant TIER_LITE = 0x01;
    uint8 internal constant TIER_STANDARD = 0x02;
    uint8 internal constant TIER_PRO = 0x04;
    uint8 internal constant TIER_MAX = 0x08;

    uint32 internal constant REPUTATION_STARTING = 500;

    event WorkerHeartbeat(address indexed worker, uint64 seenAt);
    event CompletionRecorded(address indexed worker, bool success, uint64 latencyMs, uint32 newReputation);

    function setUp() public {
        registry = new WorkerRegistry();
        registry.setSettlement(settlement);
        registry.setStaking(stakingContract);
    }

    function _registerDefaultWorker() internal {
        vm.prank(workerNode);
        registry.registerWorker(TIER_LITE | TIER_STANDARD, "RTX-4090");
    }

    function test_RegistersNewWorkerNode() public {
        _registerDefaultWorker();

        (
            bool registered,
            bool active,
            uint8 tierMask,
            uint32 reputationScore,
            uint64 jobsCompleted,
            uint64 jobsFailed,
            uint64 registeredAt,
            uint64 lastSeenAt,
            string memory gpuModel
        ) = registry.workers(workerNode);

        assertTrue(registered);
        assertTrue(active);
        assertEq(tierMask, TIER_LITE | TIER_STANDARD);
        assertEq(reputationScore, REPUTATION_STARTING);
        assertEq(jobsCompleted, 0);
        assertEq(jobsFailed, 0);
        assertEq(registeredAt, uint64(block.timestamp));
        assertEq(lastSeenAt, uint64(block.timestamp));
        assertEq(gpuModel, "RTX-4090");

        assertTrue(registry.isRegistered(workerNode));
        assertTrue(registry.isActive(workerNode));
        assertEq(registry.reputation(workerNode), REPUTATION_STARTING);
    }

    function test_UpdatesSupportedTiers() public {
        _registerDefaultWorker();

        vm.prank(workerNode);
        registry.updateWorker(TIER_LITE | TIER_STANDARD | TIER_PRO, "RTX-4090", true);

        (,, uint8 tierMask,,,,,,) = registry.workers(workerNode);
        assertEq(tierMask, TIER_LITE | TIER_STANDARD | TIER_PRO);
        assertTrue(registry.supportsTier(workerNode, TIER_PRO));
        assertFalse(registry.supportsTier(workerNode, TIER_MAX));
    }

    function test_SetsWorkerOfflineAndBackOnline() public {
        _registerDefaultWorker();

        vm.prank(workerNode);
        registry.updateWorker(TIER_LITE | TIER_STANDARD, "RTX-4090", false);
        assertFalse(registry.isActive(workerNode));

        vm.prank(workerNode);
        registry.updateWorker(TIER_LITE | TIER_STANDARD, "RTX-4090", true);
        assertTrue(registry.isActive(workerNode));
    }

    function test_RecordsCompletionAndUpdatesReputation() public {
        _registerDefaultWorker();

        // Under 500ms scores perfectly on latency.
        vm.prank(settlement);
        registry.recordCompletion(workerNode, true, 300);

        (,,,, uint64 jobsCompleted, uint64 jobsFailed,,,) = registry.workers(workerNode);
        assertEq(jobsCompleted, 1);
        assertEq(jobsFailed, 0);

        // At 300ms latency and valid proof:
        // jobScore = (1000*35 + 1000*30 + 1000*25 + 1000*10) / 100 = 1000
        // newScore = (500 * 90 + 1000 * 10) / 100 = (45000 + 10000) / 100 = 550
        assertEq(registry.reputation(workerNode), 550, "reputation should increase after perfect job");
    }

    function test_SlowLatencyDegradesJobScore() public {
        _registerDefaultWorker();

        // 2750ms is exactly halfway through the 500..5000ms band: latencyScore = 500.
        // jobScore = (1000*35 + 500*30 + 1000*25 + 1000*10) / 100 = 850
        // newScore = (500 * 90 + 850 * 10) / 100 = 535
        vm.prank(settlement);
        registry.recordCompletion(workerNode, true, 2750);
        assertEq(registry.reputation(workerNode), 535);
    }

    function test_RecordsFailureAndDecreasesReputation() public {
        _registerDefaultWorker();

        vm.prank(settlement);
        registry.recordCompletion(workerNode, true, 300);
        uint32 before = registry.reputation(workerNode);
        assertEq(before, 550);

        vm.prank(settlement);
        registry.recordCompletion(workerNode, false, 0);

        (,,,, uint64 jobsCompleted, uint64 jobsFailed,,,) = registry.workers(workerNode);
        assertEq(jobsCompleted, 1);
        assertEq(jobsFailed, 1);

        // EMA with a zero job score: 550 * 90 / 100 = 495.
        uint32 afterScore = registry.reputation(workerNode);
        assertEq(afterScore, 495);
        assertLt(afterScore, before, "reputation should drop after failure");
    }

    function test_AppliesSlashAndReducesReputation() public {
        _registerDefaultWorker();

        vm.prank(settlement);
        registry.recordCompletion(workerNode, true, 300);
        uint32 before = registry.reputation(workerNode);
        assertEq(before, 550);

        vm.prank(stakingContract);
        registry.applySlash(workerNode);

        // Reputation drops by 20% on slash: new = old * 80 / 100.
        assertEq(registry.reputation(workerNode), (before * 80) / 100);
    }

    function test_RejectsRegistrationWithNoTiers() public {
        vm.prank(stranger);
        vm.expectRevert(WorkerRegistry.NoTiersDeclared.selector);
        registry.registerWorker(0, "RTX-4090");
    }

    function test_RejectsInvalidTierMaskOnRegistration() public {
        // Bit 5 is beyond the four valid tiers.
        vm.prank(stranger);
        vm.expectRevert(WorkerRegistry.InvalidTierMask.selector);
        registry.registerWorker(0x11, "RTX-4090");
    }

    function test_RejectsInvalidTierMaskOnUpdate() public {
        _registerDefaultWorker();

        vm.prank(workerNode);
        vm.expectRevert(WorkerRegistry.InvalidTierMask.selector);
        registry.updateWorker(0x11, "RTX-4090", true);
    }

    function test_RejectsDuplicateRegistration() public {
        _registerDefaultWorker();

        vm.prank(workerNode);
        vm.expectRevert(WorkerRegistry.AlreadyRegistered.selector);
        registry.registerWorker(TIER_LITE, "RTX-4090");
    }

    function test_RejectsUpdateWhenNotRegistered() public {
        vm.prank(stranger);
        vm.expectRevert(WorkerRegistry.NotRegistered.selector);
        registry.updateWorker(TIER_LITE, "RTX-4090", true);
    }

    function test_RecordCompletionOnlySettlement() public {
        _registerDefaultWorker();

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.recordCompletion(workerNode, true, 300);
    }

    function test_RecordCompletionRequiresRegisteredWorker() public {
        vm.prank(settlement);
        vm.expectRevert(WorkerRegistry.NotRegistered.selector);
        registry.recordCompletion(stranger, true, 300);
    }

    function test_ApplySlashOnlyStaking() public {
        _registerDefaultWorker();

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.applySlash(workerNode);

        vm.prank(settlement);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.applySlash(workerNode);
    }

    function test_ApplySlashRequiresRegisteredWorker() public {
        vm.prank(stakingContract);
        vm.expectRevert(WorkerRegistry.NotRegistered.selector);
        registry.applySlash(stranger);
    }

    function test_WiringSettersOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setSettlement(stranger);

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.setStaking(stranger);
    }

    // ------------------------------------------------------------------
    // Liveness
    // ------------------------------------------------------------------

    function test_HeartbeatUpdatesLastSeen() public {
        _registerDefaultWorker();

        vm.warp(block.timestamp + 1 hours);

        vm.expectEmit(true, false, false, true);
        emit WorkerHeartbeat(workerNode, uint64(block.timestamp));
        vm.prank(workerNode);
        registry.heartbeat();

        (,,,,,,, uint64 lastSeenAt,) = registry.workers(workerNode);
        assertEq(lastSeenAt, uint64(block.timestamp));
    }

    function test_RevertWhen_HeartbeatFromUnregisteredWorker() public {
        vm.prank(stranger);
        vm.expectRevert(WorkerRegistry.NotRegistered.selector);
        registry.heartbeat();
    }

    function test_FailedJobStillUpdatesLastSeen() public {
        _registerDefaultWorker();
        uint64 registeredAt = uint64(block.timestamp);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(settlement);
        registry.recordCompletion(workerNode, false, 0);

        (,,,,,,, uint64 lastSeenAt,) = registry.workers(workerNode);
        assertEq(lastSeenAt, uint64(block.timestamp));
        assertGt(lastSeenAt, registeredAt);
    }

    function test_RecordCompletionEmitsTheOutcome() public {
        _registerDefaultWorker();

        // 500 starting reputation, EMA blends in a 1000-ish job score at 10%.
        vm.expectEmit(true, false, false, true);
        emit CompletionRecorded(workerNode, true, 300, 550);
        vm.prank(settlement);
        registry.recordCompletion(workerNode, true, 300);

        vm.expectEmit(true, false, false, true);
        emit CompletionRecorded(workerNode, false, 0, 495);
        vm.prank(settlement);
        registry.recordCompletion(workerNode, false, 0);
    }

    function test_RejectsGpuModelOverMaximumLength() public {
        string memory tooLong = string(new bytes(registry.GPU_MODEL_MAX() + 1));

        vm.prank(workerNode);
        vm.expectRevert(WorkerRegistry.GpuModelTooLong.selector);
        registry.registerWorker(TIER_LITE, tooLong);
    }

    function test_RejectsGpuModelOverMaximumLengthOnUpdate() public {
        _registerDefaultWorker();
        string memory tooLong = string(new bytes(registry.GPU_MODEL_MAX() + 1));

        vm.prank(workerNode);
        vm.expectRevert(WorkerRegistry.GpuModelTooLong.selector);
        registry.updateWorker(TIER_LITE, tooLong, true);
    }
}
