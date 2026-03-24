// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {SimpleVoteManager} from "../src/SimpleVoteManager.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract SimpleVoteManagerScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address voteProxy = Upgrades.deployUUPSProxy(
            "SimpleVoteManager.sol",
            abi.encodeCall(SimpleVoteManager.initialize, (msg.sender))
        );

        vm.stopBroadcast();

        console.log("Contract deployed at:", voteProxy, "With sender:", msg.sender);
    }
}
