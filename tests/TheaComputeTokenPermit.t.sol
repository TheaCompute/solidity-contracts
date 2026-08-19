// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {TheaComputeToken} from "../src/TheaComputeToken.sol";

contract TheaComputeTokenPermitTest is Test {
    TheaComputeToken internal token;

    uint256 internal constant OWNER_PK = 0xA11CE;
    address internal owner;
    address internal constant SPENDER = address(0xBEEF);

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        owner = vm.addr(OWNER_PK);
        token = new TheaComputeToken(address(this));
    }

    function _sign(uint256 pk, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, SPENDER, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    function test_PermitSetsAllowanceAndBumpsNonce() public {
        uint256 value = 1_000e18;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(OWNER_PK, value, 0, deadline);

        token.permit(owner, SPENDER, value, deadline, v, r, s);

        assertEq(token.allowance(owner, SPENDER), value);
        assertEq(token.nonces(owner), 1);
    }

    function test_PermitEnablesTransferFrom() public {
        // Fund the owner, then permit + pull in the spender's flow.
        token.transfer(owner, 500e18);

        uint256 value = 500e18;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(OWNER_PK, value, 0, deadline);

        token.permit(owner, SPENDER, value, deadline, v, r, s);

        vm.prank(SPENDER);
        token.transferFrom(owner, SPENDER, value);
        assertEq(token.balanceOf(SPENDER), value);
    }

    function test_PermitExpiredReverts() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _sign(OWNER_PK, 1e18, 0, deadline);

        vm.expectRevert(TheaComputeToken.PermitExpired.selector);
        token.permit(owner, SPENDER, 1e18, deadline, v, r, s);
    }

    function test_PermitWrongSignerReverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(0xB0B, 1e18, 0, deadline); // not the owner's key

        vm.expectRevert(TheaComputeToken.InvalidSigner.selector);
        token.permit(owner, SPENDER, 1e18, deadline, v, r, s);
    }

    function test_PermitReplayReverts() public {
        uint256 value = 5e18;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(OWNER_PK, value, 0, deadline);

        token.permit(owner, SPENDER, value, deadline, v, r, s);

        // The nonce has advanced, so the same signature no longer recovers to owner.
        vm.expectRevert(TheaComputeToken.InvalidSigner.selector);
        token.permit(owner, SPENDER, value, deadline, v, r, s);
    }
}
