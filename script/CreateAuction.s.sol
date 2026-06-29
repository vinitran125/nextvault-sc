// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {Auction} from "../src/Auction.sol";

contract CreateAuctionScript is Script {
    function run() public returns (bytes32 lotId) {
        Auction auction = Auction(vm.envAddress("AUCTION_ADDRESS"));

        string memory lotIdText = vm.envString("LOT_ID");
        lotId = keccak256(bytes(lotIdText));

        Auction.CreateAuctionParams memory params = Auction.CreateAuctionParams({
            lotId: lotId,
            consignor: vm.envAddress("CONSIGNOR_ADDRESS"),
            lowEstimate: vm.envUint("LOW_ESTIMATE"),
            highEstimate: vm.envUint("HIGH_ESTIMATE"),
            startingBid: vm.envUint("STARTING_BID"),
            bidIncrement: vm.envUint("BID_INCREMENT"),
            previewDurationSeconds: vm.envUint("PREVIEW_DURATION_SECONDS"),
            auctionDurationSeconds: vm.envUint("AUCTION_DURATION_SECONDS"),
            nftMaxSupply: vm.envUint("NFT_MAX_SUPPLY"),
            nftPriceRatioBps: uint16(vm.envUint("NFT_PRICE_RATIO_BPS")),
            nftName: vm.envString("NFT_NAME"),
            nftSymbol: vm.envString("NFT_SYMBOL"),
            metadataUri: vm.envString("METADATA_URI")
        });

        vm.startBroadcast();
        auction.createAuction(params);
        vm.stopBroadcast();

        Auction.AuctionConfig memory config = auction.getAuction(lotId);

        console2.log("Auction created on:", address(auction));
        console2.log("Lot ID text:", lotIdText);
        console2.logBytes32(lotId);
        console2.log("NFT collection:", config.nftCollection);
        console2.log("Start time:", config.startTime);
        console2.log("End time:", config.endTime);
        console2.log("NFT price:", config.nftPrice);
    }
}
