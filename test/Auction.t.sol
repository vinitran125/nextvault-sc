// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";
import {LotNFT} from "../src/LotNFT.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract MockUSDC is ERC20, ERC20Permit {
    constructor() ERC20("Mock USDC", "USDC") ERC20Permit("Mock USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AuctionTest is Test {
    MockUSDC public usdc;
    Auction public auction;

    address public admin = address(0xA11CE);
    address public operator = address(0xB0B);
    address public consignor = address(0xC0FFEE);
    address public stranger = address(0xBAD);
    uint256 public aliceKey = 0xA11CE;
    uint256 public bobKey = 0xB0B;
    uint256 public carolKey = 0xCA201;
    address public alice;
    address public bob;
    address public carol;

    bytes32 public lotId = keccak256("NV-2026-01-00001");

    function setUp() public {
        alice = vm.addr(aliceKey);
        bob = vm.addr(bobKey);
        carol = vm.addr(carolKey);

        usdc = new MockUSDC();

        Auction implementation = new Auction();
        bytes memory initData = abi.encodeCall(Auction.initialize, (usdc, admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        auction = Auction(address(proxy));

        bytes32 operatorRole = auction.OPERATOR_ROLE();
        vm.prank(admin);
        auction.grantRole(operatorRole, operator);

        _fundAndApprove(alice, 1_000_000 ether);
        _fundAndApprove(bob, 1_000_000 ether);
        _fundAndApprove(carol, 1_000_000 ether);
    }

    function test_CreateAuctionWithPreview() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 10 days, 14 days));

        Auction.AuctionConfig memory config = auction.getAuction(lotId);

        assertEq(config.lotId, lotId);
        assertEq(config.consignor, consignor);
        assertTrue(config.nftCollection != address(0));
        assertEq(config.lowEstimate, 10_000 ether);
        assertEq(config.highEstimate, 20_000 ether);
        assertEq(config.startingBid, 10_000 ether);
        assertEq(config.startTime, block.timestamp + 10 days);
        assertEq(config.endTime, block.timestamp + 24 days);
        assertEq(config.previewDurationSeconds, 10 days);
        assertEq(config.auctionDurationSeconds, 14 days);
        assertEq(config.nftMaxSupply, 200);
        assertEq(LotNFT(config.nftCollection).totalMinted(), 0);
        assertEq(config.nftPriceRatioBps, 1_000);
        assertEq(config.nftPrice, 5 ether);
        assertEq(config.metadataUri, "ipfs://lot/");
        assertEq(uint256(auction.currentStatus(lotId)), uint256(Auction.AuctionStatus.Preview));
        assertEq(auction.lotCount(), 1);
        assertEq(auction.lotIdAt(0), lotId);

        vm.warp(block.timestamp + 10 days);

        assertEq(uint256(auction.currentStatus(lotId)), uint256(Auction.AuctionStatus.Active));
    }

    function test_CreateAuctionWithoutPreviewStartsActive() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 0, 14 days));

        Auction.AuctionConfig memory config = auction.getAuction(lotId);

        assertEq(config.startTime, block.timestamp);
        assertEq(config.endTime, block.timestamp + 14 days);
        assertEq(uint256(auction.currentStatus(lotId)), uint256(Auction.AuctionStatus.Active));
    }

    function test_CurrentStatusBecomesEndedAfterEndTime() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 0, 14 days));

        vm.warp(block.timestamp + 14 days);

        assertEq(uint256(auction.currentStatus(lotId)), uint256(Auction.AuctionStatus.Ended));
    }

    function test_InitialMintLimitIsFivePercentMinimumOne() public {
        bytes32 smallLotId = keccak256("small");

        vm.prank(operator);
        auction.createAuction(
            Auction.CreateAuctionParams({
                lotId: smallLotId,
                consignor: consignor,
                lowEstimate: 10_000 ether,
                highEstimate: 20_000 ether,
                startingBid: 10_000 ether,
                bidIncrement: 1_000 ether,
                previewDurationSeconds: 0,
                auctionDurationSeconds: 14 days,
                nftMaxSupply: 19,
                nftPriceRatioBps: 1_000,
                nftName: "NextVault Lot",
                nftSymbol: "NVLOT",
                metadataUri: "ipfs://lot/"
            })
        );

        assertEq(auction.initialMintLimit(smallLotId), 1);
    }

    function test_AuctionStoresBidIncrementAndUsesItForNextBid() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 0, 14 days));

        Auction.AuctionConfig memory config = auction.getAuction(lotId);

        assertEq(config.bidIncrement, 1_000 ether);
        assertEq(auction.nextValidBid(lotId), 10_000 ether);
    }

    function test_RevertWhenCallerIsNotOperator() public {
        bytes32 operatorRole = auction.OPERATOR_ROLE();

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, operatorRole)
        );
        auction.createAuction(_params(lotId, 0, 14 days));
    }

    function test_RevertWhenLotAlreadyRegistered() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 0, 14 days));

        vm.prank(operator);
        vm.expectRevert(Auction.LotAlreadyRegistered.selector);
        auction.createAuction(_params(lotId, 0, 14 days));
    }

    function test_RevertInvalidAuctionInputs() public {
        vm.startPrank(operator);

        vm.expectRevert(Auction.InvalidLotId.selector);
        auction.createAuction(_params(bytes32(0), 0, 14 days));

        vm.expectRevert(Auction.InvalidConsignor.selector);
        auction.createAuction(
            Auction.CreateAuctionParams({
                lotId: keccak256("bad-consignor"),
                consignor: address(0),
                lowEstimate: 10_000 ether,
                highEstimate: 20_000 ether,
                startingBid: 10_000 ether,
                bidIncrement: 1_000 ether,
                previewDurationSeconds: 0,
                auctionDurationSeconds: 14 days,
                nftMaxSupply: 200,
                nftPriceRatioBps: 1_000,
                nftName: "NextVault Lot",
                nftSymbol: "NVLOT",
                metadataUri: "ipfs://lot/"
            })
        );

        vm.expectRevert(Auction.InvalidEstimate.selector);
        auction.createAuction(
            Auction.CreateAuctionParams({
                lotId: keccak256("bad-estimate"),
                consignor: consignor,
                lowEstimate: 20_000 ether,
                highEstimate: 10_000 ether,
                startingBid: 20_000 ether,
                bidIncrement: 1_000 ether,
                previewDurationSeconds: 0,
                auctionDurationSeconds: 14 days,
                nftMaxSupply: 200,
                nftPriceRatioBps: 1_000,
                nftName: "NextVault Lot",
                nftSymbol: "NVLOT",
                metadataUri: "ipfs://lot/"
            })
        );

        vm.expectRevert(Auction.InvalidStartingBid.selector);
        auction.createAuction(
            Auction.CreateAuctionParams({
                lotId: keccak256("bad-starting-bid"),
                consignor: consignor,
                lowEstimate: 10_000 ether,
                highEstimate: 20_000 ether,
                startingBid: 9_000 ether,
                bidIncrement: 1_000 ether,
                previewDurationSeconds: 0,
                auctionDurationSeconds: 14 days,
                nftMaxSupply: 200,
                nftPriceRatioBps: 1_000,
                nftName: "NextVault Lot",
                nftSymbol: "NVLOT",
                metadataUri: "ipfs://lot/"
            })
        );

        vm.expectRevert(Auction.InvalidStartingBid.selector);
        auction.createAuction(
            Auction.CreateAuctionParams({
                lotId: keccak256("bad-starting-increment"),
                consignor: consignor,
                lowEstimate: 10_000 ether,
                highEstimate: 20_000 ether,
                startingBid: 10_750 ether,
                bidIncrement: 1_000 ether,
                previewDurationSeconds: 0,
                auctionDurationSeconds: 14 days,
                nftMaxSupply: 200,
                nftPriceRatioBps: 1_000,
                nftName: "NextVault Lot",
                nftSymbol: "NVLOT",
                metadataUri: "ipfs://lot/"
            })
        );

        vm.expectRevert(Auction.InvalidAuctionDuration.selector);
        auction.createAuction(_params(keccak256("bad-duration"), 0, 0));

        vm.expectRevert(Auction.InvalidNftConfig.selector);
        auction.createAuction(
            Auction.CreateAuctionParams({
                lotId: keccak256("bad-nft"),
                consignor: consignor,
                lowEstimate: 10_000 ether,
                highEstimate: 20_000 ether,
                startingBid: 10_000 ether,
                bidIncrement: 1_000 ether,
                previewDurationSeconds: 0,
                auctionDurationSeconds: 14 days,
                nftMaxSupply: 0,
                nftPriceRatioBps: 1_000,
                nftName: "NextVault Lot",
                nftSymbol: "NVLOT",
                metadataUri: "ipfs://lot/"
            })
        );

        vm.stopPrank();
    }

    function test_CancelAuction() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 0, 14 days));

        vm.prank(operator);
        auction.cancelAuction(lotId);

        assertTrue(auction.cancelledAuctions(lotId));
        assertEq(uint256(auction.currentStatus(lotId)), uint256(Auction.AuctionStatus.Cancelled));

        vm.prank(operator);
        vm.expectRevert(Auction.AuctionAlreadyCancelled.selector);
        auction.cancelAuction(lotId);
    }

    function test_BuyNFTRevertsDuringPreview() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 10 days, 14 days));

        vm.prank(alice);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        auction.buyNFT(lotId, 1);
    }

    function test_BuyNFTMintsAndCollectsUSDC() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 0, 14 days));

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        auction.buyNFT(lotId, 2);

        Auction.AuctionConfig memory config = auction.getAuction(lotId);
        LotNFT nft = LotNFT(config.nftCollection);

        assertEq(nft.balanceOf(alice), 2);
        assertEq(nft.totalMinted(), 2);
        assertEq(auction.mintedByWallet(lotId, alice), 2);
        assertEq(usdc.balanceOf(address(auction)), config.nftPrice * 2);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore - config.nftPrice * 2);
    }

    function test_BuyNFTCumulativeWalletCapAllowsSixThenFourButRejectsEleven() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 0, 14 days));

        vm.prank(alice);
        auction.buyNFT(lotId, 6);

        vm.prank(alice);
        auction.buyNFT(lotId, 4);

        assertEq(auction.mintedByWallet(lotId, alice), 10);

        vm.prank(alice);
        vm.expectRevert(Auction.MintLimitExceeded.selector);
        auction.buyNFT(lotId, 1);
    }

    function test_BuyNFTRevertsWhenTotalSupplyExceeded() public {
        bytes32 tinyLotId = keccak256("tiny");

        vm.prank(operator);
        auction.createAuction(
            Auction.CreateAuctionParams({
                lotId: tinyLotId,
                consignor: consignor,
                lowEstimate: 10_000 ether,
                highEstimate: 20_000 ether,
                startingBid: 10_000 ether,
                bidIncrement: 1_000 ether,
                previewDurationSeconds: 0,
                auctionDurationSeconds: 14 days,
                nftMaxSupply: 1,
                nftPriceRatioBps: 1_000,
                nftName: "Tiny Lot",
                nftSymbol: "TINY",
                metadataUri: "ipfs://tiny/"
            })
        );

        vm.prank(alice);
        auction.buyNFT(tinyLotId, 1);

        vm.prank(bob);
        vm.expectRevert(LotNFT.MaxSupplyReached.selector);
        auction.buyNFT(tinyLotId, 1);
    }

    function test_TransferredNFTControlsBidEligibility() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 0, 14 days));

        vm.prank(alice);
        auction.buyNFT(lotId, 1);

        address nftAddress = auction.nftCollectionOf(lotId);
        LotNFT nft = LotNFT(nftAddress);

        assertTrue(auction.isEligibleToBid(lotId, alice));
        assertFalse(auction.isEligibleToBid(lotId, bob));

        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        assertFalse(auction.isEligibleToBid(lotId, alice));
        assertTrue(auction.isEligibleToBid(lotId, bob));
    }

    function test_MultipleNFTsStillOnlyMeanEligible() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 0, 14 days));

        vm.prank(alice);
        auction.buyNFT(lotId, 2);

        address nftAddress = auction.nftCollectionOf(lotId);
        LotNFT nft = LotNFT(nftAddress);

        assertEq(nft.balanceOf(alice), 2);
        assertTrue(auction.isEligibleToBid(lotId, alice));
        assertFalse(auction.isEligibleToBid(lotId, bob));

        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.balanceOf(bob), 1);
        assertTrue(auction.isEligibleToBid(lotId, alice));
        assertTrue(auction.isEligibleToBid(lotId, bob));

        vm.prank(alice);
        nft.transferFrom(alice, bob, 2);

        assertEq(nft.balanceOf(alice), 0);
        assertEq(nft.balanceOf(bob), 2);
        assertFalse(auction.isEligibleToBid(lotId, alice));
        assertTrue(auction.isEligibleToBid(lotId, bob));
    }

    function test_BuyNFTRevertsForCancelledAuction() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 0, 14 days));

        vm.prank(operator);
        auction.cancelAuction(lotId);

        vm.prank(alice);
        vm.expectRevert(Auction.AuctionIsCancelled.selector);
        auction.buyNFT(lotId, 1);
    }

    function test_BuyNFTRevertsForZeroQuantity() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 0, 14 days));

        vm.prank(alice);
        vm.expectRevert(Auction.InvalidQuantity.selector);
        auction.buyNFT(lotId, 0);
    }

    function test_PlaceBidRevertsWhenAuctionIsNotActive() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 10 days, 14 days));

        _expectPlaceBidRevert(Auction.AuctionNotActive.selector, aliceKey, 10_000 ether);

        vm.warp(block.timestamp + 24 days);

        _expectPlaceBidRevert(Auction.AuctionNotActive.selector, aliceKey, 10_000 ether);
    }

    function test_PlaceBidRevertsWhenAuctionCancelled() public {
        _createActiveAuctionWithNfts();

        vm.prank(operator);
        auction.cancelAuction(lotId);

        _expectPlaceBidRevert(Auction.AuctionIsCancelled.selector, aliceKey, 10_000 ether);
    }

    function test_PlaceBidRequiresCurrentLotNftHolder() public {
        vm.prank(operator);
        auction.createAuction(_params(lotId, 0, 14 days));

        _expectPlaceBidRevert(Auction.NotEligibleToBid.selector, aliceKey, 10_000 ether);
    }

    function test_PlaceBidFirstBidLocksDepositAndKeepsStartingBid() public {
        _createActiveAuctionWithNfts();

        uint256 balanceBefore = usdc.balanceOf(alice);

        _placeBid(aliceKey, 10_000 ether);

        Auction.BidState memory bidState = auction.getBidState(lotId);
        Auction.BidderState memory bidderState = auction.getBidderState(lotId, alice);

        assertEq(bidState.currentBidder, alice);
        assertEq(bidState.currentBid, 10_000 ether);
        assertEq(bidState.totalBids, 1);
        assertEq(bidderState.maxBid, 10_000 ether);
        assertEq(bidderState.deposit, 1_000 ether);
        assertEq(bidderState.permitValue, 11_000 ether);
        assertTrue(bidderState.activeAutoBid);
        assertEq(usdc.allowance(alice, address(auction)), 11_000 ether);
        assertEq(usdc.balanceOf(alice), balanceBefore - 1_000 ether);
    }

    function test_PlaceBidRejectsInvalidAmounts() public {
        _createActiveAuctionWithNfts();

        _placeBid(aliceKey, 10_000 ether);

        _expectPlaceBidRevert(Auction.InvalidBidAmount.selector, bobKey, 10_000 ether);

        _expectPlaceBidRevert(Auction.InvalidBidAmount.selector, bobKey, 10_750 ether);
    }

    function test_PlaceBidRejectsPermitValueBelowRemainingBidAndPremium() public {
        _createActiveAuctionWithNfts();

        Auction.PermitData memory permit = _permit(aliceKey, 9_999 ether);

        vm.prank(alice);
        vm.expectRevert(Auction.InvalidPermitValue.selector);
        auction.placeBid(lotId, 10_000 ether, permit);
    }

    function test_PlaceBidRejectsSameOrLowerMaxBidFromSameBidder() public {
        _createActiveAuctionWithNfts();

        _placeBid(aliceKey, 12_000 ether);

        _expectPlaceBidRevert(Auction.BidNotIncreased.selector, aliceKey, 11_000 ether);

        _expectPlaceBidRevert(Auction.BidNotIncreased.selector, aliceKey, 12_000 ether);
    }

    function test_PlaceBidIncreasingOwnMaxOnlyChargesDepositDifference() public {
        _createActiveAuctionWithNfts();

        uint256 balanceBefore = usdc.balanceOf(alice);

        _placeBid(aliceKey, 12_000 ether);

        _placeBid(aliceKey, 15_000 ether);

        Auction.BidderState memory bidderState = auction.getBidderState(lotId, alice);
        assertEq(bidderState.maxBid, 15_000 ether);
        assertEq(bidderState.deposit, 1_500 ether);
        assertEq(usdc.balanceOf(alice), balanceBefore - 1_500 ether);
    }

    function test_AutoBidScenarioBPreviousMaxOutpacesNextBid() public {
        _createActiveAuctionWithNftsAt(2_000 ether);

        _placeBid(aliceKey, 3_000 ether);

        uint256 bobBalanceBefore = usdc.balanceOf(bob);

        _placeBid(bobKey, 2_200 ether);

        Auction.BidState memory bidState = auction.getBidState(lotId);
        Auction.BidderState memory bobState = auction.getBidderState(lotId, bob);

        assertEq(bidState.currentBidder, alice);
        assertEq(bidState.currentBid, 2_400 ether);
        assertEq(auction.nextValidBid(lotId), 2_600 ether);
        assertEq(bobState.deposit, 0);
        assertFalse(bobState.activeAutoBid);
        assertEq(usdc.balanceOf(bob), bobBalanceBefore);
    }

    function test_AutoBidScenarioCEqualMaxKeepsEarlierBidderPriority() public {
        _createActiveAuctionWithNftsAt(2_000 ether);

        _placeBid(aliceKey, 3_000 ether);

        uint256 bobBalanceBefore = usdc.balanceOf(bob);

        _placeBid(bobKey, 3_000 ether);

        Auction.BidState memory bidState = auction.getBidState(lotId);

        assertEq(bidState.currentBidder, alice);
        assertEq(bidState.currentBid, 3_000 ether);
        assertEq(auction.nextValidBid(lotId), 3_200 ether);
        assertEq(auction.getBidderState(lotId, bob).deposit, 0);
        assertEq(usdc.balanceOf(bob), bobBalanceBefore);
    }

    function test_AutoBidNewHigherMaxWinsOneIncrementAbovePreviousMax() public {
        _createActiveAuctionWithNftsAt(2_000 ether);

        _placeBid(aliceKey, 3_000 ether);

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        _placeBid(bobKey, 3_400 ether);

        Auction.BidState memory bidState = auction.getBidState(lotId);

        assertEq(bidState.currentBidder, bob);
        assertEq(bidState.currentBid, 3_200 ether);
        assertEq(auction.nextValidBid(lotId), 3_400 ether);
        assertEq(auction.getBidderState(lotId, alice).deposit, 0);
        assertEq(auction.getBidderState(lotId, bob).deposit, 340 ether);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + 300 ether);
    }

    function test_AntiSnipeExtendsEndTimeOnlyInsideWindow() public {
        _createActiveAuctionWithNfts();

        Auction.AuctionConfig memory beforeBid = auction.getAuction(lotId);

        _placeBid(aliceKey, 10_000 ether);

        assertEq(auction.getAuction(lotId).endTime, beforeBid.endTime);

        vm.warp(beforeBid.endTime - 2 minutes);

        _placeBid(bobKey, 11_000 ether);

        uint256 firstExtendedEndTime = beforeBid.endTime + 3 minutes;
        assertEq(auction.getAuction(lotId).endTime, firstExtendedEndTime);

        vm.warp(firstExtendedEndTime - 1 minutes);

        _placeBid(aliceKey, 12_000 ether);

        assertEq(auction.getAuction(lotId).endTime, firstExtendedEndTime + 4 minutes);
    }

    function _params(bytes32 id, uint256 previewDuration, uint256 auctionDuration)
        internal
        view
        returns (Auction.CreateAuctionParams memory)
    {
        return Auction.CreateAuctionParams({
            lotId: id,
            consignor: consignor,
            lowEstimate: 10_000 ether,
            highEstimate: 20_000 ether,
            startingBid: 10_000 ether,
            bidIncrement: 1_000 ether,
            previewDurationSeconds: previewDuration,
            auctionDurationSeconds: auctionDuration,
            nftMaxSupply: 200,
            nftPriceRatioBps: 1_000,
            nftName: "NextVault Lot",
            nftSymbol: "NVLOT",
            metadataUri: "ipfs://lot/"
        });
    }

    function _createActiveAuctionWithNfts() internal {
        _createActiveAuctionWithNftsAt(10_000 ether);
    }

    function _createActiveAuctionWithNftsAt(uint256 startingBid) internal {
        vm.prank(operator);
        auction.createAuction(
            Auction.CreateAuctionParams({
                lotId: lotId,
                consignor: consignor,
                lowEstimate: startingBid,
                highEstimate: startingBid * 2,
                startingBid: startingBid,
                bidIncrement: startingBid == 2_000 ether ? 200 ether : 1_000 ether,
                previewDurationSeconds: 0,
                auctionDurationSeconds: 14 days,
                nftMaxSupply: 200,
                nftPriceRatioBps: 1_000,
                nftName: "NextVault Lot",
                nftSymbol: "NVLOT",
                metadataUri: "ipfs://lot/"
            })
        );

        vm.prank(alice);
        auction.buyNFT(lotId, 1);

        vm.prank(bob);
        auction.buyNFT(lotId, 1);
    }

    function _placeBid(uint256 bidderKey, uint256 amount) internal {
        Auction.PermitData memory permit = _permit(bidderKey, amount + auction.buyerPremium(amount));
        vm.prank(vm.addr(bidderKey));
        auction.placeBid(lotId, amount, permit);
    }

    function _expectPlaceBidRevert(bytes4 selector, uint256 bidderKey, uint256 amount) internal {
        Auction.PermitData memory permit = _permit(bidderKey, amount + auction.buyerPremium(amount));
        vm.prank(vm.addr(bidderKey));
        vm.expectRevert(selector);
        auction.placeBid(lotId, amount, permit);
    }

    function _permit(uint256 ownerKey, uint256 value) internal view returns (Auction.PermitData memory) {
        address owner = vm.addr(ownerKey);
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                usdc.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner,
                        address(auction),
                        value,
                        usdc.nonces(owner),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        return Auction.PermitData({value: value, deadline: deadline, v: v, r: r, s: s});
    }

    function _fundAndApprove(address account, uint256 amount) internal {
        usdc.mint(account, amount);
        vm.prank(account);
        usdc.approve(address(auction), type(uint256).max);
    }
}
