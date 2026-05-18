// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

contract UpgradeBackVoteManagerScript is Script {
    function run() public {
        address proxy = vm.envAddress("BACK_VOTE_PROXY");
        Options memory opts;
        opts.referenceContract = "BackVoteManagerV1.sol:BackVoteManager";

        vm.startBroadcast();

        Upgrades.upgradeProxy(proxy, "BackVoteManager.sol:BackVoteManager", "", opts);

        vm.stopBroadcast();

        console.log("BackVoteManager proxy upgraded:", proxy);
    }
}
