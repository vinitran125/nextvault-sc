// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Auction} from "../src/Auction.sol";
import {AuctionCreateAuthHelper} from "./AuctionCreateAuthHelper.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";

contract AuctionEndTest is AuctionCreateAuthHelper {
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

    event AuctionEnded(
        bytes32 indexed lotId, address indexed winner, uint256 winningBid, bool paymentCollected, uint256 blockTimestamp
    );
    event WinnerPaymentCollected(
        bytes32 indexed lotId, address indexed winner, uint256 winningBid, bool paymentCollected, uint256 blockTimestamp
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

        token.mint(bidder, 10_000 * USDC);
    }

    function testOperatorEndsAuctionWithWinnerAfterEndTime() external {
        Auction.AuctionConfig memory config = _createActiveAuction();
        _buyNftAndPlaceStartingBid(config.nftPrice);
        vm.prank(bidder);
        token.approve(address(auction), STARTING_BID - STARTING_BID / 10);
        vm.warp(config.endTime);

        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionEnded(LOT_ID, bidder, STARTING_BID, true, block.timestamp);

        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, bidder);
        assertEq(winningBid, STARTING_BID);
        assertTrue(paymentCollected);
        assertTrue(auction.endedAuctions(LOT_ID));
        assertTrue(auction.auctionPaymentCollected(LOT_ID));
        assertEq(token.balanceOf(address(auction)), config.nftPrice + STARTING_BID);
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Ended));
    }

    function testEndAuctionStartsGracePeriodWhenRemainingPaymentCannotBeCollected() external {
        Auction.AuctionConfig memory config = _createActiveAuction();
        _buyNftAndPlaceStartingBid(config.nftPrice);
        vm.warp(config.endTime);

        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionEnded(LOT_ID, bidder, STARTING_BID, false, block.timestamp);

        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, bidder);
        assertEq(winningBid, STARTING_BID);
        assertFalse(paymentCollected);
        assertTrue(auction.endedAuctions(LOT_ID));
        assertFalse(auction.auctionPaymentCollected(LOT_ID));
        assertEq(token.balanceOf(address(auction)), config.nftPrice + STARTING_BID / 10);
    }

    function testOperatorCollectsWinnerPaymentAfterAuctionEnded() external {
        Auction.AuctionConfig memory config = _createActiveAuction();
        _buyNftAndPlaceStartingBid(config.nftPrice);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);

        vm.prank(bidder);
        token.approve(address(auction), STARTING_BID - STARTING_BID / 10);

        vm.expectEmit(true, true, false, true, address(auction));
        emit WinnerPaymentCollected(LOT_ID, bidder, STARTING_BID, true, block.timestamp);

        vm.prank(operator);
        bool paymentCollected = auction.collectWinnerPayment(LOT_ID);

        assertTrue(paymentCollected);
        assertTrue(auction.auctionPaymentCollected(LOT_ID));
        assertEq(token.balanceOf(address(auction)), config.nftPrice + STARTING_BID);
    }

    function testCollectWinnerPaymentReturnsFalseWhileFundsAreUnavailable() external {
        Auction.AuctionConfig memory config = _createActiveAuction();
        _buyNftAndPlaceStartingBid(config.nftPrice);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        bool paymentCollected = auction.collectWinnerPayment(LOT_ID);
        vm.stopPrank();

        assertFalse(paymentCollected);
        assertFalse(auction.auctionPaymentCollected(LOT_ID));
    }

    function testCollectWinnerPaymentRevertsBeforeEndAuction() external {
        Auction.AuctionConfig memory config = _createActiveAuction();
        vm.warp(config.endTime);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotEnded.selector);
        auction.collectWinnerPayment(LOT_ID);
    }

    function testCollectWinnerPaymentRevertsWhenAlreadyCollected() external {
        Auction.AuctionConfig memory config = _createActiveAuction();
        _buyNftAndPlaceStartingBid(config.nftPrice);
        vm.prank(bidder);
        token.approve(address(auction), STARTING_BID - STARTING_BID / 10);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        vm.expectRevert(Auction.AuctionPaymentAlreadyCollected.selector);
        auction.collectWinnerPayment(LOT_ID);
        vm.stopPrank();
    }

    function testCollectWinnerPaymentRevertsWithoutWinner() external {
        Auction.AuctionConfig memory config = _createActiveAuction();
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        vm.expectRevert(Auction.AuctionHasNoWinner.selector);
        auction.collectWinnerPayment(LOT_ID);
        vm.stopPrank();
    }

    function testCollectWinnerPaymentRevertsForNonOperator() external {
        Auction.AuctionConfig memory config = _createActiveAuction();
        _buyNftAndPlaceStartingBid(config.nftPrice);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);

        vm.prank(stranger);
        vm.expectRevert();
        auction.collectWinnerPayment(LOT_ID);
    }

    function testOperatorEndsAuctionWithoutBids() external {
        Auction.AuctionConfig memory config = _createActiveAuction();
        vm.warp(config.endTime);

        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionEnded(LOT_ID, address(0), 0, false, block.timestamp);

        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, address(0));
        assertEq(winningBid, 0);
        assertFalse(paymentCollected);
        assertFalse(auction.auctionPaymentCollected(LOT_ID));
    }

    function testEndAuctionRevertsBeforeEndTime() external {
        _createActiveAuction();

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotEnded.selector);
        auction.endAuction(LOT_ID);
    }

    function testEndAuctionRevertsWhenAlreadyEnded() external {
        Auction.AuctionConfig memory config = _createActiveAuction();
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        vm.expectRevert(Auction.AuctionAlreadyEnded.selector);
        auction.endAuction(LOT_ID);
        vm.stopPrank();
    }

    function testEndAuctionRevertsForNonOperator() external {
        Auction.AuctionConfig memory config = _createActiveAuction();
        vm.warp(config.endTime);

        vm.prank(stranger);
        vm.expectRevert();
        auction.endAuction(LOT_ID);
    }

    function testEndAuctionRevertsWhenAuctionDoesNotExist() external {
        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotFound.selector);
        auction.endAuction(LOT_ID);
    }

    function _createActiveAuction() private returns (Auction.AuctionConfig memory) {
        Auction.CreateAuctionParams memory params = Auction.CreateAuctionParams({
            lotId: LOT_ID,
            consignor: consignor,
            lowEstimate: STARTING_BID,
            highEstimate: 5_000 * USDC,
            startingBid: STARTING_BID,
            previewDurationSeconds: 0,
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

    function _buyNftAndPlaceStartingBid(uint256 nftPrice) private {
        vm.startPrank(bidder);
        token.approve(address(auction), nftPrice);
        auction.buyNFT(LOT_ID, 1);
        token.approve(address(auction), STARTING_BID / 10);
        auction.placeBid(LOT_ID, STARTING_BID);
        vm.stopPrank();
    }
}
