// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";

abstract contract AuctionCreateAuthHelper is Test {
    bytes32 private constant CREATE_AUCTION_AUTHORIZATION_TYPEHASH = keccak256(
        "CreateAuctionAuthorization(bytes32 lotId,address consignor,uint256 lowEstimate,uint256 highEstimate,uint256 startingBid,uint256 previewDurationSeconds,uint256 auctionDurationSeconds,uint256 designAQuantity,uint256 designBQuantity,uint256 designCQuantity,uint16 nftPriceRatioBps,string nftName,string nftSymbol,string thumbnailUrl,string metadataUri,bytes32 nonce,uint256 deadline)"
    );

    uint256 private createAuctionNonceCounter;

    function _createAuctionWithAdminSignature(
        Auction auction,
        Auction.CreateAuctionParams memory params,
        uint256 adminKey
    ) internal returns (bytes32) {
        bytes32 nonce = keccak256(
            abi.encodePacked("create-auction", address(this), params.lotId, createAuctionNonceCounter++)
        );
        uint256 deadline = block.timestamp + 30 minutes;
        bytes memory signature = _signCreateAuctionAuthorization(auction, params, nonce, deadline, adminKey);

        return auction.createAuction(params, nonce, deadline, signature);
    }

    function _signCreateAuctionAuthorization(
        Auction auction,
        Auction.CreateAuctionParams memory params,
        bytes32 nonce,
        uint256 deadline,
        uint256 signerKey
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_AUCTION_AUTHORIZATION_TYPEHASH,
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
