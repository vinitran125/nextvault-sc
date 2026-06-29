// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";

contract FakeUSDCScript is Script {
    uint256 private constant MINT_AMOUNT = 1_000_000_000 * 1e6;

    function run() public returns (FakeUSDC token) {
        address mintTo = vm.envOr("USDC_MINT_TO", msg.sender);

        vm.startBroadcast();
        token = new FakeUSDC();
        token.mint(mintTo, MINT_AMOUNT);
        vm.stopBroadcast();

        console2.log("FakeUSDC deployed at:", address(token));
        console2.log("Minted to:", mintTo);
        console2.log("Minted amount:", MINT_AMOUNT);
    }
}
