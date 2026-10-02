// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {JobEscrow} from "../src/JobEscrow.sol";
import {IJobEscrow} from "../src/interfaces/IJobEscrow.sol";
import {Ownable} from "../src/Ownable.sol";
import {MockUSDG} from "./mocks/MockUSDG.sol";

/// @notice Tests for the JobEscrow contract.
///
/// Covers: credit accounting, USDG deposits, credit withdrawals, escrow locking
/// for each model tier, expired job refunds, settlement payout splits, the direct
/// owner settlement path, treasury withdrawal, and all error paths.
contract JobEscrowTest is Test {
    uint256 constant USDG_PER_CREDIT = 10_000;
    uint64 constant JOB_TIMEOUT_SECONDS = 120;

    MockUSDG usdg;
    JobEscrow escrow;

    address client = makeAddr("client");
    address worker = makeAddr("worker");
    address settlement = makeAddr("settlement");
    address stranger = makeAddr("stranger");

    event CreditsDeposited(address indexed client, uint256 usdgAmount, uint256 creditsMinted);
    event CreditsWithdrawn(address indexed client, uint256 creditsWithdrawn, uint256 usdgReturned);
    event EscrowLocked(
        bytes32 indexed jobId,
        address indexed client,
        uint256 creditsLocked,
        IJobEscrow.ModelTier tier,
        uint64 expiresAt
    );
    event EscrowRefunded(bytes32 indexed jobId, address indexed client, uint256 creditsReturned);

    function setUp() public {
        usdg = new MockUSDG();
        escrow = new JobEscrow(address(usdg));
        escrow.setSettlement(settlement);

        // Mint 100 USDG to the test client.
        usdg.mint(client, 100_000_000);
        vm.prank(client);
        usdg.approve(address(escrow), type(uint256).max);
    }

    function _deposit(uint256 usdgAmount) internal {
        vm.prank(client);
        escrow.deposit(usdgAmount);
    }

    function _lock(bytes32 jobId, IJobEscrow.ModelTier tier) internal {
        vm.prank(client);
        escrow.lockEscrow(jobId, tier);
    }

    // ------------------------------------------------------------------
    // Credits
    // ------------------------------------------------------------------

    function test_CreditBalanceStartsAtZero() public view {
        assertEq(escrow.creditBalance(client), 0);
    }

    function test_DepositMintsCredits() public {
        uint256 depositAmount = 50_000_000; // 50 USDG
        uint256 expectedCredits = depositAmount / USDG_PER_CREDIT; // 5000 credits

        vm.expectEmit(true, false, false, true);
        emit CreditsDeposited(client, depositAmount, expectedCredits);
        _deposit(depositAmount);

        assertEq(escrow.creditBalance(client), expectedCredits);
        assertEq(usdg.balanceOf(address(escrow)), depositAmount);
    }

    function test_DepositChargesOnlyForWholeCredits() public {
        // 1.5 credits requested: one credit is minted and only its exact
        // 10,000-unit cost is pulled; the 5,000-unit remainder stays with
        // the client instead of being stranded in the contract.
        uint256 clientBefore = usdg.balanceOf(client);

        vm.expectEmit(true, false, false, true);
        emit CreditsDeposited(client, USDG_PER_CREDIT, 1);
        _deposit(15_000);

        assertEq(escrow.creditBalance(client), 1);
        assertEq(clientBefore - usdg.balanceOf(client), USDG_PER_CREDIT);
        assertEq(usdg.balanceOf(address(escrow)), USDG_PER_CREDIT);
    }

    function test_RevertWhen_DepositBelowMinimum() public {
        // 5,000 USDG units = half a credit, below the one-credit minimum.
        vm.expectRevert(JobEscrow.DepositTooSmall.selector);
        _deposit(5_000);
    }

    function test_WithdrawReturnsUsdg() public {
        _deposit(50_000_000);
        uint256 clientBefore = usdg.balanceOf(client);

        uint256 creditsToWithdraw = 100;
        vm.expectEmit(true, false, false, true);
        emit CreditsWithdrawn(client, creditsToWithdraw, creditsToWithdraw * USDG_PER_CREDIT);
        vm.prank(client);
        escrow.withdraw(creditsToWithdraw);

        assertEq(usdg.balanceOf(client) - clientBefore, creditsToWithdraw * USDG_PER_CREDIT);
        assertEq(escrow.creditBalance(client), 5000 - creditsToWithdraw);
    }

    function test_RevertWhen_WithdrawZero() public {
        _deposit(50_000_000);
        vm.prank(client);
        vm.expectRevert(JobEscrow.ZeroAmount.selector);
        escrow.withdraw(0);
    }

    function test_RevertWhen_WithdrawMoreThanBalance() public {
        _deposit(50_000_000);
        vm.prank(client);
        vm.expectRevert(JobEscrow.InsufficientCredits.selector);
        escrow.withdraw(5001);
    }

    // ------------------------------------------------------------------
    // Escrow locking
    // ------------------------------------------------------------------

    function test_CreditsRequiredPerTier() public view {
        assertEq(escrow.creditsRequired(IJobEscrow.ModelTier.Lite), 2);
        assertEq(escrow.creditsRequired(IJobEscrow.ModelTier.Standard), 8);
        assertEq(escrow.creditsRequired(IJobEscrow.ModelTier.Pro), 18);
        assertEq(escrow.creditsRequired(IJobEscrow.ModelTier.Max), 40);
    }

    function test_LockEscrowLiteTier() public {
        _deposit(50_000_000);
        uint256 creditsBefore = escrow.creditBalance(client);
        bytes32 jobId = bytes32(uint256(1));

        vm.expectEmit(true, true, false, true);
        emit EscrowLocked(jobId, client, 2, IJobEscrow.ModelTier.Lite, uint64(block.timestamp) + JOB_TIMEOUT_SECONDS);
        _lock(jobId, IJobEscrow.ModelTier.Lite);

        assertEq(escrow.creditBalance(client), creditsBefore - 2, "should deduct 2 credits for Lite tier");
        assertEq(escrow.escrowCredits(jobId), 2);
        assertEq(uint8(escrow.escrowTier(jobId)), uint8(IJobEscrow.ModelTier.Lite));
        assertEq(uint8(escrow.escrowStatus(jobId)), uint8(IJobEscrow.EscrowStatus.Locked));
        assertEq(escrow.escrowClient(jobId), client);
        assertEq(escrow.escrowLockedAt(jobId), uint64(block.timestamp));
        assertEq(escrow.escrowExpiresAt(jobId), uint64(block.timestamp) + JOB_TIMEOUT_SECONDS);
    }

    function test_LockEscrowMaxTier() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(2));
        _lock(jobId, IJobEscrow.ModelTier.Max);

        assertEq(escrow.escrowCredits(jobId), 40);
        assertEq(escrow.creditBalance(client), 5000 - 40);
    }

    function test_RevertWhen_LockWithInsufficientCredits() public {
        // 30 credits in the account is not enough for a Max (40 credit) job.
        _deposit(300_000);
        assertEq(escrow.creditBalance(client), 30);

        vm.prank(client);
        vm.expectRevert(JobEscrow.InsufficientCredits.selector);
        escrow.lockEscrow(bytes32(uint256(200)), IJobEscrow.ModelTier.Max);
    }

    function test_RevertWhen_LockDuplicateJobId() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(3));
        _lock(jobId, IJobEscrow.ModelTier.Lite);

        vm.prank(client);
        vm.expectRevert(JobEscrow.EscrowAlreadyExists.selector);
        escrow.lockEscrow(jobId, IJobEscrow.ModelTier.Lite);
    }

    // ------------------------------------------------------------------
    // Refunds
    // ------------------------------------------------------------------

    function test_RefundExpiredJobByAnyone() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(99));
        _lock(jobId, IJobEscrow.ModelTier.Lite);
        uint256 creditsAfterLock = escrow.creditBalance(client);

        vm.warp(block.timestamp + JOB_TIMEOUT_SECONDS);

        vm.expectEmit(true, true, false, true);
        emit EscrowRefunded(jobId, client, 2);
        vm.prank(stranger);
        escrow.refundEscrow(jobId);

        assertEq(escrow.creditBalance(client), creditsAfterLock + 2);
        assertEq(uint8(escrow.escrowStatus(jobId)), uint8(IJobEscrow.EscrowStatus.Refunded));
    }

    function test_RevertWhen_RefundBeforeExpiry() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(100));
        _lock(jobId, IJobEscrow.ModelTier.Lite);

        vm.warp(block.timestamp + JOB_TIMEOUT_SECONDS - 1);
        vm.prank(stranger);
        vm.expectRevert(JobEscrow.NotExpiredYet.selector);
        escrow.refundEscrow(jobId);
    }

    function test_SettlementCanRefundBeforeExpiry() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(101));
        _lock(jobId, IJobEscrow.ModelTier.Standard);
        uint256 creditsAfterLock = escrow.creditBalance(client);

        vm.prank(settlement);
        escrow.refundEscrow(jobId);

        assertEq(escrow.creditBalance(client), creditsAfterLock + 8);
        assertEq(uint8(escrow.escrowStatus(jobId)), uint8(IJobEscrow.EscrowStatus.Refunded));
    }

    function test_RevertWhen_RefundNonLockedEscrow() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(102));
        _lock(jobId, IJobEscrow.ModelTier.Lite);
        vm.prank(settlement);
        escrow.refundEscrow(jobId);

        vm.prank(settlement);
        vm.expectRevert(JobEscrow.InvalidStatus.selector);
        escrow.refundEscrow(jobId);
    }

    // ------------------------------------------------------------------
    // Settlement payouts
    // ------------------------------------------------------------------

    function test_SettleEscrowBasePayout() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(10));
        _lock(jobId, IJobEscrow.ModelTier.Lite); // 2 credits = 20,000 USDG units

        vm.prank(settlement);
        escrow.settleEscrow(jobId, worker, 7_500);

        // Base split: worker 75% = 15,000, treasury 25% = 5,000.
        assertEq(usdg.balanceOf(worker), 15_000);
        assertEq(escrow.treasuryBalance(), 5_000);
        assertEq(uint8(escrow.escrowStatus(jobId)), uint8(IJobEscrow.EscrowStatus.Settled));
    }

    function test_SettleEscrowStakedPayout() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(11));
        _lock(jobId, IJobEscrow.ModelTier.Lite);

        vm.prank(settlement);
        escrow.settleEscrow(jobId, worker, 8_500);

        // Staked split: worker 85% = 17,000, treasury 15% = 3,000.
        assertEq(usdg.balanceOf(worker), 17_000);
        assertEq(escrow.treasuryBalance(), 3_000);
    }

    function test_RevertWhen_SettleEscrowUnauthorized() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(12));
        _lock(jobId, IJobEscrow.ModelTier.Lite);

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        escrow.settleEscrow(jobId, worker, 7_500);
    }

    function test_RevertWhen_SettleEscrowTwice() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(13));
        _lock(jobId, IJobEscrow.ModelTier.Lite);

        vm.prank(settlement);
        escrow.settleEscrow(jobId, worker, 7_500);

        vm.prank(settlement);
        vm.expectRevert(JobEscrow.InvalidStatus.selector);
        escrow.settleEscrow(jobId, worker, 7_500);
    }

    function test_RevertWhen_SettleEscrowBpsTooHigh() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(14));
        _lock(jobId, IJobEscrow.ModelTier.Lite);

        vm.prank(settlement);
        vm.expectRevert(JobEscrow.PayoutMismatch.selector);
        escrow.settleEscrow(jobId, worker, 10_001);
    }

    function test_RevertWhen_RefundAfterSettle() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(15));
        _lock(jobId, IJobEscrow.ModelTier.Lite);

        vm.prank(settlement);
        escrow.settleEscrow(jobId, worker, 7_500);

        vm.warp(block.timestamp + JOB_TIMEOUT_SECONDS);
        vm.prank(stranger);
        vm.expectRevert(JobEscrow.InvalidStatus.selector);
        escrow.refundEscrow(jobId);
    }

    // ------------------------------------------------------------------
    // Direct owner settlement path
    // ------------------------------------------------------------------

    function test_SettleAndPayOwnerPath() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(20));
        _lock(jobId, IJobEscrow.ModelTier.Lite);

        escrow.settleAndPay(jobId, worker, 15_000, 5_000);

        assertEq(usdg.balanceOf(worker), 15_000);
        assertEq(escrow.treasuryBalance(), 5_000);
        assertEq(uint8(escrow.escrowStatus(jobId)), uint8(IJobEscrow.EscrowStatus.Settled));
    }

    function test_RevertWhen_SettleAndPayAmountsMismatch() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(21));
        _lock(jobId, IJobEscrow.ModelTier.Lite);

        vm.expectRevert(JobEscrow.PayoutMismatch.selector);
        escrow.settleAndPay(jobId, worker, 15_000, 4_999);
    }

    function test_RevertWhen_SettleAndPayNotOwner() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(22));
        _lock(jobId, IJobEscrow.ModelTier.Lite);

        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        escrow.settleAndPay(jobId, worker, 15_000, 5_000);
    }

    // ------------------------------------------------------------------
    // Treasury and admin
    // ------------------------------------------------------------------

    function test_WithdrawTreasury() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(30));
        _lock(jobId, IJobEscrow.ModelTier.Lite);
        vm.prank(settlement);
        escrow.settleEscrow(jobId, worker, 7_500);

        address treasuryRecipient = makeAddr("treasuryRecipient");
        escrow.withdrawTreasury(treasuryRecipient, 5_000);

        assertEq(usdg.balanceOf(treasuryRecipient), 5_000);
        assertEq(escrow.treasuryBalance(), 0);
    }

    function test_RevertWhen_WithdrawTreasuryNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        escrow.withdrawTreasury(stranger, 1);
    }

    function test_RevertWhen_WithdrawTreasuryTooMuch() public {
        vm.expectRevert(JobEscrow.InsufficientTreasury.selector);
        escrow.withdrawTreasury(address(this), 1);
    }

    function test_RevertWhen_SetSettlementNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        escrow.setSettlement(stranger);
    }

    // ------------------------------------------------------------------
    // Batch refunds
    // ------------------------------------------------------------------

    function test_RefundExpiredEscrowsInABatch() public {
        _deposit(50_000_000);
        bytes32 first = bytes32(uint256(200));
        bytes32 second = bytes32(uint256(201));
        _lock(first, IJobEscrow.ModelTier.Lite);
        _lock(second, IJobEscrow.ModelTier.Standard);
        uint256 creditsAfterLocks = escrow.creditBalance(client);

        vm.warp(block.timestamp + JOB_TIMEOUT_SECONDS);

        bytes32[] memory jobIds = new bytes32[](2);
        jobIds[0] = first;
        jobIds[1] = second;

        vm.prank(stranger);
        assertEq(escrow.refundExpiredEscrows(jobIds), 2);

        assertEq(escrow.creditBalance(client), creditsAfterLocks + 10);
        assertEq(uint8(escrow.escrowStatus(first)), uint8(IJobEscrow.EscrowStatus.Refunded));
        assertEq(uint8(escrow.escrowStatus(second)), uint8(IJobEscrow.EscrowStatus.Refunded));
    }

    function test_BatchRefundSkipsEscrowsItCannotRefund() public {
        _deposit(50_000_000);
        bytes32 expired = bytes32(uint256(202));
        bytes32 settled = bytes32(uint256(203));
        bytes32 unknown = bytes32(uint256(204));
        _lock(expired, IJobEscrow.ModelTier.Lite);
        _lock(settled, IJobEscrow.ModelTier.Lite);
        uint256 creditsAfterLocks = escrow.creditBalance(client);

        // This one settles while the crank is putting its batch together.
        vm.prank(settlement);
        escrow.settleEscrow(settled, worker, 10_000);

        vm.warp(block.timestamp + JOB_TIMEOUT_SECONDS);

        bytes32[] memory jobIds = new bytes32[](3);
        jobIds[0] = expired;
        jobIds[1] = settled;
        jobIds[2] = unknown;

        vm.prank(stranger);
        assertEq(escrow.refundExpiredEscrows(jobIds), 1, "only the expired escrow refunds");

        assertEq(escrow.creditBalance(client), creditsAfterLocks + 2);
        assertEq(uint8(escrow.escrowStatus(settled)), uint8(IJobEscrow.EscrowStatus.Settled));
    }

    function test_BatchRefundSkipsEscrowsStillInsideTheTimeout() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(205));
        _lock(jobId, IJobEscrow.ModelTier.Lite);
        uint256 creditsAfterLock = escrow.creditBalance(client);

        vm.warp(block.timestamp + JOB_TIMEOUT_SECONDS - 1);

        bytes32[] memory jobIds = new bytes32[](1);
        jobIds[0] = jobId;

        assertEq(escrow.refundExpiredEscrows(jobIds), 0);
        assertEq(escrow.creditBalance(client), creditsAfterLock);
        assertEq(uint8(escrow.escrowStatus(jobId)), uint8(IJobEscrow.EscrowStatus.Locked));
    }

    // ------------------------------------------------------------------
    // Intake pause
    // ------------------------------------------------------------------

    function test_PauseStopsDepositsAndLocks() public {
        _deposit(50_000_000);

        escrow.setIntakePaused(true);
        assertTrue(escrow.intakePaused());

        vm.prank(client);
        vm.expectRevert(JobEscrow.IntakeIsPaused.selector);
        escrow.deposit(USDG_PER_CREDIT);

        vm.prank(client);
        vm.expectRevert(JobEscrow.IntakeIsPaused.selector);
        escrow.lockEscrow(bytes32(uint256(206)), IJobEscrow.ModelTier.Lite);
    }

    function test_PauseLeavesExitPathsOpen() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(207));
        _lock(jobId, IJobEscrow.ModelTier.Lite);

        escrow.setIntakePaused(true);

        // Clients can still redeem credits and recover an escrow that timed out.
        vm.warp(block.timestamp + JOB_TIMEOUT_SECONDS);
        escrow.refundEscrow(jobId);

        uint256 credits = escrow.creditBalance(client);
        vm.prank(client);
        escrow.withdraw(credits);

        assertEq(escrow.creditBalance(client), 0);
        assertEq(usdg.balanceOf(client), 100_000_000);
    }

    function test_UnpauseRestoresIntake() public {
        escrow.setIntakePaused(true);
        escrow.setIntakePaused(false);

        _deposit(50_000_000);
        _lock(bytes32(uint256(208)), IJobEscrow.ModelTier.Lite);

        assertEq(escrow.creditBalance(client), 4_998);
    }

    function test_RevertWhen_PauseCalledByNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(Ownable.Unauthorized.selector);
        escrow.setIntakePaused(true);
    }

    function test_RevertWhen_SettleEscrowToZeroWorker() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(300));
        _lock(jobId, IJobEscrow.ModelTier.Lite);

        vm.prank(settlement);
        vm.expectRevert(Ownable.ZeroAddress.selector);
        escrow.settleEscrow(jobId, address(0), 7_500);
    }

    function test_RevertWhen_SettleAndPayToZeroWorker() public {
        _deposit(50_000_000);
        bytes32 jobId = bytes32(uint256(301));
        _lock(jobId, IJobEscrow.ModelTier.Lite);

        vm.expectRevert(Ownable.ZeroAddress.selector);
        escrow.settleAndPay(jobId, address(0), 15_000, 5_000);
    }

    function test_RevertWhen_WithdrawTreasuryToZeroAddress() public {
        vm.expectRevert(Ownable.ZeroAddress.selector);
        escrow.withdrawTreasury(address(0), 1);
    }
}
