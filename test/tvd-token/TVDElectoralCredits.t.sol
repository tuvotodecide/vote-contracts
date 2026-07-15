// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TVDToken} from "../../src/tvd-token/TVDToken.sol";
import {TVDElectoralCredits} from "../../src/tvd-token/TVDElectoralCredits.sol";
import {TVDInstitutionalVesting} from "../../src/tvd-token/TVDInstitutionalVesting.sol";

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

    function setUp() public {
        token = new TVDToken(liquidity, treasury, ecosystem, vestingAddr, admin);
        credits = new TVDElectoralCredits(address(token), admin, RATE, platformWallet);

        vm.prank(treasury);
        token.transfer(institution, 10_000e18);
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

    function test_constructor_setsOwner() public view {
        assertEq(credits.owner(), admin);
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

    function test_constructor_revertsZeroToken() public {
        vm.expectRevert("TVDCredits: invalid token");
        new TVDElectoralCredits(address(0), admin, RATE, platformWallet);
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
    // topUp — plain wallet path (no vesting providers registered)
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

        vm.prank(credits.owner());
        (address inst, uint256 creditBalance, uint256 lockedTVD, uint256 pendingTVD, address vestingSource) =
            credits.getInstitution(ELECTION_ID);

        assertEq(inst, institution);
        assertEq(creditBalance, 5);
        assertEq(lockedTVD, 5 * RATE);
        assertEq(pendingTVD, 0);
        assertEq(vestingSource, address(0));
    }

    function test_topUp_accumulatesAcrossCalls() public {
        vm.startPrank(operator);
        credits.topUp(institution, ELECTION_ID, 3);
        credits.topUp(institution, ELECTION_ID, 2);
        vm.stopPrank();

        vm.prank(credits.owner());
        (, uint256 creditBalance, uint256 lockedTVD,,) = credits.getInstitution(ELECTION_ID);
        assertEq(creditBalance, 5);
        assertEq(lockedTVD, 5 * RATE);
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
        token.transfer(institution2, 1_000e18);
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
        token.transfer(institution2, 1_000e18);

        vm.prank(operator);
        vm.expectRevert();
        credits.topUp(institution2, ELECTION_ID, 5);
    }

    function test_topUp_revertsNotOperator() public {
        vm.prank(stranger);
        vm.expectRevert("TVDCredits: caller is not an authorized operator");
        credits.topUp(institution, ELECTION_ID, 5);
    }

    // ──────────────────────────────────────────────────────────────────
    // consumeVote
    // ──────────────────────────────────────────────────────────────────

    function test_consumeVote_decrementsCredit() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID);

        vm.prank(credits.owner());
        (, uint256 creditBalance,,,) = credits.getInstitution(ELECTION_ID);
        assertEq(creditBalance, 4);
    }

    function test_consumeVote_movesLockedToPending() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID);

        vm.prank(credits.owner());
        (,, uint256 lockedTVD, uint256 pendingTVD,) = credits.getInstitution(ELECTION_ID);
        assertEq(lockedTVD, 4 * RATE);
        assertEq(pendingTVD, RATE);
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

        vm.prank(credits.owner());
        (, uint256 creditBalance, uint256 lockedTVD, uint256 pendingTVD,) = credits.getInstitution(ELECTION_ID);
        assertEq(creditBalance, 2);
        assertEq(lockedTVD, 2 * RATE);
        assertEq(pendingTVD, 2 * RATE);
    }

    function test_consumeVote_ownerCanCallWithoutBeingSetAsOperator() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 1);

        vm.prank(admin);
        credits.consumeVote(ELECTION_ID);

        vm.prank(credits.owner());
        (, uint256 creditBalance,,,) = credits.getInstitution(ELECTION_ID);
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
        vm.expectRevert("TVDCredits: institution has no credits");
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

        vm.prank(credits.owner());
        (, uint256 creditBalance, uint256 lockedTVD, uint256 pendingTVD, address vestingSource) =
            credits.getInstitution(ELECTION_ID);
        assertEq(creditBalance, 0);
        assertEq(lockedTVD, 0);
        assertEq(pendingTVD, 0);
        assertEq(vestingSource, address(0));
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
        vm.prank(credits.owner());
        (, uint256 creditBalance,,,) = credits.getInstitution(ELECTION_ID);
        assertEq(creditBalance, 4);

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID);

        vm.prank(credits.owner());
        (, creditBalance,,,) = credits.getInstitution(ELECTION_ID);
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

        vm.prank(credits.owner());
        (, uint256 creditBalance, uint256 lockedTVD,,) = credits.getInstitution(ELECTION_ID);
        assertEq(creditBalance, 3);
        assertEq(lockedTVD, 3 * RATE);
    }

    // ──────────────────────────────────────────────────────────────────
    // Vesting provider integration
    // ──────────────────────────────────────────────────────────────────

    function _deployProvider(uint256 fundAmount) internal returns (TVDInstitutionalVesting provider) {
        provider = new TVDInstitutionalVesting(address(token), admin, admin, block.timestamp);
        vm.prank(admin);
        provider.setCreditsContract(address(credits));

        vm.prank(treasury);
        token.transfer(address(provider), fundAmount);
    }

    function test_topUp_usesVestingProviderWhenSufficient() public {
        TVDInstitutionalVesting provider = _deployProvider(100e18);
        vm.prank(admin);
        provider.assign(institution, 50e18);

        vm.prank(admin);
        credits.addVestingProvider(address(provider));

        uint256 walletBalBefore = token.balanceOf(institution);

        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 10); // needs 10 TVD, provider has 50 assigned

        assertEq(token.balanceOf(institution), walletBalBefore); // wallet untouched
        assertEq(provider.assignedBalance(institution), 40e18);

        vm.prank(credits.owner());
        (,,,, address vestingSource) = credits.getInstitution(ELECTION_ID);
        assertEq(vestingSource, address(provider));
    }

    function test_topUp_fallsBackToWalletWhenProviderInsufficient() public {
        TVDInstitutionalVesting provider = _deployProvider(100e18);
        vm.prank(admin);
        provider.assign(institution, 3e18); // less than the 10 TVD required

        vm.prank(admin);
        credits.addVestingProvider(address(provider));

        uint256 walletBalBefore = token.balanceOf(institution);

        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 10);

        assertEq(token.balanceOf(institution), walletBalBefore - 10 * RATE);
        assertEq(provider.assignedBalance(institution), 3e18); // untouched

        vm.prank(credits.owner());
        (,,,, address vestingSource) = credits.getInstitution(ELECTION_ID);
        assertEq(vestingSource, address(0));
    }

    function test_topUp_scansProvidersInOrderAndSkipsInsufficientOnes() public {
        TVDInstitutionalVesting providerA = _deployProvider(100e18);
        TVDInstitutionalVesting providerB = _deployProvider(100e18);

        vm.startPrank(admin);
        providerA.assign(institution, 2e18); // insufficient for a 10-credit topUp
        providerB.assign(institution, 50e18); // sufficient
        credits.addVestingProvider(address(providerA));
        credits.addVestingProvider(address(providerB));
        vm.stopPrank();

        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 10);

        vm.prank(credits.owner());
        (,,,, address vestingSource) = credits.getInstitution(ELECTION_ID);
        assertEq(vestingSource, address(providerB));
        assertEq(providerA.assignedBalance(institution), 2e18); // untouched
        assertEq(providerB.assignedBalance(institution), 40e18);
    }

    function test_liquidate_refundsToVestingProviderWhenSourced() public {
        TVDInstitutionalVesting provider = _deployProvider(100e18);
        vm.prank(admin);
        provider.assign(institution, 50e18);
        vm.prank(admin);
        credits.addVestingProvider(address(provider));

        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 10); // fully funded by provider; 10 TVD locked

        vm.prank(operator);
        credits.consumeVote(ELECTION_ID); // 1 credit consumed, 9 TVD remain locked

        vm.prank(operator);
        credits.liquidate(ELECTION_ID);

        // Refund of the unused 9 TVD is routed back to the provider, not the institution wallet.
        assertEq(provider.assignedBalance(institution), 40e18 + 9e18);
    }

    function test_liquidate_emitsRefundEventForVestingSourcedRefund() public {
        TVDInstitutionalVesting provider = _deployProvider(100e18);
        vm.prank(admin);
        provider.assign(institution, 50e18);
        vm.prank(admin);
        credits.addVestingProvider(address(provider));

        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 10);

        vm.expectEmit(true, false, false, true);
        emit TVDInstitutionalVesting.TokensRefunded(institution, 10e18);
        vm.prank(operator);
        credits.liquidate(ELECTION_ID);
    }

    // ──────────────────────────────────────────────────────────────────
    // Admin — setOperator
    // ──────────────────────────────────────────────────────────────────

    function test_setOperator_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit TVDElectoralCredits.OperatorUpdated(stranger, true);
        vm.prank(admin);
        credits.setOperator(stranger, true);
    }

    function test_setOperator_revertsNotOwner() public {
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

    function test_setBurnBps_revertsNotOwner() public {
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

        vm.prank(credits.owner());
        (,, uint256 lockedTVD,,) = credits.getInstitution(ELECTION_ID);
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

    function test_setTvdPerCredit_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        credits.setTvdPerCredit(2e18);
    }

    // ──────────────────────────────────────────────────────────────────
    // Admin — vesting provider registry
    // ──────────────────────────────────────────────────────────────────

    function test_addVestingProvider_appendsToArray() public {
        TVDInstitutionalVesting provider = _deployProvider(1e18);
        vm.prank(admin);
        credits.addVestingProvider(address(provider));

        assertEq(address(credits.vestingProviders(0)), address(provider));
    }

    function test_addVestingProvider_emitsEvent() public {
        TVDInstitutionalVesting provider = _deployProvider(1e18);
        vm.expectEmit(true, false, false, false);
        emit TVDElectoralCredits.VestingProviderAdded(address(provider));
        vm.prank(admin);
        credits.addVestingProvider(address(provider));
    }

    function test_addVestingProvider_revertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert("TVDCredits: invalid provider");
        credits.addVestingProvider(address(0));
    }

    function test_addVestingProvider_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        credits.addVestingProvider(stranger);
    }

    function test_removeVestingProvider_swapAndPop() public {
        TVDInstitutionalVesting providerA = _deployProvider(1e18);
        TVDInstitutionalVesting providerB = _deployProvider(1e18);
        TVDInstitutionalVesting providerC = _deployProvider(1e18);

        vm.startPrank(admin);
        credits.addVestingProvider(address(providerA));
        credits.addVestingProvider(address(providerB));
        credits.addVestingProvider(address(providerC));

        credits.removeVestingProvider(0); // remove A; C swapped into slot 0
        vm.stopPrank();

        assertEq(address(credits.vestingProviders(0)), address(providerC));
        assertEq(address(credits.vestingProviders(1)), address(providerB));
    }

    function test_removeVestingProvider_emitsEvent() public {
        TVDInstitutionalVesting provider = _deployProvider(1e18);
        vm.prank(admin);
        credits.addVestingProvider(address(provider));

        vm.expectEmit(true, false, false, false);
        emit TVDElectoralCredits.VestingProviderRemoved(address(provider));
        vm.prank(admin);
        credits.removeVestingProvider(0);
    }

    function test_removeVestingProvider_revertsOutOfBounds() public {
        vm.prank(admin);
        vm.expectRevert("TVDCredits: index out of bounds");
        credits.removeVestingProvider(0);
    }

    function test_removeVestingProvider_revertsNotOwner() public {
        TVDInstitutionalVesting provider = _deployProvider(1e18);
        vm.prank(admin);
        credits.addVestingProvider(address(provider));

        vm.prank(stranger);
        vm.expectRevert();
        credits.removeVestingProvider(0);
    }

    // ──────────────────────────────────────────────────────────────────
    // Admin — recoverDust
    // ──────────────────────────────────────────────────────────────────

    function test_recoverDust_revertsNoDust() public {
        vm.prank(admin);
        vm.expectRevert("TVDCredits: no dust to recover");
        credits.recoverDust();
    }

    function test_recoverDust_revertsNotOwner() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        vm.prank(stranger);
        vm.expectRevert();
        credits.recoverDust();
    }

    function test_recoverDust_emitsEvent() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 5);

        vm.expectEmit(false, false, false, true);
        emit TVDElectoralCredits.DustRecovered(5 * RATE);
        vm.prank(admin);
        credits.recoverDust();
    }

    /// @dev recoverDust() currently sweeps the ENTIRE token balance held by the
    ///      contract — it never subtracts institutions' locked/pending TVD despite
    ///      the inline comment claiming otherwise. Calling it while institutions
    ///      still have active credits drains their locked backing, leaving
    ///      topUp()'s accounting inconsistent with the contract's real balance.
    ///      This test documents the current behaviour.
    function test_recoverDust_currentlyDrainsActiveLockedTVD() public {
        vm.prank(operator);
        credits.topUp(institution, ELECTION_ID, 10); // 10 TVD locked and still backing active credits

        vm.prank(admin);
        credits.recoverDust();

        assertEq(token.balanceOf(address(credits)), 0);
        vm.prank(credits.owner());
        (,, uint256 lockedTVD,,) = credits.getInstitution(ELECTION_ID);
        assertEq(lockedTVD, 10 * RATE); // accounting still claims 10 TVD is locked…
        assertEq(token.balanceOf(address(credits)), 0); // …but no tokens remain to back it
    }
}
