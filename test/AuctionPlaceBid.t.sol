// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";

contract AuctionPlaceBidTest is Test {
    Auction private auction;
    FakeUSDC private token;

    address private admin = makeAddr("admin");
    address private operator = makeAddr("operator");
    address private consignor = makeAddr("consignor");
    address private bidderA = makeAddr("bidderA");
    address private bidderB = makeAddr("bidderB");
    address private bidderC = makeAddr("bidderC");

    bytes32 private constant LOT_ID = bytes32(uint256(1));
    uint256 private constant USDC = 1e6;
    uint256 private constant STARTING_BID = 10_000 * USDC;
    uint256 private constant NFT_PRICE = 10 * USDC;

    event BidPlaced(bytes32 indexed lotId, address indexed bidder, uint256 bidAmount, uint256 blockTimestamp);
    event BidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);

    function setUp() external {
        token = new FakeUSDC();
        Auction implementation = new Auction();
        bytes memory initData = abi.encodeCall(Auction.initialize, (token, admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        auction = Auction(address(proxy));

        bytes32 operatorRole = auction.OPERATOR_ROLE();
        vm.prank(admin);
        auction.grantRole(operatorRole, operator);

        token.mint(bidderA, 100_000 * USDC);
        token.mint(bidderB, 100_000 * USDC);
        token.mint(bidderC, 100_000 * USDC);
    }

    function testPlaceBidAcceptsStartingBidAndTakesTenPercentDeposit() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        vm.prank(bidderA);
        token.approve(address(auction), STARTING_BID / 10);

        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bidderA, STARTING_BID, block.timestamp);

        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        assertEq(token.balanceOf(address(auction)), NFT_PRICE + STARTING_BID / 10);
        assertEq(token.balanceOf(bidderA), 100_000 * USDC - NFT_PRICE - STARTING_BID / 10);
    }

    function testPlaceBidRevertsWhenStartingAboveStartingBidEvenOnLadder() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        uint256 bidAmount = 12_000 * USDC;
        vm.prank(bidderA);
        token.approve(address(auction), bidAmount / 10);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBid(LOT_ID, bidAmount);
    }

    function testPlaceBidRefundsPreviousNormalBidder() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _approveBidDeposit(bidderA, STARTING_BID);
        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        uint256 nextBid = 11_000 * USDC;
        _approveBidDeposit(bidderB, nextBid);

        vm.expectEmit(true, true, false, true, address(auction));
        emit BidRefunded(LOT_ID, bidderA, STARTING_BID / 10, block.timestamp);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bidderB, nextBid, block.timestamp);

        vm.prank(bidderB);
        auction.placeBid(LOT_ID, nextBid);

        assertEq(token.balanceOf(bidderA), 100_000 * USDC - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + nextBid / 10);
    }

    function testPlaceBidRevertsWhenAuctionMissing() external {
        vm.expectRevert(Auction.AuctionNotFound.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
    }

    function testPlaceBidRevertsWhenAuctionNotActive() external {
        _createPreviewAuction();

        vm.prank(bidderA);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
    }

    function testPlaceBidRevertsWhenBidderHasNoNft() external {
        _createActiveAuction();

        vm.prank(bidderA);
        vm.expectRevert(Auction.NotEligibleToBid.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
    }

    function testPlaceBidRevertsWhenBelowStartingBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBid(LOT_ID, STARTING_BID - 1);
    }

    function testPlaceBidRevertsWhenAmountIsNotOnLadder() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBid(LOT_ID, 10_500 * USDC);
    }

    function testPlaceBidRevertsWhenNotAboveCurrentBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _approveBidDeposit(bidderA, STARTING_BID);
        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        vm.prank(bidderB);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
    }

    function testPlaceBidRevertsWithoutAllowance() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        vm.prank(bidderA);
        vm.expectRevert();
        auction.placeBid(LOT_ID, STARTING_BID);
    }

    function testPlaceBidRevertsWhenBidderHasActiveMaxBidMode() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        uint256 operatorBid = STARTING_BID;
        _approveBidDeposit(bidderA, operatorBid);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, operatorBid);

        vm.prank(bidderA);
        vm.expectRevert(Auction.BidModeConflict.selector);
        auction.placeBid(LOT_ID, 12_000 * USDC);
    }

    function _createActiveAuction() private {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.previewDurationSeconds = 0;

        vm.prank(operator);
        auction.createAuction(params);
    }

    function _createPreviewAuction() private {
        Auction.CreateAuctionParams memory params = _defaultParams();

        vm.prank(operator);
        auction.createAuction(params);
    }

    function _buyNft(address buyer, uint256 quantity) private {
        vm.prank(buyer);
        token.approve(address(auction), NFT_PRICE * quantity);

        vm.prank(buyer);
        auction.buyNFT(LOT_ID, quantity);
    }

    function _approveBidDeposit(address bidder, uint256 bidAmount) private {
        vm.prank(bidder);
        token.approve(address(auction), bidAmount / 10);
    }

    function _defaultParams() private view returns (Auction.CreateAuctionParams memory) {
        return Auction.CreateAuctionParams({
            lotId: LOT_ID,
            consignor: consignor,
            lowEstimate: STARTING_BID,
            highEstimate: 15_000 * USDC,
            startingBid: STARTING_BID,
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
