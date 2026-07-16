// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Auction} from "../src/Auction.sol";
import {AuctionCreateAuthHelper} from "./AuctionCreateAuthHelper.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";
import {LotNFT} from "../src/LotNFT.sol";

contract AuctionMixedBidFlowTest is AuctionCreateAuthHelper {
    Auction private auction;
    FakeUSDC private token;
    LotNFT private nft;

    uint256 private adminKey = 0xA11CE;
    address private admin = vm.addr(adminKey);
    address private operator = makeAddr("operator");
    address private consignor = makeAddr("consignor");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private carol = makeAddr("carol");
    address private dave = makeAddr("dave");

    bytes32 private constant LOT_ID = bytes32(uint256(1));
    uint256 private constant USDC = 1e6;
    uint256 private constant STARTING_BID = 10_000 * USDC;
    uint256 private constant NFT_PRICE = 10 * USDC;
    uint256 private constant STARTING_BALANCE = 100_000 * USDC;

    event BidPlaced(bytes32 indexed lotId, address indexed bidder, uint256 bidAmount, uint256 blockTimestamp);
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

        token.mint(alice, STARTING_BALANCE);
        token.mint(bob, STARTING_BALANCE);
        token.mint(carol, STARTING_BALANCE);
        token.mint(dave, STARTING_BALANCE);

        _createActiveAuction();
        nft = LotNFT(auction.getAuction(LOT_ID).nftCollection);

        _buyNft(alice, 1);
        _buyNft(bob, 1);
        _buyNft(carol, 1);
        _buyNft(dave, 1);
    }

    function testMixedManualAndOperatorBidFlow() external {
        uint256 aliceBid = 10_000 * USDC;
        uint256 bobBid = 11_000 * USDC;
        uint256 carolBid = 12_000 * USDC;
        uint256 daveBid = 13_000 * USDC;
        uint256 bobSecondBid = 14_000 * USDC;

        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.balanceOf(bob), 1);
        assertEq(nft.balanceOf(carol), 1);
        assertEq(nft.balanceOf(dave), 1);

        _approveBidDeposit(alice, aliceBid);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, alice, aliceBid, block.timestamp);
        vm.prank(alice);
        auction.placeBid(LOT_ID, aliceBid);

        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 4 + aliceBid / 10);
        assertEq(token.balanceOf(alice), STARTING_BALANCE - NFT_PRICE - aliceBid / 10);

        _approveBidDeposit(bob, bobBid);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidRefunded(LOT_ID, alice, aliceBid / 10, block.timestamp);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bob, bobBid, block.timestamp);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bob, bobBid);

        assertEq(token.balanceOf(alice), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(bob), STARTING_BALANCE - NFT_PRICE - bobBid / 10);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 4 + bobBid / 10);

        _approveBidDeposit(carol, carolBid);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, carol, carolBid, block.timestamp);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, carol, carolBid);

        assertEq(token.balanceOf(bob), STARTING_BALANCE - NFT_PRICE - bobBid / 10);
        assertEq(token.balanceOf(carol), STARTING_BALANCE - NFT_PRICE - carolBid / 10);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 4 + bobBid / 10 + carolBid / 10);

        vm.prank(bob);
        vm.expectRevert(Auction.BidModeConflict.selector);
        auction.placeBid(LOT_ID, daveBid);

        vm.expectEmit(true, true, false, true, address(auction));
        emit MaxBidRefunded(LOT_ID, bob, bobBid / 10, block.timestamp);
        vm.prank(operator);
        auction.refundMaxBid(LOT_ID, bob);

        assertEq(token.balanceOf(bob), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 4 + carolBid / 10);

        _approveBidDeposit(dave, daveBid);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, dave, daveBid, block.timestamp);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, dave, daveBid);

        assertEq(token.balanceOf(carol), STARTING_BALANCE - NFT_PRICE - carolBid / 10);
        assertEq(token.balanceOf(dave), STARTING_BALANCE - NFT_PRICE - daveBid / 10);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 4 + carolBid / 10 + daveBid / 10);

        vm.expectEmit(true, true, false, true, address(auction));
        emit MaxBidRefunded(LOT_ID, carol, carolBid / 10, block.timestamp);
        vm.prank(operator);
        auction.refundMaxBid(LOT_ID, carol);

        assertEq(token.balanceOf(carol), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 4 + daveBid / 10);

        vm.prank(operator);
        vm.expectRevert(Auction.CurrentLeaderCannotWithdrawDeposit.selector);
        auction.refundMaxBid(LOT_ID, dave);

        vm.prank(bob);
        token.approve(address(auction), bobSecondBid / 10);

        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bob, bobSecondBid, block.timestamp);
        vm.prank(bob);
        auction.placeBid(LOT_ID, bobSecondBid);

        assertEq(token.balanceOf(bob), STARTING_BALANCE - NFT_PRICE - bobSecondBid / 10);
        assertEq(token.balanceOf(dave), STARTING_BALANCE - NFT_PRICE - daveBid / 10);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 4 + daveBid / 10 + bobSecondBid / 10);

        vm.prank(operator);
        auction.refundMaxBid(LOT_ID, dave);

        assertEq(token.balanceOf(dave), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 4 + bobSecondBid / 10);
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
        _createAuctionWithAdminSignature(auction, params, adminKey);
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
}
