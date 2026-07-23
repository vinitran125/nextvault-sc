// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";

contract AuctionEndWithdrawTest is Test {
    Auction private auction;
    FakeUSDC private token;

    uint256 private adminKey = 0xA11CE;
    address private admin = vm.addr(adminKey);
    address private operator = makeAddr("operator");
    address private consignor = makeAddr("consignor");
    address private bidderA = makeAddr("bidderA");
    address private bidderB = makeAddr("bidderB");
    address private stranger = makeAddr("stranger");

    bytes32 private constant LOT_ID = bytes32(uint256(1));
    bytes32 private constant UNKNOWN_LOT_ID = bytes32(uint256(999));
    uint256 private constant USDC = 1e6;
    uint256 private constant STARTING_BID = 10_000 * USDC;
    uint256 private constant NFT_PRICE = 10 * USDC;
    uint256 private constant STARTING_BALANCE = 100_000 * USDC;

    event AuctionEnded(
        bytes32 indexed lotId, address indexed winner, uint256 winningBid, bool paymentCollected, uint256 blockTimestamp
    );
    event WinnerPaymentCollected(
        bytes32 indexed lotId, address indexed winner, uint256 winningBid, bool paymentCollected, uint256 blockTimestamp
    );
    event AuctionWithdrawn(bytes32 indexed lotId, address indexed highestBidder, uint256 blockTimestamp);
    event BidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);
    event MaxBidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);

    function setUp() external {
        token = new FakeUSDC();
        Auction implementation = new Auction();
        bytes memory initData = abi.encodeCall(Auction.initialize, (token, admin));
        auction = Auction(address(new ERC1967Proxy(address(implementation), initData)));

        bytes32 operatorRole = auction.OPERATOR_ROLE();
        vm.prank(admin);
        auction.grantRole(operatorRole, operator);

        token.mint(bidderA, STARTING_BALANCE);
        token.mint(bidderB, STARTING_BALANCE);
    }

    function testEndAuctionWithoutBidsReturnsEmptyWinner() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime);

        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionEnded(LOT_ID, address(0), 0, false, block.timestamp);

        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, address(0));
        assertEq(winningBid, 0);
        assertFalse(paymentCollected);
        assertTrue(auction.endedAuctions(LOT_ID));
        assertFalse(auction.auctionPaymentCollected(LOT_ID));
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Ended));
    }

    function testEndAuctionWithWinnerStartsPaymentPendingWhenAllowanceIsMissing() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionEnded(LOT_ID, bidderA, STARTING_BID, false, block.timestamp);

        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, bidderA);
        assertEq(winningBid, STARTING_BID);
        assertFalse(paymentCollected);
        assertTrue(auction.endedAuctions(LOT_ID));
        assertFalse(auction.auctionPaymentCollected(LOT_ID));
        assertEq(token.balanceOf(address(auction)), NFT_PRICE + STARTING_BID / 10);
    }

    function testEndAuctionCollectsPaymentAndDistributesSettlementImmediately() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        _approveRemainingPayment(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, bidderA);
        assertEq(winningBid, STARTING_BID);
        assertTrue(paymentCollected);
        assertTrue(auction.auctionPaymentCollected(LOT_ID));
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Finalized));
        assertEq(token.balanceOf(consignor), 9_000 * USDC);
        assertEq(token.balanceOf(admin), 2_000 * USDC);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE);
    }

    function testSettleAuctionPaymentSucceedsForOperatorAfterInitialEndFailure() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);

        _approveRemainingPayment(bidderA, STARTING_BID);

        vm.expectEmit(true, true, false, true, address(auction));
        emit WinnerPaymentCollected(LOT_ID, bidderA, STARTING_BID, true, block.timestamp);
        vm.prank(operator);
        bool paymentCollected = auction.settleAuctionPayment(LOT_ID);

        assertTrue(paymentCollected);
        assertTrue(auction.auctionPaymentCollected(LOT_ID));
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Finalized));
    }

    function testSettleAuctionPaymentSucceedsForWinnerAfterInitialEndFailure() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);

        _approveRemainingPayment(bidderA, STARTING_BID);

        vm.prank(bidderA);
        bool paymentCollected = auction.settleAuctionPayment(LOT_ID);

        assertTrue(paymentCollected);
        assertTrue(auction.auctionPaymentCollected(LOT_ID));
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Finalized));
    }

    function testSettleAuctionPaymentRevertsForUnauthorizedCaller() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);

        vm.prank(stranger);
        vm.expectRevert(Auction.UnauthorizedPaymentCollector.selector);
        auction.settleAuctionPayment(LOT_ID);
    }

    function testSettleAuctionPaymentCanRetryWithoutChangingWinnerWhenStillUnavailable() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        bool firstRetry = auction.settleAuctionPayment(LOT_ID);
        bool secondRetry = auction.settleAuctionPayment(LOT_ID);
        vm.stopPrank();

        assertFalse(firstRetry);
        assertFalse(secondRetry);
        assertFalse(auction.auctionPaymentCollected(LOT_ID));
        assertEq(token.balanceOf(address(auction)), NFT_PRICE + STARTING_BID / 10);
    }

    function testEndAuctionAcceptsExactEndTimestamp() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime);

        vm.prank(operator);
        auction.endAuction(LOT_ID);

        assertTrue(auction.endedAuctions(LOT_ID));
    }

    function testEndAuctionRevertsBeforeEndTimestamp() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime - 1);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotEnded.selector);
        auction.endAuction(LOT_ID);
    }

    function testEndAuctionRevertsWhenCalledTwice() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        vm.expectRevert(Auction.AuctionAlreadyEnded.selector);
        auction.endAuction(LOT_ID);
        vm.stopPrank();
    }

    function testEndAuctionRevertsForCancelledAuction() external {
        _createAuction(0);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.endAuction(LOT_ID);
    }

    function testEndAuctionRevertsForNonOperator() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime);

        vm.prank(stranger);
        vm.expectRevert();
        auction.endAuction(LOT_ID);
    }

    function testEndAuctionRevertsForUnknownAuction() external {
        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotFound.selector);
        auction.endAuction(UNKNOWN_LOT_ID);
    }

    function testSettleAuctionPaymentRevertsBeforeAuctionIsEnded() external {
        _createAuction(0);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotEnded.selector);
        auction.settleAuctionPayment(LOT_ID);
    }

    function testSettleAuctionPaymentRevertsWhenAuctionHasNoWinner() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        vm.expectRevert(Auction.AuctionHasNoWinner.selector);
        auction.settleAuctionPayment(LOT_ID);
        vm.stopPrank();
    }

    function testSettleAuctionPaymentRevertsAfterPaymentWasCollected() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        _approveRemainingPayment(bidderA, STARTING_BID);
        vm.warp(config.endTime);

        vm.startPrank(operator);
        auction.endAuction(LOT_ID);
        vm.expectRevert(Auction.AuctionPaymentAlreadyCollected.selector);
        auction.settleAuctionPayment(LOT_ID);
        vm.stopPrank();
    }

    function testWithdrawActiveAuctionWithoutBids() external {
        _createAuction(0);

        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionWithdrawn(LOT_ID, address(0), block.timestamp);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        assertTrue(auction.cancelledAuctions(LOT_ID));
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Cancelled));
    }

    function testWithdrawRefundsCurrentManualBidImmediately() external {
        _createAuction(0);
        _buyNftAndPlaceManualBid(bidderA, STARTING_BID);
        uint256 bidderBalanceBeforeWithdraw = token.balanceOf(bidderA);

        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionWithdrawn(LOT_ID, bidderA, block.timestamp);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidRefunded(LOT_ID, bidderA, STARTING_BID / 10, block.timestamp);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        assertEq(token.balanceOf(bidderA), bidderBalanceBeforeWithdraw + STARTING_BID / 10);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE);
    }

    function testWithdrawLeavesAutoBidDepositForBackendRefund() external {
        _createAuction(0);
        _buyNft(bidderA);
        _setMaxBidAndPlaceFor(bidderA, 15_000 * USDC, 15_000 * USDC);
        uint256 bidderBalanceBeforeWithdraw = token.balanceOf(bidderA);
        uint256 contractBalanceBeforeWithdraw = token.balanceOf(address(auction));

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        assertEq(token.balanceOf(bidderA), bidderBalanceBeforeWithdraw);
        assertEq(token.balanceOf(address(auction)), contractBalanceBeforeWithdraw);
        assertTrue(auction.cancelledAuctions(LOT_ID));
    }

    function testBackendCanRefundAutoBidLeaderAfterWithdraw() external {
        _createAuction(0);
        _buyNft(bidderA);
        _setMaxBidAndPlaceFor(bidderA, 15_000 * USDC, 15_000 * USDC);

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        vm.expectEmit(true, true, false, true, address(auction));
        emit MaxBidRefunded(LOT_ID, bidderA, 1_500 * USDC, block.timestamp);
        vm.prank(operator);
        auction.refundMaxBid(LOT_ID, bidderA);

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE);
    }

    function testBackendCanRefundMultipleMaxBiddersAfterWithdraw() external {
        _createAuction(0);
        _buyNft(bidderA);
        _buyNft(bidderB);
        _setMaxBid(bidderA, 15_000 * USDC);
        _setMaxBid(bidderB, 16_000 * USDC);

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        vm.startPrank(operator);
        auction.refundMaxBid(LOT_ID, bidderA);
        auction.refundMaxBid(LOT_ID, bidderB);
        vm.stopPrank();

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(bidderB), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2);
    }

    function testRefundMaxBidCurrentLeaderStillRevertsBeforeWithdraw() external {
        _createAuction(0);
        _buyNft(bidderA);
        _setMaxBidAndPlaceFor(bidderA, 15_000 * USDC, STARTING_BID);

        vm.prank(operator);
        vm.expectRevert(Auction.CurrentLeaderCannotWithdrawDeposit.selector);
        auction.refundMaxBid(LOT_ID, bidderA);
    }

    function testRefundMaxBidCannotRunTwiceAfterWithdraw() external {
        _createAuction(0);
        _buyNft(bidderA);
        _setMaxBid(bidderA, 15_000 * USDC);

        vm.startPrank(operator);
        auction.withdrawAuction(LOT_ID);
        auction.refundMaxBid(LOT_ID, bidderA);
        vm.expectRevert(Auction.InvalidAmount.selector);
        auction.refundMaxBid(LOT_ID, bidderA);
        vm.stopPrank();
    }

    function testWithdrawRevertsDuringPreview() external {
        _createAuction(1 hours);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        auction.withdrawAuction(LOT_ID);
    }

    function testWithdrawRevertsAtOrAfterEndTimestamp() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        vm.warp(config.endTime);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        auction.withdrawAuction(LOT_ID);
    }

    function testWithdrawRevertsWhenCalledTwice() external {
        _createAuction(0);

        vm.startPrank(operator);
        auction.withdrawAuction(LOT_ID);
        vm.expectRevert(Auction.AuctionAlreadyCancelled.selector);
        auction.withdrawAuction(LOT_ID);
        vm.stopPrank();
    }

    function testWithdrawRevertsForNonOperatorAndUnknownAuction() external {
        _createAuction(0);

        vm.prank(stranger);
        vm.expectRevert();
        auction.withdrawAuction(LOT_ID);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionNotFound.selector);
        auction.withdrawAuction(UNKNOWN_LOT_ID);
    }

    function testWithdrawPreventsFurtherNftPurchasesAndBids() external {
        _createAuction(0);
        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        vm.startPrank(bidderA);
        token.approve(address(auction), NFT_PRICE + STARTING_BID / 10);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.buyNFT(LOT_ID, 1);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
        vm.stopPrank();
    }

    function _createAuction(uint256 previewDuration) private returns (Auction.AuctionConfig memory) {
        Auction.CreateAuctionParams memory params = Auction.CreateAuctionParams({
            lotId: LOT_ID,
            consignor: consignor,
            lowEstimate: STARTING_BID,
            highEstimate: 20_000 * USDC,
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
        bytes32 nonce = keccak256(abi.encode("lifecycle"));
        uint256 deadline = block.timestamp + 1 hours;
        auction.createAuction(params, nonce, deadline, _sign(params, nonce, deadline));
        return auction.getAuction(LOT_ID);
    }

    function _buyNft(address bidder) private {
        vm.prank(bidder);
        token.approve(address(auction), NFT_PRICE);
        vm.prank(bidder);
        auction.buyNFT(LOT_ID, 1);
    }

    function _buyNftAndPlaceManualBid(address bidder, uint256 amount) private {
        _buyNft(bidder);
        vm.prank(bidder);
        token.approve(address(auction), amount / 10);
        vm.prank(bidder);
        auction.placeBid(LOT_ID, amount);
    }

    function _setMaxBid(address bidder, uint256 amount) private {
        vm.prank(bidder);
        token.approve(address(auction), amount / 10);
        vm.prank(bidder);
        auction.setMaxBid(LOT_ID, amount);
    }

    function _setMaxBidAndPlaceFor(address bidder, uint256 maxBid, uint256 bidAmount) private {
        _setMaxBid(bidder, maxBid);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidder, bidAmount);
    }

    function _approveRemainingPayment(address winner, uint256 winningBid) private {
        uint256 buyerPremium = winningBid / 10;
        uint256 remainingPayment = winningBid + buyerPremium - winningBid / 10;
        vm.prank(winner);
        token.approve(address(auction), remainingPayment);
    }

    function _sign(Auction.CreateAuctionParams memory params, bytes32 nonce, uint256 deadline)
        private
        view
        returns (bytes memory)
    {
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adminKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
