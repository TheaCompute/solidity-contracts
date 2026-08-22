// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IJobRouter {
    /// @notice Mirrors JobRouter's public `postings` getter. The enum fields
    ///         decode as uint8: tier lite=0, standard=1, pro=2, max=3; status
    ///         none=0, open=1, assigned=2, cancelled=3.
    function postings(bytes32 jobId)
        external
        view
        returns (address client, uint8 tier, uint8 status, uint64 createdAt, uint64 expiresAt, address assignedWorker);
}
