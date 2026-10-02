// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "./interfaces/IERC20.sol";
import {IJobEscrow} from "./interfaces/IJobEscrow.sol";
import {Ownable} from "./Ownable.sol";

/// @title JobEscrow
/// @notice Holds USDG as prepaid inference credits and escrows them per job.
///         1 credit = $0.01 = 10,000 USDG units (USDG uses 6 decimals).
///         Worker payouts are released by the settlement contract; the treasury
///         share of each settled job accrues here until the owner withdraws it.
contract JobEscrow is IJobEscrow, Ownable {
    /// @notice USDG units (6 decimals) per credit: 10,000 units = $0.01.
    uint256 public constant USDG_PER_CREDIT = 10_000;
    /// @notice Seconds after locking before an escrow can be refunded by anyone.
    uint64 public constant JOB_TIMEOUT_SECONDS = 120;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    struct Escrow {
        address client;
        uint64 creditsLocked;
        ModelTier tier;
        EscrowStatus status;
        uint64 createdAt;
        uint64 expiresAt;
    }

    IERC20 public immutable usdg;

    /// @notice The settlement contract trusted to settle and refund escrows.
    address public settlement;

    /// @notice Emergency stop for new money coming in. While set, deposits and
    ///         escrow locks revert; withdrawals, settlements, and refunds stay
    ///         open so nothing already in the contract is trapped.
    bool public intakePaused;

    /// @notice Prepaid credits per client account.
    mapping(address => uint256) public creditBalance;
    mapping(bytes32 => Escrow) public escrows;

    /// @notice Treasury share of settled jobs (USDG units), withdrawable by the owner.
    uint256 public treasuryBalance;

    event CreditsDeposited(address indexed client, uint256 usdgAmount, uint256 creditsMinted);
    event CreditsWithdrawn(address indexed client, uint256 creditsWithdrawn, uint256 usdgReturned);
    event EscrowLocked(
        bytes32 indexed jobId, address indexed client, uint256 creditsLocked, ModelTier tier, uint64 expiresAt
    );
    event EscrowSettled(bytes32 indexed jobId, address indexed client, uint256 credits, uint256 usdgReleased);
    event EscrowRefunded(bytes32 indexed jobId, address indexed client, uint256 creditsReturned);
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event SettlementSet(address indexed settlement);
    event IntakePausedSet(bool paused);

    error DepositTooSmall();
    error InsufficientCredits();
    error ZeroAmount();
    error EscrowAlreadyExists();
    error InvalidStatus();
    error NotExpiredYet();
    error PayoutMismatch();
    error InsufficientTreasury();
    error TransferFailed();
    /// @notice New deposits and escrow locks are paused.
    error IntakeIsPaused();

    constructor(address usdg_) {
        usdg = IERC20(usdg_);
    }

    /// @notice Wire the trusted settlement contract. Owner only.
    function setSettlement(address settlement_) external onlyOwner {
        if (settlement_ == address(0)) revert ZeroAddress();
        settlement = settlement_;
        emit SettlementSet(settlement_);
    }

    /// @notice Halt or resume new deposits and escrow locks. Owner only.
    ///         Intended for incident response: stop the inflow while leaving
    ///         every exit path (withdraw, settle, refund) working.
    function setIntakePaused(bool paused) external onlyOwner {
        intakePaused = paused;
        emit IntakePausedSet(paused);
    }

    /// @notice Credits required to lock an escrow for a given model tier.
    function creditsRequired(ModelTier tier) public pure returns (uint64) {
        if (tier == ModelTier.Lite) return 2;
        if (tier == ModelTier.Standard) return 8;
        if (tier == ModelTier.Pro) return 18;
        return 40; // ModelTier.Max
    }

    // ---------------------------------------------------------------------
    // Credits
    // ---------------------------------------------------------------------

    /// @notice Deposit USDG and mint credits at 10,000 USDG units per credit.
    ///         Only the exact cost of the minted credits is pulled from the
    ///         caller; any remainder below one credit stays in their wallet.
    function deposit(uint256 usdgAmount) external {
        if (intakePaused) revert IntakeIsPaused();
        if (usdgAmount < USDG_PER_CREDIT) revert DepositTooSmall();
        uint256 creditsMinted = usdgAmount / USDG_PER_CREDIT;
        uint256 usdgCharged = creditsMinted * USDG_PER_CREDIT;

        if (!usdg.transferFrom(msg.sender, address(this), usdgCharged)) revert TransferFailed();
        creditBalance[msg.sender] += creditsMinted;

        emit CreditsDeposited(msg.sender, usdgCharged, creditsMinted);
    }

    /// @notice Redeem credits back to USDG at the fixed rate.
    function withdraw(uint256 creditsToWithdraw) external {
        if (creditsToWithdraw == 0) revert ZeroAmount();
        if (creditBalance[msg.sender] < creditsToWithdraw) revert InsufficientCredits();

        uint256 usdgAmount = creditsToWithdraw * USDG_PER_CREDIT;
        creditBalance[msg.sender] -= creditsToWithdraw;

        if (!usdg.transfer(msg.sender, usdgAmount)) revert TransferFailed();

        emit CreditsWithdrawn(msg.sender, creditsToWithdraw, usdgAmount);
    }

    // ---------------------------------------------------------------------
    // Escrow lifecycle
    // ---------------------------------------------------------------------

    /// @notice Lock the tier's credit price from the caller's balance into a job escrow.
    function lockEscrow(bytes32 jobId, ModelTier tier) external {
        if (intakePaused) revert IntakeIsPaused();
        if (escrows[jobId].status != EscrowStatus.None) revert EscrowAlreadyExists();

        uint64 required = creditsRequired(tier);
        if (creditBalance[msg.sender] < required) revert InsufficientCredits();
        creditBalance[msg.sender] -= required;

        uint64 nowTs = uint64(block.timestamp);
        uint64 expiresAt = nowTs + JOB_TIMEOUT_SECONDS;
        escrows[jobId] = Escrow({
            client: msg.sender,
            creditsLocked: required,
            tier: tier,
            status: EscrowStatus.Locked,
            createdAt: nowTs,
            expiresAt: expiresAt
        });

        emit EscrowLocked(jobId, msg.sender, required, tier, expiresAt);
    }

    /// @inheritdoc IJobEscrow
    function settleEscrow(bytes32 jobId, address worker, uint256 workerBps) external {
        if (msg.sender != settlement) revert Unauthorized();
        if (worker == address(0)) revert ZeroAddress();
        if (workerBps > BPS_DENOMINATOR) revert PayoutMismatch();

        Escrow storage escrow = escrows[jobId];
        if (escrow.status != EscrowStatus.Locked) revert InvalidStatus();

        uint256 usdgToRelease = uint256(escrow.creditsLocked) * USDG_PER_CREDIT;
        uint256 workerPayout = (usdgToRelease * workerBps) / BPS_DENOMINATOR;

        escrow.status = EscrowStatus.Settled;
        treasuryBalance += usdgToRelease - workerPayout;

        if (!usdg.transfer(worker, workerPayout)) revert TransferFailed();

        emit EscrowSettled(jobId, escrow.client, escrow.creditsLocked, usdgToRelease);
    }

    /// @inheritdoc IJobEscrow
    function refundEscrow(bytes32 jobId) external {
        Escrow storage escrow = escrows[jobId];
        if (escrow.status != EscrowStatus.Locked) revert InvalidStatus();

        // The settlement contract may refund at any time (dispute resolution);
        // anyone else must wait for the job timeout.
        if (msg.sender != settlement && uint64(block.timestamp) < escrow.expiresAt) {
            revert NotExpiredYet();
        }

        _refund(jobId, escrow);
    }

    /// @notice Refund every expired escrow in `jobIds` in one transaction, the
    ///         shape the refund crank actually runs in. Entries that are not
    ///         refundable (already settled, already refunded, still inside the
    ///         timeout) are skipped rather than reverting, so a job that settles
    ///         while the crank is in flight cannot strand the rest of the batch.
    /// @return refundedCount how many of the given escrows were refunded.
    function refundExpiredEscrows(bytes32[] calldata jobIds) external returns (uint256 refundedCount) {
        uint64 nowTs = uint64(block.timestamp);

        for (uint256 i = 0; i < jobIds.length; i++) {
            Escrow storage escrow = escrows[jobIds[i]];
            if (escrow.status != EscrowStatus.Locked) continue;
            if (nowTs < escrow.expiresAt) continue;

            _refund(jobIds[i], escrow);
            refundedCount++;
        }
    }

    /// @notice Direct owner settlement path: pay explicit worker and treasury
    ///         amounts that must sum to the escrowed USDG value.
    function settleAndPay(bytes32 jobId, address worker, uint256 workerPayout, uint256 treasuryPayout)
        external
        onlyOwner
    {
        if (worker == address(0)) revert ZeroAddress();
        Escrow storage escrow = escrows[jobId];
        if (escrow.status != EscrowStatus.Locked) revert InvalidStatus();

        uint256 totalOwed = uint256(escrow.creditsLocked) * USDG_PER_CREDIT;
        if (workerPayout + treasuryPayout != totalOwed) revert PayoutMismatch();

        escrow.status = EscrowStatus.Settled;
        treasuryBalance += treasuryPayout;

        if (!usdg.transfer(worker, workerPayout)) revert TransferFailed();

        emit EscrowSettled(jobId, escrow.client, escrow.creditsLocked, totalOwed);
    }

    /// @notice Withdraw accrued treasury USDG. Owner only.
    function withdrawTreasury(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > treasuryBalance) revert InsufficientTreasury();
        treasuryBalance -= amount;
        if (!usdg.transfer(to, amount)) revert TransferFailed();
        emit TreasuryWithdrawn(to, amount);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Returns a locked escrow's credits to the client. Callers are
    ///      responsible for checking the status and the timeout first.
    function _refund(bytes32 jobId, Escrow storage escrow) internal {
        uint256 creditsToReturn = escrow.creditsLocked;
        escrow.status = EscrowStatus.Refunded;
        creditBalance[escrow.client] += creditsToReturn;

        emit EscrowRefunded(jobId, escrow.client, creditsToReturn);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IJobEscrow
    function escrowStatus(bytes32 jobId) external view returns (EscrowStatus) {
        return escrows[jobId].status;
    }

    /// @inheritdoc IJobEscrow
    function escrowClient(bytes32 jobId) external view returns (address) {
        return escrows[jobId].client;
    }

    /// @inheritdoc IJobEscrow
    function escrowCredits(bytes32 jobId) external view returns (uint256) {
        return escrows[jobId].creditsLocked;
    }

    /// @inheritdoc IJobEscrow
    function escrowLockedAt(bytes32 jobId) external view returns (uint64) {
        return escrows[jobId].createdAt;
    }

    /// @notice Model tier of a locked escrow (used by settlement for tier checks).
    function escrowTier(bytes32 jobId) external view returns (ModelTier) {
        return escrows[jobId].tier;
    }

    /// @notice Timestamp after which a locked escrow may be refunded by anyone.
    function escrowExpiresAt(bytes32 jobId) external view returns (uint64) {
        return escrows[jobId].expiresAt;
    }

    /// @notice Whether anyone can refund this escrow right now: it is still
    ///         locked and its timeout has passed. Lets the refund crank filter
    ///         candidates off-chain before sending a batch.
    function isRefundable(bytes32 jobId) external view returns (bool) {
        Escrow storage escrow = escrows[jobId];
        return escrow.status == EscrowStatus.Locked && uint64(block.timestamp) >= escrow.expiresAt;
    }
}
