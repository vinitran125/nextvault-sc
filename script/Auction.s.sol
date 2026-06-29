// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Script, console2} from "forge-std/Script.sol";
import {Auction} from "../src/Auction.sol";

contract AuctionScript is Script {
    function run() public returns (Auction auction) {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address admin = vm.envOr("AUCTION_ADMIN", msg.sender);

        vm.startBroadcast();
        Auction implementation = new Auction();
        bytes memory initData = abi.encodeCall(Auction.initialize, (IERC20Permit(usdc), admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vm.stopBroadcast();

        auction = Auction(address(proxy));

        console2.log("Auction proxy deployed at:", address(proxy));
        console2.log("Auction implementation deployed at:", address(implementation));
        console2.log("USDC token:", usdc);
        console2.log("Admin:", admin);
    }
}
