// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "../src/Ownable.sol";

/// @notice Concrete stand-in for the abstract base, with one owner-gated call.
contract OwnableHarness is Ownable {
    uint256 public value;

    function setValue(uint256 value_) external onlyOwner {
        value = value_;
    }
}

/// @notice Tests for the shared two-step ownership base.
///
/// Covers: the deployer starting as owner, nomination not moving ownership on its
/// own, acceptance by the nominee only, cancellation, and the owner-only gate
/// following ownership across a handover.
contract OwnableTest is Test {
    OwnableHarness harness;

    address newOwner = makeAddr("newOwner");
    address stranger = makeAddr("stranger");

    event OwnershipTransferStarted(address indexed currentOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        harness = new OwnableHarness();
    }

    function test_DeployerIsOwner() public view {
        assertEq(harness.owner(), address(this));
        assertEq(harness.pendingOwner(), address(0));
    }

    function test_TransferOwnershipOnlyNominates() public {
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferStarted(address(this), newOwner);
        harness.transferOwnership(newOwner);

        assertEq(harness.pendingOwner(), newOwner);
        assertEq(harness.owner(), address(this), "owner moves only on acceptance");

        // The outgoing owner keeps its powers until the handover completes.
        harness.setValue(1);
        assertEq(harness.value(), 1);
    }

    function test_AcceptOwnershipCompletesHandover() public {
        harness.transferOwnership(newOwner);

        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(address(this), newOwner);
        vm.prank(newOwner);
        harness.acceptOwnership();

        assertEq(harness.owner(), newOwner);
        assertEq(harness.pendingOwner(), address(0));

        vm.prank(newOwner);
        harness.setValue(7);
        assertEq(harness.value(), 7);
    }

    function test_PreviousOwnerLosesAccessAfterHandover() public {
        harness.transferOwnership(newOwner);
        vm.prank(newOwner);
        harness.acceptOwnership();

        vm.expectRevert(Ownable.Unauthorized.selector);
        harness.setValue(1);
    }

    function test_CancelOwnershipTransferClearsNomination() public {
        harness.transferOwnership(newOwner);
        harness.cancelOwnershipTransfer();

        assertEq(harness.pendingOwner(), address(0));

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(newOwner);
        harness.acceptOwnership();
    }

    function test_RevertWhen_TransferToZeroAddress() public {
        vm.expectRevert(Ownable.ZeroAddress.selector);
        harness.transferOwnership(address(0));
    }

    function test_RevertWhen_TransferByNonOwner() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(stranger);
        harness.transferOwnership(stranger);
    }

    function test_RevertWhen_AcceptByNonNominee() public {
        harness.transferOwnership(newOwner);

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(stranger);
        harness.acceptOwnership();
    }

    function test_RevertWhen_AcceptWithNoNomination() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(stranger);
        harness.acceptOwnership();
    }
}
