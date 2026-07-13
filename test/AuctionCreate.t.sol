// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";
import {LotNFT} from "../src/LotNFT.sol";

contract AuctionCreateTest is Test {
    Auction private auction;
    FakeUSDC private token;

    address private admin = makeAddr("admin");
    address private operator = makeAddr("operator");
    address private consignor = makeAddr("consignor");

    bytes32 private constant LOT_ID = bytes32(uint256(1));
    uint256 private constant USDC = 1e6;

    event AuctionCreated(bytes32 indexed lotId, bytes data, uint256 blockTimestamp);

    function setUp() external {
        token = new FakeUSDC();
        Auction implementation = new Auction();
        bytes memory initData = abi.encodeCall(Auction.initialize, (token, admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        auction = Auction(address(proxy));

        bytes32 operatorRole = auction.OPERATOR_ROLE();
        vm.prank(admin);
        auction.grantRole(operatorRole, operator);
    }

    function testCreateAuctionStoresConfigAndDeploysNft() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        uint256 createdAt = block.timestamp;

        vm.expectEmit(true, false, false, false, address(auction));
        emit AuctionCreated(params.lotId, "", createdAt);

        vm.prank(operator);
        bytes32 lotId = auction.createAuction(params);

        assertEq(lotId, params.lotId);
        assertTrue(auction.auctionExists(params.lotId));

        Auction.AuctionConfig memory config = auction.getAuction(params.lotId);
        assertEq(config.lotId, params.lotId);
        assertEq(config.consignor, params.consignor);
        assertEq(config.lowEstimate, params.lowEstimate);
        assertEq(config.highEstimate, params.highEstimate);
        assertEq(config.startingBid, params.startingBid);
        assertEq(config.previewDurationSeconds, params.previewDurationSeconds);
        assertEq(config.auctionDurationSeconds, params.auctionDurationSeconds);
        assertEq(config.startTime, createdAt + params.previewDurationSeconds);
        assertEq(config.endTime, config.startTime + params.auctionDurationSeconds);
        assertEq(config.nftMaxSupply, 100);
        assertEq(config.designAQuantity, params.designAQuantity);
        assertEq(config.designBQuantity, params.designBQuantity);
        assertEq(config.designCQuantity, params.designCQuantity);
        assertEq(config.nftPriceRatioBps, params.nftPriceRatioBps);
        assertEq(config.nftPrice, 10 * USDC);
        assertEq(config.thumbnailUrl, params.thumbnailUrl);
        assertEq(config.metadataUri, params.metadataUri);

        LotNFT nft = LotNFT(config.nftCollection);
        assertEq(nft.name(), params.nftName);
        assertEq(nft.symbol(), params.nftSymbol);
        assertEq(nft.auction(), address(auction));
        assertEq(nft.lotId(), params.lotId);
        assertEq(nft.maxSupply(), config.nftMaxSupply);
        assertEq(nft.designAQuantity(), params.designAQuantity);
        assertEq(nft.designBQuantity(), params.designBQuantity);
        assertEq(nft.designCQuantity(), params.designCQuantity);
    }

    function testCreateAuctionWithZeroPreviewStartsActive() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.previewDurationSeconds = 0;

        vm.prank(operator);
        auction.createAuction(params);

        assertEq(uint256(auction.currentStatus(params.lotId)), uint256(Auction.AuctionStatus.Active));
    }

    function testCreateAuctionRevertsForNonOperator() external {
        Auction.CreateAuctionParams memory params = _defaultParams();

        vm.expectRevert();
        auction.createAuction(params);
    }

    function testCreateAuctionRevertsForDuplicateLot() external {
        Auction.CreateAuctionParams memory params = _defaultParams();

        vm.startPrank(operator);
        auction.createAuction(params);
        vm.expectRevert(Auction.LotAlreadyRegistered.selector);
        auction.createAuction(params);
        vm.stopPrank();
    }

    function testCreateAuctionRevertsForInvalidRarityAllocation() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.designAQuantity = 0;
        params.designBQuantity = 0;
        params.designCQuantity = 0;

        vm.prank(operator);
        vm.expectRevert(Auction.InvalidRarityAllocation.selector);
        auction.createAuction(params);
    }

    function testCreateAuctionRevertsForInvalidEstimates() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.highEstimate = params.lowEstimate - 1;

        vm.prank(operator);
        vm.expectRevert(Auction.InvalidEstimate.selector);
        auction.createAuction(params);
    }

    function testCreateAuctionRevertsForStartingBidBelowLowEstimate() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.startingBid = params.lowEstimate - 1;

        vm.prank(operator);
        vm.expectRevert(Auction.InvalidStartingBid.selector);
        auction.createAuction(params);
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
