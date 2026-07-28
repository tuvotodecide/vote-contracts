// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TVDToken} from "../../src/tvd-token/TVDToken.sol";
import {TVDElectoralCredits} from "../../src/tvd-token/TVDElectoralCredits.sol";

contract TVDElectoralCreditsTest is Test {
    TVDToken public token;
    TVDElectoralCredits public credits;

    address public admin = makeAddr("admin");
    address public liquidity = makeAddr("liquidity");
    address public treasury = makeAddr("treasury");
    address public ecosystem = makeAddr("ecosystem");
    address public vestingAddr = makeAddr("vesting");
    address public platformWallet = makeAddr("platformWallet");
    address public operator = makeAddr("operator");
    address public institution = makeAddr("institution");
    address public institution2 = makeAddr("institution2");
    address public stranger = makeAddr("stranger");

    uint256 constant RATE = 1e18; // 1 TVD per credit
    uint256 constant ELECTION_ID = 1;

    uint256 public lockupEnd;

    function setUp() public {
        lockupEnd = block.timestamp + 30 days;
        token = new TVDToken(lockupEnd, liquidity, treasury, ecosystem, vestingAddr, admin);
        credits = new TVDElectoralCredits(address(token), admin, RATE, platformWallet);

        vm.prank(treasury);
        bool success = token.transfer(institution, 10_000e18);
        assertTrue(success);

        vm.prank(institution);
        token.approve(address(credits), type(uint256).max);

        vm.prank(admin);
        credits.setOperator(operator, true);
    }

    // ──────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────

    function test_constructor_setsToken() public view {
        assertEq(address(credits.token()), address(token));
    }

    function test_constructor_setsAdminRole() public view {
        assertTrue(credits.hasRole(credits.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_constructor_setsTvdPerCredit() public view {
        assertEq(credits.tvdPerCredit(), RATE);
    }

    function test_constructor_setsPlatformWallet() public view {
        assertEq(credits.platformWallet(), platformWallet);
    }

    function test_constructor_defaultBurnBps() public view {
        assertEq(credits.burnBps(), 1_000);
    }

    function test_constructor_defaultMaxTokenPerElection() public view {
        assertEq(credits.maxTokenPerElection(), 100_000e18);
    }

    function test_constructor_revertsZeroToken() public {
        vm.expectRevert("TVDCredits: invalid token");
        new TVDElectoralCredits(address(0), admin, RATE, platformWallet);
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert("TVDCredits: invalid admin");
        new TVDElectoralCredits(address(token), address(0), RATE, platformWallet);
    }

    function test_constructor_revertsZeroRate() public {
        vm.expectRevert("TVDCredits: rate must be > 0");
        new TVDElectoralCredits(address(token), admin, 0, platformWallet);
    }

    function test_constructor_revertsZeroPlatformWallet() public {
        vm.expectRevert("TVDCredits: invalid platform wallet");
        new TVDElectoralCredits(address(token), admin, RATE, address(0));
    }

    // ──────────────────────────────────────────────────────────────────
    // topUp
    // ──────────────────────────────────────────────────────────────────

    function test_topUp_pullsFromWallet() public {
        uint256 balBefore = token.balanceOf(institution);

        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        assertEq(token.balanceOf(institution), balBefore - 5 * RATE);
        assertEq(token.balanceOf(address(credits)), 5 * RATE);
    }

    function test_topUp_updatesInstitutionState() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        (
            address inst,
            uint256 creditBalance,
            uint256 lockedTVD,
            uint256 pendingTVD,
            uint256 startCreditBalance,
            uint256 startLockedTVD,
            bool liquidated,
            uint256 burnedTVD,
            uint256 consumedTVD,
            uint256 refundedTVD
        ) = credits.getElection(ELECTION_ID);

        assertEq(inst, institution);
        assertEq(creditBalance, 5);
        assertEq(lockedTVD, 5 * RATE);
        assertEq(pendingTVD, 0);
        assertEq(startCreditBalance, 5);
        assertEq(startLockedTVD, 5 * RATE);
        assertEq(liquidated, false);
        assertEq(burnedTVD, 0);
        assertEq(consumedTVD, 0);
        assertEq(refundedTVD, 0);
    }

    function test_topUp_accumulatesAcrossCalls() public {
        vm.startPrank(operator);
        credits.topUp(institution, ELECTION_ID, 3);
        credits.topUp(institution, ELECTION_ID, 2);
        vm.stopPrank();

        (, uint256 creditBalance, uint256 lockedTVD,, uint256 startCreditBalance, uint256 startLockedTVD,,,,) =
            credits.getElection(ELECTION_ID);
        assertEq(creditBalance, 5);
        assertEq(lockedTVD, 5 * RATE);
        assertEq(startCreditBalance, 5);
        assertEq(startLockedTVD, 5 * RATE);
    }

    function test_topUp_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit TVDElectoralCredits.TopUp(institution, ELECTION_ID, 5, 5 * RATE);
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);
    }

    function test_topUp_revertsZeroCredits() public {
        vm.prank(operator);
        vm.expectRevert("TVDCredits: credits must be > 0");
        credits.topUp(institution, ELECTION_ID, 0);
    }

    function test_topUp_revertsZeroInstitution() public {
        vm.prank(operator);
        vm.expectRevert("TVDCredits: invalid institution");
        credits.topUp(address(0), ELECTION_ID, 5);
    }

    function test_topUp_revertsInstitutionMismatch() public {
        vm.prank(treasury);
        bool success = token.transfer(institution2, 1_000e18);
        assertTrue(success);

        vm.prank(institution2);
        token.approve(address(credits), type(uint256).max);

        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        vm.prank(operator);
        vm.expectRevert("TVDCredits: institution mismatch");
        credits.topUp(institution2, ELECTION_ID, 5);
    }

    function test_topUp_revertsWithoutApproval() public {
        vm.prank(treasury);
        bool success = token.transfer(institution2, 1_000e18);
        assertTrue(success);

        vm.prank(operator);
        vm.expectRevert();
        credits.topUp(institution2, ELECTION_ID, 5);
    }

    function test_topUp_revertsNotOperator() public {
        vm.prank(stranger);
        vm.expectRevert("TVDCredits: caller is not an authorized operator");
        credits.topUp(institution, ELECTION_ID, 5);
    }

    function test_topUp_revertsExceedsMaxTokenPerElection() public {
        vm.prank(admin);
        credits.setMaxTokenPerElection(10 * RATE);

        vm.prank(operator);
        vm.expectRevert("TVDCredits: exceeds max token per election");
        credits.topUp(institution, ELECTION_ID, 11);
    }

    function test_topUp_allowsExactlyMaxTokenPerElection() public {
        vm.prank(admin);
        credits.setMaxTokenPerElection(10 * RATE);

        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 10);

        (, uint256 creditBalance,,,,,,,,) = credits.getElection(ELECTION_ID);
        assertEq(creditBalance, 10);
    }

    // ──────────────────────────────────────────────────────────────────
    // consumeVote
    // ──────────────────────────────────────────────────────────────────

    function test_consumeVote_decrementsCredit() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID);

        (, uint256 creditBalance,,,,,,,,) = credits.getElection(ELECTION_ID);
        assertEq(creditBalance, 4);
    }

    function test_consumeVote_movesLockedToPending() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID);

        (,, uint256 lockedTVD, uint256 pendingTVD,,,,,,) = credits.getElection(ELECTION_ID);
        assertEq(lockedTVD, 4 * RATE);
        assertEq(pendingTVD, RATE);
    }

    function test_consumeVote_doesNotChangeStartBalances() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID);

        (,,,, uint256 startCreditBalance, uint256 startLockedTVD,,,,) = credits.getElection(ELECTION_ID);
        assertEq(startCreditBalance, 5);
        assertEq(startLockedTVD, 5 * RATE);
    }

    function test_consumeVote_noTokensLeaveContract() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        uint256 balBefore = token.balanceOf(address(credits));
        vm.prank(operator);
        credits.consumeVote(ELECTION_ID);

        assertEq(token.balanceOf(address(credits)), balBefore);
    }

    function test_consumeVote_emitsEvent() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        vm.expectEmit(true, true, false, true);
        emit TVDElectoralCredits.VoteConsumed(institution, ELECTION_ID, RATE);
        vm.prank(operator);
        credits.consumeVote(ELECTION_ID);
    }

    function test_consumeVote_multipleVotesAccumulatePending() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 4);

        vm.startPrank(operator);
        credits.consumeVote(ELECTION_ID);
        credits.consumeVote(ELECTION_ID);
        vm.stopPrank();

        (, uint256 creditBalance, uint256 lockedTVD, uint256 pendingTVD,,,,,,) = credits.getElection(ELECTION_ID);
        assertEq(creditBalance, 2);
        assertEq(lockedTVD, 2 * RATE);
        assertEq(pendingTVD, 2 * RATE);
    }

    function test_consumeVote_adminCanCallWithoutBeingSetAsOperator() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 1);

        vm.prank(admin);
        credits.consumeVote(ELECTION_ID);

        (, uint256 creditBalance,,,,,,,,) = credits.getElection(ELECTION_ID);
        assertEq(creditBalance, 0);
    }

    function test_consumeVote_revertsNotOperator() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 1);

        vm.prank(stranger);
        vm.expectRevert("TVDCredits: caller is not an authorized operator");
        credits.consumeVote(ELECTION_ID);
    }

    function test_consumeVote_revertsUninitializedElection() public {
        vm.prank(operator);
        vm.expectRevert("TVDCredits: invalid institution");
        credits.consumeVote(ELECTION_ID);
    }

    function test_consumeVote_revertsNoCredits() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        vm.prank(operator);
        credits.liquidate(ELECTION_ID);

        vm.prank(operator);
        vm.expectRevert("TVDCredits: election has no credits");
        credits.consumeVote(ELECTION_ID);
    }

    // ──────────────────────────────────────────────────────────────────
    // liquidate
    // ──────────────────────────────────────────────────────────────────

    function test_liquidate_burnsDefaultTenPercentOfPending() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 10);

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID); // pending = 1 TVD

        uint256 supplyBefore = token.totalSupply();

        vm.prank(operator);
        credits.liquidate(ELECTION_ID);

        assertEq(token.totalSupply(), supplyBefore - (RATE * 1_000) / 10_000);
    }

    function test_liquidate_sendsRemainderToPlatformWallet() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 10);

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID); // pending = 1 TVD

        vm.prank(operator);
        credits.liquidate(ELECTION_ID);

        uint256 expectedToPlatform = RATE - (RATE * 1_000) / 10_000;
        assertEq(token.balanceOf(platformWallet), expectedToPlatform);
    }

    function test_liquidate_refundsUnusedCreditsToInstitution() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 10); // locks 10 TVD

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID); // 1 credit consumed, 9 remain locked

        uint256 balBefore = token.balanceOf(institution);

        vm.prank(operator);
        credits.liquidate(ELECTION_ID);

        assertEq(token.balanceOf(institution), balBefore + 9 * RATE);
    }

    function test_liquidate_resetsInstitutionState() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 10);

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID);

        vm.prank(operator);
        credits.liquidate(ELECTION_ID);

        (
            ,
            uint256 creditBalance,
            uint256 lockedTVD,
            uint256 pendingTVD,
            uint256 startCreditBalance,
            uint256 startLockedTVD,
            bool liquidated,
            uint256 burnedTVD,
            uint256 consumedTVD,
            uint256 refundedTVD
        ) = credits.getElection(ELECTION_ID);
        assertEq(creditBalance, 0);
        assertEq(lockedTVD, 0);
        assertEq(pendingTVD, 0);
        assertEq(startCreditBalance, 10);
        assertEq(startLockedTVD, 10 * RATE);
        assertEq(liquidated, true);
        assertEq(burnedTVD, RATE / 10);
        assertEq(consumedTVD, RATE - RATE / 10);
        assertEq(refundedTVD, 9 * RATE);
    }

    function test_liquidate_emitsEvent() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 10);

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID);

        uint256 toBurn = (RATE * 1_000) / 10_000;
        uint256 toPlatform = RATE - toBurn;
        uint256 refund = 9 * RATE;

        vm.expectEmit(true, false, false, true);
        emit TVDElectoralCredits.Liquidated(institution, ELECTION_ID, toPlatform, toBurn, refund);
        vm.prank(operator);
        credits.liquidate(ELECTION_ID);
    }

    function test_liquidate_withCustomBurnBps() public {
        vm.prank(admin);
        credits.setBurnBps(5_000); // 50%

        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 10);

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID); // pending = 1 TVD

        vm.prank(operator);
        credits.liquidate(ELECTION_ID);

        assertEq(token.balanceOf(platformWallet), RATE / 2);
    }

    function test_liquidate_allowsRolloverWithoutLiquidating() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID);

        // No liquidation yet — remaining 4 credits still usable in a future election.
        (, uint256 creditBalance,,,,,,,,) = credits.getElection(ELECTION_ID);
        assertEq(creditBalance, 4);

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID);

        (, creditBalance,,,,,,,,) = credits.getElection(ELECTION_ID);
        assertEq(creditBalance, 3);
    }

    function test_liquidate_worksWithOnlyRefundNoPending() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5); // no votes consumed — pending stays 0, refund = 5 TVD

        uint256 balBefore = token.balanceOf(institution);

        vm.prank(operator);
        credits.liquidate(ELECTION_ID);

        assertEq(token.balanceOf(institution), balBefore + 5 * RATE);
    }

    function test_liquidate_revertsNothingToLiquidate() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        vm.prank(operator);
        credits.liquidate(ELECTION_ID);

        vm.prank(operator);
        vm.expectRevert("TVDCredits: nothing to liquidate");
        credits.liquidate(ELECTION_ID);
    }

    function test_liquidate_revertsUninitializedElection() public {
        vm.prank(operator);
        vm.expectRevert("TVDCredits: invalid institution");
        credits.liquidate(ELECTION_ID);
    }

    function test_liquidate_revertsNotOperator() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        vm.prank(stranger);
        vm.expectRevert("TVDCredits: caller is not an authorized operator");
        credits.liquidate(ELECTION_ID);
    }

    function test_liquidate_thenTopUpAgainStartsFresh() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);
        vm.prank(operator);
        credits.liquidate(ELECTION_ID);

        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 3);

        (
            ,
            uint256 creditBalance,
            uint256 lockedTVD,,
            uint256 startCreditBalance,
            uint256 startLockedTVD,
            bool liquidated,,,
        ) = credits.getElection(ELECTION_ID);
        assertEq(creditBalance, 3);
        assertEq(lockedTVD, 3 * RATE);
        assertEq(startCreditBalance, 3);
        assertEq(startLockedTVD, 3 * RATE);
        assertEq(liquidated, false);
    }

    // ──────────────────────────────────────────────────────────────────
    // Admin — setOperator
    // ──────────────────────────────────────────────────────────────────

    function test_setOperator_grantsOperatorRole() public {
        vm.prank(admin);
        credits.setOperator(stranger, true);
        assertTrue(credits.hasRole(credits.OPERATOR_ROLE(), stranger));
    }

    function test_setOperator_revokesOperatorRole() public {
        vm.prank(admin);
        credits.setOperator(operator, false);
        assertFalse(credits.hasRole(credits.OPERATOR_ROLE(), operator));
    }

    function test_setOperator_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit TVDElectoralCredits.OperatorUpdated(stranger, true);
        vm.prank(admin);
        credits.setOperator(stranger, true);
    }

    function test_setOperator_revertsNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        credits.setOperator(stranger, true);
    }

    function test_setOperator_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("TVDCredits: invalid operator");
        credits.setOperator(address(0), true);
    }

    function test_setOperator_canRevokeAuthorization() public {
        vm.prank(admin);
        credits.setOperator(operator, false);

        vm.prank(admin);
        credits.topUp(institution, ELECTION_ID, 1);

        vm.prank(operator);
        vm.expectRevert("TVDCredits: caller is not an authorized operator");
        credits.consumeVote(ELECTION_ID);
    }

    // ──────────────────────────────────────────────────────────────────
    // Admin — setBurnBps
    // ──────────────────────────────────────────────────────────────────

    function test_setBurnBps_success() public {
        vm.prank(admin);
        credits.setBurnBps(2_000);
        assertEq(credits.burnBps(), 2_000);
    }

    function test_setBurnBps_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit TVDElectoralCredits.BurnBpsUpdated(1_000, 2_000);
        vm.prank(admin);
        credits.setBurnBps(2_000);
    }

    function test_setBurnBps_revertsAtOrAboveMax() public {
        vm.prank(admin);
        vm.expectRevert("TVDCredits: burnBps must be < 10000");
        credits.setBurnBps(10_000);
    }

    function test_setBurnBps_revertsNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        credits.setBurnBps(2_000);
    }

    // ──────────────────────────────────────────────────────────────────
    // Admin — setTvdPerCredit
    // ──────────────────────────────────────────────────────────────────

    function test_setTvdPerCredit_success() public {
        vm.prank(admin);
        credits.setTvdPerCredit(2e18);
        assertEq(credits.tvdPerCredit(), 2e18);
    }

    function test_setTvdPerCredit_onlyAffectsFutureTopUps() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5); // locked at old rate

        vm.prank(admin);
        credits.setTvdPerCredit(2e18);

        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5); // locked at new rate

        (,, uint256 lockedTVD,,,,,,,) = credits.getElection(ELECTION_ID);
        assertEq(lockedTVD, 5 * RATE + 5 * 2e18);
    }

    function test_setTvdPerCredit_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit TVDElectoralCredits.TvdPerCreditUpdated(RATE, 2e18);
        vm.prank(admin);
        credits.setTvdPerCredit(2e18);
    }

    function test_setTvdPerCredit_revertsZero() public {
        vm.prank(admin);
        vm.expectRevert("TVDCredits: rate must be > 0");
        credits.setTvdPerCredit(0);
    }

    function test_setTvdPerCredit_revertsNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        credits.setTvdPerCredit(2e18);
    }

    // ──────────────────────────────────────────────────────────────────
    // Admin — setMaxTokenPerElection
    // ──────────────────────────────────────────────────────────────────

    function test_setMaxTokenPerElection_success() public {
        vm.prank(admin);
        credits.setMaxTokenPerElection(50_000e18);
        assertEq(credits.maxTokenPerElection(), 50_000e18);
    }

    function test_setMaxTokenPerElection_emitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit TVDElectoralCredits.MaxTokenPerElectionUpdated(100_000e18, 50_000e18);
        vm.prank(admin);
        credits.setMaxTokenPerElection(50_000e18);
    }

    function test_setMaxTokenPerElection_revertsNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert();
        credits.setMaxTokenPerElection(50_000e18);
    }
}
