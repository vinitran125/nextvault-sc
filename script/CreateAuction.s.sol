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
            previewDurationSeconds: vm.envUint("PREVIEW_DURATION_SECONDS"),
            auctionDurationSeconds: vm.envUint("AUCTION_DURATION_SECONDS"),
            designAQuantity: vm.envUint("DESIGN_A_QUANTITY"),
            designBQuantity: vm.envUint("DESIGN_B_QUANTITY"),
            designCQuantity: vm.envUint("DESIGN_C_QUANTITY"),
            nftPriceRatioBps: uint16(vm.envUint("NFT_PRICE_RATIO_BPS")),
            nftName: vm.envString("NFT_NAME"),
            nftSymbol: vm.envString("NFT_SYMBOL"),
            thumbnailUrl: vm.envString("THUMBNAIL_URL"),
            metadataUri: vm.envString("METADATA_URI")
        });

        bytes32 nonce = keccak256(abi.encodePacked("create-auction", address(auction), params.lotId, block.timestamp));
        uint256 deadline = block.timestamp + 30 minutes;
        bytes memory signature =
            _signCreateAuctionAuthorization(auction, params, nonce, deadline, vm.envUint("AUCTION_ADMIN_PRIVATE_KEY"));

        vm.startBroadcast();
        auction.createAuction(params, nonce, deadline, signature);
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

    function _signCreateAuctionAuthorization(
        Auction auction,
        Auction.CreateAuctionParams memory params,
        bytes32 nonce,
        uint256 deadline,
        uint256 signerKey
    ) private view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                auction.CREATE_AUCTION_AUTHORIZATION_TYPEHASH(),
                params.lotId,
                params.consignor,
                params.lowEstimate,
                params.highEstimate,
                params.startingBid,
                params.previewDurationSeconds,
                params.auctionDurationSeconds,
                params.designAQuantity,
                params.designBQuantity,
                params.designCQuantity,
                params.nftPriceRatioBps,
                keccak256(bytes(params.nftName)),
                keccak256(bytes(params.nftSymbol)),
                keccak256(bytes(params.thumbnailUrl)),
                keccak256(bytes(params.metadataUri)),
                nonce,
                deadline
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NextVaultAuction")),
                keccak256(bytes("1")),
                block.chainid,
                address(auction)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        return abi.encodePacked(r, s, v);
    }
}
