// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {VoteManager} from "../src/VoteManager.sol";
import {TVDToken} from "../src/tvd-token/TVDToken.sol";
import {TVDElectoralCredits} from "../src/tvd-token/TVDElectoralCredits.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VoteManagerTest is Test {
    VoteManager public manager;
    TVDToken public tvdToken;
    TVDElectoralCredits public creditsContract;

    address public owner;
    address public nonOwner;
    address public authorizedCaller;
    address public unauthorizedCaller;

    address public liquidityWallet;
    address public treasuryWallet;
    address public ecosystemWallet;
    address public vestingWallet;
    address public tokenAdmin;
    address public platformWallet;
    address public rewardClaimer;

    uint256 constant VOTE_ID = 1;
    string constant VOTE_NAME = "Test Vote";

    string constant INSTITUTION_ID = "institution-1";
    string constant VOTE_INSTITUTION_ID = "vote-institution-1";
    address public institutionAdmin;
    address public otherAddress;

    uint256 constant TVD_PER_CREDIT = 1e18;
    uint48 constant ENABLED_VOTERS_COUNT = 3;
    uint256 constant INSTITUTION_TVD_FUNDING = 1_000_000e18;

    // Timestamps used across tests
    uint48 startDate;
    uint48 endDate;
    uint48 resultsDate;

    uint256 enabledVotersMkRoot;
    string[] options;
    uint256 public lockupEnd;

    function setUp() public {
        owner = address(this);
        nonOwner = address(0xBEEF);
        authorizedCaller = address(0xCA11);
        unauthorizedCaller = address(0xD00D);
        institutionAdmin = address(0xAD41);
        otherAddress = address(0x0AAA);

        liquidityWallet = makeAddr("liquidity");
        treasuryWallet = makeAddr("treasury");
        ecosystemWallet = makeAddr("ecosystem");
        vestingWallet = makeAddr("vesting");
        tokenAdmin = makeAddr("tokenAdmin");
        platformWallet = makeAddr("platformWallet");
        rewardClaimer = makeAddr("rewardClaimer");

        // Real TVD token and electoral credits contract, backing vote creation.
        lockupEnd = block.timestamp + 30 days;
        tvdToken = new TVDToken(lockupEnd, liquidityWallet, treasuryWallet, ecosystemWallet, vestingWallet, tokenAdmin);
        creditsContract = new TVDElectoralCredits(address(tvdToken), owner, TVD_PER_CREDIT, platformWallet);

        bytes32 lockupManagerRole = tvdToken.LOCKUP_MANAGER_ROLE();
        vm.prank(tokenAdmin);
        tvdToken.grantRole(lockupManagerRole, address(creditsContract));

        // Deploy implementation + proxy
        VoteManager impl = new VoteManager();
        bytes memory initData = abi.encodeCall(
            VoteManager.initialize, (owner, authorizedCaller, address(creditsContract), address(tvdToken))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        manager = VoteManager(address(proxy));

        // Allow the manager to top up / consume credits on behalf of institutions.
        creditsContract.setOperator(address(manager), true);

        // Allow the manager to flag reward claimers' lockup status on claimVoteReward.
        vm.prank(tokenAdmin);
        tvdToken.grantRole(lockupManagerRole, address(manager));

        // Fund institutions with TVD and pre-approve the credits contract for vote top-ups.
        vm.prank(treasuryWallet);
        bool success = tvdToken.transfer(institutionAdmin, INSTITUTION_TVD_FUNDING);
        assertTrue(success);

        vm.prank(institutionAdmin);
        tvdToken.approve(address(creditsContract), type(uint256).max);

        vm.prank(treasuryWallet);
        success = tvdToken.transfer(otherAddress, INSTITUTION_TVD_FUNDING);
        assertTrue(success);

        vm.prank(otherAddress);
        tvdToken.approve(address(creditsContract), type(uint256).max);

        // Fund the manager itself so it can pay out vote rewards.
        vm.prank(treasuryWallet);
        success = tvdToken.transfer(address(manager), INSTITUTION_TVD_FUNDING);
        assertTrue(success);

        // Default dates: start in 2 days, end in 4 days, results in 6 days
        startDate = uint48(block.timestamp + 2 days);
        endDate = uint48(block.timestamp + 4 days);
        resultsDate = uint48(block.timestamp + 6 days);

        enabledVotersMkRoot = uint256(1);

        // Default options
        options = new string[](3);
        options[0] = "optionA";
        options[1] = "optionB";
        options[2] = "optionC";

        // Institution used to authorize vote creation/management in the tests below
        vm.prank(authorizedCaller);
        manager.createInstitution(VOTE_INSTITUTION_ID, institutionAdmin);
    }

    // ========== helpers ==========

    function _createVote() internal {
        vm.prank(institutionAdmin);
        manager.createVote(
            VOTE_ID,
            VOTE_INSTITUTION_ID,
            VOTE_NAME,
            startDate,
            endDate,
            resultsDate,
            ENABLED_VOTERS_COUNT,
            enabledVotersMkRoot,
            options
        );
    }

    function _castVote(string memory optionId, uint256 nullifier) internal {
        vm.prank(authorizedCaller);
        manager.castVote(optionId, VOTE_ID, nullifier);
    }

    // ========== Initialization ==========

    function test_initialize_setsOwner() public view {
        assertEq(manager.owner(), owner);
    }

    function test_initialize_setsAuthorizedCaller() public view {
        assertEq(manager.getAuthorizedCaller(), authorizedCaller);
    }

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        manager.initialize(nonOwner, unauthorizedCaller, address(creditsContract), address(tvdToken));
    }

    function test_setAuthorizedCaller_success() public {
        manager.setAuthorizedCaller(unauthorizedCaller);
        assertEq(manager.getAuthorizedCaller(), unauthorizedCaller);
    }

    function test_setAuthorizedCaller_revert_notOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        manager.setAuthorizedCaller(unauthorizedCaller);
    }

    // ========== setTvdPerVote ==========

    function test_setTvdPerVote_success() public {
        manager.setTvdPerVote(10e18);
        assertEq(manager.tvdPerVote(), 10e18);
    }

    function test_setTvdPerVote_revert_notOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        manager.setTvdPerVote(10e18);
    }

    // ========== createInstitution ==========

    function test_createInstitution_success() public {
        vm.expectEmit(true, false, false, true);
        emit VoteManager.InstitutionCreated(INSTITUTION_ID, institutionAdmin);

        vm.prank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, institutionAdmin);

        assertEq(manager.getInstitutionAdmin(INSTITUTION_ID), institutionAdmin);
    }

    function test_createInstitution_revert_emptyId() public {
        vm.expectRevert("Institution id cannot be empty");
        vm.prank(authorizedCaller);
        manager.createInstitution("", institutionAdmin);
    }

    function test_createInstitution_revert_duplicateId() public {
        vm.prank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, institutionAdmin);

        vm.expectRevert("Institution already exists");
        vm.prank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, otherAddress);
    }

    function test_createInstitution_revert_zeroAddressAdmin() public {
        vm.expectRevert("Admin cannot be zero address");
        vm.prank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, address(0));
    }

    function test_createInstitution_revert_notAuthorizedCaller() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert("Not authorized caller");
        manager.createInstitution(INSTITUTION_ID, institutionAdmin);
    }

    // ========== deleteInstitution ==========

    function test_deleteInstitution_success() public {
        vm.prank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, institutionAdmin);

        vm.expectEmit(true, false, false, true);
        emit VoteManager.InstitutionDeleted(INSTITUTION_ID);

        vm.prank(authorizedCaller);
        manager.deleteInstitution(INSTITUTION_ID);

        vm.expectRevert("Institution does not exist");
        manager.getInstitutionAdmin(INSTITUTION_ID);
    }

    function test_deleteInstitution_revert_nonExistentInstitution() public {
        vm.expectRevert("Institution does not exist");
        vm.prank(authorizedCaller);
        manager.deleteInstitution(INSTITUTION_ID);
    }

    function test_deleteInstitution_revert_notAuthorizedCaller() public {
        vm.prank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, institutionAdmin);

        vm.prank(unauthorizedCaller);
        vm.expectRevert("Not authorized caller");
        manager.deleteInstitution(INSTITUTION_ID);
    }

    // ========== addAuthorizedAddress ==========

    function test_addAuthorizedAddress_success() public {
        vm.prank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, institutionAdmin);

        vm.prank(institutionAdmin);
        manager.addAuthorizedAddress(INSTITUTION_ID, otherAddress);

        assertTrue(manager.isAuthorizedAddress(INSTITUTION_ID, otherAddress));
    }

    function test_addAuthorizedAddress_revert_zeroAddress() public {
        vm.prank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, institutionAdmin);

        vm.prank(institutionAdmin);
        vm.expectRevert("Address cannot be zero address");
        manager.addAuthorizedAddress(INSTITUTION_ID, address(0));
    }

    function test_addAuthorizedAddress_revert_nonExistentInstitution() public {
        vm.expectRevert("Institution does not exist");
        vm.prank(institutionAdmin);
        manager.addAuthorizedAddress(INSTITUTION_ID, otherAddress);
    }

    function test_addAuthorizedAddress_revert_notAdmin() public {
        vm.prank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, institutionAdmin);

        vm.prank(unauthorizedCaller);
        vm.expectRevert("Not institution admin");
        manager.addAuthorizedAddress(INSTITUTION_ID, otherAddress);
    }

    // ========== removeAuthorizedAddress ==========

    function test_removeAuthorizedAddress_success() public {
        vm.startPrank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, institutionAdmin);
        vm.stopPrank();

        vm.startPrank(institutionAdmin);
        manager.addAuthorizedAddress(INSTITUTION_ID, otherAddress);
        manager.removeAuthorizedAddress(INSTITUTION_ID, otherAddress);
        vm.stopPrank();

        assertFalse(manager.isAuthorizedAddress(INSTITUTION_ID, otherAddress));
    }

    function test_removeAuthorizedAddress_revert_nonExistentInstitution() public {
        vm.expectRevert("Institution does not exist");
        vm.prank(institutionAdmin);
        manager.removeAuthorizedAddress(INSTITUTION_ID, otherAddress);
    }

    function test_removeAuthorizedAddress_revert_notAdmin() public {
        vm.prank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, institutionAdmin);

        vm.prank(unauthorizedCaller);
        vm.expectRevert("Not institution admin");
        manager.removeAuthorizedAddress(INSTITUTION_ID, otherAddress);
    }

    // ========== changeInstitutionAdmin ==========

    function test_changeInstitutionAdmin_success() public {
        vm.prank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, institutionAdmin);

        vm.expectEmit(true, false, false, true);
        emit VoteManager.InstitutionAdminChanged(INSTITUTION_ID, otherAddress);

        vm.prank(institutionAdmin);
        manager.changeInstitutionAdmin(INSTITUTION_ID, otherAddress);

        assertEq(manager.getInstitutionAdmin(INSTITUTION_ID), otherAddress);
    }

    function test_changeInstitutionAdmin_revert_zeroAddress() public {
        vm.prank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, institutionAdmin);

        vm.prank(institutionAdmin);
        vm.expectRevert("New admin cannot be zero address");
        manager.changeInstitutionAdmin(INSTITUTION_ID, address(0));
    }

    function test_changeInstitutionAdmin_revert_nonExistentInstitution() public {
        vm.expectRevert("Institution does not exist");
        vm.prank(institutionAdmin);
        manager.changeInstitutionAdmin(INSTITUTION_ID, otherAddress);
    }

    function test_changeInstitutionAdmin_revert_notAdmin() public {
        vm.prank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, institutionAdmin);

        vm.prank(unauthorizedCaller);
        vm.expectRevert("Not institution admin");
        manager.changeInstitutionAdmin(INSTITUTION_ID, otherAddress);
    }

    function test_changeInstitutionAdmin_revert_oldAdminLosesAccess() public {
        vm.prank(authorizedCaller);
        manager.createInstitution(INSTITUTION_ID, institutionAdmin);

        vm.prank(institutionAdmin);
        manager.changeInstitutionAdmin(INSTITUTION_ID, otherAddress);

        vm.prank(institutionAdmin);
        vm.expectRevert("Not institution admin");
        manager.changeInstitutionAdmin(INSTITUTION_ID, institutionAdmin);
    }

    // ========== createVote ==========

    function test_createVote_success() public {
        vm.expectEmit(true, false, false, true);
        emit VoteManager.VoteCreated(VOTE_ID, VOTE_NAME);

        _createVote();

        (
            string memory name,
            uint48 sd,
            uint48 ed,
            uint48 rd,
            uint48 totalVoters,
            uint256 totalVotersMkRoot,
            string[] memory opts
        ) = manager.getVoteInfo(VOTE_ID);

        assertEq(name, VOTE_NAME);
        assertEq(sd, startDate);
        assertEq(ed, endDate);
        assertEq(rd, resultsDate);
        assertEq(totalVoters, ENABLED_VOTERS_COUNT);
        assertEq(totalVotersMkRoot, enabledVotersMkRoot);
        assertEq(opts.length, 3);
        assertEq(opts[0], "optionA");
        assertEq(opts[1], "optionB");
        assertEq(opts[2], "optionC");
        assertEq(manager.getVoteInstitutionId(VOTE_ID), VOTE_INSTITUTION_ID);

        // Credits were topped up from the institution admin's own TVD balance.
        (address institution, uint256 creditBalance, uint256 lockedTVD,,,,,,,) = creditsContract.getElection(VOTE_ID);
        assertEq(institution, institutionAdmin);
        assertEq(creditBalance, ENABLED_VOTERS_COUNT);
        assertEq(lockedTVD, uint256(ENABLED_VOTERS_COUNT) * TVD_PER_CREDIT);
        assertEq(
            tvdToken.balanceOf(institutionAdmin),
            INSTITUTION_TVD_FUNDING - uint256(ENABLED_VOTERS_COUNT) * TVD_PER_CREDIT
        );
    }

    function test_createVote_success_authorizedAddress() public {
        vm.prank(institutionAdmin);
        manager.addAuthorizedAddress(VOTE_INSTITUTION_ID, otherAddress);

        vm.prank(otherAddress);
        manager.createVote(
            VOTE_ID,
            VOTE_INSTITUTION_ID,
            VOTE_NAME,
            startDate,
            endDate,
            resultsDate,
            ENABLED_VOTERS_COUNT,
            enabledVotersMkRoot,
            options
        );

        assertEq(manager.getVoteInstitutionId(VOTE_ID), VOTE_INSTITUTION_ID);
    }

    function test_createVote_revert_emptyName() public {
        vm.expectRevert("Vote name cannot be empty");
        vm.prank(institutionAdmin);
        manager.createVote(
            VOTE_ID,
            VOTE_INSTITUTION_ID,
            "",
            startDate,
            endDate,
            resultsDate,
            ENABLED_VOTERS_COUNT,
            enabledVotersMkRoot,
            options
        );
    }

    function test_createVote_revert_duplicateId() public {
        _createVote();

        vm.expectRevert("Vote already exists");
        vm.prank(institutionAdmin);
        manager.createVote(
            VOTE_ID,
            VOTE_INSTITUTION_ID,
            "Another",
            startDate,
            endDate,
            resultsDate,
            ENABLED_VOTERS_COUNT,
            enabledVotersMkRoot,
            options
        );
    }

    function test_createVote_revert_emptyOptions() public {
        string[] memory emptyOpts = new string[](0);
        vm.expectRevert("Options cannot be empty");
        vm.prank(institutionAdmin);
        manager.createVote(
            VOTE_ID,
            VOTE_INSTITUTION_ID,
            VOTE_NAME,
            startDate,
            endDate,
            resultsDate,
            ENABLED_VOTERS_COUNT,
            enabledVotersMkRoot,
            emptyOpts
        );
    }

    function test_createVote_revert_invalidDates_startAfterEnd() public {
        vm.expectRevert("Start date must be before end date");
        vm.prank(institutionAdmin);
        manager.createVote(
            VOTE_ID,
            VOTE_INSTITUTION_ID,
            VOTE_NAME,
            endDate,
            startDate,
            resultsDate,
            ENABLED_VOTERS_COUNT,
            enabledVotersMkRoot,
            options
        );
    }

    function test_createVote_revert_invalidDates_endAfterResults() public {
        vm.expectRevert("End date must be before results date");
        vm.prank(institutionAdmin);
        manager.createVote(
            VOTE_ID,
            VOTE_INSTITUTION_ID,
            VOTE_NAME,
            startDate,
            resultsDate,
            endDate,
            ENABLED_VOTERS_COUNT,
            enabledVotersMkRoot,
            options
        );
    }

    function test_createVote_revert_notAuthorizedInInstitution() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert("Not authorized in institution");
        manager.createVote(
            VOTE_ID,
            VOTE_INSTITUTION_ID,
            VOTE_NAME,
            startDate,
            endDate,
            resultsDate,
            ENABLED_VOTERS_COUNT,
            enabledVotersMkRoot,
            options
        );
    }

    function test_createVote_revert_institutionDoesNotExist() public {
        vm.expectRevert("Institution does not exist");
        vm.prank(institutionAdmin);
        manager.createVote(
            VOTE_ID,
            "no-such-institution",
            VOTE_NAME,
            startDate,
            endDate,
            resultsDate,
            ENABLED_VOTERS_COUNT,
            enabledVotersMkRoot,
            options
        );
    }

    // ========== updateVoteDates ==========

    function test_updateVoteDates_success() public {
        _createVote();

        uint48 newStart = uint48(block.timestamp + 3 days);
        uint48 newEnd = uint48(block.timestamp + 5 days);
        uint48 newResults = uint48(block.timestamp + 7 days);

        vm.prank(institutionAdmin);
        manager.updateVoteDates(VOTE_ID, newStart, newEnd, newResults);

        (, uint48 sd, uint48 ed, uint48 rd,,,) = manager.getVoteInfo(VOTE_ID);
        assertEq(sd, newStart);
        assertEq(ed, newEnd);
        assertEq(rd, newResults);
    }

    function test_updateVoteDates_revert_nonExistentVote() public {
        vm.expectRevert("Vote does not exist");
        vm.prank(institutionAdmin);
        manager.updateVoteDates(99, startDate, endDate, resultsDate);
    }

    function test_updateVoteDates_revert_tooNearStartDate() public {
        _createVote();

        // Warp to 23 hours before start (less than 24h buffer)
        vm.warp(startDate - 23 hours);

        uint48 newStart = uint48(block.timestamp + 3 days);
        uint48 newEnd = uint48(block.timestamp + 5 days);
        uint48 newResults = uint48(block.timestamp + 7 days);

        vm.expectRevert("Too near to vote start date");
        vm.prank(institutionAdmin);
        manager.updateVoteDates(VOTE_ID, newStart, newEnd, newResults);
    }

    function test_updateVoteDates_revert_invalidDates() public {
        _createVote();

        vm.expectRevert("Start date must be before end date");
        vm.prank(institutionAdmin);
        manager.updateVoteDates(VOTE_ID, endDate, startDate, resultsDate);
    }

    function test_updateVoteDates_revert_notAuthorizedInInstitution() public {
        _createVote();

        vm.prank(unauthorizedCaller);
        vm.expectRevert("Not authorized in institution");
        manager.updateVoteDates(VOTE_ID, startDate, endDate, resultsDate);
    }

    function test_updateVoteDates_revert_voteDisabled() public {
        vm.startPrank(institutionAdmin);
        _createVoteAsPrankedAdmin();
        manager.disableVote(VOTE_ID);
        vm.stopPrank();

        uint48 newStart = uint48(block.timestamp + 3 days);
        uint48 newEnd = uint48(block.timestamp + 5 days);
        uint48 newResults = uint48(block.timestamp + 7 days);

        vm.expectRevert("Vote is not active");
        vm.prank(institutionAdmin);
        manager.updateVoteDates(VOTE_ID, newStart, newEnd, newResults);
    }

    // ========== disableVote ==========

    function test_disableVote_success() public {
        _createVote();

        vm.prank(institutionAdmin);
        manager.disableVote(VOTE_ID);

        vm.warp(startDate);
        vm.expectRevert("Vote is not active");
        vm.prank(authorizedCaller);
        manager.castVote("optionA", VOTE_ID, 111);
    }

    function test_disableVote_revert_notAuthorizedInInstitution() public {
        _createVote();

        vm.prank(unauthorizedCaller);
        vm.expectRevert("Not authorized in institution");
        manager.disableVote(VOTE_ID);
    }

    function test_disableVote_revert_notActiveVote() public {
        vm.startPrank(institutionAdmin);
        _createVoteAsPrankedAdmin();
        manager.disableVote(VOTE_ID);

        vm.expectRevert("Vote is not active");
        manager.disableVote(VOTE_ID);
        vm.stopPrank();
    }

    // ========== castVote ==========

    function test_castVote_success() public {
        _createVote();
        vm.warp(startDate);

        vm.expectEmit(true, false, false, false);
        emit VoteManager.Voted(VOTE_ID);

        _castVote("optionA", 111);

        // One voting credit was consumed.
        (,, uint256 lockedTVD, uint256 pendingTVD,,,,,,) = creditsContract.getElection(VOTE_ID);
        assertEq(pendingTVD, TVD_PER_CREDIT);
        assertEq(lockedTVD, (uint256(ENABLED_VOTERS_COUNT) - 1) * TVD_PER_CREDIT);
    }

    function test_castVote_multipleVoters() public {
        _createVote();
        vm.warp(startDate);

        _castVote("optionA", 111);
        _castVote("optionB", 222);
        _castVote("optionA", 333);

        // Check results after results date
        vm.warp(resultsDate + 1);
        (string[] memory opts, uint256[] memory counts) = manager.getVoteResults(VOTE_ID);

        assertEq(opts.length, 3);
        assertEq(counts[0], 2); // optionA got 2 votes
        assertEq(counts[1], 1); // optionB got 1 vote
        assertEq(counts[2], 0); // optionC got 0 votes
    }

    function test_castVote_revert_nonExistentVote() public {
        vm.expectRevert("Vote does not exist");
        vm.prank(authorizedCaller);
        manager.castVote("optionA", 99, 111);
    }

    function test_castVote_revert_votingNotActive_tooEarly() public {
        _createVote();

        // Don't warp — still before startDate
        vm.expectRevert("Voting is not active");
        vm.prank(authorizedCaller);
        manager.castVote("optionA", VOTE_ID, 111);
    }

    function test_castVote_revert_votingNotActive_tooLate() public {
        _createVote();
        vm.warp(endDate + 1);

        vm.expectRevert("Voting is not active");
        vm.prank(authorizedCaller);
        manager.castVote("optionA", VOTE_ID, 111);
    }

    function test_castVote_revert_invalidOption() public {
        _createVote();
        vm.warp(startDate);

        vm.expectRevert("Invalid option");
        vm.prank(authorizedCaller);
        manager.castVote("nonExistent", VOTE_ID, 111);
    }

    function test_castVote_revert_nullifierAlreadyUsed() public {
        _createVote();
        vm.warp(startDate);

        _castVote("optionA", 111);

        vm.expectRevert("Nullifier already used");
        vm.prank(authorizedCaller);
        manager.castVote("optionB", VOTE_ID, 111);
    }

    function test_castVote_revert_notAuthorizedCaller() public {
        _createVote();
        vm.warp(startDate);

        vm.expectRevert("Not authorized caller");
        vm.prank(unauthorizedCaller);
        manager.castVote("optionA", VOTE_ID, 111);
    }

    function test_castVote_revert_voteDisabled() public {
        vm.startPrank(institutionAdmin);
        _createVoteAsPrankedAdmin();
        manager.disableVote(VOTE_ID);
        vm.stopPrank();

        vm.expectRevert("Vote is not active");
        vm.prank(authorizedCaller);
        manager.castVote("optionA", VOTE_ID, 111);
    }

    // ========== getVoteResults ==========

    function test_getVoteResults_revert_beforeResultsDate() public {
        _createVote();
        vm.warp(resultsDate); // exactly at resultsDate, not after

        vm.expectRevert("Results are not available yet");
        manager.getVoteResults(VOTE_ID);
    }

    function test_getVoteResults_revert_nonExistentVote() public {
        vm.expectRevert("Vote does not exist");
        manager.getVoteResults(99);
    }

    function test_getVoteResults_noVotesCast() public {
        _createVote();
        vm.warp(resultsDate + 1);

        (string[] memory opts, uint256[] memory counts) = manager.getVoteResults(VOTE_ID);
        assertEq(opts.length, 3);
        for (uint256 i = 0; i < counts.length; i++) {
            assertEq(counts[i], 0);
        }
    }

    function test_getVoteResults_revert_voteDisabled_beforeResultsDate() public {
        vm.startPrank(institutionAdmin);
        _createVoteAsPrankedAdmin();
        manager.disableVote(VOTE_ID);
        vm.stopPrank();

        vm.expectRevert("Results are not available yet");
        manager.getVoteResults(VOTE_ID);
    }

    // ========== getVoteInfo ==========

    function test_getVoteInfo_revert_nonExistentVote() public {
        vm.expectRevert("Vote does not exist");
        manager.getVoteInfo(99);
    }

    function test_getVoteInfo_success_voteDisabled() public {
        vm.startPrank(institutionAdmin);
        _createVoteAsPrankedAdmin();
        manager.disableVote(VOTE_ID);
        vm.stopPrank();

        (
            string memory name,
            uint48 sd,
            uint48 ed,
            uint48 rd,
            uint48 totalVoters,
            uint256 totalVotersMkRoot,
            string[] memory opts
        ) = manager.getVoteInfo(VOTE_ID);

        assertEq(name, VOTE_NAME);
        assertEq(sd, startDate);
        assertEq(ed, endDate);
        assertEq(rd, resultsDate);
        assertEq(totalVoters, ENABLED_VOTERS_COUNT);
        assertEq(totalVotersMkRoot, enabledVotersMkRoot);
        assertEq(opts.length, 3);
    }

    // ========== getOwnVoteInfo ==========

    function test_getOwnVoteInfo_success() public {
        _createVote();
        vm.warp(startDate);

        _castVote("optionB", 222);

        (bool hasVoted, string memory optionVoted) = manager.getOwnVoteInfo(VOTE_ID, 222);
        assertTrue(hasVoted);
        assertEq(optionVoted, "optionB");
    }

    function test_getOwnVoteInfo_revert_notVotedYet() public {
        _createVote();

        vm.expectRevert("Not voted yet");
        manager.getOwnVoteInfo(VOTE_ID, 111);
    }

    function test_getOwnVoteInfo_revert_nonExistentVote() public {
        vm.expectRevert("Vote does not exist");
        manager.getOwnVoteInfo(99, 111);
    }

    function test_getOwnVoteInfo_success_voteDisabled() public {
        _createVote();
        vm.warp(startDate);

        _castVote("optionA", 111);

        vm.prank(institutionAdmin);
        manager.disableVote(VOTE_ID);

        (bool hasVoted, string memory optionVoted) = manager.getOwnVoteInfo(VOTE_ID, 111);
        assertTrue(hasVoted);
        assertEq(optionVoted, "optionA");
    }

    // ========== claimVoteReward ==========

    function test_claimVoteReward_success() public {
        manager.setTvdPerVote(10e18);
        _createVote();
        vm.warp(endDate + 1);

        uint256 claimerBalanceBefore = tvdToken.balanceOf(rewardClaimer);

        vm.expectEmit(true, true, false, true);
        emit VoteManager.Rewarded(VOTE_ID, rewardClaimer);

        vm.prank(authorizedCaller);
        manager.claimVoteReward(VOTE_ID, 555, rewardClaimer);

        assertEq(tvdToken.balanceOf(rewardClaimer), claimerBalanceBefore + 10e18);
    }

    function test_claimVoteReward_revert_notAuthorizedCaller() public {
        manager.setTvdPerVote(10e18);
        _createVote();
        vm.warp(endDate + 1);

        vm.expectRevert("Not authorized caller");
        vm.prank(unauthorizedCaller);
        manager.claimVoteReward(VOTE_ID, 555, rewardClaimer);
    }

    function test_claimVoteReward_revert_voteNotEnded() public {
        manager.setTvdPerVote(10e18);
        _createVote();

        vm.expectRevert("Vote has not ended yet");
        vm.prank(authorizedCaller);
        manager.claimVoteReward(VOTE_ID, 555, rewardClaimer);
    }

    function test_claimVoteReward_revert_alreadyRewarded() public {
        manager.setTvdPerVote(10e18);
        _createVote();
        vm.warp(endDate + 1);

        vm.prank(authorizedCaller);
        manager.claimVoteReward(VOTE_ID, 555, rewardClaimer);

        vm.expectRevert("Already rewarded");
        vm.prank(authorizedCaller);
        manager.claimVoteReward(VOTE_ID, 555, rewardClaimer);
    }

    function test_claimVoteReward_revert_nonExistentVote() public {
        manager.setTvdPerVote(10e18);

        vm.expectRevert("Vote does not exist");
        vm.prank(authorizedCaller);
        manager.claimVoteReward(99, 555, rewardClaimer);
    }

    function test_claimVoteReward_revert_insufficientBalance() public {
        manager.setTvdPerVote(INSTITUTION_TVD_FUNDING + 1);
        _createVote();
        vm.warp(endDate + 1);

        vm.expectRevert("Insufficient contract balance");
        vm.prank(authorizedCaller);
        manager.claimVoteReward(VOTE_ID, 555, rewardClaimer);
    }

    // ========== hasReceivedReward ==========

    function test_hasReceivedReward_falseBeforeClaim() public {
        _createVote();

        assertFalse(manager.hasReceivedReward(VOTE_ID, 555));
    }

    function test_hasReceivedReward_trueAfterClaim() public {
        manager.setTvdPerVote(10e18);
        _createVote();
        vm.warp(endDate + 1);

        vm.prank(authorizedCaller);
        manager.claimVoteReward(VOTE_ID, 555, rewardClaimer);

        assertTrue(manager.hasReceivedReward(VOTE_ID, 555));
    }

    function test_hasReceivedReward_falseForDifferentRewardHash() public {
        manager.setTvdPerVote(10e18);
        _createVote();
        vm.warp(endDate + 1);

        vm.prank(authorizedCaller);
        manager.claimVoteReward(VOTE_ID, 555, rewardClaimer);

        assertFalse(manager.hasReceivedReward(VOTE_ID, 666));
    }

    function test_hasReceivedReward_falseForNonExistentVote() public view {
        assertFalse(manager.hasReceivedReward(99, 555));
    }

    // ========== internal helpers that must run inside vm.startPrank ==========

    function _createVoteAsPrankedAdmin() internal {
        manager.createVote(
            VOTE_ID,
            VOTE_INSTITUTION_ID,
            VOTE_NAME,
            startDate,
            endDate,
            resultsDate,
            ENABLED_VOTERS_COUNT,
            enabledVotersMkRoot,
            options
        );
    }
}
