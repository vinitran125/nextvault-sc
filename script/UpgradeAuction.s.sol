// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {Auction} from "../src/Auction.sol";

contract UpgradeAuctionScript is Script {
    bytes32 private constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    function run() public returns (Auction upgradedAuction) {
        address proxy = vm.envAddress("AUCTION_ADDRESS");

        vm.startBroadcast();
        Auction implementation = new Auction();
        Auction(payable(proxy)).upgradeToAndCall(address(implementation), "");
        vm.stopBroadcast();

        upgradedAuction = Auction(proxy);

        console2.log("Auction proxy upgraded:", proxy);
        console2.log("New implementation:", address(implementation));
        console2.log("Proxy implementation slot:", _implementationOf(proxy));
    }

    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }
}
