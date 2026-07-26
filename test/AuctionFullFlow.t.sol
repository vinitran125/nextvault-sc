// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";
import {LotNFT} from "../src/LotNFT.sol";

contract AuctionFullFlowTest is Test {
    Auction private auction;
    FakeUSDC private token;

    uint256 private adminKey = 0xA11CE;
    address private admin = vm.addr(adminKey);
    address private operator = makeAddr("operator");
    address private consignor = makeAddr("consignor");
    address private bidderA = makeAddr("bidderA");
    address private bidderB = makeAddr("bidderB");
    address private bidderC = makeAddr("bidderC");

    bytes32 private constant LOT_ID = bytes32(uint256(1));
    uint256 private constant USDC = 1e6;
    uint256 private constant STARTING_BID = 10_000 * USDC;
    uint256 private constant NFT_PRICE = 10 * USDC;
    uint256 private constant STARTING_BALANCE = 100_000 * USDC;

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
        token.mint(bidderC, STARTING_BALANCE);
    }

    function testFullFlowPreviewMixedBidsGracePaymentAndFinalSettlement() external {
        Auction.AuctionConfig memory config = _createAuction(1 hours);
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Preview));

        vm.warp(config.startTime);
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Active));

        _buyNft(bidderA);
        _buyNft(bidderB);
        _buyNft(bidderC);

        _setMaxBid(bidderA, 15_000 * USDC);
        _setMaxBid(bidderB, 18_000 * USDC);

        _placeBidFor(bidderA, STARTING_BID);
        _placeBidFor(bidderB, 11_000 * USDC);
        _placeBidFor(bidderA, 15_000 * USDC);
        _placeBidFor(bidderB, 18_000 * USDC);
        _placeManualBid(bidderC, 19_000 * USDC);

        // The interval worker refunds max bids after the manual bid has exhausted them.
        vm.startPrank(operator);
        auction.refundMaxBid(LOT_ID, bidderA);
        auction.refundMaxBid(LOT_ID, bidderB);
        vm.stopPrank();

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(bidderB), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(bidderC), STARTING_BALANCE - NFT_PRICE - 1_900 * USDC);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 3 + 1_900 * USDC);

        vm.warp(config.endTime);
        vm.prank(operator);
        (address winner, uint256 winningBid, bool collectedAtEnd) = auction.endAuction(LOT_ID);

        assertEq(winner, bidderC);
        assertEq(winningBid, 19_000 * USDC);
        assertFalse(collectedAtEnd);
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Ended));

        _approveRemainingPayment(bidderC, winningBid);
        vm.prank(operator);
        bool collectedAfterRetry = auction.settleAuctionPayment(LOT_ID);

        assertTrue(collectedAfterRetry);
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Finalized));
        assertEq(token.balanceOf(consignor), 17_100 * USDC);
        assertEq(token.balanceOf(admin), 3_800 * USDC);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 3);
        assertEq(token.balanceOf(bidderC), 79_090 * USDC);
    }

    function testFullFlowAutoBidWinnerPaysImmediatelyAtAuctionEnd() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        _buyNft(bidderA);
        _buyNft(bidderB);

        _setMaxBid(bidderA, 15_000 * USDC);
        _setMaxBid(bidderB, 18_000 * USDC);
        _placeBidFor(bidderA, STARTING_BID);
        _placeBidFor(bidderB, 18_000 * USDC);

        vm.prank(operator);
        auction.refundMaxBid(LOT_ID, bidderA);

        _approveRemainingPayment(bidderB, 18_000 * USDC);
        vm.warp(config.endTime);

        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, bidderB);
        assertEq(winningBid, 18_000 * USDC);
        assertTrue(paymentCollected);
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Finalized));
        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(bidderB), 80_190 * USDC);
        assertEq(token.balanceOf(consignor), 16_200 * USDC);
        assertEq(token.balanceOf(admin), 3_600 * USDC);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2);
    }

    function testFullFlowWithdrawRefundsManualAndBackendRefundsAllMaxBids() external {
        Auction.AuctionConfig memory config = _createAuction(0);
        LotNFT nft = LotNFT(config.nftCollection);

        _buyNft(bidderA);
        _buyNft(bidderB);
        _buyNft(bidderC);
        _setMaxBid(bidderA, 15_000 * USDC);
        _setMaxBid(bidderB, 18_000 * USDC);
        _placeBidFor(bidderA, STARTING_BID);
        _placeBidFor(bidderB, 18_000 * USDC);
        _placeManualBid(bidderC, 19_000 * USDC);

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        assertEq(token.balanceOf(bidderC), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 3 + 3_300 * USDC);
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Cancelled));

        // The backend interval finds every remaining max-bid deposit and refunds it.
        vm.startPrank(operator);
        auction.refundMaxBid(LOT_ID, bidderA);
        auction.refundMaxBid(LOT_ID, bidderB);
        vm.stopPrank();

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(bidderB), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 3);
        assertEq(nft.ownerOf(1), bidderA);
        assertEq(nft.ownerOf(2), bidderB);
        assertEq(nft.ownerOf(3), bidderC);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.endAuction(LOT_ID);
    }

    function testFullFlowNoBidEndsWithoutRefundingPurchasedNfts() external {
        Auction.AuctionConfig memory config = _createAuction(30 minutes);
        vm.warp(config.startTime);

        _buyNft(bidderA);
        _buyNft(bidderB);
        LotNFT nft = LotNFT(config.nftCollection);

        vm.warp(config.endTime);
        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, address(0));
        assertEq(winningBid, 0);
        assertFalse(paymentCollected);
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Ended));
        assertEq(nft.ownerOf(1), bidderA);
        assertEq(nft.ownerOf(2), bidderB);
        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(bidderB), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2);
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
        bytes32 nonce = keccak256(abi.encode("full-flow"));
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

    function _setMaxBid(address bidder, uint256 amount) private {
        vm.prank(bidder);
        token.approve(address(auction), amount / 10);
        vm.prank(bidder);
        auction.setMaxBid(LOT_ID, amount);
    }

    function _placeBidFor(address bidder, uint256 amount) private {
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidder, amount);
    }

    function _placeManualBid(address bidder, uint256 amount) private {
        vm.prank(bidder);
        token.approve(address(auction), amount / 10);
        vm.prank(bidder);
        auction.placeBid(LOT_ID, amount);
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
