// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TVDToken}   from "../../src/tvd-token/TVDToken.sol";
import {TVDVesting} from "../../src/tvd-token/TVDVesting.sol";

contract TVDVestingTest is Test {
    TVDToken   public token;
    TVDVesting public vesting;

    address public admin     = makeAddr("admin");
    address public liquidity = makeAddr("liquidity");
    address public treasury  = makeAddr("treasury");
    address public ecosystem = makeAddr("ecosystem");
    address public alice     = makeAddr("alice");   // team beneficiary
    address public bob       = makeAddr("bob");     // another beneficiary
    address public stranger  = makeAddr("stranger");

    uint256 constant VESTING_POOL = 3_150_000e18;

    // Default schedule matching the whitepaper
    uint64 constant CLIFF    = 365 days;
    uint64 constant DURATION = 730 days;

    function setUp() public {
        // Deploy token with treasury absorbing the vesting allocation temporarily.
        // (vestingContract param must be non-zero; treasury acts as placeholder.)
        token = new TVDToken(liquidity, treasury, ecosystem, treasury, admin);

        // Deploy real vesting contract now that we have the token address.
        vesting = new TVDVesting(address(token), admin);

        // Move the vesting pool from treasury into the vesting contract.
        vm.prank(treasury);
        token.transfer(address(vesting), VESTING_POOL);
    }

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    function test_constructor_setsToken() public view {
        assertEq(address(vesting.token()), address(token));
    }

    function test_constructor_setsOwner() public view {
        assertEq(vesting.owner(), admin);
    }

    function test_constructor_revertsOnZeroToken() public {
        vm.expectRevert("TVDVesting: invalid token");
        new TVDVesting(address(0), admin);
    }

    // ──────────────────────────────────────────────────────────────────
    // addBeneficiary
    // ──────────────────────────────────────────────────────────────────

    function test_addBeneficiary_success() public {
        uint256 amount = 1_000e18;
        vm.prank(admin);
        vesting.addBeneficiary(alice, amount, CLIFF, DURATION);

        (uint256 total,,,,, bool revoked) = vesting.schedules(alice);
        assertEq(total, amount);
        assertFalse(revoked);
    }

    function test_addBeneficiary_emitsEvent() public {
        uint256 amount = 1_000e18;
        vm.expectEmit(true, false, false, true);
        emit TVDVesting.BeneficiaryAdded(alice, amount, CLIFF, DURATION);

        vm.prank(admin);
        vesting.addBeneficiary(alice, amount, CLIFF, DURATION);
    }

    function test_addBeneficiary_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        vesting.addBeneficiary(alice, 1_000e18, CLIFF, DURATION);
    }

    function test_addBeneficiary_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("TVDVesting: invalid beneficiary");
        vesting.addBeneficiary(address(0), 1_000e18, CLIFF, DURATION);
    }

    function test_addBeneficiary_revertsZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert("TVDVesting: amount must be > 0");
        vesting.addBeneficiary(alice, 0, CLIFF, DURATION);
    }

    function test_addBeneficiary_revertsZeroVestingDuration() public {
        vm.prank(admin);
        vm.expectRevert("TVDVesting: vesting duration must be > 0");
        vesting.addBeneficiary(alice, 1_000e18, CLIFF, 0);
    }

    function test_addBeneficiary_revertsDuplicate() public {
        vm.startPrank(admin);
        vesting.addBeneficiary(alice, 500e18, CLIFF, DURATION);
        vm.expectRevert("TVDVesting: beneficiary already registered");
        vesting.addBeneficiary(alice, 500e18, CLIFF, DURATION);
        vm.stopPrank();
    }

    function test_addBeneficiary_revertsInsufficientBalance() public {
        vm.prank(admin);
        vm.expectRevert("TVDVesting: insufficient contract balance");
        vesting.addBeneficiary(alice, VESTING_POOL + 1, CLIFF, DURATION);
    }

    // ──────────────────────────────────────────────────────────────────
    // releasable / vestedAmount — cliff behaviour
    // ──────────────────────────────────────────────────────────────────

    function test_releasable_zeroBeforeCliff() public {
        vm.prank(admin);
        vesting.addBeneficiary(alice, 1_000e18, CLIFF, DURATION);

        vm.warp(block.timestamp + CLIFF - 1);
        assertEq(vesting.releasable(alice), 0);
    }

    function test_releasable_zeroAtCliffStart() public {
        vm.prank(admin);
        vesting.addBeneficiary(alice, 1_000e18, CLIFF, DURATION);

        // Exactly at cliff end — 0 seconds post-cliff → still 0
        vm.warp(block.timestamp + CLIFF);
        assertEq(vesting.releasable(alice), 0);
    }

    function test_releasable_partialAfterHalfVesting() public {
        uint256 amount = 1_000e18;
        vm.prank(admin);
        vesting.addBeneficiary(alice, amount, CLIFF, DURATION);

        // Move to cliff end + half of vesting period
        vm.warp(block.timestamp + CLIFF + DURATION / 2);

        uint256 expected = amount / 2;
        assertApproxEqAbs(vesting.releasable(alice), expected, 1e15); // 0.001 TVD tolerance
    }

    function test_releasable_fullAfterVestingComplete() public {
        uint256 amount = 1_000e18;
        vm.prank(admin);
        vesting.addBeneficiary(alice, amount, CLIFF, DURATION);

        vm.warp(block.timestamp + CLIFF + DURATION);
        assertEq(vesting.releasable(alice), amount);
    }

    function test_releasable_zeroForUnregistered() public view {
        assertEq(vesting.releasable(stranger), 0);
    }

    function test_vestedAmount_zeroBeforeCliff() public {
        vm.prank(admin);
        vesting.addBeneficiary(alice, 1_000e18, CLIFF, DURATION);

        assertEq(vesting.vestedAmount(alice), 0);
    }

    function test_vestedAmount_fullAfterVesting() public {
        uint256 amount = 1_000e18;
        vm.prank(admin);
        vesting.addBeneficiary(alice, amount, CLIFF, DURATION);

        vm.warp(block.timestamp + CLIFF + DURATION + 1 days);
        assertEq(vesting.vestedAmount(alice), amount);
    }

    // ──────────────────────────────────────────────────────────────────
    // release
    // ──────────────────────────────────────────────────────────────────

    function test_release_revertsNothingToRelease() public {
        vm.prank(admin);
        vesting.addBeneficiary(alice, 1_000e18, CLIFF, DURATION);

        vm.prank(alice);
        vm.expectRevert("TVDVesting: nothing to release");
        vesting.release();
    }

    function test_release_transfersTokensToBeneficiary() public {
        uint256 amount = 1_000e18;
        vm.prank(admin);
        vesting.addBeneficiary(alice, amount, CLIFF, DURATION);

        vm.warp(block.timestamp + CLIFF + DURATION);

        vm.prank(alice);
        vesting.release();

        assertEq(token.balanceOf(alice), amount);
    }

    function test_release_updatesReleasedAmount() public {
        uint256 amount = 1_200e18;
        vm.prank(admin);
        vesting.addBeneficiary(alice, amount, CLIFF, DURATION);

        vm.warp(block.timestamp + CLIFF + DURATION);

        vm.prank(alice);
        vesting.release();

        (, uint256 released,,,,) = vesting.schedules(alice);
        assertEq(released, amount);
    }

    function test_release_emitsEvent() public {
        uint256 amount = 1_000e18;
        vm.prank(admin);
        vesting.addBeneficiary(alice, amount, CLIFF, DURATION);

        vm.warp(block.timestamp + CLIFF + DURATION);

        vm.expectEmit(true, false, false, true);
        emit TVDVesting.TokensReleased(alice, amount);

        vm.prank(alice);
        vesting.release();
    }

    function test_release_partial_thenFull() public {
        uint256 amount = 1_200e18;
        vm.prank(admin);
        vesting.addBeneficiary(alice, amount, CLIFF, DURATION);

        // First release at half vesting
        vm.warp(block.timestamp + CLIFF + DURATION / 2);
        vm.prank(alice);
        vesting.release();
        uint256 firstRelease = token.balanceOf(alice);
        assertGt(firstRelease, 0);

        // Second release at full vesting
        vm.warp(block.timestamp + DURATION / 2);
        vm.prank(alice);
        vesting.release();
        assertApproxEqAbs(token.balanceOf(alice), amount, 1e15);
    }

    // ──────────────────────────────────────────────────────────────────
    // releaseFor
    // ──────────────────────────────────────────────────────────────────

    function test_releaseFor_byOwner() public {
        uint256 amount = 500e18;
        vm.prank(admin);
        vesting.addBeneficiary(alice, amount, CLIFF, DURATION);

        vm.warp(block.timestamp + CLIFF + DURATION);

        vm.prank(admin);
        vesting.releaseFor(alice);

        assertEq(token.balanceOf(alice), amount);
    }

    function test_releaseFor_byBeneficiary() public {
        uint256 amount = 500e18;
        vm.prank(admin);
        vesting.addBeneficiary(alice, amount, CLIFF, DURATION);

        vm.warp(block.timestamp + CLIFF + DURATION);

        vm.prank(alice);
        vesting.releaseFor(alice);

        assertEq(token.balanceOf(alice), amount);
    }

    function test_releaseFor_revertsUnauthorized() public {
        uint256 amount = 500e18;
        vm.prank(admin);
        vesting.addBeneficiary(alice, amount, CLIFF, DURATION);

        vm.warp(block.timestamp + CLIFF + DURATION);

        vm.prank(stranger);
        vm.expectRevert("TVDVesting: unauthorized");
        vesting.releaseFor(alice);
    }

    // ──────────────────────────────────────────────────────────────────
    // revoke
    // ──────────────────────────────────────────────────────────────────

    function test_revoke_unvestedStaysInContract() public {
        uint256 amount = 1_000e18;
        vm.prank(admin);
        vesting.addBeneficiary(alice, amount, CLIFF, DURATION);

        uint256 contractBalBefore = token.balanceOf(address(vesting));

        // Revoke before cliff ends — full amount is unvested
        vm.prank(admin);
        vesting.revoke(alice);

        // Unvested tokens remain in the vesting contract (not sent anywhere)
        assertEq(token.balanceOf(address(vesting)), contractBalBefore);
        assertEq(token.balanceOf(admin), 0);
    }

    function test_revoke_releaseEarnedPortionFirst() public {
        uint256 amount = 1_000e18;
        vm.prank(admin);
        vesting.addBeneficiary(alice, amount, CLIFF, DURATION);

        // Warp to halfway through vesting
        vm.warp(block.timestamp + CLIFF + DURATION / 2);

        uint256 expectedVested = amount / 2;
        uint256 contractBalBefore = token.balanceOf(address(vesting));

        vm.prank(admin);
        vesting.revoke(alice);

        // Alice receives her vested portion
        assertApproxEqAbs(token.balanceOf(alice), expectedVested, 1e15);
        // Unvested remainder stays in the contract
        assertApproxEqAbs(
            token.balanceOf(address(vesting)),
            contractBalBefore - expectedVested,
            1e15
        );
    }

    function test_revoke_marksScheduleRevoked() public {
        vm.prank(admin);
        vesting.addBeneficiary(alice, 1_000e18, CLIFF, DURATION);

        vm.prank(admin);
        vesting.revoke(alice);

        (,,,,, bool revoked) = vesting.schedules(alice);
        assertTrue(revoked);
    }

    function test_revoke_revertsAlreadyRevoked() public {
        vm.prank(admin);
        vesting.addBeneficiary(alice, 1_000e18, CLIFF, DURATION);

        vm.startPrank(admin);
        vesting.revoke(alice);
        vm.expectRevert("TVDVesting: schedule already revoked");
        vesting.revoke(alice);
        vm.stopPrank();
    }

    function test_revoke_revertsNotFound() public {
        vm.prank(admin);
        vm.expectRevert("TVDVesting: beneficiary not found");
        vesting.revoke(stranger);
    }

    function test_revoke_revertsNotOwner() public {
        vm.prank(admin);
        vesting.addBeneficiary(alice, 1_000e18, CLIFF, DURATION);

        vm.prank(stranger);
        vm.expectRevert();
        vesting.revoke(alice);
    }

    function test_revoke_releasable_zeroAfterRevoke() public {
        vm.prank(admin);
        vesting.addBeneficiary(alice, 1_000e18, CLIFF, DURATION);

        vm.prank(admin);
        vesting.revoke(alice);

        vm.warp(block.timestamp + CLIFF + DURATION);
        assertEq(vesting.releasable(alice), 0);
    }

    // ──────────────────────────────────────────────────────────────────
    // getBeneficiaries
    // ──────────────────────────────────────────────────────────────────

    function test_getBeneficiaries_returnsAll() public {
        vm.startPrank(admin);
        vesting.addBeneficiary(alice, 500e18, CLIFF, DURATION);
        vesting.addBeneficiary(bob,   500e18, CLIFF, DURATION);
        vm.stopPrank();

        address[] memory beneficiaries = vesting.getBeneficiaries();
        assertEq(beneficiaries.length, 2);
        assertEq(beneficiaries[0], alice);
        assertEq(beneficiaries[1], bob);
    }
}
