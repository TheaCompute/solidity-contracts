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

/// @notice Deploys the full TheaCompute suite and wires every cross-contract
///         authority in a single broadcast.
///
///         Optional env vars:
///           USDG_ADDRESS       reuse an existing USDG (required on mainnet;
///                              otherwise a MockUSDG is deployed)
///           THEACOMPUTE_ADDRESS  reuse an existing $THEA token (otherwise a
///                              fresh one is minted to the deployer)
contract Deploy is Script {
    function run() external {
        address deployer = msg.sender;

        address usdgAddr = vm.envOr("USDG_ADDRESS", address(0));
        address theaAddr = vm.envOr("THEACOMPUTE_ADDRESS", address(0));

        vm.startBroadcast();

        if (usdgAddr == address(0)) {
            usdgAddr = address(new MockUSDG());
            console.log("MockUSDG:          ", usdgAddr);
        } else {
            console.log("USDG (existing):   ", usdgAddr);
        }

        if (theaAddr == address(0)) {
            theaAddr = address(new TheaComputeToken(deployer));
            console.log("TheaComputeToken:    ", theaAddr);
        } else {
            console.log("THEA (existing):  ", theaAddr);
        }

        WorkerRegistry workerRegistry = new WorkerRegistry();
        Staking staking = new Staking(theaAddr, usdgAddr);
        JobEscrow jobEscrow = new JobEscrow(usdgAddr);
        Settlement settlement = new Settlement();
        Governance governance = new Governance();
        JobRouter jobRouter = new JobRouter();
        ModelRegistry modelRegistry = new ModelRegistry();
        RewardDistributor rewardDistributor = new RewardDistributor(usdgAddr);

        workerRegistry.setSettlement(address(settlement));
        workerRegistry.setStaking(address(staking));

        staking.setSettlement(address(settlement));
        staking.setWorkerRegistry(address(workerRegistry));

        jobEscrow.setSettlement(address(settlement));

        settlement.setJobEscrow(address(jobEscrow));
        settlement.setWorkerRegistry(address(workerRegistry));
        settlement.setStaking(address(staking));

        governance.setStaking(address(staking));

        jobRouter.setJobEscrow(address(jobEscrow));
        jobRouter.setWorkerRegistry(address(workerRegistry));

        rewardDistributor.setStaking(address(staking));

        vm.stopBroadcast();

        console.log("WorkerRegistry:    ", address(workerRegistry));
        console.log("Staking:           ", address(staking));
        console.log("JobEscrow:         ", address(jobEscrow));
        console.log("Settlement:        ", address(settlement));
        console.log("Governance:        ", address(governance));
        console.log("JobRouter:         ", address(jobRouter));
        console.log("ModelRegistry:     ", address(modelRegistry));
        console.log("RewardDistributor: ", address(rewardDistributor));
    }
}
