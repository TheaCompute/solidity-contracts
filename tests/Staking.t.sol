// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * Tests for the Staking contract.
 *
 * Covers: fresh-position defaults, staking with each lock period,
 * correct weighted stake calculation, unstake after lock expiry,
 * early unstake rejection, worker linking, slash execution,
 * and USDG reward crediting and claiming.
 */
import {Test} from "forge-std/Test.sol";
import {Staking} from "../src/Staking.sol";
import {WorkerRegistry} from "../src/WorkerRegistry.sol";
import {TheaComputeToken} from "../src/TheaComputeToken.sol";
import {Ownable} from "../src/Ownable.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

contract StakingTest is Test {
    Staking internal staking;
    WorkerRegistry internal registry;
    TheaComputeToken internal thea;
    MockUSDG internal usdg;

    address internal settlement = makeAddr("settlement");
    address internal staker = makeAddr("staker");
    address internal workerNode = makeAddr("workerNode");
    address internal stranger = makeAddr("stranger");

    // 10,000 $THEA for testing larger stakes.
    uint256 internal constant TEST_STAKE = 10_000e18;

    function setUp() public {
        thea = new TheaComputeToken(address(this));
        usdg = new MockUSDG();
        registry = new WorkerRegistry();
        staking = new Staking(address(thea), address(usdg));

        staking.setSettlement(settlement);
        staking.setWorkerRegistry(address(registry));
        registry.setStaking(address(staking));
        registry.setSettlement(settlement);

        // Fund the staker with 100,000 $THEA.
        thea.transfer(staker, 100_000e18);
        vm.prank(staker);
        thea.approve(address(staking), type(uint256).max);

        // Register the worker node the staker will back.
        vm.prank(workerNode);
        registry.registerWorker(0x01, "RTX-4090");
    }

    function _lockedUntil(address account) internal view returns (uint64 lockedUntil) {
        (,,, lockedUntil,,,,) = staking.positions(account);
    }

    function test_FreshPositionHasNoStake() public view {
        assertEq(staking.stakedAmount(staker), 0);
        assertEq(staking.weightedStake(staker), 0);
        assertEq(staking.totalWeightedStake(), 0);
        assertEq(staking.linkedWorker(staker), address(0));
        assertFalse(staking.meetsWorkerMinimum(staker));
    }

    function test_Stakes30DayLock() public {
        vm.prank(staker);
        staking.stake(TEST_STAKE, 30);

        assertEq(staking.stakedAmount(staker), TEST_STAKE);

        // 30d weight: 1.0x — weighted stake equals amount staked.
        assertEq(staking.weightedStake(staker), TEST_STAKE);
        assertEq(staking.totalWeightedStake(), TEST_STAKE);

        assertEq(_lockedUntil(staker), uint64(block.timestamp) + 30 days);

        // Staked tokens are held by the contract.
        assertEq(thea.balanceOf(address(staking)), TEST_STAKE);
        assertEq(thea.balanceOf(staker), 100_000e18 - TEST_STAKE);
    }

    function test_StakesAdditional90DayLock() public {
        vm.prank(staker);
        staking.stake(TEST_STAKE, 30);

        uint256 additionalStake = 5_000e18;
        uint256 totalExpected = TEST_STAKE + additionalStake;

        vm.prank(staker);
        staking.stake(additionalStake, 90);

        assertEq(staking.stakedAmount(staker), totalExpected);

        // weighted = total * 1250 / 1000 = total * 1.25
        uint256 expectedWeighted = totalExpected * 1_250 / 1_000;
        assertEq(staking.weightedStake(staker), expectedWeighted);
        assertEq(staking.totalWeightedStake(), expectedWeighted);

        // The whole position re-locks for 90 days from now.
        assertEq(_lockedUntil(staker), uint64(block.timestamp) + 90 days);
    }

    function test_Stakes180DayLock() public {
        vm.prank(staker);
        staking.stake(TEST_STAKE, 180);

        // 180d weight: 1.5x.
        assertEq(staking.weightedStake(staker), TEST_STAKE * 1_500 / 1_000);
        assertEq(_lockedUntil(staker), uint64(block.timestamp) + 180 days);
    }

    function test_RejectsInvalidLockPeriod() public {
        // 45 days is not a valid option.
        vm.prank(staker);
        vm.expectRevert(Staking.InvalidLockPeriod.selector);
        staking.stake(1_000e18, 45);
    }

    function test_RejectsZeroAmountStake() public {
        vm.prank(staker);
        vm.expectRevert(Staking.ZeroAmount.selector);
        staking.stake(0, 30);
    }

    function test_RejectsShorterLockOnAdditionalStake() public {
        vm.prank(staker);
        staking.stake(TEST_STAKE, 90);

        vm.prank(staker);
        vm.expectRevert(Staking.LockPeriodTooShort.selector);
        staking.stake(1_000e18, 30);
    }

    function test_RejectsUnstakeWhileStillLocked() public {
        vm.prank(staker);
        staking.stake(TEST_STAKE, 30);

        vm.prank(staker);
        vm.expectRevert(Staking.StillLocked.selector);
        staking.unstake();

        // Still locked one second before expiry.
        vm.warp(block.timestamp + 30 days - 1);
        vm.prank(staker);
        vm.expectRevert(Staking.StillLocked.selector);
        staking.unstake();
    }

    function test_RejectsUnstakeWithNothingStaked() public {
        vm.prank(staker);
        vm.expectRevert(Staking.NothingStaked.selector);
        staking.unstake();
    }

    function test_UnstakesAfterLockExpiry() public {
        vm.prank(staker);
        staking.stake(TEST_STAKE, 30);

        vm.warp(block.timestamp + 30 days);
        vm.prank(staker);
        staking.unstake();

        assertEq(thea.balanceOf(staker), 100_000e18);
        assertEq(thea.balanceOf(address(staking)), 0);
        assertEq(staking.stakedAmount(staker), 0);
        assertEq(staking.weightedStake(staker), 0);
        assertEq(staking.totalWeightedStake(), 0);
    }

    function test_UnstakeClearsWorkerLink() public {
        vm.startPrank(staker);
        staking.stake(TEST_STAKE, 30);
        staking.linkWorker(workerNode);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        vm.prank(staker);
        staking.unstake();

        assertEq(staking.linkedWorker(staker), address(0));
        assertEq(staking.stakerForWorker(workerNode), address(0));
        assertFalse(staking.meetsWorkerMinimum(workerNode));
    }

    function test_CreditsAndClaimsRewards() public {
        vm.prank(staker);
        staking.stake(TEST_STAKE, 30);

        // The crank operator credits USDG rewards to the stake position.
        uint256 rewardAmount = 500_000; // 0.5 USDG
        vm.prank(staking.crankOperator());
        staking.creditRewards(staker, rewardAmount);

        (,,,,,, uint256 pendingRewards,) = staking.positions(staker);
        assertEq(pendingRewards, rewardAmount);

        // Rewards pay out of the contract's USDG balance.
        usdg.mint(address(staking), 1_000_000);
        vm.prank(staker);
        staking.claimRewards();

        assertEq(usdg.balanceOf(staker), rewardAmount);
        (,,,,,, pendingRewards,) = staking.positions(staker);
        assertEq(pendingRewards, 0);
    }

    function test_CreditRewardsOnlyCrankOperator() public {
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.creditRewards(staker, 500_000);
    }

    function test_CreditRewardsRejectsZeroAmount() public {
        vm.prank(staking.crankOperator());
        vm.expectRevert(Staking.ZeroAmount.selector);
        staking.creditRewards(staker, 0);
    }

    function test_ClaimRewardsRequiresPendingRewards() public {
        vm.prank(staker);
        vm.expectRevert(Staking.NoPendingRewards.selector);
        staking.claimRewards();
    }

    function test_CreditsRewardsInABatch() public {
        address second = makeAddr("secondStaker");

        address[] memory stakers = new address[](2);
        stakers[0] = staker;
        stakers[1] = second;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 500_000;
        amounts[1] = 250_000;

        vm.prank(staking.crankOperator());
        assertEq(staking.creditRewardsBatch(stakers, amounts), 750_000);

        (,,,,,, uint256 firstPending,) = staking.positions(staker);
        (,,,,,, uint256 secondPending,) = staking.positions(second);
        assertEq(firstPending, 500_000);
        assertEq(secondPending, 250_000);
    }

    function test_BatchCreditAddsToExistingPendingRewards() public {
        vm.prank(staking.crankOperator());
        staking.creditRewards(staker, 100_000);

        address[] memory stakers = new address[](1);
        stakers[0] = staker;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 400_000;

        vm.prank(staking.crankOperator());
        staking.creditRewardsBatch(stakers, amounts);

        (,,,,,, uint256 pendingRewards,) = staking.positions(staker);
        assertEq(pendingRewards, 500_000);
    }

    function test_BatchCreditOnlyCrankOperator() public {
        address[] memory stakers = new address[](1);
        stakers[0] = staker;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500_000;

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.creditRewardsBatch(stakers, amounts);
    }

    function test_BatchCreditRejectsMismatchedLengths() public {
        address[] memory stakers = new address[](2);
        stakers[0] = staker;
        stakers[1] = stranger;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500_000;

        vm.prank(staking.crankOperator());
        vm.expectRevert(Staking.LengthMismatch.selector);
        staking.creditRewardsBatch(stakers, amounts);
    }

    function test_BatchCreditRejectsZeroAmountEntries() public {
        address[] memory stakers = new address[](2);
        stakers[0] = staker;
        stakers[1] = stranger;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 500_000;
        amounts[1] = 0;

        vm.prank(staking.crankOperator());
        vm.expectRevert(Staking.ZeroAmount.selector);
        staking.creditRewardsBatch(stakers, amounts);

        // The whole batch reverts, so the first entry is not credited either.
        (,,,,,, uint256 pendingRewards,) = staking.positions(staker);
        assertEq(pendingRewards, 0);
    }

    function test_LinksWorker() public {
        vm.startPrank(staker);
        staking.stake(TEST_STAKE, 30);
        staking.linkWorker(workerNode);
        vm.stopPrank();

        assertEq(staking.linkedWorker(staker), workerNode);
        assertEq(staking.stakerForWorker(workerNode), staker);

        // Minimum check resolves the worker node to its backing staker.
        assertTrue(staking.meetsWorkerMinimum(workerNode));
        assertTrue(staking.meetsWorkerMinimum(staker));
    }

    function test_LinkWorkerRejectsBelowMinimumStake() public {
        vm.startPrank(staker);
        staking.stake(999e18, 30);

        vm.expectRevert(Staking.BelowMinimumWorkerStake.selector);
        staking.linkWorker(workerNode);
        vm.stopPrank();
    }

    function test_LinkWorkerAcceptsExactMinimumStake() public {
        vm.startPrank(staker);
        staking.stake(1_000e18, 30);
        staking.linkWorker(workerNode);
        vm.stopPrank();

        assertTrue(staking.meetsWorkerMinimum(workerNode));
    }

    function test_LinkWorkerRejectsDoubleLink() public {
        vm.startPrank(staker);
        staking.stake(TEST_STAKE, 30);
        staking.linkWorker(workerNode);

        vm.expectRevert(Staking.AlreadyLinked.selector);
        staking.linkWorker(workerNode);
        vm.stopPrank();
    }

    function test_LinkWorkerRejectsUnregisteredWorker() public {
        vm.startPrank(staker);
        staking.stake(TEST_STAKE, 30);

        vm.expectRevert(Staking.WorkerNotRegistered.selector);
        staking.linkWorker(stranger);
        vm.stopPrank();
    }

    function test_SlashWorkerBurnsStakeAndAppliesReputationSlash() public {
        vm.startPrank(staker);
        staking.stake(TEST_STAKE, 30);
        staking.linkWorker(workerNode);
        vm.stopPrank();

        uint32 reputationBefore = registry.reputation(workerNode);

        // Settlement slashes 5% (500 bps) after a dishonest dispute.
        vm.prank(settlement);
        uint256 slashed = staking.slashWorker(workerNode, 500);

        uint256 expectedSlash = TEST_STAKE * 500 / 10_000;
        assertEq(slashed, expectedSlash);
        assertEq(staking.stakedAmount(staker), TEST_STAKE - expectedSlash);
        assertEq(staking.weightedStake(staker), TEST_STAKE - expectedSlash);
        assertEq(staking.totalWeightedStake(), TEST_STAKE - expectedSlash);

        // Slashed tokens are burned out of circulation.
        assertEq(thea.balanceOf(staking.BURN_ADDRESS()), expectedSlash);
        assertEq(thea.balanceOf(address(staking)), TEST_STAKE - expectedSlash);

        // Reputation drops by 20% in the registry: new = old * 80 / 100.
        assertEq(registry.reputation(workerNode), (reputationBefore * 80) / 100);
    }

    function test_SlashWorkerKeepsLockWeightMultiplier() public {
        vm.startPrank(staker);
        staking.stake(TEST_STAKE, 180);
        staking.linkWorker(workerNode);
        vm.stopPrank();

        // Slash 10% (1000 bps); remaining weighted stake keeps the 1.5x multiplier.
        vm.prank(settlement);
        uint256 slashed = staking.slashWorker(workerNode, 1_000);

        assertEq(slashed, 1_000e18);
        assertEq(staking.stakedAmount(staker), 9_000e18);
        assertEq(staking.weightedStake(staker), 9_000e18 * 1_500 / 1_000);
        assertEq(staking.totalWeightedStake(), 9_000e18 * 1_500 / 1_000);
    }

    function test_SlashWorkerOnlySettlement() public {
        vm.startPrank(staker);
        staking.stake(TEST_STAKE, 30);
        staking.linkWorker(workerNode);
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.slashWorker(workerNode, 500);
    }

    function test_SlashWorkerRejectsAboveFullSlash() public {
        vm.startPrank(staker);
        staking.stake(TEST_STAKE, 30);
        staking.linkWorker(workerNode);
        vm.stopPrank();

        // More than 10,000 bps would exceed the staked balance.
        vm.prank(settlement);
        vm.expectRevert(Staking.InvalidSlashBps.selector);
        staking.slashWorker(workerNode, 10_001);
    }

    function test_MeetsWorkerMinimumBoundary() public {
        vm.prank(staker);
        staking.stake(999e18, 30);
        assertFalse(staking.meetsWorkerMinimum(staker));

        vm.prank(staker);
        staking.stake(1e18, 30);
        assertTrue(staking.meetsWorkerMinimum(staker));
    }

    function test_WiringSettersOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setSettlement(stranger);

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        staking.setWorkerRegistry(stranger);
    }
}
