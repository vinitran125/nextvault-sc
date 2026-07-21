// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Auction} from "../src/Auction.sol";
import {AuctionCreateAuthHelper} from "./AuctionCreateAuthHelper.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";

contract AuctionWithdrawTest is AuctionCreateAuthHelper {
    Auction private auction;
    FakeUSDC private token;

    uint256 private adminKey = 0xA11CE;
    address private admin = vm.addr(adminKey);
    address private operator = makeAddr("operator");
    address private bidder = makeAddr("bidder");
    address private consignor = makeAddr("consignor");
    address private stranger = makeAddr("stranger");

    bytes32 private constant LOT_ID = bytes32(uint256(1));
    uint256 private constant USDC = 1e6;
    uint256 private constant STARTING_BID = 2_000 * USDC;

    event AuctionWithdrawn(
        bytes32 indexed lotId, address indexed highestBidder, uint256 refundedDeposit, uint256 blockTimestamp
    );
    event BidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);
    event MaxBidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);

    function setUp() external {
        token = new FakeUSDC();
        Auction implementation = new Auction();
        bytes memory initData = abi.encodeCall(Auction.initialize, (token, admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        auction = Auction(address(proxy));

        bytes32 operatorRole = auction.OPERATOR_ROLE();
        vm.prank(admin);
        auction.grantRole(operatorRole, operator);
        token.mint(bidder, 20_000 * USDC);
    }

    function testWithdrawActiveAuctionWithoutBids() external {
        _createAuction(0);

        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionWithdrawn(LOT_ID, address(0), 0, block.timestamp);

        vm.prank(operator);
        (address highestBidder, uint256 refundedDeposit) = auction.withdrawAuction(LOT_ID);

        assertEq(highestBidder, address(0));
        assertEq(refundedDeposit, 0);
        assertTrue(auction.cancelledAuctions(LOT_ID));
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Cancelled));
    }

    function testWithdrawRefundsHighestManualBidDeposit() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNft(config.nftPrice);

        uint256 bidderBalanceBeforeBid = token.balanceOf(bidder);
        vm.startPrank(bidder);
        token.approve(address(auction), STARTING_BID / 10);
        auction.placeBid(LOT_ID, STARTING_BID);
        vm.stopPrank();

        vm.expectEmit(true, true, false, true, address(auction));
        emit BidRefunded(LOT_ID, bidder, STARTING_BID / 10, block.timestamp);
        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionWithdrawn(LOT_ID, bidder, STARTING_BID / 10, block.timestamp);

        vm.prank(operator);
        (address highestBidder, uint256 refundedDeposit) = auction.withdrawAuction(LOT_ID);

        assertEq(highestBidder, bidder);
        assertEq(refundedDeposit, STARTING_BID / 10);
        assertEq(token.balanceOf(bidder), bidderBalanceBeforeBid);
        assertTrue(auction.cancelledAuctions(LOT_ID));
    }

    function testWithdrawRefundsEntireHighestMaxBidDeposit() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNft(config.nftPrice);

        uint256 secondBid = 2_200 * USDC;
        uint256 bidderBalanceBeforeBid = token.balanceOf(bidder);
        vm.prank(bidder);
        token.approve(address(auction), secondBid / 10);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidder, STARTING_BID);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidder, secondBid);

        vm.expectEmit(true, true, false, true, address(auction));
        emit MaxBidRefunded(LOT_ID, bidder, secondBid / 10, block.timestamp);
        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionWithdrawn(LOT_ID, bidder, secondBid / 10, block.timestamp);

        vm.prank(operator);
        (address highestBidder, uint256 refundedDeposit) = auction.withdrawAuction(LOT_ID);

        assertEq(highestBidder, bidder);
        assertEq(refundedDeposit, secondBid / 10);
        assertEq(token.balanceOf(bidder), bidderBalanceBeforeBid);
        assertTrue(auction.cancelledAuctions(LOT_ID));
    }

    function testWithdrawPreventsFurtherBidsAndNftPurchases() external {
        Auction.AuctionConfig memory config = _createAuction(0);

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        vm.startPrank(bidder);
        token.approve(address(auction), config.nftPrice + STARTING_BID / 10);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.buyNFT(LOT_ID, 1);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
        vm.stopPrank();
    }

    function testWithdrawRevertsWhenAuctionDoesNotExist() external {
        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotFound.selector);
        auction.withdrawAuction(LOT_ID);
    }

    function testWithdrawRevertsForNonOperator() external {
        _createAuction(0);

        vm.prank(stranger);
        vm.expectRevert();
        auction.withdrawAuction(LOT_ID);
    }

    function testWithdrawRevertsDuringPreview() external {
        _createAuction(1 hours);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        auction.withdrawAuction(LOT_ID);
    }

    function testWithdrawRevertsAfterAuctionTimeExpires() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        auction.withdrawAuction(LOT_ID);
    }

    function testWithdrawRevertsAfterAuctionEnded() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        auction.withdrawAuction(LOT_ID);
    }

    function testWithdrawCannotRunTwice() external {
        _createAuction(0);

        vm.startPrank(operator);
        auction.withdrawAuction(LOT_ID);
        vm.expectRevert(Auction.AuctionAlreadyCancelled.selector);
        auction.withdrawAuction(LOT_ID);
        vm.stopPrank();
    }

    function _createAuction(uint256 previewDuration) private returns (Auction.AuctionConfig memory) {
        Auction.CreateAuctionParams memory params = Auction.CreateAuctionParams({
            lotId: LOT_ID,
            consignor: consignor,
            lowEstimate: STARTING_BID,
            highEstimate: 5_000 * USDC,
            startingBid: STARTING_BID,
            previewDurationSeconds: previewDuration,
            auctionDurationSeconds: 1 hours,
            designAQuantity: 50,
            designBQuantity: 30,
            designCQuantity: 20,
            nftPriceRatioBps: 1_000,
            nftName: "NextVault Lot 1",
            nftSymbol: "NVL1",
            thumbnailUrl: "ipfs://thumbnail",
            metadataUri: "ipfs://metadata/"
        });

        vm.prank(operator);
        _createAuctionWithAdminSignature(auction, params, adminKey);
        return auction.getAuction(LOT_ID);
    }

    function _buyNft(uint256 nftPrice) private {
        vm.startPrank(bidder);
        token.approve(address(auction), nftPrice);
        auction.buyNFT(LOT_ID, 1);
        vm.stopPrank();
    }
}
