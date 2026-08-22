// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IJobEscrow {
    /// @notice Model tiers, mirroring credit pricing. lite=0, standard=1, pro=2, max=3.
    enum ModelTier {
        Lite,
        Standard,
        Pro,
        Max
    }

    enum EscrowStatus {
        None,
        Locked,
        Settled,
        Refunded
    }

    function creditBalance(address account) external view returns (uint256);
    function escrowStatus(bytes32 jobId) external view returns (EscrowStatus);
    function escrowClient(bytes32 jobId) external view returns (address);
    function escrowCredits(bytes32 jobId) external view returns (uint256);
    function escrowLockedAt(bytes32 jobId) external view returns (uint64);
    function escrowTier(bytes32 jobId) external view returns (ModelTier);
    function escrowExpiresAt(bytes32 jobId) external view returns (uint64);

    /// @notice Pay out a locked escrow. Callable only by the settlement contract.
    /// @param worker receives `workerBps` of the USDG value; the remainder accrues to the treasury.
    function settleEscrow(bytes32 jobId, address worker, uint256 workerBps) external;

    /// @notice Return a locked escrow to the client's credit balance. Callable by the
    ///         settlement contract (dispute resolution) or by anyone after the job timeout.
    function refundEscrow(bytes32 jobId) external;
}
