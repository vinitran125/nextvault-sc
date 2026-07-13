// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";
import {LotNFT} from "../src/LotNFT.sol";

contract AuctionBuyNFTTest is Test {
    Auction private auction;
    FakeUSDC private token;

    address private admin = makeAddr("admin");
    address private operator = makeAddr("operator");
    address private consignor = makeAddr("consignor");
    address private buyer = makeAddr("buyer");

    bytes32 private constant LOT_ID = bytes32(uint256(1));
    uint256 private constant USDC = 1e6;

    event NFTPurchased(
        bytes32 indexed lotId,
        address indexed buyer,
        uint256 quantity,
        uint256 totalPrice,
        uint256 lastTokenId,
        uint256 blockTimestamp
    );

    function setUp() external {
        token = new FakeUSDC();
        Auction implementation = new Auction();
        bytes memory initData = abi.encodeCall(Auction.initialize, (token, admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        auction = Auction(address(proxy));

        bytes32 operatorRole = auction.OPERATOR_ROLE();
        vm.prank(admin);
        auction.grantRole(operatorRole, operator);

        token.mint(buyer, 10_000 * USDC);
    }

    function testBuyNFTTransfersPaymentAndMintsNfts() external {
        Auction.AuctionConfig memory config = _createActiveAuction();
        LotNFT nft = LotNFT(config.nftCollection);
        uint256 quantity = 3;
        uint256 totalPrice = config.nftPrice * quantity;

        vm.prank(buyer);
        token.approve(address(auction), totalPrice);

        vm.expectEmit(true, true, false, true, address(auction));
        emit NFTPurchased(LOT_ID, buyer, quantity, totalPrice, quantity, block.timestamp);

        vm.prank(buyer);
        auction.buyNFT(LOT_ID, quantity);

        assertEq(token.balanceOf(address(auction)), totalPrice);
        assertEq(token.balanceOf(buyer), 10_000 * USDC - totalPrice);
        assertEq(nft.totalMinted(), quantity);
        assertEq(nft.mintedByWallet(buyer), quantity);
        assertEq(nft.ownerOf(1), buyer);
        assertEq(nft.ownerOf(2), buyer);
        assertEq(nft.ownerOf(3), buyer);
    }

    function testBuyNFTCanMintAgainWithinWalletLimit() external {
        Auction.AuctionConfig memory config = _createActiveAuction();
        LotNFT nft = LotNFT(config.nftCollection);

        vm.prank(buyer);
        token.approve(address(auction), config.nftPrice * 5);

        vm.startPrank(buyer);
        auction.buyNFT(LOT_ID, 2);
        auction.buyNFT(LOT_ID, 3);
        vm.stopPrank();

        assertEq(nft.totalMinted(), 5);
        assertEq(nft.mintedByWallet(buyer), 5);
        assertEq(nft.ownerOf(5), buyer);
    }

    function testBuyNFTRevertsWhenAuctionMissing() external {
        vm.expectRevert(Auction.AuctionNotFound.selector);
        auction.buyNFT(LOT_ID, 1);
    }

    function testBuyNFTRevertsBeforeAuctionActive() external {
        _createPreviewAuction();

        vm.prank(buyer);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        auction.buyNFT(LOT_ID, 1);
    }

    function testBuyNFTRevertsAfterAuctionEnded() external {
        _createActiveAuction();
        vm.warp(block.timestamp + 8 days);

        vm.prank(buyer);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        auction.buyNFT(LOT_ID, 1);
    }

    function testBuyNFTRevertsForZeroQuantity() external {
        _createActiveAuction();

        vm.prank(buyer);
        vm.expectRevert(Auction.InvalidQuantity.selector);
        auction.buyNFT(LOT_ID, 0);
    }

    function testBuyNFTRevertsWhenWalletMintLimitExceeded() external {
        Auction.AuctionConfig memory config = _createActiveAuction();

        vm.prank(buyer);
        token.approve(address(auction), config.nftPrice * 6);

        vm.prank(buyer);
        vm.expectRevert(LotNFT.MintLimitExceeded.selector);
        auction.buyNFT(LOT_ID, 6);
    }

    function testBuyNFTRevertsWithoutAllowance() external {
        _createActiveAuction();

        vm.prank(buyer);
        vm.expectRevert();
        auction.buyNFT(LOT_ID, 1);
    }

    function _createActiveAuction() private returns (Auction.AuctionConfig memory) {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.previewDurationSeconds = 0;

        vm.prank(operator);
        auction.createAuction(params);

        return auction.getAuction(params.lotId);
    }

    function _createPreviewAuction() private returns (Auction.AuctionConfig memory) {
        Auction.CreateAuctionParams memory params = _defaultParams();

        vm.prank(operator);
        auction.createAuction(params);

        return auction.getAuction(params.lotId);
    }

    function _defaultParams() private view returns (Auction.CreateAuctionParams memory) {
        return Auction.CreateAuctionParams({
            lotId: LOT_ID,
            consignor: consignor,
            lowEstimate: 10_000 * USDC,
            highEstimate: 15_000 * USDC,
            startingBid: 10_000 * USDC,
            previewDurationSeconds: 1 days,
            auctionDurationSeconds: 7 days,
            designAQuantity: 50,
            designBQuantity: 30,
            designCQuantity: 20,
            nftPriceRatioBps: 1_000,
            nftName: "NextVault Lot 1",
            nftSymbol: "NVL1",
            thumbnailUrl: "ipfs://thumbnail",
            metadataUri: "ipfs://metadata/"
        });
    }
}
