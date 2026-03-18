// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {VoteManager} from "../src/VoteManager.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

contract VoteManagerScript is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        Options memory opts;
        opts.unsafeAllow = "external-library-linking";

        address voteProxy = Upgrades.deployUUPSProxy(
            "VoteManager.sol",
            abi.encodeCall(VoteManager.initialize, ()),
            opts
        );

        vm.stopBroadcast();

        console.log("Contract deployed at:", voteProxy);
    }
}
