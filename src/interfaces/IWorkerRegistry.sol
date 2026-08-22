// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IWorkerRegistry {
    /// @notice Tier bitmask flags. lite=1, standard=2, pro=4, max=8.
    function registerWorker(uint8 tierMask, string calldata gpuModel) external;
    function updateWorker(uint8 tierMask, string calldata gpuModel, bool active) external;

    /// @notice Called by the settlement contract after a job settles.
    /// @param success true when the proof verified and payout was released.
    /// @param latencyMs end-to-end job latency used in the reputation EMA.
    function recordCompletion(address worker, bool success, uint64 latencyMs) external;

    /// @notice Called by the staking contract when a slash is applied.
    function applySlash(address worker) external;

    function isRegistered(address worker) external view returns (bool);
    function isActive(address worker) external view returns (bool);
    function supportsTier(address worker, uint8 tierMask) external view returns (bool);
    function reputation(address worker) external view returns (uint32);
}
