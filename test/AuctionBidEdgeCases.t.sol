// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";

contract AuctionBidEdgeCasesTest is Test {
    Auction private auction;
    FakeUSDC private token;

    address private admin = makeAddr("admin");
    address private operator = makeAddr("operator");
    address private consignor = makeAddr("consignor");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private carol = makeAddr("carol");

    bytes32 private constant LOT_ID = bytes32(uint256(1));
    uint256 private constant USDC = 1e6;
    uint256 private constant STARTING_BID = 10_000 * USDC;
    uint256 private constant NFT_PRICE = 10 * USDC;
    uint256 private constant STARTING_BALANCE = 100_000 * USDC;

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

        token.mint(alice, STARTING_BALANCE);
        token.mint(bob, STARTING_BALANCE);
        token.mint(carol, STARTING_BALANCE);

        _createActiveAuction();
        _buyNft(alice);
        _buyNft(bob);
        _buyNft(carol);
    }

    function testSameManualBidderCanIncreaseBidInSameBlock() external {
        uint256 firstBid = 10_000 * USDC;
        uint256 secondBid = 11_000 * USDC;

        _approveBidDeposit(alice, firstBid);
        vm.prank(alice);
        auction.placeBid(LOT_ID, firstBid);

        _approveBidDeposit(alice, secondBid);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidRefunded(LOT_ID, alice, firstBid / 10, block.timestamp);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, alice, secondBid, block.timestamp);

        vm.prank(alice);
        auction.placeBid(LOT_ID, secondBid);

        assertEq(token.balanceOf(alice), STARTING_BALANCE - NFT_PRICE - secondBid / 10);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 3 + secondBid / 10);
    }

    function testSameManualBidderSecondBidNeedsFullDepositAllowance() external {
        uint256 firstBid = 10_000 * USDC;
        uint256 secondBid = 11_000 * USDC;
        uint256 deltaDeposit = secondBid / 10 - firstBid / 10;

        _approveBidDeposit(alice, firstBid);
        vm.prank(alice);
        auction.placeBid(LOT_ID, firstBid);

        vm.prank(alice);
        token.approve(address(auction), deltaDeposit);

        vm.prank(alice);
        vm.expectRevert();
        auction.placeBid(LOT_ID, secondBid);
    }

    function testTwoDifferentManualBiddersSameAmountInSameBlockSecondReverts() external {
        _approveBidDeposit(alice, STARTING_BID);
        vm.prank(alice);
        auction.placeBid(LOT_ID, STARTING_BID);

        _approveBidDeposit(bob, STARTING_BID);
        vm.prank(bob);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
    }

    function testTwoDifferentManualBiddersHigherBidInSameBlockRefundsPrevious() external {
        uint256 bobBid = 11_000 * USDC;

        _approveBidDeposit(alice, STARTING_BID);
        vm.prank(alice);
        auction.placeBid(LOT_ID, STARTING_BID);

        _approveBidDeposit(bob, bobBid);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidRefunded(LOT_ID, alice, STARTING_BID / 10, block.timestamp);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bob, bobBid, block.timestamp);

        vm.prank(bob);
        auction.placeBid(LOT_ID, bobBid);

        assertEq(token.balanceOf(alice), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(bob), STARTING_BALANCE - NFT_PRICE - bobBid / 10);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 3 + bobBid / 10);
    }

    function testManualBidAfterActiveMaxBidDoesNotRefundMaxBidderImmediately() external {
        uint256 bobMaxBid = STARTING_BID;
        uint256 carolBid = 11_000 * USDC;

        _approveBidDeposit(bob, bobMaxBid);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bob, bobMaxBid);

        _approveBidDeposit(carol, carolBid);
        vm.prank(carol);
        auction.placeBid(LOT_ID, carolBid);

        assertEq(token.balanceOf(bob), STARTING_BALANCE - NFT_PRICE - bobMaxBid / 10);
        assertEq(token.balanceOf(carol), STARTING_BALANCE - NFT_PRICE - carolBid / 10);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 3 + bobMaxBid / 10 + carolBid / 10);

        vm.prank(operator);
        auction.refundMaxBid(LOT_ID, bob);

        assertEq(token.balanceOf(bob), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 3 + carolBid / 10);
    }

    function testDifferentBidTypesSameAmountInSameBlockSecondReverts() external {
        uint256 bobMaxBid = STARTING_BID;

        _approveBidDeposit(bob, bobMaxBid);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bob, bobMaxBid);

        _approveBidDeposit(carol, bobMaxBid);
        vm.prank(carol);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBid(LOT_ID, bobMaxBid);
    }

    function _createActiveAuction() private {
        Auction.CreateAuctionParams memory params = Auction.CreateAuctionParams({
            lotId: LOT_ID,
            consignor: consignor,
            lowEstimate: STARTING_BID,
            highEstimate: 20_000 * USDC,
            startingBid: STARTING_BID,
            previewDurationSeconds: 0,
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

        vm.prank(operator);
        auction.createAuction(params);
    }

    function _buyNft(address buyer) private {
        vm.prank(buyer);
        token.approve(address(auction), NFT_PRICE);

        vm.prank(buyer);
        auction.buyNFT(LOT_ID, 1);
    }

    function _approveBidDeposit(address bidder, uint256 bidAmount) private {
        vm.prank(bidder);
        token.approve(address(auction), bidAmount / 10);
    }
}
