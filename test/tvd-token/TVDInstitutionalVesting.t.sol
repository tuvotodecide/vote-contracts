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
    address public institution = makeAddr("institution");
    address public stranger = makeAddr("stranger");

    uint256 public lockupEnd;
    uint256 constant FUNDING = 100_000e18;

    function setUp() public {
        lockupEnd = block.timestamp + 30 days;
        token = new TVDToken(lockupEnd, liquidity, treasury, ecosystem, vestingAddr, admin);

        vesting = new TVDInstitutionalVesting(address(token), admin, operator);

        vm.startPrank(admin);
        token.grantRole(token.LOCKUP_MANAGER_ROLE(), address(vesting));
        vm.stopPrank();

        vm.prank(treasury);
        bool success = token.transfer(address(vesting), FUNDING);
        assertTrue(success);
    }

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    function test_constructor_setsToken() public view {
        assertEq(address(vesting.token()), address(token));
    }

    function test_constructor_setsAdminRole() public view {
        assertTrue(vesting.hasRole(vesting.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_constructor_setsOperatorRole() public view {
        assertTrue(vesting.hasRole(vesting.OPERATOR_ROLE(), operator));
    }

    function test_constructor_revertsZeroToken() public {
        vm.expectRevert("TVDInstVesting: invalid token");
        new TVDInstitutionalVesting(address(0), admin, operator);
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert("TVDInstVesting: invalid admin");
        new TVDInstitutionalVesting(address(token), address(0), operator);
    }

    function test_constructor_revertsZeroOperator() public {
        vm.expectRevert("TVDInstVesting: invalid operator");
        new TVDInstitutionalVesting(address(token), admin, address(0));
    }

    // ──────────────────────────────────────────────────────────────────
    // OPERATOR_ROLE management
    // ──────────────────────────────────────────────────────────────────

    function test_grantOperatorRole_success() public {
        address newOperator = makeAddr("newOperator");
        bytes32 operatorRole = vesting.OPERATOR_ROLE();
        vm.prank(admin);
        vesting.grantRole(operatorRole, newOperator);
        assertTrue(vesting.hasRole(operatorRole, newOperator));
    }

    function test_revokeOperatorRole_success() public {
        bytes32 operatorRole = vesting.OPERATOR_ROLE();
        vm.prank(admin);
        vesting.revokeRole(operatorRole, operator);
        assertFalse(vesting.hasRole(operatorRole, operator));
    }

    function test_grantOperatorRole_revertsNotAdmin() public {
        bytes32 operatorRole = vesting.OPERATOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert();
        vesting.grantRole(operatorRole, stranger);
    }

    // ──────────────────────────────────────────────────────────────────
    // assign
    // ──────────────────────────────────────────────────────────────────

    function test_assign_transfersTokensToInstitution() public {
        uint256 amount = 1_000e18;
        vm.prank(operator);
        vesting.assign(institution, amount);

        assertEq(token.balanceOf(institution), amount);
        assertEq(token.balanceOf(address(vesting)), FUNDING - amount);
    }

    function test_assign_accumulatesAcrossCalls() public {
        vm.startPrank(operator);
        vesting.assign(institution, 1_000e18);
        vesting.assign(institution, 500e18);
        vm.stopPrank();

        assertEq(token.balanceOf(institution), 1_500e18);
    }

    function test_assign_emitsEvent() public {
        uint256 amount = 1_000e18;
        vm.expectEmit(true, false, false, true);
        emit TVDInstitutionalVesting.TokensAssigned(institution, amount);
        vm.prank(operator);
        vesting.assign(institution, amount);
    }

    function test_assign_revertsNotOperator() public {
        vm.prank(admin);
        vm.expectRevert();
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

    function test_assign_revertsWithoutLockupManagerRole() public {
        // A vesting instance that was never granted LOCKUP_MANAGER_ROLE on the
        // token cannot lock the institution it assigns tokens to.
        TVDInstitutionalVesting v2 = new TVDInstitutionalVesting(address(token), admin, operator);
        vm.prank(treasury);
        bool success = token.transfer(address(v2), FUNDING);
        assertTrue(success);

        vm.prank(operator);
        vm.expectRevert();
        v2.assign(institution, 1_000e18);
    }

    // ──────────────────────────────────────────────────────────────────
    // Lockup effect on assigned institutions
    // ──────────────────────────────────────────────────────────────────

    function test_assign_locksInstitutionInToken() public {
        uint256 amount = 1_000e18;
        vm.prank(operator);
        vesting.assign(institution, amount);

        vm.prank(institution);
        vm.expectRevert("tokens are still locked");
        token.transfer(stranger, amount);
    }

    function test_assign_lockedInstitutionCanTransferToBypassAddress() public {
        uint256 amount = 1_000e18;
        vm.prank(operator);
        vesting.assign(institution, amount);

        bytes32 lockupBypassRole = token.LOCKUP_BYPASS_ROLE();
        vm.prank(admin);
        token.grantRole(lockupBypassRole, stranger);

        vm.prank(institution);
        bool success = token.transfer(stranger, amount);

        assertTrue(success);
        assertEq(token.balanceOf(stranger), amount);
    }

    function test_assign_lockedInstitutionCanTransferFreelyAfterLockupEnd() public {
        uint256 amount = 1_000e18;
        vm.prank(operator);
        vesting.assign(institution, amount);

        vm.warp(lockupEnd);

        vm.prank(institution);
        bool success = token.transfer(stranger, amount);

        assertTrue(success);
        assertEq(token.balanceOf(stranger), amount);
    }

    // ──────────────────────────────────────────────────────────────────
    // rescueTokens
    // ──────────────────────────────────────────────────────────────────

    function test_rescueTokens_transfersTokensToRecipient() public {
        uint256 amount = 1_000e18;
        vm.prank(admin);
        vesting.rescueTokens(stranger, amount);

        assertEq(token.balanceOf(stranger), amount);
        assertEq(token.balanceOf(address(vesting)), FUNDING - amount);
    }

    function test_rescueTokens_emitsEvent() public {
        uint256 amount = 1_000e18;
        vm.expectEmit(true, false, false, true);
        emit TVDInstitutionalVesting.TokensRescued(stranger, amount);
        vm.prank(admin);
        vesting.rescueTokens(stranger, amount);
    }

    function test_rescueTokens_revertsNotAdmin() public {
        vm.prank(operator);
        vm.expectRevert();
        vesting.rescueTokens(stranger, 1_000e18);
    }

    function test_rescueTokens_revertsZeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert("TVDInstVesting: invalid recipient");
        vesting.rescueTokens(address(0), 1_000e18);
    }

    function test_rescueTokens_revertsZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert("TVDInstVesting: amount must be > 0");
        vesting.rescueTokens(stranger, 0);
    }

    function test_rescueTokens_revertsExceedsBalance() public {
        vm.prank(admin);
        vm.expectRevert("TVDInstVesting: insufficient contract balance");
        vesting.rescueTokens(stranger, FUNDING + 1);
    }

    function test_rescueTokens_worksForLockedRecipient() public {
        // rescueTokens does not apply a lockup, unlike assign().
        uint256 amount = 1_000e18;
        vm.prank(admin);
        vesting.rescueTokens(institution, amount);

        vm.prank(institution);
        bool success = token.transfer(stranger, amount);

        assertTrue(success);
        assertEq(token.balanceOf(stranger), amount);
    }
}
