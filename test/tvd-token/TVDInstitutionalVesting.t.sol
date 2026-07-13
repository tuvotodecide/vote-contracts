// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TVDToken} from "../../src/tvd-token/TVDToken.sol";
import {TVDInstitutionalVesting} from "../../src/tvd-token/TVDInstitutionalVesting.sol";

contract TVDInstitutionalVestingTest is Test {
    TVDToken public token;
    TVDInstitutionalVesting public vesting;

    address public admin = makeAddr("admin");
    address public liquidity = makeAddr("liquidity");
    address public treasury = makeAddr("treasury");
    address public ecosystem = makeAddr("ecosystem");
    address public vestingAddr = makeAddr("vesting");
    address public operator = makeAddr("operator");
    address public creditsContract = makeAddr("creditsContract");
    address public institution = makeAddr("institution");
    address public institution2 = makeAddr("institution2");
    address public stranger = makeAddr("stranger");

    uint256 public startTime;
    uint256 constant FUNDING = 100_000e18;

    function setUp() public {
        token = new TVDToken(liquidity, treasury, ecosystem, vestingAddr, admin);

        startTime = block.timestamp;
        // admin is both owner and operator here so setCreditsContract() (which
        // requires both) can be exercised directly in setUp; a dedicated
        // `operator` address is used below for assign()/setOperator() checks.
        vesting = new TVDInstitutionalVesting(address(token), admin, admin, startTime);

        vm.prank(treasury);
        token.transfer(address(vesting), FUNDING);

        vm.prank(admin);
        vesting.setCreditsContract(creditsContract);

        vm.prank(admin);
        vesting.setOperator(operator);
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

    function test_constructor_setsOperator() public view {
        assertEq(vesting.operator(), operator);
    }

    function test_constructor_setsStartTime() public view {
        assertEq(vesting.startTime(), startTime);
    }

    function test_constructor_defaultDuration() public view {
        assertEq(vesting.duration(), 365 days);
    }

    function test_constructor_revertsZeroToken() public {
        vm.expectRevert("TVDInstVesting: invalid token");
        new TVDInstitutionalVesting(address(0), admin, operator, startTime);
    }

    function test_constructor_revertsZeroStartTime() public {
        vm.expectRevert("TVDInstVesting: invalid startTime");
        new TVDInstitutionalVesting(address(token), admin, operator, 0);
    }

    function test_constructor_revertsZeroOperator() public {
        vm.expectRevert("TVDInstVesting: invalid operator");
        new TVDInstitutionalVesting(address(token), admin, address(0), startTime);
    }

    // ──────────────────────────────────────────────────────────────────
    // setOperator
    // ──────────────────────────────────────────────────────────────────

    function test_setOperator_success() public {
        address newOperator = makeAddr("newOperator");
        vm.prank(admin);
        vesting.setOperator(newOperator);
        assertEq(vesting.operator(), newOperator);
    }

    function test_setOperator_emitsEvent() public {
        address newOperator = makeAddr("newOperator");
        vm.expectEmit(true, true, false, false);
        emit TVDInstitutionalVesting.OperatorSet(operator, newOperator);
        vm.prank(admin);
        vesting.setOperator(newOperator);
    }

    function test_setOperator_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        vesting.setOperator(stranger);
    }

    function test_setOperator_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("TVDInstVesting: invalid operator");
        vesting.setOperator(address(0));
    }

    // ──────────────────────────────────────────────────────────────────
    // setCreditsContract — requires caller to be BOTH owner and operator
    // ──────────────────────────────────────────────────────────────────

    function test_setCreditsContract_revertsOperatorOnly() public {
        vm.prank(operator);
        vm.expectRevert();
        vesting.setCreditsContract(makeAddr("other"));
    }

    function test_setCreditsContract_revertsOwnerOnlyWhenNotOperator() public {
        // admin is owner but not operator in this setup
        vm.prank(admin);
        vm.expectRevert("TVDInstVesting: caller is not operator");
        vesting.setCreditsContract(makeAddr("other"));
    }

    function test_setCreditsContract_successWhenOwnerAndOperator() public {
        TVDInstitutionalVesting v2 = new TVDInstitutionalVesting(address(token), admin, admin, startTime);
        vm.prank(admin);
        v2.setCreditsContract(creditsContract);
        assertEq(v2.creditsContract(), creditsContract);
    }

    function test_setCreditsContract_revertsZeroAddress() public {
        TVDInstitutionalVesting v2 = new TVDInstitutionalVesting(address(token), admin, admin, startTime);
        vm.prank(admin);
        vm.expectRevert("TVDInstVesting: invalid address");
        v2.setCreditsContract(address(0));
    }

    // ──────────────────────────────────────────────────────────────────
    // setDuration
    // ──────────────────────────────────────────────────────────────────

    function test_setDuration_success() public {
        vm.prank(admin);
        vesting.setDuration(30 days);
        assertEq(vesting.duration(), 30 days);
    }

    function test_setDuration_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert("TVDInstVesting: duration must be > 0");
        vesting.setDuration(0);
    }

    function test_setDuration_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        vesting.setDuration(30 days);
    }

    // ──────────────────────────────────────────────────────────────────
    // assign
    // ──────────────────────────────────────────────────────────────────

    function test_assign_success() public {
        uint256 amount = 1_000e18;
        vm.prank(operator);
        vesting.assign(institution, amount);

        assertEq(vesting.assignedBalance(institution), amount);
        assertEq(vesting.totalAssigned(), amount);
    }

    function test_assign_emitsEvent() public {
        uint256 amount = 1_000e18;
        vm.expectEmit(true, false, false, true);
        emit TVDInstitutionalVesting.TokensAssigned(institution, amount);
        vm.prank(operator);
        vesting.assign(institution, amount);
    }

    function test_assign_accumulates() public {
        vm.startPrank(operator);
        vesting.assign(institution, 1_000e18);
        vesting.assign(institution, 500e18);
        vm.stopPrank();

        assertEq(vesting.assignedBalance(institution), 1_500e18);
        assertEq(vesting.totalAssigned(), 1_500e18);
    }

    function test_assign_revertsNotOperator() public {
        vm.prank(admin);
        vm.expectRevert("TVDInstVesting: caller is not operator");
        vesting.assign(institution, 1_000e18);
    }

    function test_assign_revertsZeroInstitution() public {
        vm.prank(operator);
        vm.expectRevert("TVDInstVesting: invalid institution");
        vesting.assign(address(0), 1_000e18);
    }

    function test_assign_revertsZeroAmount() public {
        vm.prank(operator);
        vm.expectRevert("TVDInstVesting: amount must be > 0");
        vesting.assign(institution, 0);
    }

    function test_assign_revertsExceedsBalance() public {
        vm.prank(operator);
        vm.expectRevert("TVDInstVesting: insufficient contract balance");
        vesting.assign(institution, FUNDING + 1);
    }

    // ──────────────────────────────────────────────────────────────────
    // withdrawFor
    // ──────────────────────────────────────────────────────────────────

    function test_withdrawFor_success() public {
        uint256 amount = 1_000e18;
        vm.prank(operator);
        vesting.assign(institution, amount);

        vm.prank(creditsContract);
        vesting.withdrawFor(institution, amount);

        assertEq(token.balanceOf(creditsContract), amount);
        assertEq(vesting.assignedBalance(institution), 0);
        assertEq(vesting.totalAssigned(), 0);
    }

    function test_withdrawFor_partial() public {
        uint256 amount = 1_000e18;
        vm.prank(operator);
        vesting.assign(institution, amount);

        vm.prank(creditsContract);
        vesting.withdrawFor(institution, 400e18);

        assertEq(vesting.assignedBalance(institution), 600e18);
        assertEq(vesting.totalAssigned(), 600e18);
    }

    function test_withdrawFor_emitsEvent() public {
        uint256 amount = 1_000e18;
        vm.prank(operator);
        vesting.assign(institution, amount);

        vm.expectEmit(true, false, false, true);
        emit TVDInstitutionalVesting.TokensWithdrawn(institution, amount);
        vm.prank(creditsContract);
        vesting.withdrawFor(institution, amount);
    }

    function test_withdrawFor_revertsNotCreditsContract() public {
        vm.prank(operator);
        vesting.assign(institution, 1_000e18);

        vm.prank(stranger);
        vm.expectRevert("TVDInstVesting: caller is not credits contract");
        vesting.withdrawFor(institution, 1_000e18);
    }

    function test_withdrawFor_revertsInsufficientBalance() public {
        vm.prank(operator);
        vesting.assign(institution, 500e18);

        vm.prank(creditsContract);
        vm.expectRevert("TVDInstVesting: insufficient balance");
        vesting.withdrawFor(institution, 1_000e18);
    }

    // ──────────────────────────────────────────────────────────────────
    // creditRefund
    // ──────────────────────────────────────────────────────────────────

    function test_creditRefund_success() public {
        uint256 amount = 1_000e18;
        vm.prank(operator);
        vesting.assign(institution, amount);

        vm.prank(creditsContract);
        vesting.withdrawFor(institution, amount);

        // Simulate TVDElectoralCredits transferring tokens back before crediting.
        vm.prank(creditsContract);
        token.transfer(address(vesting), amount);

        vm.prank(creditsContract);
        vesting.creditRefund(institution, amount);

        assertEq(vesting.assignedBalance(institution), amount);
        assertEq(vesting.totalAssigned(), amount);
    }

    function test_creditRefund_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit TVDInstitutionalVesting.TokensRefunded(institution, 500e18);
        vm.prank(creditsContract);
        vesting.creditRefund(institution, 500e18);
    }

    function test_creditRefund_revertsNotCreditsContract() public {
        vm.prank(stranger);
        vm.expectRevert("TVDInstVesting: caller is not credits contract");
        vesting.creditRefund(institution, 500e18);
    }

    function test_creditRefund_revertsZeroInstitution() public {
        vm.prank(creditsContract);
        vm.expectRevert("TVDInstVesting: invalid institution");
        vesting.creditRefund(address(0), 500e18);
    }

    // ──────────────────────────────────────────────────────────────────
    // release
    // ──────────────────────────────────────────────────────────────────

    function test_release_revertsWhileLocked() public {
        vm.prank(operator);
        vesting.assign(institution, 1_000e18);

        vm.prank(institution);
        vm.expectRevert("TVDInstVesting: tokens are still locked");
        vesting.release();
    }

    function test_release_revertsZeroBalance() public {
        vm.warp(startTime + 365 days);

        vm.prank(institution);
        vm.expectRevert("TVDInstVesting: no tokens to release");
        vesting.release();
    }

    function test_release_success() public {
        uint256 amount = 1_000e18;
        vm.prank(operator);
        vesting.assign(institution, amount);

        vm.warp(startTime + 365 days);

        vm.prank(institution);
        vesting.release();

        assertEq(token.balanceOf(institution), amount);
        assertEq(vesting.assignedBalance(institution), 0);
        assertEq(vesting.totalAssigned(), 0);
    }

    function test_release_emitsEvent() public {
        uint256 amount = 1_000e18;
        vm.prank(operator);
        vesting.assign(institution, amount);

        vm.warp(startTime + 365 days);

        vm.expectEmit(true, false, false, true);
        emit TVDInstitutionalVesting.TokensReleased(institution, amount);
        vm.prank(institution);
        vesting.release();
    }

    function test_release_doesNotAffectOtherInstitutions() public {
        vm.startPrank(operator);
        vesting.assign(institution, 1_000e18);
        vesting.assign(institution2, 2_000e18);
        vm.stopPrank();

        vm.warp(startTime + 365 days);

        vm.prank(institution);
        vesting.release();

        assertEq(vesting.assignedBalance(institution2), 2_000e18);
        assertEq(vesting.totalAssigned(), 2_000e18);
    }

    // ──────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────

    function test_unlockTime() public view {
        assertEq(vesting.unlockTime(), startTime + 365 days);
    }

    function test_isUnlocked_falseBeforeUnlock() public view {
        assertFalse(vesting.isUnlocked());
    }

    function test_isUnlocked_trueAfterUnlock() public {
        vm.warp(startTime + 365 days);
        assertTrue(vesting.isUnlocked());
    }
}
