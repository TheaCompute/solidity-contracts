// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {MockUSDG} from "../tests/mocks/MockUSDG.sol";
import {TheaComputeToken} from "../src/TheaComputeToken.sol";
import {WorkerRegistry} from "../src/WorkerRegistry.sol";
import {Staking} from "../src/Staking.sol";
import {JobEscrow} from "../src/JobEscrow.sol";
import {Settlement} from "../src/Settlement.sol";
import {Governance} from "../src/Governance.sol";
import {JobRouter} from "../src/JobRouter.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {IJobEscrow} from "../src/interfaces/IJobEscrow.sol";

/// @notice Second seeding pass: exactly 20 transactions exercising the parts
///         of the protocol the first pass (Seed15) did not touch — governance,
///         reward epochs, the dispute/slashing path, and credit withdrawal.
///
///           1  TheaComputeToken.approve      allow Staking to pull more $THEA
///           2  Staking.stake               +5,000 $THEA (weighted stake now 12,500)
///           3  Governance.createProposal   parameter-change proposal #0
///           4  Governance.castVote         Yes on proposal #0
///           5  MockUSDG.approve            allow RewardDistributor to pull USDG
///           6  RewardDistributor.startEpoch  epoch 1 funded with 50 USDG
///           7  RewardDistributor.claimReward epoch 1 payout to the staker
///           8  JobEscrow.lockEscrow        job #3 (Pro tier)
///           9  JobRouter.postJob           job #3
///          10  JobRouter.claimJob          job #3
///          11  Settlement.submitProof      job #3 settles cleanly
///          12  JobEscrow.lockEscrow        job #4 (Standard tier)
///          13  JobRouter.postJob           job #4
///          14  JobRouter.claimJob          job #4
///          15  Settlement.submitProof      job #4 settles, dispute window opens
///          16  Settlement.openDispute      client contests job #4's output hash
///          17  Settlement.resolveDispute   worker found dishonest, 5% stake slashed
///          18  ModelRegistry.registerModel mistral-small-24b-instruct
///          19  JobEscrow.withdraw          redeem 500 credits back to USDG
///          20  WorkerRegistry.updateWorker heartbeat refreshing lastSeenAt
///
///         Required env vars: USDG_ADDRESS, THEACOMPUTE_ADDRESS, WORKER_REGISTRY,
///         STAKING, JOB_ESCROW, SETTLEMENT, GOVERNANCE, JOB_ROUTER,
///         MODEL_REGISTRY, REWARD_DISTRIBUTOR.
contract Seed20 is Script {
    function run() external {
        MockUSDG usdg = MockUSDG(vm.envAddress("USDG_ADDRESS"));
        TheaComputeToken thea = TheaComputeToken(vm.envAddress("THEACOMPUTE_ADDRESS"));
        WorkerRegistry workerRegistry = WorkerRegistry(vm.envAddress("WORKER_REGISTRY"));
        Staking staking = Staking(vm.envAddress("STAKING"));
        JobEscrow jobEscrow = JobEscrow(vm.envAddress("JOB_ESCROW"));
        Settlement settlement = Settlement(vm.envAddress("SETTLEMENT"));
        Governance governance = Governance(vm.envAddress("GOVERNANCE"));
        JobRouter jobRouter = JobRouter(vm.envAddress("JOB_ROUTER"));
        ModelRegistry modelRegistry = ModelRegistry(vm.envAddress("MODEL_REGISTRY"));
        RewardDistributor rewardDistributor = RewardDistributor(vm.envAddress("REWARD_DISTRIBUTOR"));

        address operator = msg.sender;
        bytes32 job3 = keccak256(abi.encodePacked("theacompute-seed-job-3", operator, block.timestamp));
        bytes32 job4 = keccak256(abi.encodePacked("theacompute-seed-job-4", operator, block.timestamp));
        uint64 nextEpoch = rewardDistributor.currentEpoch() + 1;

        vm.startBroadcast();

        // Governance requires 10,000e18 weighted stake to propose; top the
        // position up to 10,000 $THEA staked (12,500e18 weighted at 90 days).
        thea.approve(address(staking), 5_000e18); //  1
        staking.stake(5_000e18, 90); //  2
        uint32 proposalId = governance.createProposal(
            "Raise staked worker payout to 87.5%",
            "Increase workerBpsStaked from 8500 to 8750 to reward staked operators.",
            Governance.ProposalType.ParameterChange,
            abi.encode(uint16(4), uint256(8_750))
        ); //  3
        governance.castVote(proposalId, Governance.VoteChoice.Yes); //  4

        // Reward epoch: fund with 50 USDG against the current stake snapshot,
        // then claim the staker's pro-rata share.
        usdg.approve(address(rewardDistributor), type(uint256).max); //  5
        rewardDistributor.startEpoch(nextEpoch, 50e6, staking.totalWeightedStake()); //  6
        rewardDistributor.claimReward(nextEpoch); //  7

        // Job #3: clean lifecycle at the Pro tier.
        jobEscrow.lockEscrow(job3, IJobEscrow.ModelTier.Pro); //  8
        jobRouter.postJob(job3); //  9
        jobRouter.claimJob(job3); // 10
        settlement.submitProof(job3, keccak256("seed-job-3-output"), 3412); // 11

        // Job #4: settles, then the client disputes and the arbitrator rules
        // against the worker, slashing 5% of the linked stake.
        jobEscrow.lockEscrow(job4, IJobEscrow.ModelTier.Standard); // 12
        jobRouter.postJob(job4); // 13
        jobRouter.claimJob(job4); // 14
        settlement.submitProof(job4, keccak256("seed-job-4-output"), 2077); // 15
        settlement.openDispute(job4, keccak256("seed-job-4-client-hash")); // 16
        settlement.resolveDispute(job4, true); // 17

        modelRegistry.registerModel(
            keccak256("mistral-small-24b-instruct"),
            "mistral-small-24b-instruct",
            "Mistral Small 3 24B Instruct, Q4_K_M",
            0x02 | 0x04
        ); // 18

        jobEscrow.withdraw(500); // 19
        workerRegistry.updateWorker(0x0F, "NVIDIA RTX 4090 24GB", true); // 20

        vm.stopBroadcast();

        console.log("Seeded 20 transactions.");
        console.log("proposalId:", proposalId);
        console.log("epoch:", nextEpoch);
        console.log("job3 (settled):");
        console.logBytes32(job3);
        console.log("job4 (disputed, worker slashed):");
        console.logBytes32(job4);
    }
}
