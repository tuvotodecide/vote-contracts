// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TVDToken} from "../../src/tvd-token/TVDToken.sol";

contract TVDTokenTest is Test {
    TVDToken public token;

    address public admin = makeAddr("admin");
    address public liquidity = makeAddr("liquidity");
    address public treasury = makeAddr("treasury");
    address public ecosystem = makeAddr("ecosystem");
    address public vestingAddr = makeAddr("vesting");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant LIQUIDITY_AMOUNT = 4_200_000e18;
    uint256 constant TREASURY_AMOUNT = 8_400_000e18;
    uint256 constant ECOSYSTEM_AMOUNT = 5_250_000e18;
    uint256 constant VESTING_AMOUNT = 3_150_000e18;
    uint256 constant MAX_SUPPLY = 21_000_000e18;

    uint256 public lockupEnd;

    function setUp() public {
        lockupEnd = block.timestamp + 30 days;
        token = new TVDToken(lockupEnd, liquidity, treasury, ecosystem, vestingAddr, admin);
    }

    function _lockAddress(address account) internal {
        vm.startPrank(admin);
        token.grantRole(token.LOCKUP_MANAGER_ROLE(), admin);
        token.setApplyLockup(account, true);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────
    // Metadata
    // ──────────────────────────────────────────────────────────────────

    function test_name() public view {
        assertEq(token.name(), "Tu Voto Decide");
    }

    function test_symbol() public view {
        assertEq(token.symbol(), "TVD");
    }

    function test_decimals() public view {
        assertEq(token.decimals(), 18);
    }

    function test_maxSupplyConstant() public view {
        assertEq(token.MAX_SUPPLY(), MAX_SUPPLY);
    }

    // ──────────────────────────────────────────────────────────────────
    // Initial distribution
    // ──────────────────────────────────────────────────────────────────

    function test_initialDistribution_totalSupply() public view {
        assertEq(token.totalSupply(), MAX_SUPPLY);
    }

    function test_initialDistribution_liquidityBalance() public view {
        assertEq(token.balanceOf(liquidity), LIQUIDITY_AMOUNT);
    }

    function test_initialDistribution_treasuryBalance() public view {
        assertEq(token.balanceOf(treasury), TREASURY_AMOUNT);
    }

    function test_initialDistribution_ecosystemBalance() public view {
        assertEq(token.balanceOf(ecosystem), ECOSYSTEM_AMOUNT);
    }

    function test_initialDistribution_vestingBalance() public view {
        assertEq(token.balanceOf(vestingAddr), VESTING_AMOUNT);
    }

    function test_initialDistribution_emitsEvent() public {
        vm.expectEmit(true, true, true, false);
        emit TVDToken.InitialDistribution(liquidity, treasury, ecosystem, vestingAddr);
        new TVDToken(lockupEnd, liquidity, treasury, ecosystem, vestingAddr, admin);
    }

    function test_lockupEnd_setFromConstructor() public view {
        assertEq(token.lockupEnd(), lockupEnd);
    }

    // ──────────────────────────────────────────────────────────────────
    // Constructor reverts
    // ──────────────────────────────────────────────────────────────────

    function test_constructor_revertsOnZeroLiquidity() public {
        vm.expectRevert("TVD: invalid liquidity wallet");
        new TVDToken(lockupEnd, address(0), treasury, ecosystem, vestingAddr, admin);
    }

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert("TVD: invalid treasury wallet");
        new TVDToken(lockupEnd, liquidity, address(0), ecosystem, vestingAddr, admin);
    }

    function test_constructor_revertsOnZeroEcosystem() public {
        vm.expectRevert("TVD: invalid ecosystem wallet");
        new TVDToken(lockupEnd, liquidity, treasury, address(0), vestingAddr, admin);
    }

    function test_constructor_revertsOnZeroVesting() public {
        vm.expectRevert("TVD: invalid vesting contract");
        new TVDToken(lockupEnd, liquidity, treasury, ecosystem, address(0), admin);
    }

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert("TVD: invalid admin");
        new TVDToken(lockupEnd, liquidity, treasury, ecosystem, vestingAddr, address(0));
    }

    // ──────────────────────────────────────────────────────────────────
    // AccessControl
    // ──────────────────────────────────────────────────────────────────

    function test_adminRole_grantedToAdmin() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_adminRole_notGrantedToOthers() public view {
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), alice));
    }

    // ──────────────────────────────────────────────────────────────────
    // Burn
    // ──────────────────────────────────────────────────────────────────

    function test_burn_reducesTotalSupply() public {
        uint256 burnAmount = 1_000e18;
        uint256 supplyBefore = token.totalSupply();

        vm.prank(liquidity);
        token.burn(burnAmount);

        assertEq(token.totalSupply(), supplyBefore - burnAmount);
        assertEq(token.balanceOf(liquidity), LIQUIDITY_AMOUNT - burnAmount);
    }

    function test_burnFrom_withAllowance() public {
        uint256 burnAmount = 500e18;

        vm.prank(liquidity);
        token.approve(alice, burnAmount);

        vm.prank(alice);
        token.burnFrom(liquidity, burnAmount);

        assertEq(token.balanceOf(liquidity), LIQUIDITY_AMOUNT - burnAmount);
    }

    function test_burnFrom_revertsWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert();
        token.burnFrom(liquidity, 1e18);
    }

    // ──────────────────────────────────────────────────────────────────
    // Hard cap — no minting beyond MAX_SUPPLY
    // ──────────────────────────────────────────────────────────────────

    function test_cap_equalsMaxSupply() public view {
        assertEq(token.cap(), MAX_SUPPLY);
    }

    function test_cap_supplyAlreadyAtCap() public view {
        // The full 21M is minted at construction; totalSupply == cap.
        assertEq(token.totalSupply(), token.cap());
    }

    // ──────────────────────────────────────────────────────────────────
    // ERC-20 transfers
    // ──────────────────────────────────────────────────────────────────

    function test_transfer_liquidity_succeeds() public {
        uint256 amount = 100e18;
        vm.prank(liquidity);
        bool success = token.transfer(alice, amount);
        assertTrue(success);

        assertEq(token.balanceOf(alice), amount);
    }

    function test_transfer_treasury_succeeds() public {
        uint256 amount = 100e18;
        vm.prank(treasury);
        bool success = token.transfer(alice, amount);
        assertTrue(success);

        assertEq(token.balanceOf(alice), amount);
    }

    function test_transfer_ecosystem_succeeds() public {
        uint256 amount = 100e18;
        vm.prank(ecosystem);
        bool success = token.transfer(alice, amount);
        assertTrue(success);
        assertEq(token.balanceOf(alice), amount);
    }

    function test_transfer_revertsInsufficientBalance() public {
        vm.prank(alice); // alice has no tokens
        vm.expectRevert();
        token.transfer(bob, 1e18);
    }

    function test_transferFrom_withApproval() public {
        uint256 amount = 200e18;
        vm.prank(treasury);
        token.approve(alice, amount);

        vm.prank(alice);
        bool success = token.transferFrom(treasury, bob, amount);

        assertTrue(success);
        assertEq(token.balanceOf(bob), amount);
    }

    // ──────────────────────────────────────────────────────────────────
    // Lockup roles — setApplyLockup
    // ──────────────────────────────────────────────────────────────────

    function test_setApplyLockup_revertsWithoutRole() public {
        vm.prank(alice);
        vm.expectRevert();
        token.setApplyLockup(liquidity, true);
    }

    function test_setApplyLockup_succeedsWithRole() public {
        bytes32 lockupManagerRole = token.LOCKUP_MANAGER_ROLE();
        vm.prank(admin);
        token.grantRole(lockupManagerRole, admin);

        vm.prank(admin);
        token.setApplyLockup(liquidity, true);
    }

    function test_setApplyLockup_emitsEvent() public {
        bytes32 lockupManagerRole = token.LOCKUP_MANAGER_ROLE();
        vm.prank(admin);
        token.grantRole(lockupManagerRole, admin);

        vm.expectEmit(true, false, false, true);
        emit TVDToken.ApplyLockupUpdated(liquidity, true);
        vm.prank(admin);
        token.setApplyLockup(liquidity, true);
    }

    // ──────────────────────────────────────────────────────────────────
    // Transfer lockup
    // ──────────────────────────────────────────────────────────────────

    function test_lockedAddress_cannotTransferToNonBypassAddress() public {
        _lockAddress(liquidity);

        vm.prank(liquidity);
        vm.expectRevert("tokens are still locked");
        token.transfer(alice, 1e18);
    }

    function test_lockedAddress_canTransferToBypassAddress() public {
        _lockAddress(liquidity);

        bytes32 lockupBypassRole = token.LOCKUP_BYPASS_ROLE();
        vm.prank(admin);
        token.grantRole(lockupBypassRole, bob);

        vm.prank(liquidity);
        bool success = token.transfer(bob, 1e18);
        assertTrue(success);

        assertEq(token.balanceOf(bob), 1e18);
    }

    function test_lockedAddress_canTransferFreelyAfterLockupEnd() public {
        _lockAddress(liquidity);

        vm.warp(lockupEnd);

        vm.prank(liquidity);
        bool success = token.transfer(alice, 1e18);
        assertTrue(success);

        assertEq(token.balanceOf(alice), 1e18);
    }

    function test_unlockedAddress_transfersFreelyDuringLockup() public {
        // treasury was never flagged via setApplyLockup.
        vm.prank(treasury);
        bool success = token.transfer(alice, 1e18);
        assertTrue(success);
        assertEq(token.balanceOf(alice), 1e18);
    }

    function test_unflaggingAddress_restoresFreeTransfer() public {
        _lockAddress(liquidity);

        vm.prank(admin);
        token.setApplyLockup(liquidity, false);

        vm.prank(liquidity);
        bool success = token.transfer(alice, 1e18);
        assertTrue(success);
        assertEq(token.balanceOf(alice), 1e18);
    }
}
