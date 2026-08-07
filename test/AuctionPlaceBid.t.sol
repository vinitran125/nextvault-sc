// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";
import {LotNFT} from "../src/LotNFT.sol";
import {NFTDesignManager} from "../src/NFTDesignManager.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

contract AuctionPlaceBidTest is Test {
    Auction private auction;
    FakeUSDC private token;
    MockVRFCoordinator private vrf;
    NFTDesignManager private designManager;

    uint256 private adminKey = 0xA11CE;
    address private admin = vm.addr(adminKey);
    address private operator = makeAddr("operator");
    address private consignor = makeAddr("consignor");
    address private bidderA = makeAddr("bidderA");
    address private bidderB = makeAddr("bidderB");
    address private bidderC = makeAddr("bidderC");

    bytes32 private constant LOT_ID = bytes32(uint256(1));
    bytes32 private constant UNKNOWN_LOT_ID = bytes32(uint256(999));
    uint256 private constant USDC = 1e6;
    uint256 private constant LOW_ESTIMATE = 10_000 * USDC;
    uint256 private constant HIGH_ESTIMATE = 20_000 * USDC;
    uint256 private constant STARTING_BID = 10_000 * USDC;
    uint256 private constant NFT_PRICE = 10 * USDC;
    uint256 private constant STARTING_BALANCE = 100_000 * USDC;

    event BidPlaced(
        bytes32 indexed lotId, address indexed bidder, uint256 previousBid, uint256 amount, uint256 blockTimestamp
    );
    event AuctionExtended(bytes32 indexed lotId, uint256 newEndTime);
    event BidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);

    function setUp() external {
        token = new FakeUSDC();
        vrf = new MockVRFCoordinator();
        LotNFT lotNFTImplementation = new LotNFT();
        designManager = new NFTDesignManager(
            admin, address(lotNFTImplementation), address(vrf), 1, bytes32(uint256(1)), 500_000, 3, false
        );
        Auction implementation = new Auction();
        bytes memory initData = abi.encodeCall(Auction.initialize, (token, admin, address(designManager)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        auction = Auction(address(proxy));

        vm.prank(admin);
        designManager.initializeAuction(address(auction));

        bytes32 operatorRole = auction.OPERATOR_ROLE();
        vm.prank(admin);
        auction.grantRole(operatorRole, operator);

        token.mint(bidderA, STARTING_BALANCE);
        token.mint(bidderB, STARTING_BALANCE);
        token.mint(bidderC, STARTING_BALANCE);
    }

    function testPlaceBidAcceptsStartingBidAndTakesTenPercentDeposit() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bidderA, 0, STARTING_BID, block.timestamp);

        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        assertEq(token.balanceOf(address(auction)), NFT_PRICE + STARTING_BID / 10);
        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE - STARTING_BID / 10);
    }

    function testPlaceBidExtendsAuctionWhenBidIsInsideAntiSnipeWindow() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, STARTING_BID);

        uint256 previousEndTime = auction.getAuction(LOT_ID).endTime;
        vm.warp(previousEndTime - 4 minutes);
        uint256 newEndTime = block.timestamp + 5 minutes;

        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bidderA, 0, STARTING_BID, block.timestamp);
        vm.expectEmit(true, false, false, true, address(auction));
        emit AuctionExtended(LOT_ID, newEndTime);

        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        assertEq(auction.getAuction(LOT_ID).endTime, newEndTime);
    }

    function testPlaceBidDoesNotExtendAuctionOutsideAntiSnipeWindow() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, STARTING_BID);

        uint256 previousEndTime = auction.getAuction(LOT_ID).endTime;
        vm.warp(previousEndTime - 6 minutes);

        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        assertEq(auction.getAuction(LOT_ID).endTime, previousEndTime);
    }

    function testPlaceBidUsesConfiguredAntiSnipeWindow() external {
        vm.prank(operator);
        auction.setAuctionTimingConfig(1 hours, 2 minutes);

        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, STARTING_BID);

        uint256 previousEndTime = auction.getAuction(LOT_ID).endTime;
        vm.warp(previousEndTime - 90 seconds);
        uint256 newEndTime = block.timestamp + 2 minutes;

        vm.expectEmit(true, false, false, true, address(auction));
        emit AuctionExtended(LOT_ID, newEndTime);

        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        assertEq(auction.getAuction(LOT_ID).endTime, newEndTime);
    }

    function testPlaceBidRefundsPreviousManualBidder() external {
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
        emit BidPlaced(LOT_ID, bidderB, STARTING_BID, nextBid, block.timestamp);

        vm.prank(bidderB);
        auction.placeBid(LOT_ID, nextBid);

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(bidderB), STARTING_BALANCE - NFT_PRICE - nextBid / 10);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + nextBid / 10);
    }

    function testPlaceBidRevertsWhenAuctionMissing() external {
        vm.prank(bidderA);
        vm.expectRevert(Auction.AuctionNotFound.selector);
        auction.placeBid(UNKNOWN_LOT_ID, STARTING_BID);
    }

    function testPlaceBidRevertsWhenAuctionIsInPreview() external {
        _createPreviewAuction();

        vm.prank(bidderA);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
    }

    function testPlaceBidRevertsWhenAuctionEndedByTime() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.warp(block.timestamp + 7 days);

        vm.prank(bidderA);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
    }

    function testPlaceBidRevertsWhenAuctionCancelled() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.prank(operator);
        auction.withdrawAuction(LOT_ID);

        vm.prank(bidderA);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
    }

    function testPlaceBidRevertsWhenBidderHasNoNft() external {
        _createActiveAuction();
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.prank(bidderA);
        vm.expectRevert(Auction.NotEligibleToBid.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
    }

    function testPlaceBidRevertsWhenFirstBidBelowStartingBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBid(LOT_ID, STARTING_BID - 1);
    }

    function testPlaceBidRevertsWhenFirstBidSkipsAboveStartingBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, 11_000 * USDC);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBid(LOT_ID, 11_000 * USDC);
    }

    function testPlaceBidRevertsWhenNextBidDoesNotMatchIncrement() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _approveBidDeposit(bidderA, STARTING_BID);
        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        _approveBidDeposit(bidderB, 12_000 * USDC);
        vm.prank(bidderB);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBid(LOT_ID, 12_000 * USDC);
    }

    function testPlaceBidRevertsWithoutEnoughAllowance() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        vm.prank(bidderA);
        vm.expectRevert();
        auction.placeBid(LOT_ID, STARTING_BID);
    }

    function testPlaceBidRevertsWhenBelowRegisteredMaxBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        uint256 maxBid = 15_000 * USDC;
        _approveBidDeposit(bidderA, maxBid);
        vm.prank(bidderA);
        auction.setMaxBid(LOT_ID, maxBid);

        _approveBidDeposit(bidderB, STARTING_BID);
        vm.prank(bidderB);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
    }

    function testPlaceBidDoesNotRefundPreviousAutoBidder() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _approveBidDeposit(bidderA, STARTING_BID);
        vm.prank(bidderA);
        auction.setMaxBid(LOT_ID, STARTING_BID);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);

        uint256 nextBid = 11_000 * USDC;
        _approveBidDeposit(bidderB, nextBid);

        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bidderB, STARTING_BID, nextBid, block.timestamp);

        vm.prank(bidderB);
        auction.placeBid(LOT_ID, nextBid);

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE - STARTING_BID / 10);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + STARTING_BID / 10 + nextBid / 10);
    }

    function _createActiveAuction() private {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.previewDurationSeconds = 0;
        _createAuction(params, "active");
    }

    function _createPreviewAuction() private {
        _createAuction(_defaultParams(), "preview");
    }

    function _createAuction(Auction.CreateAuctionParams memory params, string memory nonceSeed) private {
        bytes32 nonce = keccak256(bytes(nonceSeed));
        uint256 deadline = block.timestamp + 1 hours;
        auction.createAuction(params, nonce, deadline, _sign(params, nonce, deadline, adminKey));
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
            lowEstimate: LOW_ESTIMATE,
            highEstimate: HIGH_ESTIMATE,
            startingBid: STARTING_BID,
            previewDurationSeconds: 1 days,
            auctionDurationSeconds: 7 days,
            variant1Quantity: 50,
            variant2Quantity: 30,
            variant3Quantity: 20,
            nftPriceRatioBps: 1_000,
            nftName: "NextVault Lot 1",
            nftSymbol: "NVL1",
            thumbnailUrl: "ipfs://thumbnail",
            metadataUri: "ipfs://metadata/"
        });
    }

    function _sign(Auction.CreateAuctionParams memory params, bytes32 nonce, uint256 deadline, uint256 signerKey)
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
                params.variant1Quantity,
                params.variant2Quantity,
                params.variant3Quantity,
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
