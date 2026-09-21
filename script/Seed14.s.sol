// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {MockUSDG} from "../tests/mocks/MockUSDG.sol";
import {TheaComputeToken} from "../src/TheaComputeToken.sol";
import {WorkerRegistry} from "../src/WorkerRegistry.sol";
import {Staking} from "../src/Staking.sol";
import {JobEscrow} from "../src/JobEscrow.sol";
import {Settlement} from "../src/Settlement.sol";
import {JobRouter} from "../src/JobRouter.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {IJobEscrow} from "../src/interfaces/IJobEscrow.sol";

/// @notice Seeds a fresh deployment with exactly 14 transactions that walk the
///         protocol end to end from one wallet acting as client, worker, and
///         curator:
///
///           1  MockUSDG.mint            fund the wallet with test USDG
///           2  MockUSDG.approve         allow JobEscrow to pull USDG
///           3  JobEscrow.deposit        buy prepaid credits
///           4  TheaComputeToken.approve   allow Staking to pull $THEA
///           5  Staking.stake            lock 5,000 $THEA for 90 days
///           6  WorkerRegistry.registerWorker
///           7  Staking.linkWorker       make the stake slashable for the worker
///           8  ModelRegistry.registerModel   llama-3.1-8b-instruct
///           9  JobEscrow.lockEscrow     job #1 (Standard tier)
///          10  JobRouter.postJob        job #1 hits the board
///          11  JobRouter.claimJob       worker reserves job #1
///          12  Settlement.submitProof   job #1 settles, worker paid at 85%
///          13  JobEscrow.lockEscrow     job #2 (Lite tier)
///          14  JobRouter.postJob        job #2 left open on the board
///
///         Required env vars: USDG_ADDRESS, THEACOMPUTE_ADDRESS, WORKER_REGISTRY,
///         STAKING, JOB_ESCROW, SETTLEMENT, JOB_ROUTER, MODEL_REGISTRY.
contract Seed14 is Script {
    function run() external {
        MockUSDG usdg = MockUSDG(vm.envAddress("USDG_ADDRESS"));
        TheaComputeToken thea = TheaComputeToken(vm.envAddress("THEACOMPUTE_ADDRESS"));
        WorkerRegistry workerRegistry = WorkerRegistry(vm.envAddress("WORKER_REGISTRY"));
        Staking staking = Staking(vm.envAddress("STAKING"));
        JobEscrow jobEscrow = JobEscrow(vm.envAddress("JOB_ESCROW"));
        Settlement settlement = Settlement(vm.envAddress("SETTLEMENT"));
        JobRouter jobRouter = JobRouter(vm.envAddress("JOB_ROUTER"));
        ModelRegistry modelRegistry = ModelRegistry(vm.envAddress("MODEL_REGISTRY"));

        address operator = msg.sender;
        bytes32 job1 = keccak256(abi.encodePacked("theacompute-seed-job-1", operator, block.timestamp));
        bytes32 job2 = keccak256(abi.encodePacked("theacompute-seed-job-2", operator, block.timestamp));

        vm.startBroadcast();

        // Credits: fund with 1,000 USDG, deposit 500 => 50,000 credits.
        usdg.mint(operator, 1_000e6); //  1
        usdg.approve(address(jobEscrow), type(uint256).max); //  2
        jobEscrow.deposit(500e6); //  3

        // Worker: stake above the 1,000 $THEA minimum, register, link.
        thea.approve(address(staking), 5_000e18); //  4
        staking.stake(5_000e18, 90); //  5
        workerRegistry.registerWorker(0x0F, "NVIDIA RTX 4090 24GB"); //  6
        staking.linkWorker(operator); //  7

        // Catalog: one Standard-tier model.
        modelRegistry.registerModel(
            keccak256("llama-3.1-8b-instruct"),
            "llama-3.1-8b-instruct",
            "Meta Llama 3.1 8B Instruct, Q4_K_M",
            0x02 | 0x04 | 0x08
        ); //  8

        // Job #1: full lifecycle through settlement.
        jobEscrow.lockEscrow(job1, IJobEscrow.ModelTier.Standard); //  9
        jobRouter.postJob(job1); // 10
        jobRouter.claimJob(job1); // 11
        settlement.submitProof(job1, keccak256("seed-job-1-output"), 1874); // 12

        // Job #2: locked and posted, left open for the explorer.
        jobEscrow.lockEscrow(job2, IJobEscrow.ModelTier.Lite); // 13
        jobRouter.postJob(job2); // 14

        vm.stopBroadcast();

        console.log("Seeded 14 transactions.");
        console.log("job1 (settled):");
        console.logBytes32(job1);
        console.log("job2 (open):");
        console.logBytes32(job2);
    }
}
