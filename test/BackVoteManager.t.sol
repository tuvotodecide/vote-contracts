// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {BackVoteManager} from "../src/BackVoteManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract BackVoteManagerTest is Test {
    BackVoteManager public manager;
    address public owner;
    address public nonOwner;
    address public authorizedCaller;
    address public unauthorizedCaller;

    string constant VOTE_ID = "vote-1";
    string constant VOTE_NAME = "Test Vote";

    // Timestamps used across tests
    uint48 startDate;
    uint48 endDate;
    uint48 resultsDate;

    string[] voters;
    string[] options;

    function setUp() public {
        owner = address(this);
        nonOwner = address(0xBEEF);
        authorizedCaller = address(0xCA11);
        unauthorizedCaller = address(0xD00D);

        // Deploy implementation + proxy
        BackVoteManager impl = new BackVoteManager();
        bytes memory initData = abi.encodeCall(BackVoteManager.initialize, (owner, authorizedCaller));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        manager = BackVoteManager(address(proxy));

        // Default dates: start in 2 days, end in 4 days, results in 6 days
        startDate = uint48(block.timestamp + 2 days);
        endDate   = uint48(block.timestamp + 4 days);
        resultsDate = uint48(block.timestamp + 6 days);

        // Default voters
        voters = new string[](3);
        voters[0] = "111";
        voters[1] = "222";
        voters[2] = "333";

        // Default options
        options = new string[](3);
        options[0] = "optionA";
        options[1] = "optionB";
        options[2] = "optionC";
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
        manager.initialize(nonOwner, unauthorizedCaller);
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

    // ========== createVote ==========

    function test_createVote_success() public {
        vm.expectEmit(true, false, false, true);
        emit BackVoteManager.VoteCreated(VOTE_ID, VOTE_NAME);

        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);

        (string memory name, uint48 sd, uint48 ed, uint48 rd, uint48 totalVoters, string[] memory opts) =
            manager.getVoteInfo(VOTE_ID);

        assertEq(name, VOTE_NAME);
        assertEq(sd, startDate);
        assertEq(ed, endDate);
        assertEq(rd, resultsDate);
        assertEq(totalVoters, 3);
        assertEq(opts.length, 3);
        assertEq(opts[0], "optionA");
        assertEq(opts[1], "optionB");
        assertEq(opts[2], "optionC");
    }

    function test_createVote_revert_emptyName() public {
        vm.expectRevert("Vote name cannot be empty");
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, "", startDate, endDate, resultsDate, voters, options);
    }

    function test_createVote_revert_duplicateId() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);

        vm.expectRevert("Vote already exists");
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, "Another", startDate, endDate, resultsDate, voters, options);
    }

    function test_createVote_revert_emptyOptions() public {
        string[] memory emptyOpts = new string[](0);
        vm.expectRevert("Options cannot be empty");
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, emptyOpts);
    }

    function test_createVote_revert_invalidDates_startAfterEnd() public {
        vm.expectRevert("Start date must be before end date");
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, endDate, startDate, resultsDate, voters, options);
    }

    function test_createVote_revert_invalidDates_endAfterResults() public {
        vm.expectRevert("End date must be before results date");
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, resultsDate, endDate, voters, options);
    }

    function test_createVote_revert_notAuthorizedCaller() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert("Not authorized caller");
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);
    }

    // ========== updateVoteDates ==========

    function test_updateVoteDates_success() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);

        uint48 newStart = uint48(block.timestamp + 3 days);
        uint48 newEnd   = uint48(block.timestamp + 5 days);
        uint48 newResults = uint48(block.timestamp + 7 days);

        vm.prank(authorizedCaller);
        manager.updateVoteDates(VOTE_ID, newStart, newEnd, newResults);

        (, uint48 sd, uint48 ed, uint48 rd,,) = manager.getVoteInfo(VOTE_ID);
        assertEq(sd, newStart);
        assertEq(ed, newEnd);
        assertEq(rd, newResults);
    }

    function test_updateVoteDates_revert_nonExistentVote() public {
        vm.expectRevert("Vote does not exist");
        vm.prank(authorizedCaller);
        manager.updateVoteDates("99", startDate, endDate, resultsDate);
    }

    function test_updateVoteDates_revert_tooNearStartDate() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);

        // Warp to 23 hours before start (less than 24h buffer)
        vm.warp(startDate - 23 hours);

        uint48 newStart = uint48(block.timestamp + 3 days);
        uint48 newEnd   = uint48(block.timestamp + 5 days);
        uint48 newResults = uint48(block.timestamp + 7 days);

        vm.expectRevert("Too near to vote start date");
        vm.prank(authorizedCaller);
        manager.updateVoteDates(VOTE_ID, newStart, newEnd, newResults);
    }

    function test_updateVoteDates_revert_invalidDates() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);

        vm.expectRevert("Start date must be before end date");
        vm.prank(authorizedCaller);
        manager.updateVoteDates(VOTE_ID, endDate, startDate, resultsDate);
    }

    function test_updateVoteDates_revert_notAuthorizedCaller() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);

        vm.prank(unauthorizedCaller);
        vm.expectRevert("Not authorized caller");
        manager.updateVoteDates(VOTE_ID, startDate, endDate, resultsDate);
    }

    // ========== castVote ==========

    function test_castVote_success() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);

        // Warp into voting period
        vm.warp(startDate);

        vm.expectEmit(true, false, false, false);
        emit BackVoteManager.Voted(VOTE_ID);

        vm.prank(authorizedCaller);
        manager.castVote(VOTE_ID, "optionA", "111");
    }

    function test_castVote_multipleVoters() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);
        vm.warp(startDate);

        vm.startPrank(authorizedCaller);
        manager.castVote(VOTE_ID, "optionA", "111");
        manager.castVote(VOTE_ID, "optionB", "222");
        manager.castVote(VOTE_ID, "optionA", "333");
        vm.stopPrank();

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
        manager.castVote("99", "optionA", "111");
    }

    function test_castVote_revert_notEligible() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);
        vm.warp(startDate);

        vm.expectRevert("Not eligible to vote");
        vm.prank(authorizedCaller);
        manager.castVote(VOTE_ID, "optionA", "999"); // 999 is not a registered voter
    }

    function test_castVote_revert_votingNotActive_tooEarly() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);

        // Don't warp — still before startDate
        vm.expectRevert("Voting is not active");
        vm.prank(authorizedCaller);
        manager.castVote(VOTE_ID, "optionA", "111");
    }

    function test_castVote_revert_votingNotActive_tooLate() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);
        vm.warp(endDate + 1);

        vm.expectRevert("Voting is not active");
        vm.prank(authorizedCaller);
        manager.castVote(VOTE_ID, "optionA", "111");
    }

    function test_castVote_revert_invalidOption() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);
        vm.warp(startDate);

        vm.expectRevert("Invalid option");
        vm.prank(authorizedCaller);
        manager.castVote(VOTE_ID, "nonExistent", "111");
    }

    function test_castVote_revert_nullifierAlreadyUsed() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);
        vm.warp(startDate);

        vm.prank(authorizedCaller);
        manager.castVote(VOTE_ID, "optionA", "111");

        vm.expectRevert("Nullifier already used");
        vm.prank(authorizedCaller);
        manager.castVote(VOTE_ID, "optionB", "111");
    }

    function test_castVote_revert_notAuthorizedCaller() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);
        vm.warp(startDate);

        vm.prank(unauthorizedCaller);
        vm.expectRevert("Not authorized caller");
        manager.castVote(VOTE_ID, "optionA", "111");
    }

    // ========== getVoteResults ==========

    function test_getVoteResults_revert_beforeResultsDate() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);
        vm.warp(resultsDate); // exactly at resultsDate, not after

        vm.expectRevert("Results are not available yet");
        manager.getVoteResults(VOTE_ID);
    }

    function test_getVoteResults_revert_nonExistentVote() public {
        vm.expectRevert("Vote does not exist");
        manager.getVoteResults("99");
    }

    function test_getVoteResults_noVotesCast() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);
        vm.warp(resultsDate + 1);

        (string[] memory opts, uint256[] memory counts) = manager.getVoteResults(VOTE_ID);
        assertEq(opts.length, 3);
        for (uint i = 0; i < counts.length; i++) {
            assertEq(counts[i], 0);
        }
    }

    // ========== getVoteInfo ==========

    function test_getVoteInfo_revert_nonExistentVote() public {
        vm.expectRevert("Vote does not exist");
        manager.getVoteInfo("99");
    }

    // ========== getOwnVoteInfo ==========

    function test_getOwnVoteInfo_success() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);
        vm.warp(startDate);

        vm.prank(authorizedCaller);
        manager.castVote(VOTE_ID, "optionB", "222");

        (bool hasVoted, string memory optionVoted) = manager.getOwnVoteInfo(VOTE_ID, "222");
        assertTrue(hasVoted);
        assertEq(optionVoted, "optionB");
    }

    function test_getOwnVoteInfo_revert_notVotedYet() public {
        vm.prank(authorizedCaller);
        manager.createVote(VOTE_ID, VOTE_NAME, startDate, endDate, resultsDate, voters, options);

        vm.expectRevert("Not voted yet");
        manager.getOwnVoteInfo(VOTE_ID, "111");
    }

    function test_getOwnVoteInfo_revert_nonExistentVote() public {
        vm.expectRevert("Vote does not exist");
        manager.getOwnVoteInfo("99", "111");
    }
}
