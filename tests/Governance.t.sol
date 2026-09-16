// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Governance} from "../src/Governance.sol";
import {Ownable} from "../src/Ownable.sol";
import {IStaking} from "../src/interfaces/IStaking.sol";

/// @notice Minimal staking mock exposing settable stake weights for
///         governance tests. Only the views Governance reads are meaningful.
contract GovernanceStakingMock is IStaking {
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

/// @notice Tests for the Governance contract.
///
/// Covers: state initialization, proposal creation (with and without
/// sufficient stake), voting, finalization (passed and rejected paths),
/// timelock enforcement, parameter-change execution, and cancellation.
contract GovernanceTest is Test {
    Governance internal gov;
    GovernanceStakingMock internal staking;

    address internal proposer = makeAddr("proposer");
    address internal voter = makeAddr("voter");
    address internal whale = makeAddr("whale");
    address internal nobody = makeAddr("nobody");

    function setUp() public {
        staking = new GovernanceStakingMock();
        gov = new Governance();
        gov.setStaking(address(staking));

        // Proposer holds 15,000 $THEA at the 90-day tier (1.25x).
        staking.setStake(proposer, 15_000e18, 18_750e18);
        // Voter holds 3,000 $THEA at the 90-day tier (1.25x).
        staking.setStake(voter, 3_000e18, 3_750e18);
        // Whale holds enough weighted stake to clear quorum alone.
        staking.setStake(whale, 60_000_000e18, 60_000_000e18);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _paramChangePayload(uint16 paramId, uint256 newValue) internal pure returns (bytes memory p) {
        // Little-endian: bytes 0-1 = paramId, bytes 2-33 = newValue.
        p = new bytes(34);
        p[0] = bytes1(uint8(paramId));
        p[1] = bytes1(uint8(paramId >> 8));
        for (uint256 i = 0; i < 32; i++) {
            p[2 + i] = bytes1(uint8(newValue >> (8 * i)));
        }
    }

    function _createParameterChangeProposal() internal returns (uint32 id) {
        vm.prank(proposer);
        id = gov.createProposal(
            "Reduce dispute window to 30s",
            "The current 60-second dispute window creates unnecessary latency for honest workers. Reducing it to 30s cuts median settlement time while preserving adequate dispute coverage.",
            Governance.ProposalType.ParameterChange,
            _paramChangePayload(1, 30)
        );
    }

    // ------------------------------------------------------------------
    // Initialization
    // ------------------------------------------------------------------

    function test_InitializesGovernanceState() public view {
        assertEq(gov.proposalCount(), 0);
        assertEq(gov.owner(), address(this));
    }

    function test_InitializesDefaultParams() public view {
        (
            uint256 jobTimeoutSeconds,
            uint256 disputeWindowSeconds,
            uint256 minWorkerStake,
            uint256 workerBpsBase,
            uint256 workerBpsStaked,
            uint256 minStakeForBonus
        ) = gov.params();
        assertEq(jobTimeoutSeconds, 120);
        assertEq(disputeWindowSeconds, 60);
        assertEq(minWorkerStake, 1_000e18);
        assertEq(workerBpsBase, 7_500);
        assertEq(workerBpsStaked, 8_500);
        assertEq(minStakeForBonus, 1_000e18);
    }

    // ------------------------------------------------------------------
    // Proposal creation
    // ------------------------------------------------------------------

    function test_CreatesParameterChangeProposal() public {
        uint32 id = _createParameterChangeProposal();

        assertEq(gov.proposalCount(), 1);

        Governance.Proposal memory prop = gov.getProposal(id);
        assertEq(prop.id, 0);
        assertEq(prop.proposer, proposer);
        assertEq(prop.title, "Reduce dispute window to 30s");
        assertEq(uint8(prop.status), uint8(Governance.ProposalStatus.Active));
        assertEq(prop.yesVotes, 0);
        assertEq(prop.votingEndsAt, uint64(block.timestamp) + gov.VOTING_PERIOD());
    }

    function test_CreatesModelCurationProposal() public {
        vm.prank(proposer);
        uint32 id = gov.createProposal(
            "Add Llama-3.3-70B to approved set",
            "Llama-3.3-70B has cleared our safety benchmarks. This proposal adds it to the Max tier approved model set.",
            Governance.ProposalType.ModelCuration,
            bytes('{"action":"add","model":"meta-llama/Llama-3.3-70B-Instruct","tier":"Max"}')
        );

        Governance.Proposal memory prop = gov.getProposal(id);
        assertEq(uint8(prop.proposalType), uint8(Governance.ProposalType.ModelCuration));
    }

    function test_RejectsProposalWithoutSufficientStake() public {
        // 5,000 weighted stake is below the 10,000e18 threshold.
        staking.setStake(nobody, 5_000e18, 5_000e18);
        vm.prank(nobody);
        vm.expectRevert(Governance.InsufficientStakeToPropose.selector);
        gov.createProposal("Should fail", "Proposer lacks stake.", Governance.ProposalType.TreasurySpend, "");
    }

    function test_RejectsOversizedTitle() public {
        string memory longTitle = new string(65);
        vm.prank(proposer);
        vm.expectRevert(Governance.TitleTooLong.selector);
        gov.createProposal(longTitle, "desc", Governance.ProposalType.ParameterChange, "");
    }

    function test_RejectsOversizedPayload() public {
        bytes memory bigPayload = new bytes(129);
        vm.prank(proposer);
        vm.expectRevert(Governance.PayloadTooLong.selector);
        gov.createProposal("Title", "desc", Governance.ProposalType.ParameterChange, bigPayload);
    }

    // ------------------------------------------------------------------
    // Voting
    // ------------------------------------------------------------------

    function test_CastsYesVote() public {
        uint32 id = _createParameterChangeProposal();

        vm.prank(voter);
        gov.castVote(id, Governance.VoteChoice.Yes);

        Governance.Proposal memory prop = gov.getProposal(id);
        assertGt(prop.yesVotes, 0);
        assertEq(prop.yesVotes, 3_750e18);

        Governance.VoteRecord memory record = gov.getVoteRecord(id, voter);
        assertEq(uint8(record.vote), uint8(Governance.VoteChoice.Yes));
        assertEq(record.voter, voter);
        assertEq(record.votingPower, 3_750e18);
    }

    function test_RejectsDuplicateVoteFromSameAccount() public {
        uint32 id = _createParameterChangeProposal();

        vm.prank(voter);
        gov.castVote(id, Governance.VoteChoice.Yes);

        vm.prank(voter);
        vm.expectRevert(Governance.AlreadyVoted.selector);
        gov.castVote(id, Governance.VoteChoice.No);
    }

    function test_RejectsVoteWithZeroStake() public {
        uint32 id = _createParameterChangeProposal();

        vm.prank(nobody);
        vm.expectRevert(Governance.NoStakeToVote.selector);
        gov.castVote(id, Governance.VoteChoice.Yes);
    }

    function test_RejectsVoteAfterVotingEnds() public {
        uint32 id = _createParameterChangeProposal();

        vm.warp(block.timestamp + 7 days);
        vm.prank(voter);
        vm.expectRevert(Governance.VotingEnded.selector);
        gov.castVote(id, Governance.VoteChoice.Yes);
    }

    function test_RejectsVoteOnUnknownProposal() public {
        vm.prank(voter);
        vm.expectRevert(Governance.ProposalIdMismatch.selector);
        gov.castVote(42, Governance.VoteChoice.Yes);
    }

    // ------------------------------------------------------------------
    // Finalization
    // ------------------------------------------------------------------

    function test_ProposalStaysActiveBeforeVotingEnds() public {
        uint32 id = _createParameterChangeProposal();

        Governance.Proposal memory prop = gov.getProposal(id);
        assertEq(uint8(prop.status), uint8(Governance.ProposalStatus.Active));

        vm.expectRevert(Governance.VotingNotEnded.selector);
        gov.finalizeProposal(id);
    }

    function test_FinalizesRejectedProposalBelowQuorum() public {
        // Total voting weight here is well below the 50M $THEA quorum,
        // so the proposal is rejected even with 100% yes.
        uint32 id = _createParameterChangeProposal();

        vm.prank(voter);
        gov.castVote(id, Governance.VoteChoice.Yes);

        vm.warp(block.timestamp + 7 days);
        gov.finalizeProposal(id);

        Governance.Proposal memory prop = gov.getProposal(id);
        assertEq(uint8(prop.status), uint8(Governance.ProposalStatus.Rejected));
        assertEq(prop.executableAt, 0);
    }

    function test_FinalizesRejectedProposalBelowApproval() public {
        // Quorum is met via abstain + contested votes, but yes share of the
        // contested vote is below 60%.
        uint32 id = _createParameterChangeProposal();

        staking.setStake(nobody, 60_000_000e18, 60_000_000e18);
        vm.prank(whale);
        gov.castVote(id, Governance.VoteChoice.No);
        vm.prank(nobody);
        gov.castVote(id, Governance.VoteChoice.Yes);
        // yes = 60M, no = 60M → 50% yes < 60% approval threshold.

        vm.warp(block.timestamp + 7 days);
        gov.finalizeProposal(id);

        Governance.Proposal memory prop = gov.getProposal(id);
        assertEq(uint8(prop.status), uint8(Governance.ProposalStatus.Rejected));
    }

    function test_FinalizesPassedProposal() public {
        uint32 id = _createParameterChangeProposal();

        vm.prank(whale);
        gov.castVote(id, Governance.VoteChoice.Yes);

        vm.warp(block.timestamp + 7 days);
        gov.finalizeProposal(id);

        Governance.Proposal memory prop = gov.getProposal(id);
        assertEq(uint8(prop.status), uint8(Governance.ProposalStatus.Passed));
        assertEq(prop.executableAt, uint64(block.timestamp) + gov.TIMELOCK_PERIOD());
    }

    // ------------------------------------------------------------------
    // Execution and timelock
    // ------------------------------------------------------------------

    function _passProposal(uint32 id) internal {
        vm.prank(whale);
        gov.castVote(id, Governance.VoteChoice.Yes);
        vm.warp(block.timestamp + 7 days);
        gov.finalizeProposal(id);
    }

    function test_EnforcesTimelockBeforeExecution() public {
        uint32 id = _createParameterChangeProposal();
        _passProposal(id);

        vm.expectRevert(Governance.TimelockNotExpired.selector);
        gov.executeProposal(id);
    }

    function test_ExecutesPassedProposalAfterTimelock() public {
        uint32 id = _createParameterChangeProposal();
        _passProposal(id);

        vm.warp(block.timestamp + 2 days);
        gov.executeProposal(id);

        Governance.Proposal memory prop = gov.getProposal(id);
        assertEq(uint8(prop.status), uint8(Governance.ProposalStatus.Executed));
    }

    function test_RejectsExecutingUnpassedProposal() public {
        uint32 id = _createParameterChangeProposal();
        vm.expectRevert(Governance.ProposalNotPassed.selector);
        gov.executeProposal(id);
    }

    function test_ExecutesParameterChange() public {
        uint32 id = _createParameterChangeProposal();
        _passProposal(id);
        vm.warp(block.timestamp + 2 days);
        gov.executeProposal(id);

        gov.executeParameterChange(id);

        (, uint256 disputeWindowSeconds,,,,) = gov.params();
        assertEq(disputeWindowSeconds, 30);
    }

    function test_RejectsParameterChangeBeforeExecution() public {
        uint32 id = _createParameterChangeProposal();
        vm.expectRevert(Governance.ProposalNotExecuted.selector);
        gov.executeParameterChange(id);
    }

    function test_RejectsParameterChangeOnWrongType() public {
        vm.prank(proposer);
        uint32 id = gov.createProposal(
            "Curation only", "Not a parameter change.", Governance.ProposalType.ModelCuration, ""
        );
        _passProposal(id);
        vm.warp(block.timestamp + 2 days);
        gov.executeProposal(id);

        vm.expectRevert(Governance.WrongProposalType.selector);
        gov.executeParameterChange(id);
    }

    function test_RejectsUnknownParamId() public {
        vm.prank(proposer);
        uint32 id = gov.createProposal(
            "Bad param id", "Payload targets a nonexistent parameter.",
            Governance.ProposalType.ParameterChange,
            _paramChangePayload(9, 1)
        );
        _passProposal(id);
        vm.warp(block.timestamp + 2 days);
        gov.executeProposal(id);

        vm.expectRevert(Governance.UnknownParamId.selector);
        gov.executeParameterChange(id);
    }

    // ------------------------------------------------------------------
    // Cancellation
    // ------------------------------------------------------------------

    function test_CancelsProposalAsProposer() public {
        vm.prank(proposer);
        uint32 id = gov.createProposal(
            "Test proposal to cancel",
            "This proposal will be cancelled immediately to test cancellation.",
            Governance.ProposalType.ParameterChange,
            bytes("{}")
        );

        vm.prank(proposer);
        gov.cancelProposal(id);

        Governance.Proposal memory prop = gov.getProposal(id);
        assertEq(uint8(prop.status), uint8(Governance.ProposalStatus.Cancelled));
    }

    function test_CancelsProposalAsGovernanceOwner() public {
        uint32 id = _createParameterChangeProposal();

        // Test contract is the owner.
        gov.cancelProposal(id);

        Governance.Proposal memory prop = gov.getProposal(id);
        assertEq(uint8(prop.status), uint8(Governance.ProposalStatus.Cancelled));
    }

    function test_RejectsCancelFromUnauthorizedAccount() public {
        uint32 id = _createParameterChangeProposal();

        vm.prank(nobody);
        vm.expectRevert(Governance.NotAuthorized.selector);
        gov.cancelProposal(id);
    }

    function test_RejectsCancellingNonActiveProposal() public {
        uint32 id = _createParameterChangeProposal();
        vm.prank(proposer);
        gov.cancelProposal(id);

        vm.prank(proposer);
        vm.expectRevert(Governance.ProposalNotActive.selector);
        gov.cancelProposal(id);
    }

    // ------------------------------------------------------------------
    // Ownership
    // ------------------------------------------------------------------

    function test_OwnershipHandoverMovesCancelRights() public {
        address multisig = makeAddr("multisig");
        gov.transferOwnership(multisig);
        vm.prank(multisig);
        gov.acceptOwnership();

        uint32 id = _createParameterChangeProposal();

        // The deployer that handed ownership over is now just another account.
        vm.expectRevert(Governance.NotAuthorized.selector);
        gov.cancelProposal(id);

        vm.prank(multisig);
        gov.cancelProposal(id);

        Governance.Proposal memory prop = gov.getProposal(id);
        assertEq(uint8(prop.status), uint8(Governance.ProposalStatus.Cancelled));
    }

    function test_RejectsWiringFromNonOwner() public {
        vm.prank(nobody);
        vm.expectRevert(Ownable.Unauthorized.selector);
        gov.setStaking(address(staking));
    }
}
