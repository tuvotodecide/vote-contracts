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

        address voteProxy = Upgrades.deployUUPSProxy(
            "BackVoteManager.sol",
            abi.encodeCall(BackVoteManager.initialize, (msg.sender, caller))
        );

        vm.stopBroadcast();

        console.log("Contract deployed at:", voteProxy, "With sender:", msg.sender);
    }
}
