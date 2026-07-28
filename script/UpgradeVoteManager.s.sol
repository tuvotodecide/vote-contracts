// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

contract UpgradeVoteManagerScript is Script {
    function run() public {
        address proxy = vm.envAddress("BACK_VOTE_PROXY");
        Options memory opts;
        opts.referenceContract = "VoteManagerV2.sol:VoteManager";

        vm.startBroadcast();

        Upgrades.upgradeProxy(proxy, "VoteManager.sol:VoteManager", "", opts);

        vm.stopBroadcast();

        console.log("VoteManager proxy upgraded:", proxy);
    }
}
