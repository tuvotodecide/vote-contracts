// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {TVDToken} from "../src/tvd-token/TVDToken.sol";
import {TVDVesting} from "../src/tvd-token/TVDVesting.sol";
import {TVDInstitutionalVesting} from "../src/tvd-token/TVDInstitutionalVesting.sol";
import {TVDElectoralCredits} from "../src/tvd-token/TVDElectoralCredits.sol";
import {TVDIncentiveCampaigns} from "../src/tvd-token/TVDIncentiveCampaigns.sol";
import {VoteManager} from "../src/VoteManager.sol";

/// @title E2EEcosystemTest
/// @notice Wires up the full TVD ecosystem (token, vesting, electoral credits, incentive
/// campaigns) exactly as `script/TVDEcosystem.s.sol` deploys it, plus the VoteManager UUPS
/// proxy from `script/VoteManager.s.sol`, so end-to-end flows can be exercised across all
/// contracts together.
contract E2EEcosystemTest is Test {
    TVDToken public token;
    TVDVesting public vesting;
    TVDInstitutionalVesting public institutionalVesting;
    TVDElectoralCredits public credits;
    TVDIncentiveCampaigns public incentiveCampaigns;
    VoteManager public voteManager;

    address public admin = makeAddr("admin");
    address public owner = makeAddr("owner");
    address public authorizedCaller = makeAddr("authorizedCaller");

    address public liquidityWallet = makeAddr("liquidityWallet");
    address public treasuryWallet = makeAddr("treasuryWallet");
    address public ecosystemWallet = makeAddr("ecosystemWallet");
    address public tempVestingWallet = makeAddr("tempVestingWallet");
    address public platformWallet = makeAddr("platformWallet");
    address public institutionalVestingOperator = makeAddr("institutionalVestingOperator");
    address public incentiveCampaignsOperator = makeAddr("incentiveCampaignsOperator");

    uint256 constant VESTING_POOL = 3_150_000e18;
    uint256 constant TVD_PER_CREDIT = 1e18;
    uint256 constant VOTE_MANAGER_REWARD_FUNDING = 1_000e18;
    uint256 constant INSTITUTIONAL_VESTING_FUNDING = 1_000e18;

    uint256 public lockupEnd;

    function setUp() public {
        lockupEnd = block.timestamp + 30 days;

        // ── TVD token + team vesting ────────────────────────────────
        token = new TVDToken(lockupEnd, liquidityWallet, treasuryWallet, ecosystemWallet, tempVestingWallet, admin);
        vesting = new TVDVesting(address(token), admin);

        vm.prank(tempVestingWallet);
        bool sentToVesting = token.transfer(address(vesting), VESTING_POOL);
        assertTrue(sentToVesting);

        bytes32 lockupManagerRole = token.LOCKUP_MANAGER_ROLE();
        bytes32 lockupBypassRole = token.LOCKUP_BYPASS_ROLE();

        // ── Institutional vesting ───────────────────────────────────
        institutionalVesting = new TVDInstitutionalVesting(address(token), admin, institutionalVestingOperator);
        vm.prank(admin);
        token.grantRole(lockupManagerRole, address(institutionalVesting));

        // ── Electoral credits ───────────────────────────────────────
        credits = new TVDElectoralCredits(address(token), admin, TVD_PER_CREDIT, platformWallet);
        assertEq(credits.maxTokenPerElection(), 100_000e18);
        vm.prank(admin);
        token.grantRole(lockupBypassRole, address(credits));

        // ── Incentive campaigns ─────────────────────────────────────
        incentiveCampaigns = new TVDIncentiveCampaigns(address(token), admin, incentiveCampaignsOperator);
        vm.prank(admin);
        token.grantRole(lockupManagerRole, address(incentiveCampaigns));

        // ── VoteManager (UUPS proxy) ────────────────────────────────
        VoteManager impl = new VoteManager();
        bytes memory initData =
            abi.encodeCall(VoteManager.initialize, (owner, authorizedCaller, address(credits), address(token)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        voteManager = VoteManager(address(proxy));

        // VoteManager tops up / consumes electoral credits on institutions' behalf.
        vm.prank(admin);
        credits.setOperator(address(voteManager), true);

        // VoteManager applies the transfer lockup to reward claimants (see claimVoteReward).
        vm.prank(admin);
        token.grantRole(lockupManagerRole, address(voteManager));

        // Fund VoteManager so it can pay out vote rewards.
        vm.startPrank(ecosystemWallet);
        bool success = token.transfer(address(voteManager), VOTE_MANAGER_REWARD_FUNDING);
        assertTrue(success);

        // Fund InstitutinalVesting so it can assign tokens to institutions
        success = token.transfer(address(institutionalVesting), INSTITUTIONAL_VESTING_FUNDING);
        assertTrue(success);
        vm.stopPrank();
    }

    function test_e2e_fullEcosystemFlow() public {
        address institution = makeAddr("institution");
        address stranger = makeAddr("stranger");

        uint256 assignAmount = 10e18;
        uint256 incentiveAmount = 10e18;

        // ── 1. Institutional vesting assigns tokens to the institution ─────
        vm.expectEmit(true, false, false, true);
        emit TVDInstitutionalVesting.TokensAssigned(institution, assignAmount);
        vm.prank(institutionalVestingOperator);
        institutionalVesting.assign(institution, assignAmount);

        assertEq(token.balanceOf(institution), assignAmount);

        vm.prank(institution);
        vm.expectRevert("tokens are still locked");
        token.transfer(stranger, 1e18);

        // ── 2. Create an incentive campaign for the institution ────────────
        uint256 campaignStart = block.timestamp;
        uint256 campaignDuration = 30 days;

        vm.prank(ecosystemWallet);
        token.approve(address(incentiveCampaigns), incentiveAmount);

        vm.expectEmit(true, false, false, true);
        emit TVDIncentiveCampaigns.CampaignCreated(incentiveAmount, campaignStart, campaignDuration, 1, ecosystemWallet);
        vm.prank(admin);
        incentiveCampaigns.createCampaign(incentiveAmount, campaignStart, campaignDuration, 1, ecosystemWallet);

        assertEq(token.balanceOf(address(incentiveCampaigns)), incentiveAmount);

        // ── 3. Give the institution its incentive ───────────────────────────
        vm.expectEmit(true, false, false, true);
        emit TVDIncentiveCampaigns.IncentiveTransferred(institution, incentiveAmount);
        vm.prank(incentiveCampaignsOperator);
        incentiveCampaigns.giveIncentive(institution);

        assertEq(token.balanceOf(institution), assignAmount + incentiveAmount);
        assertEq(token.balanceOf(address(incentiveCampaigns)), 0);

        // ── 4. Refund the now-empty campaign ────────────────────────────────
        uint256 ecosystemBalanceBeforeRefund = token.balanceOf(ecosystemWallet);

        vm.expectEmit(true, false, false, true);
        emit TVDIncentiveCampaigns.CampaignRefunded(ecosystemWallet, 0);
        vm.prank(admin);
        incentiveCampaigns.refundCampaign();

        assertTrue(incentiveCampaigns.isCampaignRefunded());
        assertEq(token.balanceOf(ecosystemWallet), ecosystemBalanceBeforeRefund);

        // ── 5. Register the institution in VoteManager ──────────────────────
        string memory institutionId = "institution-1";

        vm.expectEmit(true, false, false, true);
        emit VoteManager.InstitutionCreated(institutionId, institution);
        vm.prank(authorizedCaller);
        voteManager.createInstitution(institutionId, institution);

        // ── 6. Institution creates an election: 2 options, 20 voter credits ─
        uint256 voteId = 1;
        string memory voteName = "Test Election";
        uint48 startDate = uint48(block.timestamp);
        uint48 endDate = uint48(block.timestamp + 2 days);
        uint48 resultsDate = uint48(block.timestamp + 4 days);
        uint48 enabledVotersCount = 20;
        uint256 enabledVotersMkRoot = 12345;
        string[] memory options = new string[](2);
        options[0] = "yes";
        options[1] = "no";

        vm.prank(institution);
        token.approve(address(credits), type(uint256).max);

        vm.expectEmit(true, false, false, true);
        emit VoteManager.VoteCreated(voteId, voteName);
        vm.prank(institution);
        voteManager.createVote(
            voteId,
            institutionId,
            voteName,
            startDate,
            endDate,
            resultsDate,
            enabledVotersCount,
            enabledVotersMkRoot,
            options
        );

        // ── 7. Cast 20 valid votes, one per enabled voter ────────────────────
        uint256 votesCast = 20;
        uint256 firstNullifier = 1;

        for (uint256 i = 0; i < votesCast; i++) {
            uint256 nullifier = firstNullifier + i;

            vm.expectEmit(true, false, false, true);
            emit VoteManager.Voted(voteId);
            vm.prank(authorizedCaller);
            voteManager.castVote("yes", voteId, nullifier);
        }

        (, uint256 creditBalanceAfterVotes,,,,,,,,) = credits.getElection(voteId);
        assertEq(creditBalanceAfterVotes, 0);

        // ── 8. Re-casting with an already-used nullifier is rejected ────────
        vm.prank(authorizedCaller);
        vm.expectRevert("Nullifier already used");
        voteManager.castVote("no", voteId, firstNullifier);

        // ── 9. Liquidate the election ────────────────────────────────────────
        uint256 institutionBalanceBeforeLiquidate = token.balanceOf(institution);

        vm.expectEmit(true, false, false, true);
        emit TVDElectoralCredits.Liquidated(institution, voteId, 18e18, 2e18, 0);
        vm.prank(admin);
        credits.liquidate(voteId);

        (
            address electionInstitution,
            uint256 creditBalance,
            uint256 lockedTVD,
            uint256 pendingTVD,,,
            bool liquidated,
            uint256 burnedTVD,
            uint256 consumedTVD,
            uint256 refundedTVD
        ) = credits.getElection(voteId);
        assertEq(electionInstitution, institution);
        assertEq(creditBalance, 0);
        assertEq(lockedTVD, 0);
        assertEq(pendingTVD, 0);
        assertTrue(liquidated);
        assertEq(burnedTVD, 2e18);
        assertEq(consumedTVD, 18e18);
        assertEq(refundedTVD, 0);

        // All 20 credits were consumed by votes, so nothing is left to refund.
        assertEq(token.balanceOf(institution), institutionBalanceBeforeLiquidate);

        // ── 10. A vote with a fresh nullifier fails: no credits left ────────
        uint256 extraNullifier = firstNullifier + votesCast;
        vm.prank(authorizedCaller);
        vm.expectRevert("TVDCredits: election has no credits");
        voteManager.castVote("no", voteId, extraNullifier);

        // ── 11. Once resultsDate passes, all 20 votes are counted ───────────
        vm.warp(resultsDate + 1);
        (string[] memory resultOptions, uint256[] memory voteCounts) = voteManager.getVoteResults(voteId);
        assertEq(resultOptions.length, 2);
        assertEq(voteCounts[0], votesCast); // "yes"
        assertEq(voteCounts[1], 0); // "no"
    }
}
