// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";
import {LotNFT} from "../src/LotNFT.sol";
import {NFTDesignManager} from "../src/NFTDesignManager.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

contract AuctionBidAuthorizationTest is Test {
    Auction private auction;
    FakeUSDC private token;

    uint256 private constant ADMIN_KEY = 0xA11CE;
    address private admin = vm.addr(ADMIN_KEY);
    address private operator = makeAddr("operator");
    address private consignor = makeAddr("consignor");
    address private bidderA = makeAddr("bidderA");
    address private bidderB = makeAddr("bidderB");

    bytes32 private constant LOT_ID = bytes32(uint256(1));
    uint256 private constant USDC = 1e6;
    uint256 private constant STARTING_BID = 10_000 * USDC;
    uint256 private constant NFT_PRICE = 10 * USDC;

    function setUp() external {
        token = new FakeUSDC();
        MockVRFCoordinator vrf = new MockVRFCoordinator();
        LotNFT lotNFTImplementation = new LotNFT();
        NFTDesignManager designManager = new NFTDesignManager(
            admin, address(lotNFTImplementation), address(vrf), 1, bytes32(uint256(1)), 500_000, 3, false
        );
        Auction implementation = new Auction();
        bytes memory initData = abi.encodeCall(Auction.initialize, (token, admin, address(designManager)));
        auction = Auction(address(new ERC1967Proxy(address(implementation), initData)));

        vm.prank(admin);
        designManager.initializeAuction(address(auction));
        bytes32 operatorRole = auction.OPERATOR_ROLE();
        vm.prank(admin);
        auction.grantRole(operatorRole, operator);

        token.mint(bidderA, 100_000 * USDC);
        token.mint(bidderB, 100_000 * USDC);
        _createActiveAuction();
        _buyNft(bidderA);
        _buyNft(bidderB);
    }

    function testBidAuthorizationIsRequiredByDefault() external {
        vm.prank(bidderA);
        vm.expectRevert(Auction.BidAuthorizationRequired.selector);
        auction.placeBid(LOT_ID, STARTING_BID);

        vm.prank(bidderA);
        vm.expectRevert(Auction.BidAuthorizationRequired.selector);
        auction.setMaxBid(LOT_ID, STARTING_BID);
    }

    function testAuthorizedManualBidUsesSignedAmount() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "manual");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        vm.prank(bidderA);
        auction.placeBid(authorization, signature);

        assertTrue(auction.usedNonces(authorization.nonce));
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2);
        (uint256 totalExposure,) = auction.getBidCreditExposure(LOT_ID, bidderA);
        assertEq(totalExposure, STARTING_BID);
    }

    function testManualBidRejectsAmountChangedAfterSigning() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "tampered-amount");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        authorization.amount += USDC;

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidSigner.selector);
        auction.placeBid(authorization, signature);
    }

    function testManualBidRejectsDifferentCaller() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "wrong-bidder");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);

        vm.prank(bidderB);
        vm.expectRevert(Auction.InvalidBidAuthorization.selector);
        auction.placeBid(authorization, signature);
    }

    function testManualBidAuthorizationCannotBeReplayed() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "replay");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        vm.prank(bidderA);
        auction.placeBid(authorization, signature);

        vm.prank(bidderA);
        vm.expectRevert(Auction.NonceAlreadyUsed.selector);
        auction.placeBid(authorization, signature);
    }

    function testManualBidRejectsExpiredAuthorization() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "expired");
        authorization.deadline = block.timestamp - 1;
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);

        vm.prank(bidderA);
        vm.expectRevert(Auction.AuthorizationExpired.selector);
        auction.placeBid(authorization, signature);
    }

    function testAuthorizedMaximumBidKeepsOperatorAutobidFlow() external {
        uint256 maxBid = 15_000 * USDC;
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, maxBid, Auction.BidType.Maximum, "maximum");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);
        vm.prank(bidderA);
        auction.setMaxBid(authorization, signature);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);

        assertTrue(auction.usedNonces(authorization.nonce));
        (uint256 totalExposure,) = auction.getBidCreditExposure(LOT_ID, bidderA);
        assertEq(totalExposure, maxBid);
    }

    function testManualAuthorizationCannotSetMaximumBid() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "wrong-type");
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidBidAuthorization.selector);
        auction.setMaxBid(authorization, signature);
    }

    function testBidAuthorizationRejectsSignerWithoutOperatorRole() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "non-operator");
        bytes memory signature = _signBidAuthorization(authorization, 0xB0B);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidSigner.selector);
        auction.placeBid(authorization, signature);
    }

    function testCreditBidCannotExceedSignedGlobalLimit() external {
        Auction.BidAuthorization memory authorization =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "over-limit");
        authorization.biddingLimit = STARTING_BID - 1;
        bytes memory signature = _signBidAuthorization(authorization, ADMIN_KEY);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidBidAuthorization.selector);
        auction.placeBid(authorization, signature);

        (uint256 totalExposure,) = auction.getBidCreditExposure(LOT_ID, bidderA);
        assertEq(totalExposure, 0);
    }

    function testOutbidReleasesManualCreditExposure() external {
        Auction.BidAuthorization memory first =
            _authorization(bidderA, STARTING_BID, Auction.BidType.Manual, "first-credit");
        bytes memory firstSignature = _signBidAuthorization(first, ADMIN_KEY);
        vm.prank(bidderA);
        auction.placeBid(first, firstSignature);

        uint256 nextBid = STARTING_BID + 1_000 * USDC;
        Auction.BidAuthorization memory second =
            _authorization(bidderB, nextBid, Auction.BidType.Manual, "second-credit");
        bytes memory secondSignature = _signBidAuthorization(second, ADMIN_KEY);
        vm.prank(bidderB);
        auction.placeBid(second, secondSignature);

        (uint256 bidderATotal,) = auction.getBidCreditExposure(LOT_ID, bidderA);
        (uint256 bidderBTotal,) = auction.getBidCreditExposure(LOT_ID, bidderB);
        assertEq(bidderATotal, 0);
        assertEq(bidderBTotal, nextBid);
    }

    function testOnlyAdminCanDisableRequirementForStagedMigration() external {
        vm.prank(operator);
        vm.expectRevert();
        auction.setBidAuthorizationRequired(false);

        vm.prank(admin);
        auction.setBidAuthorizationRequired(false);
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + STARTING_BID / 10);
    }

    function _authorization(address bidder, uint256 amount, Auction.BidType bidType, string memory nonceSeed)
        private
        view
        returns (Auction.BidAuthorization memory)
    {
        return Auction.BidAuthorization({
            lotId: LOT_ID,
            bidder: bidder,
            amount: amount,
            bidType: bidType,
            depositAmount: 0,
            biddingLimit: type(uint256).max,
            nonce: keccak256(bytes(nonceSeed)),
            deadline: block.timestamp + 5 minutes
        });
    }

    function _signBidAuthorization(Auction.BidAuthorization memory authorization, uint256 signerKey)
        private
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                auction.BID_AUTHORIZATION_TYPEHASH(),
                authorization.lotId,
                authorization.bidder,
                authorization.amount,
                authorization.bidType,
                authorization.depositAmount,
                authorization.biddingLimit,
                authorization.nonce,
                authorization.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("NextVaultAuction")),
                keccak256(bytes("1")),
                block.chainid,
                address(auction)
            )
        );
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
            variant1Quantity: 50,
            variant2Quantity: 30,
            variant3Quantity: 20,
            nftPriceRatioBps: 1_000,
            nftName: "NextVault Lot 1",
            nftSymbol: "NVL1",
            thumbnailUrl: "ipfs://thumbnail",
            metadataUri: "ipfs://metadata/"
        });
        bytes32 nonce = keccak256("create-auction");
        uint256 deadline = block.timestamp + 1 hours;
        auction.createAuction(params, nonce, deadline, _signCreateAuction(params, nonce, deadline));
    }

    function _signCreateAuction(Auction.CreateAuctionParams memory params, bytes32 nonce, uint256 deadline)
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ADMIN_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buyNft(address buyer) private {
        vm.prank(buyer);
        token.approve(address(auction), NFT_PRICE);
        vm.prank(buyer);
        auction.buyNFT(LOT_ID, 1);
    }

    function _approveBidDeposit(address bidder, uint256 amount) private {
        vm.prank(bidder);
        token.approve(address(auction), amount / 10);
    }
}
