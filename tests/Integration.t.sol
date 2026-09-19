// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {TheaComputeToken} from "../src/TheaComputeToken.sol";
import {WorkerRegistry} from "../src/WorkerRegistry.sol";
import {Staking} from "../src/Staking.sol";
import {JobEscrow} from "../src/JobEscrow.sol";
import {Settlement} from "../src/Settlement.sol";
import {JobRouter} from "../src/JobRouter.sol";
import {IJobEscrow} from "../src/interfaces/IJobEscrow.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

/// @notice End-to-end integration covering the full happy path and the dispute path.
///
/// Happy path:   register worker → deposit credits → lock escrow → post job →
///               claim job → submit proof → worker receives USDG → reputation updated
///
/// Dispute path: same up to submitProof → client opens dispute →
///               arbitrator resolves dishonest → worker stake slashed, registry synced
contract IntegrationTest is Test {
    uint8 internal constant TIER_STANDARD = 0x02;
    uint256 internal constant USDG_PER_CREDIT = 10_000;

    MockUSDG internal usdg;
    TheaComputeToken internal thea;
    WorkerRegistry internal registry;
    Staking internal staking;
    JobEscrow internal escrow;
    Settlement internal settlement;
    JobRouter internal router;

    address internal client = makeAddr("client");
    address internal workerOwner = makeAddr("workerOwner");

    function setUp() public {
        usdg = new MockUSDG();
        thea = new TheaComputeToken(address(this));
        registry = new WorkerRegistry();
        staking = new Staking(address(thea), address(usdg));
        escrow = new JobEscrow(address(usdg));
        settlement = new Settlement();
        router = new JobRouter();

        // Wire the mesh.
        registry.setSettlement(address(settlement));
        registry.setStaking(address(staking));
        staking.setSettlement(address(settlement));
        staking.setWorkerRegistry(address(registry));
        escrow.setSettlement(address(settlement));
        settlement.setJobEscrow(address(escrow));
        settlement.setWorkerRegistry(address(registry));
        settlement.setStaking(address(staking));
        router.setJobEscrow(address(escrow));
        router.setWorkerRegistry(address(registry));

        // Fund participants.
        usdg.mint(client, 100_000e6);
        thea.transfer(workerOwner, 5_000e18);

        // Worker: register, stake 2,000 $THEA for 90 days, link.
        vm.startPrank(workerOwner);
        registry.registerWorker(TIER_STANDARD, "nvidia-rtx-4090");
        thea.approve(address(staking), type(uint256).max);
        staking.stake(2_000e18, 90);
        staking.linkWorker(workerOwner);
        vm.stopPrank();

        // Client: deposit 100 USDG → 10,000 credits.
        vm.startPrank(client);
        usdg.approve(address(escrow), type(uint256).max);
        escrow.deposit(100e6);
        vm.stopPrank();
        assertEq(escrow.creditBalance(client), 10_000);
    }

    // -----------------------------------------------------------------
    // Happy path
    // -----------------------------------------------------------------

    function test_happyPath_lockPostClaimProvePayout() public {
        bytes32 jobId = keccak256("integration-happy-job");

        // Client locks escrow (Standard = 8 credits) and posts the job.
        vm.startPrank(client);
        escrow.lockEscrow(jobId, IJobEscrow.ModelTier.Standard);
        router.postJob(jobId);
        vm.stopPrank();
        assertEq(uint8(escrow.escrowStatus(jobId)), uint8(IJobEscrow.EscrowStatus.Locked));
        assertEq(escrow.creditBalance(client), 10_000 - 8);

        // Worker claims the job.
        vm.prank(workerOwner);
        router.claimJob(jobId);
        (,, JobRouter.PostingStatus status,,, address assigned) = router.postings(jobId);
        assertEq(uint8(status), uint8(JobRouter.PostingStatus.Assigned));
        assertEq(assigned, workerOwner);

        // Worker submits proof and is paid immediately (staked → 85% split).
        uint256 workerBefore = usdg.balanceOf(workerOwner);
        uint32 repBefore = registry.reputation(workerOwner);
        (,,,, uint64 completedBefore,,,,) = registry.workers(workerOwner);

        vm.prank(workerOwner);
        settlement.submitProof(jobId, keccak256("output"), 350);

        uint256 jobValue = 8 * USDG_PER_CREDIT; // 80,000 units = $0.08
        assertEq(usdg.balanceOf(workerOwner) - workerBefore, jobValue * 8_500 / 10_000);
        assertEq(escrow.treasuryBalance(), jobValue * 1_500 / 10_000);
        assertEq(uint8(escrow.escrowStatus(jobId)), uint8(IJobEscrow.EscrowStatus.Settled));

        (,,,, uint64 completedAfter,,,,) = registry.workers(workerOwner);
        assertEq(completedAfter, completedBefore + 1);
        assertGt(registry.reputation(workerOwner), repBefore);
    }

    // -----------------------------------------------------------------
    // Dispute path
    // -----------------------------------------------------------------

    function test_disputePath_dishonestWorkerSlashed() public {
        bytes32 jobId = keccak256("integration-dispute-job");

        vm.prank(client);
        escrow.lockEscrow(jobId, IJobEscrow.ModelTier.Standard);

        vm.prank(workerOwner);
        settlement.submitProof(jobId, keccak256("worker-output"), 400);

        // Client opens a dispute with a mismatching hash inside the window.
        vm.prank(client);
        settlement.openDispute(jobId, keccak256("client-output"));
        Settlement.ProofRecord memory record = settlement.proofRecord(jobId);
        assertTrue(record.disputed);

        // Arbitrator resolves dishonest: 5% of stake burned, reputation cut.
        uint256 stakeBefore = staking.stakedAmount(workerOwner);
        uint32 repBefore = registry.reputation(workerOwner);

        vm.prank(settlement.arbitrator());
        settlement.resolveDispute(jobId, true);

        assertEq(staking.stakedAmount(workerOwner), stakeBefore - stakeBefore / 20);
        assertLt(registry.reputation(workerOwner), repBefore);
    }

}
