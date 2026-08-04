// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {VoteManager} from "../src/VoteManager.sol";
import {TVDToken} from "../src/tvd-token/TVDToken.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract VoteManagerScript is Script {
    function setUp() public {}

    function run() public {
        address caller = vm.envAddress("VOTE_MANAGER_AUTH_CALLER");
        address creditsContract = vm.envAddress("TVD_ELECTORAL_CREDITS");
        address tvdToken = vm.envAddress("TVD_TOKEN");
        uint256 adminPk = vm.envUint("ADMIN_PK");

        vm.startBroadcast();
        address voteProxy = Upgrades.deployUUPSProxy(
            "VoteManager.sol", abi.encodeCall(VoteManager.initialize, (msg.sender, caller, creditsContract, tvdToken))
        );
        vm.stopBroadcast();

        vm.startBroadcast(adminPk);
        TVDToken token = TVDToken(tvdToken);
        token.grantRole(token.LOCKUP_MANAGER_ROLE(), voteProxy);
        vm.stopBroadcast();

        console.log("Contract deployed at:", voteProxy, "With sender:", msg.sender);
        console.log("Assign this contract as operator in ElectoralCredits is required");
    }
}
