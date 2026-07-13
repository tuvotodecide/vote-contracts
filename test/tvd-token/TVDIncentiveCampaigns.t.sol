// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TVDToken} from "../../src/tvd-token/TVDToken.sol";
import {TVDIncentiveCampaigns} from "../../src/tvd-token/TVDIncentiveCampaigns.sol";

contract TVDIncentiveCampaignsTest is Test {
    TVDToken public token;
    TVDIncentiveCampaigns public campaigns;

    address public admin = makeAddr("admin");
    address public liquidity = makeAddr("liquidity");
    address public treasury = makeAddr("treasury"); // acts as fundingWallet
    address public ecosystem = makeAddr("ecosystem");
    address public vestingAddr = makeAddr("vesting");
    address public operator = makeAddr("operator");
    address public creditsContract = makeAddr("creditsContract");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public stranger = makeAddr("stranger");

    uint256 public blockStart;

    function setUp() public {
        token = new TVDToken(liquidity, treasury, ecosystem, vestingAddr, admin);

        blockStart = block.timestamp;
        campaigns = new TVDIncentiveCampaigns(address(token), admin, operator, blockStart);

        vm.prank(treasury);
        token.approve(address(campaigns), type(uint256).max);

        vm.prank(admin);
        campaigns.setCreditsContract(creditsContract);
    }

    function _createCampaign(uint256 amount, uint256 start, uint256 duration, uint256 maxWallets)
        internal
        returns (uint256 id)
    {
        vm.prank(admin);
        id = campaigns.createCampaign(amount, start, duration, maxWallets, treasury);
    }

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    function test_constructor_setsToken() public view {
        assertEq(address(campaigns.token()), address(token));
    }

    function test_constructor_setsOperator() public view {
        assertEq(campaigns.operator(), operator);
    }

    function test_constructor_setsOwner() public view {
        assertEq(campaigns.owner(), admin);
    }

    function test_constructor_setsBlockStartTime() public view {
        assertEq(campaigns.blockStartTime(), blockStart);
    }

    function test_constructor_defaultBlockDuration() public view {
        assertEq(campaigns.blockDuration(), 365 days);
    }

    function test_constructor_revertsZeroToken() public {
        vm.expectRevert("TVDIncentive: invalid token");
        new TVDIncentiveCampaigns(address(0), admin, operator, blockStart);
    }

    function test_constructor_revertsZeroOperator() public {
        vm.expectRevert("TVDIncentive: invalid operator");
        new TVDIncentiveCampaigns(address(token), admin, address(0), blockStart);
    }

    function test_constructor_revertsZeroBlockStartTime() public {
        vm.expectRevert("TVDIncentive: invalid blockStartTime");
        new TVDIncentiveCampaigns(address(token), admin, operator, 0);
    }

    // ──────────────────────────────────────────────────────────────────
    // setOperator / setCreditsContract
    // ──────────────────────────────────────────────────────────────────

    function test_setOperator_success() public {
        address newOperator = makeAddr("newOperator");
        vm.prank(admin);
        campaigns.setOperator(newOperator);
        assertEq(campaigns.operator(), newOperator);
    }

    function test_setOperator_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        campaigns.setOperator(stranger);
    }

    function test_setOperator_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("TVDIncentive: invalid operator");
        campaigns.setOperator(address(0));
    }

    function test_setCreditsContract_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        campaigns.setCreditsContract(stranger);
    }

    function test_setCreditsContract_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("TVDIncentive: invalid address");
        campaigns.setCreditsContract(address(0));
    }

    // ──────────────────────────────────────────────────────────────────
    // createCampaign
    // ──────────────────────────────────────────────────────────────────

    function test_createCampaign_storesFields() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);

        (
            uint256 incentiveAmountPerWallet,
            uint256 start,
            uint256 duration,
            bool isPaused,
            uint256 maxWallets,
            address fundingWallet,
            uint256 walletsCount
        ) = campaigns.campaigns(id);

        assertEq(incentiveAmountPerWallet, 100e18);
        assertEq(start, blockStart);
        assertEq(duration, 30 days);
        assertFalse(isPaused);
        assertEq(maxWallets, 5);
        assertEq(fundingWallet, treasury);
        assertEq(walletsCount, 0);
    }

    function test_createCampaign_pullsBudgetFromFundingWallet() public {
        uint256 balBefore = token.balanceOf(treasury);
        _createCampaign(100e18, blockStart, 30 days, 5);
        assertEq(token.balanceOf(treasury), balBefore - 500e18);
        assertEq(token.balanceOf(address(campaigns)), 500e18);
    }

    function test_createCampaign_defaultDurationWhenZero() public {
        uint256 id = _createCampaign(100e18, blockStart, 0, 5);
        (,, uint256 duration,,,,) = campaigns.campaigns(id);
        assertEq(duration, campaigns.DEFAULT_DURATION());
    }

    function test_createCampaign_emitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit TVDIncentiveCampaigns.CampaignCreated(0, 100e18, blockStart, 30 days, 5, treasury);
        _createCampaign(100e18, blockStart, 30 days, 5);
    }

    function test_createCampaign_incrementsCampaignCount() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        assertEq(campaigns.campaignCount(), 1);
    }

    function test_createCampaign_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        campaigns.createCampaign(100e18, blockStart, 30 days, 5, treasury);
    }

    function test_createCampaign_revertsZeroIncentive() public {
        vm.prank(admin);
        vm.expectRevert("TVDIncentive: incentive must be > 0");
        campaigns.createCampaign(0, blockStart, 30 days, 5, treasury);
    }

    function test_createCampaign_revertsZeroStart() public {
        vm.prank(admin);
        vm.expectRevert("TVDIncentive: invalid start time");
        campaigns.createCampaign(100e18, 0, 30 days, 5, treasury);
    }

    function test_createCampaign_revertsZeroFundingWallet() public {
        vm.prank(admin);
        vm.expectRevert("TVDIncentive: invalid funding wallet");
        campaigns.createCampaign(100e18, blockStart, 30 days, 5, address(0));
    }

    function test_createCampaign_revertsOverlappingWindow() public {
        _createCampaign(100e18, blockStart, 30 days, 5);

        vm.prank(admin);
        vm.expectRevert("TVDIncentive: time window overlaps with an existing campaign");
        campaigns.createCampaign(100e18, blockStart + 15 days, 30 days, 5, treasury);
    }

    function test_createCampaign_revertsOverlapEvenWhenExistingPaused() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(admin);
        campaigns.setPause(id, true);

        vm.prank(admin);
        vm.expectRevert("TVDIncentive: time window overlaps with an existing campaign");
        campaigns.createCampaign(100e18, blockStart + 15 days, 30 days, 5, treasury);
    }

    function test_createCampaign_succeedsNonOverlappingWindow() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        uint256 id2 = _createCampaign(100e18, blockStart + 30 days, 30 days, 5);
        assertEq(id2, 1);
        assertEq(campaigns.campaignCount(), 2);
    }

    // ──────────────────────────────────────────────────────────────────
    // setPause
    // ──────────────────────────────────────────────────────────────────

    function test_setPause_success() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(admin);
        campaigns.setPause(id, true);
        (,,, bool isPaused,,,) = campaigns.campaigns(id);
        assertTrue(isPaused);
    }

    function test_setPause_emitsEvent() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.expectEmit(true, false, false, true);
        emit TVDIncentiveCampaigns.CampaignPauseSet(id, true);
        vm.prank(admin);
        campaigns.setPause(id, true);
    }

    function test_setPause_revertsNotOwner() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(stranger);
        vm.expectRevert();
        campaigns.setPause(id, true);
    }

    function test_setPause_revertsNonexistentCampaign() public {
        vm.prank(admin);
        vm.expectRevert("TVDIncentive: campaign does not exist");
        campaigns.setPause(0, true);
    }

    // ──────────────────────────────────────────────────────────────────
    // giveIncentive — within block period (assignment, no transfer)
    // ──────────────────────────────────────────────────────────────────

    function test_giveIncentive_assignsDuringBlockPeriod() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);

        vm.prank(operator);
        campaigns.giveIncentive(id, alice);

        assertEq(campaigns.campaignBalance(id, alice), 100e18);
        assertEq(token.balanceOf(alice), 0);
        assertTrue(campaigns.hasReceived(id, alice));
    }

    function test_giveIncentive_incrementsWalletsCount() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);

        vm.prank(operator);
        campaigns.giveIncentive(id, alice);

        (,,,,,, uint256 walletsCount) = campaigns.campaigns(id);
        assertEq(walletsCount, 1);
    }

    function test_giveIncentive_emitsAssignedEvent() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);

        vm.expectEmit(true, true, false, true);
        emit TVDIncentiveCampaigns.IncentiveAssigned(id, alice, 100e18);
        vm.prank(operator);
        campaigns.giveIncentive(id, alice);
    }

    function test_giveIncentive_transfersImmediatelyAfterBlockPeriod() public {
        // A campaign window that opens after the global block period ends.
        uint256 id = _createCampaign(100e18, blockStart + 400 days, 30 days, 5);
        vm.warp(blockStart + 400 days + 1);

        vm.prank(operator);
        campaigns.giveIncentive(id, bob);

        assertEq(token.balanceOf(bob), 100e18);
        assertEq(campaigns.campaignBalance(id, bob), 0);
    }

    function test_giveIncentive_emitsTransferredEventAfterBlockPeriod() public {
        uint256 id = _createCampaign(100e18, blockStart + 400 days, 30 days, 5);
        vm.warp(blockStart + 400 days + 1);

        vm.expectEmit(true, true, false, true);
        emit TVDIncentiveCampaigns.IncentiveTransferred(id, bob, 100e18);
        vm.prank(operator);
        campaigns.giveIncentive(id, bob);
    }

    function test_giveIncentive_revertsNotOperator() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(stranger);
        vm.expectRevert("TVDIncentive: caller is not operator");
        campaigns.giveIncentive(id, alice);
    }

    function test_giveIncentive_revertsZeroRecipient() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(operator);
        vm.expectRevert("TVDIncentive: invalid recipient");
        campaigns.giveIncentive(id, address(0));
    }

    function test_giveIncentive_revertsPausedCampaign() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(admin);
        campaigns.setPause(id, true);

        vm.prank(operator);
        vm.expectRevert("TVDIncentive: campaign is paused");
        campaigns.giveIncentive(id, alice);
    }

    function test_giveIncentive_revertsBeforeWindowStarts() public {
        uint256 id = _createCampaign(100e18, blockStart + 10 days, 30 days, 5);

        vm.prank(operator);
        vm.expectRevert("TVDIncentive: campaign grant window is not active");
        campaigns.giveIncentive(id, alice);
    }

    function test_giveIncentive_revertsAfterWindowEnds() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.warp(blockStart + 30 days);

        vm.prank(operator);
        vm.expectRevert("TVDIncentive: campaign grant window is not active");
        campaigns.giveIncentive(id, alice);
    }

    function test_giveIncentive_revertsAlreadyReceived() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);

        vm.prank(operator);
        campaigns.giveIncentive(id, alice);

        vm.prank(operator);
        vm.expectRevert("TVDIncentive: already received");
        campaigns.giveIncentive(id, alice);
    }

    function test_giveIncentive_revertsMaxWalletsReached() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 1);

        vm.prank(operator);
        campaigns.giveIncentive(id, alice);

        vm.prank(operator);
        vm.expectRevert("TVDIncentive: max wallets reached");
        campaigns.giveIncentive(id, bob);
    }

    function test_giveIncentive_unlimitedWhenMaxWalletsZero() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 0);

        vm.startPrank(operator);
        campaigns.giveIncentive(id, alice);
        campaigns.giveIncentive(id, bob);
        vm.stopPrank();

        assertEq(campaigns.campaignBalance(id, alice), 100e18);
        assertEq(campaigns.campaignBalance(id, bob), 100e18);
    }

    function test_giveIncentive_revertsNonexistentCampaign() public {
        vm.prank(operator);
        vm.expectRevert("TVDIncentive: campaign does not exist");
        campaigns.giveIncentive(0, alice);
    }

    // ──────────────────────────────────────────────────────────────────
    // release
    // ──────────────────────────────────────────────────────────────────

    function test_release_revertsWhileBlocked() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(operator);
        campaigns.giveIncentive(id, alice);

        vm.prank(alice);
        vm.expectRevert("TVDIncentive: tokens are still locked");
        campaigns.release(id);
    }

    function test_release_revertsNothingToClaim() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.warp(blockStart + 365 days);

        vm.prank(alice);
        vm.expectRevert("TVDIncentive: nothing to claim");
        campaigns.release(id);
    }

    function test_release_success() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(operator);
        campaigns.giveIncentive(id, alice);

        vm.warp(blockStart + 365 days);

        vm.prank(alice);
        campaigns.release(id);

        assertEq(token.balanceOf(alice), 100e18);
        assertEq(campaigns.campaignBalance(id, alice), 0);
    }

    function test_release_emitsEvent() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(operator);
        campaigns.giveIncentive(id, alice);

        vm.warp(blockStart + 365 days);

        vm.expectEmit(true, true, false, true);
        emit TVDIncentiveCampaigns.IncentiveClaimed(id, alice, 100e18);
        vm.prank(alice);
        campaigns.release(id);
    }

    function test_release_doesNotClearOtherCampaignBalance() public {
        uint256 id1 = _createCampaign(100e18, blockStart, 30 days, 5);
        uint256 id2 = _createCampaign(50e18, blockStart + 40 days, 30 days, 5);

        vm.prank(operator);
        campaigns.giveIncentive(id1, alice);

        vm.warp(blockStart + 40 days);
        vm.prank(operator);
        campaigns.giveIncentive(id2, alice);

        vm.warp(blockStart + 365 days + 1);

        vm.prank(alice);
        campaigns.release(id1);

        assertEq(token.balanceOf(alice), 100e18);
        assertEq(campaigns.campaignBalance(id1, alice), 0);
        assertEq(campaigns.campaignBalance(id2, alice), 50e18);
    }

    function test_release_includesRefundedHolding() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(operator);
        campaigns.giveIncentive(id, alice);

        // Simulate a liquidation refund routed back through TVDElectoralCredits.
        vm.prank(treasury);
        token.transfer(address(campaigns), 25e18);
        vm.prank(creditsContract);
        campaigns.creditRefund(alice, 25e18);

        vm.warp(blockStart + 365 days + 1);
        vm.prank(alice);
        campaigns.release(id);

        assertEq(token.balanceOf(alice), 125e18);
    }

    function test_release_revertsNonexistentCampaign() public {
        vm.warp(blockStart + 365 days);
        vm.prank(alice);
        vm.expectRevert("TVDIncentive: campaign does not exist");
        campaigns.release(0);
    }

    // ──────────────────────────────────────────────────────────────────
    // IVestingProvider — assignedBalance / withdrawFor / creditRefund
    // ──────────────────────────────────────────────────────────────────

    function test_assignedBalance_sumsAcrossCampaigns() public {
        uint256 id1 = _createCampaign(100e18, blockStart, 30 days, 5);
        uint256 id2 = _createCampaign(50e18, blockStart + 40 days, 30 days, 5);

        vm.prank(operator);
        campaigns.giveIncentive(id1, alice);

        vm.warp(blockStart + 40 days);
        vm.prank(operator);
        campaigns.giveIncentive(id2, alice);

        assertEq(campaigns.assignedBalance(alice), 150e18);
    }

    function test_withdrawFor_pullsAcrossMultipleCampaigns() public {
        uint256 id1 = _createCampaign(100e18, blockStart, 30 days, 5);
        uint256 id2 = _createCampaign(50e18, blockStart + 40 days, 30 days, 5);

        vm.prank(operator);
        campaigns.giveIncentive(id1, alice);

        vm.warp(blockStart + 40 days);
        vm.prank(operator);
        campaigns.giveIncentive(id2, alice);

        vm.prank(creditsContract);
        campaigns.withdrawFor(alice, 120e18);

        assertEq(token.balanceOf(creditsContract), 120e18);
        // Withdrawn from the last campaign backwards: id2's 50 fully drained,
        // then 70 taken from id1's 100, leaving 30.
        assertEq(campaigns.campaignBalance(id2, alice), 0);
        assertEq(campaigns.campaignBalance(id1, alice), 30e18);
    }

    function test_withdrawFor_emitsEvent() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(operator);
        campaigns.giveIncentive(id, alice);

        vm.expectEmit(true, false, false, true);
        emit TVDIncentiveCampaigns.InstitutionTokensWithdrawn(alice, 100e18);
        vm.prank(creditsContract);
        campaigns.withdrawFor(alice, 100e18);
    }

    function test_withdrawFor_revertsNotCreditsContract() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(operator);
        campaigns.giveIncentive(id, alice);

        vm.prank(stranger);
        vm.expectRevert("TVDIncentive: caller is not credits contract");
        campaigns.withdrawFor(alice, 100e18);
    }

    function test_withdrawFor_revertsInsufficientAssignedBalance() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(operator);
        campaigns.giveIncentive(id, alice);

        vm.prank(creditsContract);
        vm.expectRevert("TVDIncentive: insufficient assigned balance");
        campaigns.withdrawFor(alice, 200e18);
    }

    function test_creditRefund_success() public {
        vm.prank(treasury);
        token.transfer(address(campaigns), 50e18);

        vm.prank(creditsContract);
        campaigns.creditRefund(alice, 50e18);

        assertEq(campaigns.refundedHolding(alice), 50e18);
    }

    function test_creditRefund_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit TVDIncentiveCampaigns.InstitutionTokensRefunded(alice, 50e18);
        vm.prank(creditsContract);
        campaigns.creditRefund(alice, 50e18);
    }

    function test_creditRefund_revertsNotCreditsContract() public {
        vm.prank(stranger);
        vm.expectRevert("TVDIncentive: caller is not credits contract");
        campaigns.creditRefund(alice, 50e18);
    }

    function test_creditRefund_revertsZeroInstitution() public {
        vm.prank(creditsContract);
        vm.expectRevert("TVDIncentive: invalid institution");
        campaigns.creditRefund(address(0), 50e18);
    }

    // ──────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────

    function test_unlockTime() public view {
        assertEq(campaigns.unlockTime(), blockStart + 365 days);
    }

    function test_campaignEndTime() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        assertEq(campaigns.campaignEndTime(id), blockStart + 30 days);
    }

    function test_campaignEndTime_revertsNonexistent() public {
        vm.expectRevert("TVDIncentive: campaign does not exist");
        campaigns.campaignEndTime(0);
    }

    function test_isActive_trueDuringWindow() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        assertTrue(campaigns.isActive(id));
    }

    function test_isActive_falseBeforeWindow() public {
        uint256 id = _createCampaign(100e18, blockStart + 10 days, 30 days, 5);
        assertFalse(campaigns.isActive(id));
    }

    function test_isActive_falseAfterWindow() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.warp(blockStart + 30 days);
        assertFalse(campaigns.isActive(id));
    }

    function test_getAmountReceived_returnsCallerBalance() public {
        uint256 id = _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(operator);
        campaigns.giveIncentive(id, alice);

        vm.prank(alice);
        assertEq(campaigns.getAmountReceived(id), 100e18);
    }
}
