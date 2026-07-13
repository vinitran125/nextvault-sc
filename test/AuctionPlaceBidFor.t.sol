// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";

contract AuctionPlaceBidForTest is Test {
    Auction private auction;
    FakeUSDC private token;

    address private admin = makeAddr("admin");
    address private operator = makeAddr("operator");
    address private bidderA = makeAddr("bidderA");
    address private bidderB = makeAddr("bidderB");
    address private consignor = makeAddr("consignor");
    address private stranger = makeAddr("stranger");

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
        token.mint(stranger, 100_000 * USDC);
    }

    function testPlaceBidForAllowsOperatorToBidForUser() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        _approveBidDeposit(bidderA, STARTING_BID);

        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bidderA, STARTING_BID, block.timestamp);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);

        assertEq(token.balanceOf(address(auction)), NFT_PRICE + STARTING_BID / 10);
        assertEq(token.balanceOf(bidderA), 100_000 * USDC - NFT_PRICE - STARTING_BID / 10);
    }

    function testPlaceBidForRevertsForNonOperator() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.prank(stranger);
        vm.expectRevert();
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);
    }

    function testPlaceBidForPullsOnlyAdditionalDepositForSameMaxBidder() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        uint256 firstBid = STARTING_BID;
        uint256 secondBid = 11_000 * USDC;

        vm.prank(bidderA);
        token.approve(address(auction), secondBid / 10);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, firstBid);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, secondBid);

        assertEq(token.balanceOf(address(auction)), NFT_PRICE + secondBid / 10);
        assertEq(token.allowance(bidderA, address(auction)), 0);
        assertEq(token.balanceOf(bidderA), 100_000 * USDC - NFT_PRICE - secondBid / 10);
    }

    function testPlaceBidForRefundsPreviousNormalBidder() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _approveBidDeposit(bidderA, STARTING_BID);
        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        uint256 operatorBid = 11_000 * USDC;
        _approveBidDeposit(bidderB, operatorBid);

        vm.expectEmit(true, true, false, true, address(auction));
        emit BidRefunded(LOT_ID, bidderA, STARTING_BID / 10, block.timestamp);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bidderB, operatorBid, block.timestamp);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderB, operatorBid);

        assertEq(token.balanceOf(bidderA), 100_000 * USDC - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + operatorBid / 10);
    }

    function testPlaceBidForDoesNotRefundPreviousActiveMaxBidder() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        uint256 firstBid = STARTING_BID;
        uint256 secondBid = 11_000 * USDC;
        _approveBidDeposit(bidderA, firstBid);
        _approveBidDeposit(bidderB, secondBid);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, firstBid);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderB, secondBid);

        assertEq(token.balanceOf(bidderA), 100_000 * USDC - NFT_PRICE - firstBid / 10);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + firstBid / 10 + secondBid / 10);
    }

    function testPlaceBidForRevertsWhenAuctionMissing() external {
        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotFound.selector);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);
    }

    function testPlaceBidForRevertsWhenAuctionNotActive() external {
        _createPreviewAuction();

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);
    }

    function testPlaceBidForRevertsWhenBidderHasNoNft() external {
        _createActiveAuction();

        vm.prank(operator);
        vm.expectRevert(Auction.NotEligibleToBid.selector);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);
    }

    function testPlaceBidForRevertsWhenBelowStartingBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        vm.prank(operator);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID - 1);
    }

    function testPlaceBidForRevertsWhenAmountIsNotOnLadder() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        vm.prank(operator);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBidFor(LOT_ID, bidderA, 10_500 * USDC);
    }

    function testPlaceBidForRevertsWhenNotAboveCurrentBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _approveBidDeposit(bidderA, STARTING_BID);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);

        vm.prank(operator);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBidFor(LOT_ID, bidderB, STARTING_BID);
    }

    function testPlaceBidForRevertsWhenBidderAlreadyUsedManualBidMode() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        _approveBidDeposit(bidderA, STARTING_BID);
        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        vm.prank(operator);
        vm.expectRevert(Auction.BidModeConflict.selector);
        auction.placeBidFor(LOT_ID, bidderA, 11_000 * USDC);
    }

    function testPlaceBidForRevertsWithoutEnoughAllowanceForAdditionalDeposit() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        vm.prank(bidderA);
        token.approve(address(auction), STARTING_BID / 10 - 1);

        vm.prank(operator);
        vm.expectRevert();
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);
    }

    function testPlaceBidForOperatorCanRefundPreviousMaxBidderAfterOutbid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        uint256 firstBid = STARTING_BID;
        uint256 secondBid = 11_000 * USDC;
        _approveBidDeposit(bidderA, firstBid);
        _approveBidDeposit(bidderB, secondBid);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, firstBid);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderB, secondBid);

        vm.prank(operator);
        auction.refundMaxBid(LOT_ID, bidderA);

        assertEq(token.balanceOf(bidderA), 100_000 * USDC - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + secondBid / 10);
    }

    function testRefundMaxBidRevertsForNonOperator() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        uint256 firstBid = STARTING_BID;
        uint256 secondBid = 11_000 * USDC;
        _approveBidDeposit(bidderA, firstBid);
        _approveBidDeposit(bidderB, secondBid);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, firstBid);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderB, secondBid);

        vm.prank(bidderA);
        vm.expectRevert();
        auction.refundMaxBid(LOT_ID, bidderA);
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
