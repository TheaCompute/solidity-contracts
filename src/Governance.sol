// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IStaking} from "./interfaces/IStaking.sol";
import {Ownable} from "./Ownable.sol";

/// @title Governance
/// @notice Weighted-stake governance for TheaCompute. Stakers create
///         proposals, vote with their lock-tier-weighted stake, and passed
///         proposals execute after a timelock. ParameterChange proposals
///         write into the on-chain protocol parameter store held here.
contract Governance is Ownable {
    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint64 public constant VOTING_PERIOD = 7 days;
    uint64 public constant TIMELOCK_PERIOD = 2 days;
    /// @notice Quorum: 5% of the 1B $THEA supply (18 decimals).
    uint256 public constant QUORUM_THRESHOLD = 50_000_000e18;
    uint256 public constant APPROVAL_NUMERATOR = 60;
    uint256 public constant APPROVAL_DENOMINATOR = 100;

    // Maximum byte lengths for proposal text storage.
    uint256 public constant TITLE_MAX = 64;
    uint256 public constant DESC_MAX = 256;
    uint256 public constant PAYLOAD_MAX = 128;
    uint256 public constant MIN_WEIGHTED_STAKE_TO_PROPOSE = 10_000e18;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum ProposalType {
        ParameterChange,
        ModelCuration,
        TreasurySpend,
        ContractUpgrade
    }

    enum ProposalStatus {
        Active,
        Passed,
        Rejected,
        Executed,
        Cancelled
    }

    enum VoteChoice {
        Yes,
        No,
        Abstain
    }

    struct Proposal {
        uint32 id;
        address proposer;
        string title;
        string description;
        ProposalType proposalType;
        bytes payload;
        ProposalStatus status;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 abstainVotes;
        uint64 createdAt;
        uint64 votingEndsAt;
        uint64 executableAt;
    }

    struct VoteRecord {
        address voter;
        uint32 proposalId;
        VoteChoice vote;
        uint256 votingPower;
        uint64 votedAt;
    }

    struct GovernanceParams {
        uint256 jobTimeoutSeconds;
        uint256 disputeWindowSeconds;
        uint256 minWorkerStake;
        uint256 workerBpsBase;
        uint256 workerBpsStaked;
        uint256 minStakeForBonus;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    IStaking public staking;
    uint32 public proposalCount;
    GovernanceParams public params;

    mapping(uint32 => Proposal) internal _proposals;
    mapping(uint32 => mapping(address => VoteRecord)) internal _voteRecords;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event ProposalCreated(uint32 indexed proposalId, address indexed proposer, ProposalType proposalType);
    event VoteCast(uint32 indexed proposalId, address indexed voter, VoteChoice vote, uint256 votingPower);
    event ProposalFinalized(
        uint32 indexed proposalId,
        ProposalStatus status,
        uint256 yesVotes,
        uint256 noVotes,
        bool quorumReached,
        bool approvalReached
    );
    event ProposalExecuted(uint32 indexed proposalId, ProposalType proposalType);
    event ProposalCancelled(uint32 indexed proposalId);
    event ParameterChanged(uint32 indexed proposalId, uint16 paramId, uint256 newValue);
    event StakingSet(address indexed staking);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error InsufficientStakeToPropose();
    error ProposalIdMismatch();
    error ProposalNotActive();
    error VotingEnded();
    error NoStakeToVote();
    error AlreadyVoted();
    error VotingNotEnded();
    error ProposalNotPassed();
    error TimelockNotExpired();
    error NotAuthorized();
    error ProposalNotExecuted();
    error WrongProposalType();
    error UnknownParamId();
    error TitleTooLong();
    error DescriptionTooLong();
    error PayloadTooLong();
    error InvalidPayload();

    /// @notice Deploys governance and seeds the protocol parameter store
    ///         with the current protocol defaults.
    constructor() {
        params = GovernanceParams({
            jobTimeoutSeconds: 120,
            disputeWindowSeconds: 60,
            minWorkerStake: 1_000e18,
            workerBpsBase: 7_500,
            workerBpsStaked: 8_500,
            minStakeForBonus: 1_000e18
        });
    }

    // ---------------------------------------------------------------------
    // Owner wiring
    // ---------------------------------------------------------------------

    /// @notice Wires the staking contract used for vote weights.
    function setStaking(address staking_) external onlyOwner {
        if (staking_ == address(0)) revert ZeroAddress();
        staking = IStaking(staking_);
        emit StakingSet(staking_);
    }

    // ---------------------------------------------------------------------
    // Proposals
    // ---------------------------------------------------------------------

    /// @notice Creates a proposal. The proposer must hold at least
    ///         MIN_WEIGHTED_STAKE_TO_PROPOSE weighted stake.
    function createProposal(
        string calldata title,
        string calldata description,
        ProposalType proposalType,
        bytes calldata payload
    ) external returns (uint32 proposalId) {
        if (staking.weightedStake(msg.sender) < MIN_WEIGHTED_STAKE_TO_PROPOSE) {
            revert InsufficientStakeToPropose();
        }
        if (bytes(title).length > TITLE_MAX) revert TitleTooLong();
        if (bytes(description).length > DESC_MAX) revert DescriptionTooLong();
        if (payload.length > PAYLOAD_MAX) revert PayloadTooLong();

        proposalId = proposalCount;
        Proposal storage proposal = _proposals[proposalId];
        proposal.id = proposalId;
        proposal.proposer = msg.sender;
        proposal.title = title;
        proposal.description = description;
        proposal.proposalType = proposalType;
        proposal.payload = payload;
        proposal.status = ProposalStatus.Active;
        proposal.createdAt = uint64(block.timestamp);
        proposal.votingEndsAt = uint64(block.timestamp) + VOTING_PERIOD;
        proposal.executableAt = 0;

        proposalCount = proposalId + 1;

        emit ProposalCreated(proposalId, msg.sender, proposalType);
    }

    /// @notice Casts a vote weighted by the voter's weighted stake at vote time.
    ///         One vote per account per proposal.
    function castVote(uint32 proposalId, VoteChoice vote) external {
        Proposal storage proposal = _requireProposal(proposalId);
        if (proposal.status != ProposalStatus.Active) revert ProposalNotActive();
        if (block.timestamp >= proposal.votingEndsAt) revert VotingEnded();

        if (staking.stakedAmount(msg.sender) == 0) revert NoStakeToVote();
        uint256 votingPower = staking.weightedStake(msg.sender);

        VoteRecord storage voteRecord = _voteRecords[proposalId][msg.sender];
        if (voteRecord.votedAt != 0) revert AlreadyVoted();
        voteRecord.voter = msg.sender;
        voteRecord.proposalId = proposalId;
        voteRecord.vote = vote;
        voteRecord.votingPower = votingPower;
        voteRecord.votedAt = uint64(block.timestamp);

        if (vote == VoteChoice.Yes) {
            proposal.yesVotes += votingPower;
        } else if (vote == VoteChoice.No) {
            proposal.noVotes += votingPower;
        } else {
            proposal.abstainVotes += votingPower;
        }

        emit VoteCast(proposalId, msg.sender, vote, votingPower);
    }

    /// @notice Finalizes a proposal after its voting period: Passed when both
    ///         quorum and approval thresholds are met, Rejected otherwise.
    function finalizeProposal(uint32 proposalId) external {
        Proposal storage proposal = _requireProposal(proposalId);
        if (proposal.status != ProposalStatus.Active) revert ProposalNotActive();
        if (block.timestamp < proposal.votingEndsAt) revert VotingNotEnded();

        uint256 totalVotes = proposal.yesVotes + proposal.noVotes + proposal.abstainVotes;
        bool quorumReached = totalVotes >= QUORUM_THRESHOLD;

        uint256 contested = proposal.yesVotes + proposal.noVotes;
        bool approvalReached =
            contested > 0 && proposal.yesVotes * APPROVAL_DENOMINATOR >= contested * APPROVAL_NUMERATOR;

        if (quorumReached && approvalReached) {
            proposal.status = ProposalStatus.Passed;
            proposal.executableAt = uint64(block.timestamp) + TIMELOCK_PERIOD;
        } else {
            proposal.status = ProposalStatus.Rejected;
        }

        emit ProposalFinalized(
            proposalId, proposal.status, proposal.yesVotes, proposal.noVotes, quorumReached, approvalReached
        );
    }

    /// @notice Marks a passed proposal as executed once its timelock expires.
    function executeProposal(uint32 proposalId) external {
        Proposal storage proposal = _requireProposal(proposalId);
        if (proposal.status != ProposalStatus.Passed) revert ProposalNotPassed();
        if (block.timestamp < proposal.executableAt) revert TimelockNotExpired();

        proposal.status = ProposalStatus.Executed;

        emit ProposalExecuted(proposalId, proposal.proposalType);
    }

    /// @notice Applies an executed ParameterChange proposal to the parameter
    ///         store. Payload encoding (little-endian, matching the legacy
    ///         format widened to 256-bit values): bytes 0-1 = paramId (uint16 LE),
    ///         bytes 2-33 = newValue (uint256 LE).
    function executeParameterChange(uint32 proposalId) external {
        Proposal storage proposal = _requireProposal(proposalId);
        if (proposal.status != ProposalStatus.Executed) revert ProposalNotExecuted();
        if (proposal.proposalType != ProposalType.ParameterChange) revert WrongProposalType();

        bytes storage p = proposal.payload;
        if (p.length < 34) revert InvalidPayload();

        uint16 paramId = uint16(uint8(p[0])) | (uint16(uint8(p[1])) << 8);
        uint256 newValue;
        for (uint256 i = 0; i < 32; i++) {
            newValue |= uint256(uint8(p[2 + i])) << (8 * i);
        }

        if (paramId == 0) params.jobTimeoutSeconds = newValue;
        else if (paramId == 1) params.disputeWindowSeconds = newValue;
        else if (paramId == 2) params.minWorkerStake = newValue;
        else if (paramId == 3) params.workerBpsBase = newValue;
        else if (paramId == 4) params.workerBpsStaked = newValue;
        else if (paramId == 5) params.minStakeForBonus = newValue;
        else revert UnknownParamId();

        emit ParameterChanged(proposalId, paramId, newValue);
    }

    /// @notice Cancels an active proposal. Only the proposer or the
    ///         governance owner may cancel.
    function cancelProposal(uint32 proposalId) external {
        Proposal storage proposal = _requireProposal(proposalId);
        if (proposal.status != ProposalStatus.Active) revert ProposalNotActive();
        if (msg.sender != proposal.proposer && msg.sender != owner) revert NotAuthorized();

        proposal.status = ProposalStatus.Cancelled;
        emit ProposalCancelled(proposalId);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getProposal(uint32 proposalId) external view returns (Proposal memory) {
        if (proposalId >= proposalCount) revert ProposalIdMismatch();
        return _proposals[proposalId];
    }

    function getVoteRecord(uint32 proposalId, address voter) external view returns (VoteRecord memory) {
        return _voteRecords[proposalId][voter];
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _requireProposal(uint32 proposalId) internal view returns (Proposal storage) {
        if (proposalId >= proposalCount) revert ProposalIdMismatch();
        return _proposals[proposalId];
    }
}
