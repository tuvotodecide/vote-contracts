// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {TVDToken} from "../src/tvd-token/TVDToken.sol";
import {TVDVesting} from "../src/tvd-token/TVDVesting.sol";
import {TVDInstitutionalVesting} from "../src/tvd-token/TVDInstitutionalVesting.sol";
import {TVDElectoralCredits} from "../src/tvd-token/TVDElectoralCredits.sol";
import {TVDIncentiveCampaigns} from "../src/tvd-token/TVDIncentiveCampaigns.sol";
import {VoteManager} from "../src/VoteManager.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract TVDEcosystemScript is Script {
    uint256 constant VESTING_POOL = 3_150_000e18;
    address adminAddr;
    uint256 adminPk;
    address finalAdminAddr;

    function setUp() public {
        adminAddr = vm.envAddress("ADMIN_WALLET");
        adminPk = vm.envUint("ADMIN_PK");
        finalAdminAddr = vm.envAddress("FINAL_ADMIN_WALLET");
    }

    function run() public {
        (address token, address vesting) = deployToken();

        address instVesting = deployInsitutionalVesting(token);
        address credits = deployElectoralCredits(token);
        address incentive = deployIncentiveCampaign(token);
        deployVoteManager(token, credits);

        transferAdminRoles(token, vesting, instVesting, credits, incentive);
    }

    function deployToken() public returns (address tokenAddr, address vestingAddr) {
        uint256 lockupEnd = vm.envUint("TOKEN_LOCKUP_END_TIMESTAMP");
        address liquidityWallet = vm.envAddress("LIQUIDITY_WALLET");
        address treasuryWallet = vm.envAddress("TREASURY_WALLET");
        address ecosystemWallet = vm.envAddress("ECOSYSTEM_WALLET");
        address tempVestingWallet = vm.envAddress("TEMP_VESTING_WALLET");
        uint256 tempVestingPrivateKey = vm.envUint("TEMP_VESTING_PRIVATE_KEY");

        vm.startBroadcast();
        TVDToken token =
            new TVDToken(lockupEnd, liquidityWallet, treasuryWallet, ecosystemWallet, tempVestingWallet, adminAddr);
        TVDVesting vestingContract = new TVDVesting(address(token), adminAddr);
        vm.stopBroadcast();
        console.log("TVDVesting Contract deployed at:", address(vestingContract), "With sender:", msg.sender);

        vm.startBroadcast(tempVestingPrivateKey);
        bool sucess = token.transfer(address(vestingContract), VESTING_POOL);
        require(sucess, "TVD transfer to vesting pool failed");
        vm.stopBroadcast();

        tokenAddr = address(token);
        vestingAddr = address(vestingContract);
        console.log("TVDToken Contract deployed at:", tokenAddr, "With sender:", msg.sender);
    }

    function deployInsitutionalVesting(address tokenAddr) public returns (address instVestingAddr) {
        address operator = vm.envAddress("OPERATOR_WALLET");

        vm.startBroadcast();
        TVDInstitutionalVesting instVesting = new TVDInstitutionalVesting(tokenAddr, adminAddr, operator);
        vm.stopBroadcast();
        instVestingAddr = address(instVesting);

        TVDToken token = TVDToken(tokenAddr);
        vm.startBroadcast(adminPk);
        token.grantRole(token.LOCKUP_MANAGER_ROLE(), instVestingAddr);
        vm.stopBroadcast();

        console.log("TVDInstitutionalVesting contract deployed at:", instVestingAddr, "With sender", msg.sender);
    }

    function deployElectoralCredits(address tokenAddr) public returns (address creditsAddr) {
        uint256 tvdPerCredit = vm.envUint("TVD_PER_CREDIT");
        address platformWallet = vm.envAddress("PLATFORM_WALLET");
        uint256 maxTokenPerElection = vm.envOr("MAX_TOKEN_PER_ELECTION", uint256(100_000e18));
        address operator = vm.envAddress("OPERATOR_WALLET");

        vm.startBroadcast();
        TVDElectoralCredits credits = new TVDElectoralCredits(tokenAddr, adminAddr, tvdPerCredit, platformWallet);
        vm.stopBroadcast();
        creditsAddr = address(credits);

        TVDToken token = TVDToken(tokenAddr);
        vm.startBroadcast(adminPk);
        token.grantRole(token.LOCKUP_BYPASS_ROLE(), creditsAddr);
        if (maxTokenPerElection != credits.maxTokenPerElection()) {
            credits.setMaxTokenPerElection(maxTokenPerElection);
        }
        credits.grantRole(credits.OPERATOR_ROLE(), operator);
        vm.stopBroadcast();

        console.log("TVDElectoralCredits contract deployed at:", creditsAddr, "With sender", msg.sender);
    }

    function deployIncentiveCampaign(address tokenAddr) public returns (address incentiveAddr) {
        address operator = vm.envAddress("OPERATOR_WALLET");

        vm.startBroadcast();
        TVDIncentiveCampaigns incentive = new TVDIncentiveCampaigns(tokenAddr, adminAddr, operator);
        vm.stopBroadcast();
        incentiveAddr = address(incentive);

        TVDToken token = TVDToken(tokenAddr);
        vm.startBroadcast(adminPk);
        token.grantRole(token.LOCKUP_MANAGER_ROLE(), incentiveAddr);
        vm.stopBroadcast();

        console.log("TVDIncentiveCampaigns contract deployed at:", incentiveAddr, "With sender", msg.sender);
    }

    function deployVoteManager(address tokenAddr, address creditsAddr) public returns (address voteManagerAddr) {
        address caller = vm.envAddress("VOTE_MANAGER_AUTH_CALLER");

        vm.startBroadcast();
        voteManagerAddr = Upgrades.deployUUPSProxy(
            "VoteManager.sol", abi.encodeCall(VoteManager.initialize, (finalAdminAddr, caller, creditsAddr, tokenAddr))
        );
        vm.stopBroadcast();

        TVDToken token = TVDToken(tokenAddr);
        TVDElectoralCredits credits = TVDElectoralCredits(creditsAddr);
        vm.startBroadcast(adminPk);
        token.grantRole(token.LOCKUP_MANAGER_ROLE(), voteManagerAddr);
        credits.grantRole(credits.OPERATOR_ROLE(), voteManagerAddr);
        vm.stopBroadcast();

        console.log("VoteManager contract deployed at:", voteManagerAddr, "With owner:", finalAdminAddr);
    }

    function transferAdminRoles(
        address tokenAddr,
        address vestingAddr,
        address instVestingAddr,
        address creditsAddr,
        address incentiveAddr
    ) public {
        require(finalAdminAddr != address(0), "TVDEcosystem: invalid final admin");

        TVDToken token = TVDToken(tokenAddr);
        TVDVesting vesting = TVDVesting(vestingAddr);
        TVDInstitutionalVesting instVesting = TVDInstitutionalVesting(instVestingAddr);
        TVDElectoralCredits credits = TVDElectoralCredits(creditsAddr);
        TVDIncentiveCampaigns incentive = TVDIncentiveCampaigns(incentiveAddr);

        vm.startBroadcast(adminPk);

        token.grantRole(token.DEFAULT_ADMIN_ROLE(), finalAdminAddr);
        token.renounceRole(token.DEFAULT_ADMIN_ROLE(), adminAddr);

        vesting.transferOwnership(finalAdminAddr);

        instVesting.grantRole(instVesting.DEFAULT_ADMIN_ROLE(), finalAdminAddr);
        instVesting.renounceRole(instVesting.DEFAULT_ADMIN_ROLE(), adminAddr);

        credits.grantRole(credits.DEFAULT_ADMIN_ROLE(), finalAdminAddr);
        credits.renounceRole(credits.DEFAULT_ADMIN_ROLE(), adminAddr);

        incentive.grantRole(incentive.DEFAULT_ADMIN_ROLE(), finalAdminAddr);
        incentive.renounceRole(incentive.DEFAULT_ADMIN_ROLE(), adminAddr);

        vm.stopBroadcast();

        console.log("Admin roles transferred from", adminAddr, "to FINAL_ADMIN_WALLET:", finalAdminAddr);
    }
}
