// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";

contract AuctionMaxBidTest is Test {
    Auction private auction;
    FakeUSDC private token;

    uint256 private adminKey = 0xA11CE;
    address private admin = vm.addr(adminKey);
    address private operator = makeAddr("operator");
    address private consignor = makeAddr("consignor");
    address private bidderA = makeAddr("bidderA");
    address private bidderB = makeAddr("bidderB");
    address private bidderC = makeAddr("bidderC");
    address private stranger = makeAddr("stranger");

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
    event MaxBidSet(
        bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 depositAmount, uint256 blockTimestamp
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

        token.mint(bidderA, STARTING_BALANCE);
        token.mint(bidderB, STARTING_BALANCE);
        token.mint(bidderC, STARTING_BALANCE);
        token.mint(stranger, STARTING_BALANCE);
    }

    function testSetMaxBidLocksTenPercentDepositWithoutPlacingBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        uint256 maxBid = 15_000 * USDC;
        _approveBidDeposit(bidderA, maxBid);

        vm.expectEmit(true, true, false, true, address(auction));
        emit MaxBidSet(LOT_ID, bidderA, maxBid, maxBid / 10, block.timestamp);

        vm.prank(bidderA);
        auction.setMaxBid(LOT_ID, maxBid);

        assertEq(token.balanceOf(address(auction)), NFT_PRICE + maxBid / 10);
        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE - maxBid / 10);
    }

    function testSetMaxBidTopUpOnlyPullsAdditionalDeposit() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        uint256 firstMaxBid = STARTING_BID;
        uint256 secondMaxBid = 15_000 * USDC;

        vm.prank(bidderA);
        token.approve(address(auction), secondMaxBid / 10);

        vm.prank(bidderA);
        auction.setMaxBid(LOT_ID, firstMaxBid);

        vm.prank(bidderA);
        auction.setMaxBid(LOT_ID, secondMaxBid);

        assertEq(token.allowance(bidderA, address(auction)), 0);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE + secondMaxBid / 10);
        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE - secondMaxBid / 10);
    }

    function testSetMaxBidRevertsWhenAuctionMissing() external {
        vm.prank(bidderA);
        vm.expectRevert(Auction.AuctionNotFound.selector);
        auction.setMaxBid(UNKNOWN_LOT_ID, STARTING_BID);
    }

    function testSetMaxBidRevertsWhenAuctionIsNotActive() external {
        _createPreviewAuction();

        vm.prank(bidderA);
        vm.expectRevert(Auction.AuctionNotActive.selector);
        auction.setMaxBid(LOT_ID, STARTING_BID);
    }

    function testSetMaxBidRevertsWhenBidderHasNoNft() external {
        _createActiveAuction();
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.prank(bidderA);
        vm.expectRevert(Auction.NotEligibleToBid.selector);
        auction.setMaxBid(LOT_ID, STARTING_BID);
    }

    function testSetMaxBidRevertsWhenAmountIsBelowNextBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.setMaxBid(LOT_ID, STARTING_BID - 1);
    }

    function testSetMaxBidRevertsWhenAmountIsNotOnBidLadder() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, 15_500 * USDC);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.setMaxBid(LOT_ID, 15_500 * USDC);
    }

    function testSetMaxBidRevertsWhenLoweringExistingMaxBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, 15_000 * USDC);

        vm.prank(bidderA);
        auction.setMaxBid(LOT_ID, 15_000 * USDC);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.setMaxBid(LOT_ID, STARTING_BID);
    }

    function testSetMaxBidRevertsWhenAmountEqualsExistingMaxBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, 15_000 * USDC);

        vm.prank(bidderA);
        auction.setMaxBid(LOT_ID, 15_000 * USDC);

        vm.prank(bidderA);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.setMaxBid(LOT_ID, 15_000 * USDC);
    }

    function testPlaceBidForAllowsOperatorToBidForRegisteredMaxBidder() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        uint256 maxBid = 15_000 * USDC;
        _approveBidDeposit(bidderA, maxBid);
        vm.prank(bidderA);
        auction.setMaxBid(LOT_ID, maxBid);

        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bidderA, STARTING_BID, STARTING_BID, block.timestamp);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);

        assertEq(token.balanceOf(address(auction)), NFT_PRICE + maxBid / 10);
        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE - maxBid / 10);
    }

    function testPlaceBidForCanJumpAcrossValidBidStepsWithinMaxBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, 15_000 * USDC);

        vm.prank(bidderA);
        auction.setMaxBid(LOT_ID, 15_000 * USDC);

        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bidderA, STARTING_BID, 15_000 * USDC, block.timestamp);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, 15_000 * USDC);
    }

    function testPlaceBidForRefundsPreviousManualBidder() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _approveBidDeposit(bidderA, STARTING_BID);
        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        _approveBidDeposit(bidderB, 15_000 * USDC);
        vm.prank(bidderB);
        auction.setMaxBid(LOT_ID, 15_000 * USDC);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderB, 11_000 * USDC);

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + 15_000 * USDC / 10);
    }

    function testPlaceBidForRevertsForNonOperator() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.prank(bidderA);
        auction.setMaxBid(LOT_ID, STARTING_BID);

        vm.prank(stranger);
        vm.expectRevert();
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);
    }

    function testPlaceBidForRevertsWhenBidderHasNoNft() external {
        _createActiveAuction();

        vm.prank(operator);
        vm.expectRevert(Auction.NotEligibleToBid.selector);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);
    }

    function testPlaceBidForRevertsWhenAmountExceedsRegisteredMaxBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.prank(bidderA);
        auction.setMaxBid(LOT_ID, STARTING_BID);

        vm.prank(operator);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBidFor(LOT_ID, bidderA, 11_000 * USDC);
    }

    function testPlaceBidForRevertsWhenAmountIsNotOnBidLadder() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, 16_000 * USDC);

        vm.prank(bidderA);
        auction.setMaxBid(LOT_ID, 15_000 * USDC);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);

        vm.prank(operator);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBidFor(LOT_ID, bidderA, 15_500 * USDC);
    }

    function testPlaceBidForRevertsWhenAmountIsBelowNextBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _approveBidDeposit(bidderA, STARTING_BID);
        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        _approveBidDeposit(bidderB, 11_000 * USDC);
        vm.prank(bidderB);
        auction.setMaxBid(LOT_ID, 11_000 * USDC);

        vm.prank(operator);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBidFor(LOT_ID, bidderB, STARTING_BID);
    }

    function testPlaceBidForCanMoveLeadershipBetweenMaxBidders() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _approveBidDeposit(bidderA, 15_000 * USDC);
        vm.prank(bidderA);
        auction.setMaxBid(LOT_ID, 15_000 * USDC);

        _approveBidDeposit(bidderB, 16_000 * USDC);
        vm.prank(bidderB);
        auction.setMaxBid(LOT_ID, 16_000 * USDC);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);

        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bidderB, STARTING_BID, 11_000 * USDC, block.timestamp);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderB, 11_000 * USDC);

        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + 15_000 * USDC / 10 + 16_000 * USDC / 10);
    }

    function testMixedManualThenAutoBidRefundsOnlyManualDeposit() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _placeManualBid(bidderA, STARTING_BID);
        _setMaxBid(bidderB, 15_000 * USDC);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderB, 11_000 * USDC);

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(bidderB), STARTING_BALANCE - NFT_PRICE - 1_500 * USDC);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + 1_500 * USDC);
        _assertWinnerAfterEnd(bidderB, 11_000 * USDC);
    }

    function testMixedAutoThenManualBidKeepsAutoBidDepositLocked() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _setMaxBid(bidderA, STARTING_BID);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);

        _placeManualBid(bidderB, 11_000 * USDC);

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE - 1_000 * USDC);
        assertEq(token.balanceOf(bidderB), STARTING_BALANCE - NFT_PRICE - 1_100 * USDC);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + 2_100 * USDC);
        _assertWinnerAfterEnd(bidderB, 11_000 * USDC);
    }

    function testMixedManualBidderCanConvertToMaxBidAndReceivesManualRefund() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        _placeManualBid(bidderA, STARTING_BID);
        _setMaxBid(bidderA, 15_000 * USDC);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, 15_000 * USDC);

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE - 1_500 * USDC);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE + 1_500 * USDC);
        _assertWinnerAfterEnd(bidderA, 15_000 * USDC);
    }

    function testMixedRepeatedAutoBidsBySameBidderDoNotMoveTokensAgain() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _setMaxBid(bidderA, 15_000 * USDC);

        uint256 bidderBalanceAfterMaxBid = token.balanceOf(bidderA);
        uint256 contractBalanceAfterMaxBid = token.balanceOf(address(auction));

        vm.startPrank(operator);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);
        auction.placeBidFor(LOT_ID, bidderA, 11_000 * USDC);
        auction.placeBidFor(LOT_ID, bidderA, 15_000 * USDC);
        vm.stopPrank();

        assertEq(token.balanceOf(bidderA), bidderBalanceAfterMaxBid);
        assertEq(token.balanceOf(address(auction)), contractBalanceAfterMaxBid);
        _assertWinnerAfterEnd(bidderA, 15_000 * USDC);
    }

    function testMixedThreeMaxBiddersCanAlternateLeadershipAcrossManySteps() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);
        _buyNft(bidderC, 1);

        _setMaxBid(bidderA, 15_000 * USDC);
        _setMaxBid(bidderB, 16_000 * USDC);
        _setMaxBid(bidderC, 18_000 * USDC);

        vm.startPrank(operator);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);
        auction.placeBidFor(LOT_ID, bidderB, 11_000 * USDC);
        auction.placeBidFor(LOT_ID, bidderA, 12_000 * USDC);
        auction.placeBidFor(LOT_ID, bidderC, 13_000 * USDC);
        auction.placeBidFor(LOT_ID, bidderB, 14_000 * USDC);
        auction.placeBidFor(LOT_ID, bidderA, 15_000 * USDC);
        auction.placeBidFor(LOT_ID, bidderC, 18_000 * USDC);
        vm.stopPrank();

        assertEq(
            token.balanceOf(address(auction)),
            NFT_PRICE * 3 + 15_000 * USDC / 10 + 16_000 * USDC / 10 + 18_000 * USDC / 10
        );
        _assertWinnerAfterEnd(bidderC, 18_000 * USDC);
    }

    function testMixedAutoBidCanJumpOverSeveralCompetingBidSteps() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _placeManualBid(bidderA, STARTING_BID);
        _setMaxBid(bidderB, 18_000 * USDC);

        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bidderB, STARTING_BID, 18_000 * USDC, block.timestamp);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderB, 18_000 * USDC);

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + 1_800 * USDC);
        _assertWinnerAfterEnd(bidderB, 18_000 * USDC);
    }

    function testMixedManualBidCannotPassBelowHighestRegisteredMaxBid() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);
        _setMaxBid(bidderA, 15_000 * USDC);

        uint256 bidderBalanceBefore = token.balanceOf(bidderB);
        uint256 contractBalanceBefore = token.balanceOf(address(auction));
        _approveBidDeposit(bidderB, STARTING_BID);

        vm.prank(bidderB);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBid(LOT_ID, STARTING_BID);

        assertEq(token.balanceOf(bidderB), bidderBalanceBefore);
        assertEq(token.balanceOf(address(auction)), contractBalanceBefore);
    }

    function testMixedManualBidAtNextStepStillFailsWhileHigherMaxBidIsPending() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);
        _buyNft(bidderC, 1);

        _placeManualBid(bidderA, STARTING_BID);
        _setMaxBid(bidderB, 15_000 * USDC);

        uint256 bidderBalanceBefore = token.balanceOf(bidderC);
        uint256 contractBalanceBefore = token.balanceOf(address(auction));
        _approveBidDeposit(bidderC, 11_000 * USDC);

        vm.prank(bidderC);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBid(LOT_ID, 11_000 * USDC);

        assertEq(token.balanceOf(bidderC), bidderBalanceBefore);
        assertEq(token.balanceOf(address(auction)), contractBalanceBefore);
    }

    function testMixedManualBidCanOutbidAfterAutoBidReachesRegisteredMaximum() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _setMaxBid(bidderA, 15_000 * USDC);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, 15_000 * USDC);

        _placeManualBid(bidderB, 16_000 * USDC);

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE - 1_500 * USDC);
        assertEq(token.balanceOf(bidderB), STARTING_BALANCE - NFT_PRICE - 1_600 * USDC);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE * 2 + 3_100 * USDC);
        _assertWinnerAfterEnd(bidderB, 16_000 * USDC);
    }

    function testMixedFailedAutoBidDoesNotRefundCurrentManualLeader() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _placeManualBid(bidderA, STARTING_BID);
        _setMaxBid(bidderB, 15_000 * USDC);

        uint256 bidderABalanceBefore = token.balanceOf(bidderA);
        uint256 contractBalanceBefore = token.balanceOf(address(auction));

        vm.prank(operator);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBidFor(LOT_ID, bidderB, 12_500 * USDC);

        assertEq(token.balanceOf(bidderA), bidderABalanceBefore);
        assertEq(token.balanceOf(address(auction)), contractBalanceBefore);
        _assertWinnerAfterEnd(bidderA, STARTING_BID);
    }

    function testMixedFailedManualBidDoesNotReplaceCurrentAutoLeader() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);

        _setMaxBid(bidderA, 15_000 * USDC);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, 15_000 * USDC);

        uint256 bidderBBalanceBefore = token.balanceOf(bidderB);
        uint256 contractBalanceBefore = token.balanceOf(address(auction));
        _approveBidDeposit(bidderB, 17_000 * USDC);

        vm.prank(bidderB);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBid(LOT_ID, 17_000 * USDC);

        assertEq(token.balanceOf(bidderB), bidderBBalanceBefore);
        assertEq(token.balanceOf(address(auction)), contractBalanceBefore);
        _assertWinnerAfterEnd(bidderA, 15_000 * USDC);
    }

    function testMixedPlaceBidForWithoutRegisteredMaxBidCannotUseManualAllowance() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _approveBidDeposit(bidderA, STARTING_BID);

        vm.prank(operator);
        vm.expectRevert(Auction.InvalidBidAmount.selector);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);

        assertEq(token.balanceOf(bidderA), STARTING_BALANCE - NFT_PRICE);
        assertEq(token.balanceOf(address(auction)), NFT_PRICE);
    }

    function testMixedMaxBidTopUpAfterAutoBidDoesNotChangeCurrentLeaderUntilPlaceBidFor() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);

        _setMaxBid(bidderA, 12_000 * USDC);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderA, STARTING_BID);

        vm.prank(bidderA);
        token.approve(address(auction), 600 * USDC);
        vm.prank(bidderA);
        auction.setMaxBid(LOT_ID, 18_000 * USDC);

        assertEq(token.balanceOf(address(auction)), NFT_PRICE + 1_800 * USDC);
        _assertWinnerAfterEnd(bidderA, STARTING_BID);
    }

    function testMixedManualAndAutoSequenceEmitsEveryLeaderTransition() external {
        _createActiveAuction();
        _buyNft(bidderA, 1);
        _buyNft(bidderB, 1);
        _buyNft(bidderC, 1);

        _approveBidDeposit(bidderA, STARTING_BID);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bidderA, 0, STARTING_BID, block.timestamp);
        vm.prank(bidderA);
        auction.placeBid(LOT_ID, STARTING_BID);

        _setMaxBid(bidderB, 15_000 * USDC);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bidderB, STARTING_BID, 15_000 * USDC, block.timestamp);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidderB, 15_000 * USDC);

        _approveBidDeposit(bidderC, 16_000 * USDC);
        vm.expectEmit(true, true, false, true, address(auction));
        emit BidPlaced(LOT_ID, bidderC, 15_000 * USDC, 16_000 * USDC, block.timestamp);
        vm.prank(bidderC);
        auction.placeBid(LOT_ID, 16_000 * USDC);

        _assertWinnerAfterEnd(bidderC, 16_000 * USDC);
    }

    function _placeManualBid(address bidder, uint256 amount) private {
        _approveBidDeposit(bidder, amount);
        vm.prank(bidder);
        auction.placeBid(LOT_ID, amount);
    }

    function _setMaxBid(address bidder, uint256 amount) private {
        _approveBidDeposit(bidder, amount);
        vm.prank(bidder);
        auction.setMaxBid(LOT_ID, amount);
    }

    function _assertWinnerAfterEnd(address expectedWinner, uint256 expectedWinningBid) private {
        Auction.AuctionConfig memory config = auction.getAuction(LOT_ID);
        vm.warp(config.endTime);

        vm.prank(operator);
        (address winner, uint256 winningBid, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, expectedWinner);
        assertEq(winningBid, expectedWinningBid);
        assertFalse(paymentCollected);
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        return abi.encodePacked(r, s, v);
    }
}
