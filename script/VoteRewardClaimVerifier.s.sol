// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {VoteRewardClaimVerifier} from "../src/circuits/VoteRewardClaimVerifier.sol";

contract VoteRewardClaimVerifierScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        VoteRewardClaimVerifier verifier = new VoteRewardClaimVerifier();

        vm.stopBroadcast();

        console.log("Contract VoteRewardClaimVerifier deployed at:", address(verifier), "With sender:", msg.sender);
    }
}
