// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";
import {LotNFT} from "../src/LotNFT.sol";
import {NFTDesignManager} from "../src/NFTDesignManager.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

contract AuctionCreateTest is Test {
    Auction private auction;
    FakeUSDC private token;
    MockVRFCoordinator private vrf;
    NFTDesignManager private designManager;
    LotNFT private lotNFTImplementation;

    uint256 private adminKey = 0xA11CE;
    uint256 private nonAdminKey = 0xB0B;
    address private admin = vm.addr(adminKey);
    address private operator = makeAddr("operator");
    address private consignor = makeAddr("consignor");
    address private buyer = makeAddr("buyer");

    bytes32 private constant LOT_ID = bytes32(uint256(1));
    uint256 private constant USDC = 1e6;
    uint256 private constant LOW_ESTIMATE = 10_000 * USDC;
    uint256 private constant HIGH_ESTIMATE = 20_000 * USDC;
    uint256 private constant STARTING_BID = 10_000 * USDC;

    event AuctionDetailsUpdated(
        bytes32 indexed lotId,
        address indexed consignor,
        uint256 lowEstimate,
        uint256 highEstimate,
        string thumbnailUrl,
        uint256 blockTimestamp
    );
    event NFTVariantUpdated(
        bytes32 indexed lotId,
        address indexed nftCollection,
        uint256 indexed tokenId,
        uint8 variant,
        uint256 blockTimestamp
    );

    function setUp() external {
        token = new FakeUSDC();
        vrf = new MockVRFCoordinator();
        lotNFTImplementation = new LotNFT();
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
    }

    function testCreateAuctionStoresConfigAndDeploysLotNft() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        bytes32 nonce = _nonce("happy");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _sign(params, nonce, deadline, adminKey);

        vm.recordLogs();
        vm.prank(operator);
        bytes32 createdLotId = auction.createAuction(params, nonce, deadline, signature);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(createdLotId, LOT_ID);
        assertTrue(auction.auctionExists(LOT_ID));
        assertTrue(auction.usedNonces(nonce));

        Auction.AuctionConfig memory config = auction.getAuction(LOT_ID);
        assertEq(config.lotId, LOT_ID);
        assertEq(config.consignor, consignor);
        assertEq(config.lowEstimate, LOW_ESTIMATE);
        assertEq(config.highEstimate, HIGH_ESTIMATE);
        assertEq(config.startingBid, STARTING_BID);
        assertEq(config.previewDurationSeconds, 1 days);
        assertEq(config.auctionDurationSeconds, 7 days);
        assertEq(config.startTime, block.timestamp + 1 days);
        assertEq(config.endTime, block.timestamp + 8 days);
        assertEq(config.nftMaxSupply, 100);
        assertEq(config.nftPriceRatioBps, 1_000);
        assertEq(config.nftPrice, 10 * USDC);
        assertEq(config.thumbnailUrl, "ipfs://thumbnail");
        assertTrue(config.nftCollection != address(0));

        bytes32 eventSignature = keccak256("AuctionCreated(bytes32,address,uint256)");
        bool eventFound;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(auction) || logs[i].topics[0] != eventSignature) continue;

            assertEq(logs[i].topics[1], LOT_ID);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), config.nftCollection);
            assertEq(abi.decode(logs[i].data, (uint256)), block.timestamp);
            eventFound = true;
            break;
        }
        assertTrue(eventFound);

        LotNFT nft = LotNFT(config.nftCollection);
        assertEq(nft.name(), "NextVault Lot 1");
        assertEq(nft.symbol(), "NVL1");
        assertEq(nft.lotId(), LOT_ID);
        assertEq(nft.auction(), address(auction));
        assertEq(nft.maxSupply(), 100);
        assertEq(nft.variant1Quantity(), 50);
        assertEq(nft.variant2Quantity(), 30);
        assertEq(nft.variant3Quantity(), 20);
        assertEq(nft.initialMintLimit(), 5);
        assertEq(config.nftCollection.code.length, 45);
        assertNotEq(config.nftCollection, address(lotNFTImplementation));
        assertEq(designManager.lotNFTImplementation(), address(lotNFTImplementation));
    }

    function testDesignManagerIsFixedDuringInitialization() external {
        assertEq(auction.nftDesignManager(), address(designManager));

        vm.prank(admin);
        vm.expectRevert(NFTDesignManager.AlreadyInitialized.selector);
        designManager.initializeAuction(makeAddr("another-auction"));
    }

    function testLotNftImplementationCannotBeInitialized() external {
        vm.expectRevert(bytes4(keccak256("InvalidInitialization()")));
        lotNFTImplementation.initialize(
            "Implementation", "IMPL", "", LOT_ID, 1, 1, 0, 0, address(auction), address(designManager)
        );
    }

    function testCreateAuctionWithZeroPreviewStartsImmediately() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.previewDurationSeconds = 0;
        bytes32 nonce = _nonce("zero-preview");
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(operator);
        auction.createAuction(params, nonce, deadline, _sign(params, nonce, deadline, adminKey));

        Auction.AuctionConfig memory config = auction.getAuction(LOT_ID);
        assertEq(config.startTime, block.timestamp);
        assertEq(config.endTime, block.timestamp + 7 days);
        assertEq(uint256(auction.currentStatus(LOT_ID)), uint256(Auction.AuctionStatus.Active));
    }

    function testBuyNftMintsPendingThenVrfAssignsDesignsFromRemainingPool() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.previewDurationSeconds = 0;
        bytes32 nonce = _nonce("vrf-reveal");
        uint256 deadline = block.timestamp + 1 hours;
        auction.createAuction(params, nonce, deadline, _sign(params, nonce, deadline, adminKey));

        token.mint(buyer, 50 * USDC);
        vm.startPrank(buyer);
        token.approve(address(auction), 50 * USDC);
        auction.buyNFT(LOT_ID, 5);
        vm.stopPrank();

        LotNFT nft = LotNFT(auction.getAuction(LOT_ID).nftCollection);
        assertEq(nft.balanceOf(buyer), 5);
        assertEq(nft.variantOf(1), 0);
        assertEq(nft.tokenURI(1), "");

        NFTDesignManager.VariantRequest memory request = designManager.getVariantRequest(1);
        assertEq(request.lotId, LOT_ID);
        assertEq(request.buyer, buyer);
        assertEq(request.firstTokenId, 1);
        assertEq(request.quantity, 5);
        assertFalse(request.fulfilled);

        vrf.fulfill(1, 123);

        request = designManager.getVariantRequest(1);
        assertTrue(request.fulfilled);
        assertTrue(nft.variantOf(1) != 0);
        assertEq(nft.tokenURI(1), string.concat("ipfs://metadata/", vm.toString(nft.variantOf(1))));
        assertEq(nft.variant1Remaining() + nft.variant2Remaining() + nft.variant3Remaining(), 95);
    }

    function testTokenUriUsesVariantNumberInsteadOfMintSequence() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.previewDurationSeconds = 0;
        params.variant1Quantity = 0;
        params.variant2Quantity = 1;
        params.variant3Quantity = 0;
        bytes32 nonce = _nonce("variant-uri");
        uint256 deadline = block.timestamp + 1 hours;
        auction.createAuction(params, nonce, deadline, _sign(params, nonce, deadline, adminKey));

        Auction.AuctionConfig memory config = auction.getAuction(LOT_ID);
        token.mint(buyer, config.nftPrice);
        vm.startPrank(buyer);
        token.approve(address(auction), config.nftPrice);
        auction.buyNFT(LOT_ID, 1);
        vm.stopPrank();

        LotNFT nft = LotNFT(config.nftCollection);
        assertEq(nft.tokenURI(1), "");

        vrf.fulfill(1, 123);

        assertEq(nft.variantOf(1), 2);
        assertEq(nft.tokenURI(1), "ipfs://metadata/2");
    }

    function testVrfFulfillmentEmitsDesignUpdateFromAuction() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.previewDurationSeconds = 0;
        bytes32 nonce = _nonce("vrf-auction-event");
        uint256 deadline = block.timestamp + 1 hours;
        auction.createAuction(params, nonce, deadline, _sign(params, nonce, deadline, adminKey));

        Auction.AuctionConfig memory config = auction.getAuction(LOT_ID);
        token.mint(buyer, config.nftPrice);
        vm.startPrank(buyer);
        token.approve(address(auction), config.nftPrice);
        auction.buyNFT(LOT_ID, 1);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, address(auction));
        emit NFTVariantUpdated(LOT_ID, config.nftCollection, 1, 1, block.timestamp);
        vrf.fulfill(1, 0);
    }

    function testDesignUpdateCallbackRejectsCallerThatIsNotLotCollection() external {
        _createDefaultAuction();

        vm.expectRevert(Auction.InvalidNftCollection.selector);
        auction.onLotNFTVariantAssigned(LOT_ID, 1, 1);
    }

    function testRawFulfillRandomWordsRejectsNonCoordinator() external {
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 1;

        vm.expectRevert(NFTDesignManager.OnlyVRFCoordinator.selector);
        designManager.rawFulfillRandomWords(1, randomWords);
    }

    function testVrfAssignmentsExhaustConfiguredRarityPoolExactly() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.previewDurationSeconds = 0;
        params.variant1Quantity = 2;
        params.variant2Quantity = 2;
        params.variant3Quantity = 2;
        bytes32 nonce = _nonce("exhaust-rarity-pool");
        uint256 deadline = block.timestamp + 1 hours;
        auction.createAuction(params, nonce, deadline, _sign(params, nonce, deadline, adminKey));

        Auction.AuctionConfig memory config = auction.getAuction(LOT_ID);
        LotNFT nft = LotNFT(config.nftCollection);
        for (uint256 i = 0; i < 6; i++) {
            address currentBuyer = address(uint160(100 + i));
            token.mint(currentBuyer, config.nftPrice);
            vm.startPrank(currentBuyer);
            token.approve(address(auction), config.nftPrice);
            auction.buyNFT(LOT_ID, 1);
            vm.stopPrank();
            vrf.fulfill(i + 1, 0);
        }

        assertEq(nft.variant1Remaining(), 0);
        assertEq(nft.variant2Remaining(), 0);
        assertEq(nft.variant3Remaining(), 0);

        uint256[5] memory variantCounts;
        for (uint256 tokenId = 1; tokenId <= 6; tokenId++) {
            variantCounts[uint256(nft.variantOf(tokenId))]++;
        }
        assertEq(variantCounts[1], 2);
        assertEq(variantCounts[2], 2);
        assertEq(variantCounts[3], 2);
    }

    function testOperatorCanUpdateAuctionDetailsDuringPreview() external {
        _createDefaultAuction();
        address newConsignor = makeAddr("new-consignor");
        uint256 newLowEstimate = 12_000 * USDC;
        uint256 newHighEstimate = 24_000 * USDC;

        vm.expectEmit(true, true, false, true, address(auction));
        emit AuctionDetailsUpdated(
            LOT_ID, newConsignor, newLowEstimate, newHighEstimate, "ipfs://new-thumbnail", block.timestamp
        );

        vm.prank(operator);
        auction.updateAuctionDetails(LOT_ID, newConsignor, newLowEstimate, newHighEstimate, "ipfs://new-thumbnail");

        Auction.AuctionConfig memory config = auction.getAuction(LOT_ID);
        assertEq(config.consignor, newConsignor);
        assertEq(config.lowEstimate, newLowEstimate);
        assertEq(config.highEstimate, newHighEstimate);
        assertEq(config.thumbnailUrl, "ipfs://new-thumbnail");

        assertEq(config.startingBid, STARTING_BID);
        assertEq(config.nftPriceRatioBps, 1_000);
        assertEq(config.nftPrice, 10 * USDC);
        assertEq(config.previewDurationSeconds, 1 days);
        assertEq(config.auctionDurationSeconds, 7 days);
    }

    function testOperatorCanUpdateAuctionDetailsWhileActive() external {
        _createDefaultAuction();
        vm.warp(block.timestamp + 1 days);

        vm.prank(operator);
        auction.updateAuctionDetails(
            LOT_ID, makeAddr("active-consignor"), 11_000 * USDC, 21_000 * USDC, "ipfs://active-thumbnail"
        );

        Auction.AuctionConfig memory config = auction.getAuction(LOT_ID);
        assertEq(config.lowEstimate, 11_000 * USDC);
        assertEq(config.highEstimate, 21_000 * USDC);
    }

    function testUpdateAuctionDetailsRevertsForNonOperator() external {
        _createDefaultAuction();

        vm.expectRevert();
        auction.updateAuctionDetails(
            LOT_ID, makeAddr("new-consignor"), 11_000 * USDC, 21_000 * USDC, "ipfs://new-thumbnail"
        );
    }

    function testUpdateAuctionDetailsRevertsForInvalidValues() external {
        _createDefaultAuction();

        vm.startPrank(operator);
        vm.expectRevert(Auction.InvalidConsignor.selector);
        auction.updateAuctionDetails(LOT_ID, address(0), 11_000 * USDC, 21_000 * USDC, "ipfs://thumbnail");

        vm.expectRevert(Auction.InvalidEstimate.selector);
        auction.updateAuctionDetails(
            LOT_ID, makeAddr("new-consignor"), 22_000 * USDC, 21_000 * USDC, "ipfs://thumbnail"
        );
        vm.stopPrank();
    }

    function testUpdateAuctionDetailsRevertsAfterAuctionTimeEnds() external {
        _createDefaultAuction();
        vm.warp(block.timestamp + 8 days);

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionDetailsLocked.selector);
        auction.updateAuctionDetails(
            LOT_ID, makeAddr("new-consignor"), 11_000 * USDC, 21_000 * USDC, "ipfs://thumbnail"
        );
    }

    function testCreateAuctionRevertsWhenAuthorizationExpired() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        bytes32 nonce = _nonce("expired");
        uint256 deadline = block.timestamp - 1;
        bytes memory signature = _sign(params, nonce, deadline, adminKey);

        vm.expectRevert(Auction.AuthorizationExpired.selector);
        auction.createAuction(params, nonce, deadline, signature);
    }

    function testCreateAuctionRevertsWhenNonceAlreadyUsed() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        bytes32 nonce = _nonce("reuse");
        uint256 deadline = block.timestamp + 1 hours;

        auction.createAuction(params, nonce, deadline, _sign(params, nonce, deadline, adminKey));

        params.lotId = bytes32(uint256(2));
        bytes memory signature = _sign(params, nonce, deadline, adminKey);
        vm.expectRevert(Auction.NonceAlreadyUsed.selector);
        auction.createAuction(params, nonce, deadline, signature);
    }

    function testCreateAuctionRevertsWhenSignerIsNotAdmin() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        bytes32 nonce = _nonce("bad-signer");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _sign(params, nonce, deadline, nonAdminKey);

        vm.expectRevert(Auction.InvalidSigner.selector);
        auction.createAuction(params, nonce, deadline, signature);
    }

    function testCreateAuctionRevertsWhenSignatureDoesNotMatchParams() external {
        Auction.CreateAuctionParams memory signedParams = _defaultParams();
        bytes32 nonce = _nonce("tampered");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _sign(signedParams, nonce, deadline, adminKey);

        signedParams.highEstimate = HIGH_ESTIMATE + 1;
        vm.expectRevert(Auction.InvalidSigner.selector);
        auction.createAuction(signedParams, nonce, deadline, signature);
    }

    function testCreateAuctionRevertsWhenLotIdIsZero() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.lotId = bytes32(0);

        _expectCreateRevert(params, "zero-lot", Auction.InvalidLotId.selector);
    }

    function testCreateAuctionRevertsWhenLotAlreadyRegistered() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        bytes32 nonce = _nonce("first");
        uint256 deadline = block.timestamp + 1 hours;
        auction.createAuction(params, nonce, deadline, _sign(params, nonce, deadline, adminKey));

        nonce = _nonce("duplicate");
        bytes memory signature = _sign(params, nonce, deadline, adminKey);
        vm.expectRevert(Auction.LotAlreadyRegistered.selector);
        auction.createAuction(params, nonce, deadline, signature);
    }

    function testCreateAuctionRevertsWhenConsignorIsZero() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.consignor = address(0);

        _expectCreateRevert(params, "zero-consignor", Auction.InvalidConsignor.selector);
    }

    function testCreateAuctionRevertsWhenEstimateIsInvalid() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.lowEstimate = 0;
        _expectCreateRevert(params, "zero-low", Auction.InvalidEstimate.selector);

        params = _defaultParams();
        params.highEstimate = params.lowEstimate - 1;
        _expectCreateRevert(params, "high-below-low", Auction.InvalidEstimate.selector);
    }

    function testCreateAuctionRevertsWhenStartingBidIsInvalid() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.startingBid = 0;
        _expectCreateRevert(params, "zero-starting", Auction.InvalidStartingBid.selector);

        params = _defaultParams();
        params.startingBid = params.lowEstimate - 1;
        _expectCreateRevert(params, "starting-below-low", Auction.InvalidStartingBid.selector);
    }

    function testCreateAuctionRevertsWhenAuctionDurationIsZero() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.auctionDurationSeconds = 0;

        _expectCreateRevert(params, "zero-duration", Auction.InvalidAuctionDuration.selector);
    }

    function testCreateAuctionRevertsWhenNftConfigIsInvalid() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.nftPriceRatioBps = 0;
        _expectCreateRevert(params, "zero-ratio", Auction.InvalidNftConfig.selector);

        params = _defaultParams();
        params.lowEstimate = 1;
        params.highEstimate = 1;
        params.startingBid = 1;
        params.nftPriceRatioBps = 1;
        _expectCreateRevert(params, "zero-price", Auction.InvalidNftConfig.selector);
    }

    function testCreateAuctionRevertsWhenRarityAllocationIsZero() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.variant1Quantity = 0;
        params.variant2Quantity = 0;
        params.variant3Quantity = 0;

        _expectCreateRevert(params, "zero-supply", Auction.InvalidVariantAllocation.selector);
    }

    function testCreateAuctionSupportsSmallSupplyMintLimitMinimumOne() external {
        Auction.CreateAuctionParams memory params = _defaultParams();
        params.variant1Quantity = 1;
        params.variant2Quantity = 0;
        params.variant3Quantity = 0;
        bytes32 nonce = _nonce("small-supply");
        uint256 deadline = block.timestamp + 1 hours;

        auction.createAuction(params, nonce, deadline, _sign(params, nonce, deadline, adminKey));

        LotNFT nft = LotNFT(auction.getAuction(LOT_ID).nftCollection);
        assertEq(nft.maxSupply(), 1);
        assertEq(nft.initialMintLimit(), 1);
    }

    function _createDefaultAuction() private {
        Auction.CreateAuctionParams memory params = _defaultParams();
        bytes32 nonce = _nonce("update-details");
        uint256 deadline = block.timestamp + 1 hours;
        auction.createAuction(params, nonce, deadline, _sign(params, nonce, deadline, adminKey));
    }

    function _expectCreateRevert(Auction.CreateAuctionParams memory params, string memory nonceSeed, bytes4 selector)
        private
    {
        bytes32 nonce = _nonce(nonceSeed);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _sign(params, nonce, deadline, adminKey);
        vm.expectRevert(selector);
        auction.createAuction(params, nonce, deadline, signature);
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

    function _nonce(string memory seed) private pure returns (bytes32) {
        return keccak256(bytes(seed));
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
