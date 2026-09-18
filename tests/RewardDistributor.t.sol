// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {Ownable} from "../src/Ownable.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

/// @notice Minimal staking mock exposing settable stake weights for
///         distributor tests. Only the views RewardDistributor reads matter.
contract DistributorStakingMock is IStaking {
    mapping(address => uint256) public stakedAmount;
    mapping(address => uint256) public weightedStake;
    mapping(address => address) public linkedWorker;
    uint256 public totalWeightedStake;

    function setStake(address account, uint256 rawAmount, uint256 weighted) external {
        totalWeightedStake = totalWeightedStake - weightedStake[account] + weighted;
        stakedAmount[account] = rawAmount;
        weightedStake[account] = weighted;
    }

    function slashWorker(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function meetsWorkerMinimum(address account) external view returns (bool) {
        return stakedAmount[account] >= 1_000e18;
    }
}

/// @notice Tests for the RewardDistributor contract.
///
/// Covers: initialization, epoch funding, sequential epoch ID enforcement,
/// pro-rata claims for both stakers, and double-claim rejection.
contract RewardDistributorTest is Test {
    RewardDistributor internal dist;
    DistributorStakingMock internal staking;
    MockUSDG internal usdg;

    address internal staker = makeAddr("staker");
    address internal staker2 = makeAddr("staker2");
    address internal dust = makeAddr("dust");

    // staker holds 3,000 $THEA at the 90-day tier (1.25x) → 3,750 weighted.
    uint256 internal constant STAKER_WEIGHTED = 3_750e18;
    // staker2 holds 1,000 $THEA at the 30-day tier (1.0x) → 1,000 weighted.
    uint256 internal constant STAKER2_WEIGHTED = 1_000e18;
    uint256 internal constant TOTAL_SNAPSHOT = 4_750e18;
    uint256 internal constant EPOCH_FUNDING = 10_000e6; // 10,000 USDG

    function setUp() public {
        usdg = new MockUSDG();
        staking = new DistributorStakingMock();
        dist = new RewardDistributor(address(usdg));
        dist.setStaking(address(staking));

        staking.setStake(staker, 3_000e18, STAKER_WEIGHTED);
        staking.setStake(staker2, 1_000e18, STAKER2_WEIGHTED);

        // Starting USDG balance for the owner (this test contract) to fund epochs.
        usdg.mint(address(this), 1_000_000e6);
        usdg.approve(address(dist), type(uint256).max);
    }

    function _startEpochOne() internal {
        dist.startEpoch(1, EPOCH_FUNDING, TOTAL_SNAPSHOT);
    }

    // ------------------------------------------------------------------
    // Initialization
    // ------------------------------------------------------------------

    function test_InitializesDistributor() public view {
        assertEq(dist.currentEpoch(), 0);
        assertEq(dist.totalDistributed(), 0);
        assertEq(dist.owner(), address(this));
        assertEq(usdg.balanceOf(address(dist)), 0);
    }

    // ------------------------------------------------------------------
    // Epochs
    // ------------------------------------------------------------------

    function test_StartsEpochOneAndTransfersUsdgIn() public {
        _startEpochOne();

        assertEq(dist.currentEpoch(), 1);
        assertEq(dist.totalDistributed(), EPOCH_FUNDING);
        assertEq(usdg.balanceOf(address(dist)), EPOCH_FUNDING);

        RewardDistributor.Epoch memory epoch = dist.getEpoch(1);
        assertEq(epoch.epochId, 1);
        assertEq(epoch.usdgDeposited, EPOCH_FUNDING);
        assertEq(epoch.totalStakeSnapshot, TOTAL_SNAPSHOT);
        assertEq(epoch.startedAt, uint64(block.timestamp));
    }

    function test_RejectsStartingEpochWithWrongEpochId() public {
        vm.expectRevert(RewardDistributor.EpochMismatch.selector);
        dist.startEpoch(5, 1_000e6, TOTAL_SNAPSHOT);
    }

    function test_RejectsZeroAmountEpoch() public {
        vm.expectRevert(RewardDistributor.ZeroAmount.selector);
        dist.startEpoch(1, 0, TOTAL_SNAPSHOT);
    }

    function test_RejectsZeroStakeSnapshotEpoch() public {
        vm.expectRevert(RewardDistributor.ZeroStakeSnapshot.selector);
        dist.startEpoch(1, EPOCH_FUNDING, 0);
    }

    function test_RejectsStartEpochFromNonOwner() public {
        vm.prank(staker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        dist.startEpoch(1, EPOCH_FUNDING, TOTAL_SNAPSHOT);
    }

    function test_StartsSequentialEpochs() public {
        _startEpochOne();
        dist.startEpoch(2, 5_000e6, TOTAL_SNAPSHOT);

        assertEq(dist.currentEpoch(), 2);
        assertEq(dist.totalDistributed(), EPOCH_FUNDING + 5_000e6);
    }

    // ------------------------------------------------------------------
    // Claims
    // ------------------------------------------------------------------

    function test_StakerClaimsProRataRewardFromEpochOne() public {
        _startEpochOne();

        uint256 before = usdg.balanceOf(staker);
        vm.prank(staker);
        dist.claimReward(1);
        uint256 received = usdg.balanceOf(staker) - before;

        // staker has 3,750 weighted stake out of 4,750 total.
        // Expected: 3750/4750 * 10,000 USDG ≈ 7,894.736842 USDG.
        assertGt(received, 0);
        assertEq(received, (STAKER_WEIGHTED * EPOCH_FUNDING) / TOTAL_SNAPSHOT);
        assertEq(received, 7_894_736_842);

        RewardDistributor.ClaimRecord memory claim = dist.getClaimRecord(1, staker);
        assertEq(claim.staker, staker);
        assertEq(claim.epochId, 1);
        assertEq(claim.amountClaimed, received);
    }

    function test_RejectsDoubleClaimForSameEpoch() public {
        _startEpochOne();

        vm.prank(staker);
        dist.claimReward(1);

        vm.prank(staker);
        vm.expectRevert(RewardDistributor.AlreadyClaimed.selector);
        dist.claimReward(1);
    }

    function test_SecondStakerClaimsSmallerShareFromEpochOne() public {
        _startEpochOne();

        vm.prank(staker);
        dist.claimReward(1);

        uint256 before = usdg.balanceOf(staker2);
        vm.prank(staker2);
        dist.claimReward(1);
        uint256 received = usdg.balanceOf(staker2) - before;

        // staker2 has 1,000 weighted stake out of 4,750 total.
        assertGt(received, 0);
        assertEq(received, (STAKER2_WEIGHTED * EPOCH_FUNDING) / TOTAL_SNAPSHOT);
        assertEq(received, 2_105_263_157);
    }

    function test_RejectsClaimBelowMinimumStake() public {
        _startEpochOne();

        // 500 weighted stake is below the 1,000e18 claim minimum.
        staking.setStake(dust, 500e18, 500e18);
        vm.prank(dust);
        vm.expectRevert(RewardDistributor.NoStake.selector);
        dist.claimReward(1);
    }

    function test_RejectsClaimForUnknownEpoch() public {
        vm.prank(staker);
        vm.expectRevert(RewardDistributor.EpochNotFound.selector);
        dist.claimReward(1);
    }

    function test_EachStakerCanClaimAcrossMultipleEpochs() public {
        _startEpochOne();
        dist.startEpoch(2, EPOCH_FUNDING, TOTAL_SNAPSHOT);

        vm.startPrank(staker);
        dist.claimReward(1);
        dist.claimReward(2);
        vm.stopPrank();

        uint256 expectedPerEpoch = (STAKER_WEIGHTED * EPOCH_FUNDING) / TOTAL_SNAPSHOT;
        assertEq(usdg.balanceOf(staker), 2 * expectedPerEpoch);
    }

    // ------------------------------------------------------------------
    // Sweeping unclaimed rewards
    // ------------------------------------------------------------------

    function test_TracksClaimedAndUnclaimedPerEpoch() public {
        _startEpochOne();
        assertEq(dist.unclaimedInEpoch(1), EPOCH_FUNDING);

        vm.prank(staker);
        dist.claimReward(1);

        uint256 claimed = (STAKER_WEIGHTED * EPOCH_FUNDING) / TOTAL_SNAPSHOT;
        assertEq(dist.claimedInEpoch(1), claimed);
        assertEq(dist.unclaimedInEpoch(1), EPOCH_FUNDING - claimed);
    }

    function test_SweepsWhatIsLeftAfterTheClaimWindow() public {
        _startEpochOne();

        // Only one of the two stakers ever claims.
        vm.prank(staker);
        dist.claimReward(1);
        uint256 claimed = (STAKER_WEIGHTED * EPOCH_FUNDING) / TOTAL_SNAPSHOT;

        vm.warp(block.timestamp + 30 days);

        address treasury = makeAddr("treasury");
        assertEq(dist.sweepUnclaimed(1, treasury), EPOCH_FUNDING - claimed);

        assertEq(usdg.balanceOf(treasury), EPOCH_FUNDING - claimed);
        assertEq(usdg.balanceOf(address(dist)), 0);
        assertEq(dist.totalDistributed(), claimed, "totalDistributed nets out the sweep");
        assertEq(dist.unclaimedInEpoch(1), 0);
        assertTrue(dist.epochSwept(1));
    }

    function test_RejectsSweepDuringTheClaimWindow() public {
        _startEpochOne();

        vm.warp(block.timestamp + 30 days - 1);
        vm.expectRevert(RewardDistributor.SweepTooEarly.selector);
        dist.sweepUnclaimed(1, address(this));
    }

    function test_RejectsSweepOfAFullyClaimedEpoch() public {
        // 9,500 USDG over a 4,750e18 snapshot divides evenly between the two
        // stakers, so a full round of claims leaves no remainder.
        dist.startEpoch(1, 9_500e6, TOTAL_SNAPSHOT);

        vm.prank(staker);
        dist.claimReward(1);
        vm.prank(staker2);
        dist.claimReward(1);

        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(RewardDistributor.NothingToSweep.selector);
        dist.sweepUnclaimed(1, address(this));
    }

    function test_RejectsSecondSweepAndLateClaims() public {
        _startEpochOne();
        vm.warp(block.timestamp + 30 days);
        dist.sweepUnclaimed(1, address(this));

        vm.expectRevert(RewardDistributor.AlreadySwept.selector);
        dist.sweepUnclaimed(1, address(this));

        // Claiming after a sweep would come out of a later epoch's funding.
        vm.prank(staker);
        vm.expectRevert(RewardDistributor.AlreadySwept.selector);
        dist.claimReward(1);
    }

    function test_RejectsSweepByNonOwnerOrToZeroAddress() public {
        _startEpochOne();
        vm.warp(block.timestamp + 30 days);

        vm.prank(staker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        dist.sweepUnclaimed(1, staker);

        vm.expectRevert(Ownable.ZeroAddress.selector);
        dist.sweepUnclaimed(1, address(0));
    }

    function test_RejectsSweepOfUnknownEpoch() public {
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(RewardDistributor.EpochNotFound.selector);
        dist.sweepUnclaimed(1, address(this));
    }
}
