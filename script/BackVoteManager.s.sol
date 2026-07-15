// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {BackVoteManager} from "../src/BackVoteManager.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract BackVoteManagerScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address caller = address(0x2Df3821cf770C501aaAB5F8F2e30C55c7e249010);
        address creditsContract = vm.envAddress("TVD_ELECTORAL_CREDITS");
        address voteRewardClaimVerifier = vm.envAddress("VOTE_REWARD_CLAIM_VERIFIER");
        address tvdToken = vm.envAddress("TVD_TOKEN");

        address voteProxy = Upgrades.deployUUPSProxy(
            "BackVoteManager.sol",
            abi.encodeCall(
                BackVoteManager.initialize, (msg.sender, caller, creditsContract, voteRewardClaimVerifier, tvdToken)
            )
        );

        vm.stopBroadcast();

        console.log("Contract deployed at:", voteProxy, "With sender:", msg.sender);
    }
}
