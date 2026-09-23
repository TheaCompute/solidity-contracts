// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {Staking} from "../src/Staking.sol";
import {JobEscrow} from "../src/JobEscrow.sol";
import {Settlement} from "../src/Settlement.sol";
import {IJobEscrow} from "../src/interfaces/IJobEscrow.sol";

/// @notice Third seeding pass: exactly 10 transactions, all targeting the three
///         showcase contracts (JobEscrow, Settlement, Staking). Assumes the
///         operator already has USDG approved for the escrow, a registered
///         worker, and the crank operator role on Staking.
///
///           1  JobEscrow.deposit          top up 100 USDG of credits
///           2  JobEscrow.refundEscrow     permissionless refund of an expired lock
///           3  JobEscrow.lockEscrow       job #5 (Max tier)
///           4  Settlement.submitProof     job #5 settles at the staked 85% split
///           5  Staking.creditRewards      crank credits rewards after job #5
///           6  JobEscrow.lockEscrow       job #6 (Lite tier)
///           7  Settlement.submitProof     job #6 settles
///           8  Settlement.openDispute     client contests job #6's output hash
///           9  Settlement.resolveDispute  worker found honest, no slash
///          10  Staking.creditRewards      crank credits rewards after job #6
///
///         Required env vars: STAKING, JOB_ESCROW, SETTLEMENT, REFUND_JOB_ID
///         (an expired, still-Locked escrow to refund).
contract Seed10 is Script {
    function run() external {
        Staking staking = Staking(vm.envAddress("STAKING"));
        JobEscrow jobEscrow = JobEscrow(vm.envAddress("JOB_ESCROW"));
        Settlement settlement = Settlement(vm.envAddress("SETTLEMENT"));
        bytes32 refundJobId = vm.envBytes32("REFUND_JOB_ID");

        address operator = msg.sender;
        bytes32 job5 = keccak256(abi.encodePacked("theacompute-seed-job-5", operator, block.timestamp));
        bytes32 job6 = keccak256(abi.encodePacked("theacompute-seed-job-6", operator, block.timestamp));

        vm.startBroadcast();

        jobEscrow.deposit(100e6); //  1
        jobEscrow.refundEscrow(refundJobId); //  2

        // Job #5: clean lifecycle at the Max tier.
        jobEscrow.lockEscrow(job5, IJobEscrow.ModelTier.Max); //  3
        settlement.submitProof(job5, keccak256("seed-job-5-output"), 5290); //  4
        staking.creditRewards(operator, 15e6); //  5

        // Job #6: settles, gets disputed, and the arbitrator rules the worker
        // honest, closing the dispute with no slash.
        jobEscrow.lockEscrow(job6, IJobEscrow.ModelTier.Lite); //  6
        settlement.submitProof(job6, keccak256("seed-job-6-output"), 861); //  7
        settlement.openDispute(job6, keccak256("seed-job-6-client-hash")); //  8
        settlement.resolveDispute(job6, false); //  9
        staking.creditRewards(operator, 10e6); // 10

        vm.stopBroadcast();

        console.log("Seeded 10 transactions.");
        console.log("job5 (settled, Max tier):");
        console.logBytes32(job5);
        console.log("job6 (disputed, worker vindicated):");
        console.logBytes32(job6);
    }
}
