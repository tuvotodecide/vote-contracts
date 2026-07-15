// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {TVDToken} from "../src/tvd-token/TVDToken.sol";
import {TVDVesting} from "../src/tvd-token/TVDVesting.sol";
import {TVDInstitutionalVesting} from "../src/tvd-token/TVDInstitutionalVesting.sol";
import {TVDElectoralCredits} from "../src/tvd-token/TVDElectoralCredits.sol";

contract TVDEcosystemScript is Script {
    uint256 constant VESTING_POOL = 3_150_000e18;

    function setUp() public {}

    function run() public {
        //address token = deployToken();
        //address instVesting = deployInsitutionalVesting(token);
        address token = vm.envAddress("TVD_TOKEN");
        address instVesting = vm.envAddress("INSTITUTIONAL_VESTING_ADDR");
        deployElectoralCredits(token, instVesting);
    }

    function deployToken() public returns(address tokenAddr) {
        address liquidityWallet = vm.envAddress("LIQUIDITY_WALLET");
        address treasuryWallet = vm.envAddress("TREASURY_WALLET");
        address ecosystemWallet = vm.envAddress("ECOSYSTEM_WALLET");
        address adminWallet = vm.envAddress("ADMIN_WALLET");
        address tempVestingWallet = vm.envAddress("TEMP_VESTING_WALLET");
        uint256 tempVestingPrivateKey = vm.envUint("TEMP_VESTING_PRIVATE_KEY");

        address vestingAdmin = vm.envAddress("VESTING_ADMIN");

        vm.startBroadcast();

        TVDToken token = new TVDToken(
            liquidityWallet,
            treasuryWallet,
            ecosystemWallet,
            tempVestingWallet,
            adminWallet
        );

        TVDVesting vestingContract = new TVDVesting(address(token), vestingAdmin);
        vm.stopBroadcast();

        vm.startBroadcast(tempVestingPrivateKey);
        token.transfer(address(vestingContract), VESTING_POOL);
        vm.stopBroadcast();

        tokenAddr = address(token);
        console.log("TVDToken Contract deployed at:", tokenAddr, "With sender:", msg.sender);
    }

    function deployInsitutionalVesting(address tokenAddr) public returns (address instVestingAddr) {
        address admin = vm.envAddress("INSTITUTIONAL_VESTING_ADMIN");
        address operator = vm.envAddress("INSTITUTIONAL_VESTING_OPERATOR");

        vm.startBroadcast();

        TVDInstitutionalVesting instVesting = new TVDInstitutionalVesting(
            tokenAddr,
            admin,
            operator,
            block.timestamp
        );

        vm.stopBroadcast();

        instVestingAddr = address(instVesting);
        console.log("TVDInstitutionalVesting contract deployed at:", instVestingAddr, "With sender", msg.sender);
    }

    function deployElectoralCredits(address token, address institutionalVesting) public returns(address creditsAddr) {
        address admin = vm.envAddress("ELECTORAL_CREDITS_ADMIN");
        uint256 adminPrivKey = vm.envUint("ELECTORAL_CREDITS_ADMIN_PK");
        uint256 tvdPerCredit = vm.envUint("TVD_PER_CREDIT");
        address platformWallet = vm.envAddress("PLATFORM_WALLET");

        vm.startBroadcast();
        TVDElectoralCredits credits = new TVDElectoralCredits(token, admin, tvdPerCredit, platformWallet);
        vm.stopBroadcast();

        vm.startBroadcast(adminPrivKey);
        credits.addVestingProvider(institutionalVesting);
        vm.stopBroadcast();

        creditsAddr = address(credits);
        console.log("TVDElectoralCredits contract deployed at:", creditsAddr, "With sender", msg.sender);
    }
}
