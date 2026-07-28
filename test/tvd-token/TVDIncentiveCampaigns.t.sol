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
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public stranger = makeAddr("stranger");

    uint256 public lockupEnd;
    uint256 public blockStart;

    function setUp() public {
        lockupEnd = block.timestamp + 1000 days;
        token = new TVDToken(lockupEnd, liquidity, treasury, ecosystem, vestingAddr, admin);

        blockStart = block.timestamp;
        campaigns = new TVDIncentiveCampaigns(address(token), admin, operator);

        vm.startPrank(admin);
        token.grantRole(token.LOCKUP_MANAGER_ROLE(), address(campaigns));
        vm.stopPrank();

        vm.prank(treasury);
        token.approve(address(campaigns), type(uint256).max);
    }

    function _createCampaign(uint256 amount, uint256 start_, uint256 duration_, uint256 maxWallets_) internal {
        vm.prank(admin);
        campaigns.createCampaign(amount, start_, duration_, maxWallets_, treasury);
    }

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    function test_constructor_setsToken() public view {
        assertEq(address(campaigns.token()), address(token));
    }

    function test_constructor_setsAdminRole() public view {
        assertTrue(campaigns.hasRole(campaigns.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_constructor_setsOperatorRole() public view {
        assertTrue(campaigns.hasRole(campaigns.OPERATOR_ROLE(), operator));
    }

    function test_constructor_revertsZeroToken() public {
        vm.expectRevert("TVDIncentive: invalid token");
        new TVDIncentiveCampaigns(address(0), admin, operator);
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert("TVDIncentive: invalid admin");
        new TVDIncentiveCampaigns(address(token), address(0), operator);
    }

    function test_constructor_revertsZeroOperator() public {
        vm.expectRevert("TVDIncentive: invalid operator");
        new TVDIncentiveCampaigns(address(token), admin, address(0));
    }

    // ──────────────────────────────────────────────────────────────────
    // createCampaign
    // ──────────────────────────────────────────────────────────────────

    function test_createCampaign_storesFields() public {
        _createCampaign(100e18, blockStart, 30 days, 5);

        assertEq(campaigns.incentiveAmountPerWallet(), 100e18);
        assertEq(campaigns.start(), blockStart);
        assertEq(campaigns.duration(), 30 days);
        assertFalse(campaigns.isPaused());
        assertEq(campaigns.maxWallets(), 5);
        assertEq(campaigns.fundingWallet(), treasury);
        assertEq(campaigns.walletsCount(), 0);
        assertFalse(campaigns.isCampaignRefunded());
    }

    function test_createCampaign_pullsBudgetFromFundingWallet() public {
        uint256 balBefore = token.balanceOf(treasury);
        _createCampaign(100e18, blockStart, 30 days, 5);
        assertEq(token.balanceOf(treasury), balBefore - 500e18);
        assertEq(token.balanceOf(address(campaigns)), 500e18);
    }

    function test_createCampaign_defaultDurationWhenZero() public {
        _createCampaign(100e18, blockStart, 0, 5);
        assertEq(campaigns.duration(), campaigns.DEFAULT_DURATION());
    }

    function test_createCampaign_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit TVDIncentiveCampaigns.CampaignCreated(100e18, blockStart, 30 days, 5, treasury);
        _createCampaign(100e18, blockStart, 30 days, 5);
    }

    function test_createCampaign_revertsNotAdmin() public {
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

    function test_createCampaign_revertsWhileCurrentCampaignActive() public {
        _createCampaign(100e18, blockStart, 30 days, 5);

        vm.prank(admin);
        vm.expectRevert("TVDIncentive: previous campaign not refunded");
        campaigns.createCampaign(100e18, blockStart + 15 days, 30 days, 5, treasury);
    }

    function test_createCampaign_revertsWhileActiveEvenWhenPaused() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(admin);
        campaigns.setPause(true);

        vm.prank(admin);
        vm.expectRevert("TVDIncentive: previous campaign not refunded");
        campaigns.createCampaign(100e18, blockStart + 15 days, 30 days, 5, treasury);
    }

    function test_createCampaign_revertsAfterWindowElapsedWithoutRefund() public {
        // Letting the grant window elapse is no longer enough on its own —
        // refundCampaign() must be called first.
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.warp(blockStart + 30 days);

        vm.prank(admin);
        vm.expectRevert("TVDIncentive: previous campaign not refunded");
        campaigns.createCampaign(50e18, blockStart + 30 days, 30 days, 3, treasury);
    }

    function test_createCampaign_succeedsAfterRefund() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(admin);
        campaigns.refundCampaign();

        _createCampaign(50e18, blockStart + 5 days, 30 days, 3);

        assertEq(campaigns.incentiveAmountPerWallet(), 50e18);
        assertFalse(campaigns.isCampaignRefunded());
    }

    function test_createCampaign_succeedsAfterWindowElapsedAndRefund() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.warp(blockStart + 30 days);

        vm.prank(admin);
        campaigns.refundCampaign();

        _createCampaign(50e18, blockStart + 30 days, 30 days, 3);

        assertEq(campaigns.incentiveAmountPerWallet(), 50e18);
        assertEq(campaigns.maxWallets(), 3);
    }

    function test_createCampaign_resetsWalletsCount() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(operator);
        campaigns.giveIncentive(alice);

        vm.warp(blockStart + 30 days);
        vm.prank(admin);
        campaigns.refundCampaign();
        _createCampaign(50e18, blockStart + 30 days, 30 days, 3);

        assertEq(campaigns.walletsCount(), 0);
    }

    // ──────────────────────────────────────────────────────────────────
    // setPause
    // ──────────────────────────────────────────────────────────────────

    function test_setPause_success() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(admin);
        campaigns.setPause(true);
        assertTrue(campaigns.isPaused());
    }

    function test_setPause_emitsEvent() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.expectEmit(false, false, false, true);
        emit TVDIncentiveCampaigns.CampaignPauseSet(true);
        vm.prank(admin);
        campaigns.setPause(true);
    }

    function test_setPause_revertsNotAdmin() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(stranger);
        vm.expectRevert();
        campaigns.setPause(true);
    }

    function test_setPause_revertsNoActiveCampaign() public {
        vm.prank(admin);
        vm.expectRevert("TVDIncentive: no active campaign");
        campaigns.setPause(true);
    }

    // ──────────────────────────────────────────────────────────────────
    // refundCampaign
    // ──────────────────────────────────────────────────────────────────

    function test_refundCampaign_setsRefundedFlag() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(admin);
        campaigns.refundCampaign();
        assertTrue(campaigns.isCampaignRefunded());
    }

    function test_refundCampaign_refundsFullBudgetWhenUnused() public {
        uint256 balBeforeCreate = token.balanceOf(treasury);
        _createCampaign(100e18, blockStart, 30 days, 5);

        vm.prank(admin);
        campaigns.refundCampaign();

        assertEq(token.balanceOf(treasury), balBeforeCreate);
        assertEq(token.balanceOf(address(campaigns)), 0);
    }

    function test_refundCampaign_refundsOnlyRemainingBudget() public {
        uint256 balBeforeCreate = token.balanceOf(treasury);
        _createCampaign(100e18, blockStart, 30 days, 5);

        vm.prank(operator);
        campaigns.giveIncentive(alice); // 100e18 leaves the contract permanently

        vm.prank(admin);
        campaigns.refundCampaign();

        assertEq(token.balanceOf(treasury), balBeforeCreate - 100e18);
        assertEq(token.balanceOf(address(campaigns)), 0);
    }

    function test_refundCampaign_succeedsAfterGrantWindowElapsed() public {
        // The whole point of refundCampaign(): unused tokens can be swept
        // back even once the grant window has already passed.
        uint256 balBeforeCreate = token.balanceOf(treasury);
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.warp(blockStart + 30 days + 1);

        vm.prank(admin);
        campaigns.refundCampaign();

        assertEq(token.balanceOf(treasury), balBeforeCreate);
        assertEq(token.balanceOf(address(campaigns)), 0);
    }

    function test_refundCampaign_emitsEvent() public {
        _createCampaign(100e18, blockStart, 30 days, 5);

        vm.expectEmit(true, false, false, true);
        emit TVDIncentiveCampaigns.CampaignRefunded(treasury, 500e18);
        vm.prank(admin);
        campaigns.refundCampaign();
    }

    function test_refundCampaign_revertsNotAdmin() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(stranger);
        vm.expectRevert();
        campaigns.refundCampaign();
    }

    function test_refundCampaign_revertsNoActiveCampaign() public {
        vm.prank(admin);
        vm.expectRevert("TVDIncentive: no active campaign");
        campaigns.refundCampaign();
    }

    function test_refundCampaign_revertsAlreadyRefunded() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(admin);
        campaigns.refundCampaign();

        vm.prank(admin);
        vm.expectRevert("TVDIncentive: campaign already refunded");
        campaigns.refundCampaign();
    }

    // ──────────────────────────────────────────────────────────────────
    // giveIncentive
    // ──────────────────────────────────────────────────────────────────

    function test_giveIncentive_transfersTokensToRecipient() public {
        _createCampaign(100e18, blockStart, 30 days, 5);

        vm.prank(operator);
        campaigns.giveIncentive(alice);

        assertEq(token.balanceOf(alice), 100e18);
        assertTrue(campaigns.hasReceived(alice));
    }

    function test_giveIncentive_locksRecipientInToken() public {
        _createCampaign(100e18, blockStart, 30 days, 5);

        vm.prank(operator);
        campaigns.giveIncentive(alice);

        vm.prank(alice);
        vm.expectRevert("tokens are still locked");
        token.transfer(stranger, 100e18);
    }

    function test_giveIncentive_lockedRecipientCanTransferToBypassAddress() public {
        _createCampaign(100e18, blockStart, 30 days, 5);

        vm.prank(operator);
        campaigns.giveIncentive(alice);

        bytes32 lockupBypassRole = token.LOCKUP_BYPASS_ROLE();
        vm.prank(admin);
        token.grantRole(lockupBypassRole, stranger);

        vm.prank(alice);
        bool success = token.transfer(stranger, 100e18);

        assertTrue(success);
        assertEq(token.balanceOf(stranger), 100e18);
    }

    function test_giveIncentive_incrementsWalletsCount() public {
        _createCampaign(100e18, blockStart, 30 days, 5);

        vm.prank(operator);
        campaigns.giveIncentive(alice);

        assertEq(campaigns.walletsCount(), 1);
    }

    function test_giveIncentive_emitsEvent() public {
        _createCampaign(100e18, blockStart, 30 days, 5);

        vm.expectEmit(true, false, false, true);
        emit TVDIncentiveCampaigns.IncentiveTransferred(alice, 100e18);
        vm.prank(operator);
        campaigns.giveIncentive(alice);
    }

    function test_giveIncentive_revertsNotOperator() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(stranger);
        vm.expectRevert();
        campaigns.giveIncentive(alice);
    }

    function test_giveIncentive_revertsZeroRecipient() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(operator);
        vm.expectRevert("TVDIncentive: invalid recipient");
        campaigns.giveIncentive(address(0));
    }

    function test_giveIncentive_revertsPausedCampaign() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(admin);
        campaigns.setPause(true);

        vm.prank(operator);
        vm.expectRevert("TVDIncentive: campaign is paused");
        campaigns.giveIncentive(alice);
    }

    function test_giveIncentive_revertsRefundedCampaign() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(admin);
        campaigns.refundCampaign();

        vm.prank(operator);
        vm.expectRevert("TVDIncentive: campaign has been refunded");
        campaigns.giveIncentive(alice);
    }

    function test_giveIncentive_revertsBeforeWindowStarts() public {
        _createCampaign(100e18, blockStart + 10 days, 30 days, 5);

        vm.prank(operator);
        vm.expectRevert("TVDIncentive: campaign grant window is not active");
        campaigns.giveIncentive(alice);
    }

    function test_giveIncentive_revertsAfterWindowEnds() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.warp(blockStart + 30 days);

        vm.prank(operator);
        vm.expectRevert("TVDIncentive: campaign grant window is not active");
        campaigns.giveIncentive(alice);
    }

    function test_giveIncentive_revertsAlreadyReceived() public {
        _createCampaign(100e18, blockStart, 30 days, 5);

        vm.prank(operator);
        campaigns.giveIncentive(alice);

        vm.prank(operator);
        vm.expectRevert("TVDIncentive: already received");
        campaigns.giveIncentive(alice);
    }

    function test_giveIncentive_revertsAlreadyReceivedAcrossCampaigns() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(operator);
        campaigns.giveIncentive(alice);

        vm.warp(blockStart + 30 days);
        vm.prank(admin);
        campaigns.refundCampaign();
        _createCampaign(50e18, blockStart + 30 days, 30 days, 5);

        // Alice already received an incentive in the previous campaign — a
        // wallet may only ever be granted the incentive once.
        vm.prank(operator);
        vm.expectRevert("TVDIncentive: already received");
        campaigns.giveIncentive(alice);
    }

    function test_giveIncentive_revertsMaxWalletsReached() public {
        _createCampaign(100e18, blockStart, 30 days, 1);

        vm.prank(operator);
        campaigns.giveIncentive(alice);

        vm.prank(operator);
        vm.expectRevert("TVDIncentive: max wallets reached");
        campaigns.giveIncentive(bob);
    }

    function test_createCampaign_revertsZeroMaxWallets() public {
        vm.prank(admin);
        vm.expectRevert("TVDIncentive: max wallets must be > 0");
        campaigns.createCampaign(100e18, blockStart, 30 days, 0, treasury);
    }

    function test_giveIncentive_revertsNoActiveCampaign() public {
        vm.prank(operator);
        vm.expectRevert("TVDIncentive: no active campaign");
        campaigns.giveIncentive(alice);
    }

    // ──────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────

    function test_campaignEndTime() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        assertEq(campaigns.campaignEndTime(), blockStart + 30 days);
    }

    function test_campaignEndTime_revertsNoActiveCampaign() public {
        vm.expectRevert("TVDIncentive: no active campaign");
        campaigns.campaignEndTime();
    }

    function test_isActive_trueDuringWindow() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        assertTrue(campaigns.isActive());
    }

    function test_isActive_falseBeforeWindow() public {
        _createCampaign(100e18, blockStart + 10 days, 30 days, 5);
        assertFalse(campaigns.isActive());
    }

    function test_isActive_falseAfterWindow() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.warp(blockStart + 30 days);
        assertFalse(campaigns.isActive());
    }

    function test_isActive_falseWhenRefunded() public {
        _createCampaign(100e18, blockStart, 30 days, 5);
        vm.prank(admin);
        campaigns.refundCampaign();
        assertFalse(campaigns.isActive());
    }
}
