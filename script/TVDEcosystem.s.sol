// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {TVDToken} from "../src/tvd-token/TVDToken.sol";
import {TVDVesting} from "../src/tvd-token/TVDVesting.sol";
import {TVDInstitutionalVesting} from "../src/tvd-token/TVDInstitutionalVesting.sol";
import {TVDElectoralCredits} from "../src/tvd-token/TVDElectoralCredits.sol";
import {TVDIncentiveCampaigns} from "../src/tvd-token/TVDIncentiveCampaigns.sol";

contract TVDEcosystemScript is Script {
    uint256 constant VESTING_POOL = 3_150_000e18;
    address adminAddr;
    uint256 adminPk;

    function setUp() public {
        adminAddr = vm.envAddress("ADMIN_WALLET");
        adminPk = vm.envUint("ADMIN_PK");
    }

    function run() public {
        address token = deployToken();

        deployInsitutionalVesting(token);
        deployElectoralCredits(token);
        deployIncentiveCampaign(token);
    }

    function deployToken() public returns (address tokenAddr) {
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
}
