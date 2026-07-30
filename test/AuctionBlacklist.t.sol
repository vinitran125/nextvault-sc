// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";
import {LotNFT} from "../src/LotNFT.sol";
import {NFTDesignManager} from "../src/NFTDesignManager.sol";
import {MockVRFCoordinator} from "./mocks/MockVRFCoordinator.sol";

contract AuctionBlacklistTest is Test {
    Auction private auction;
    FakeUSDC private token;

    uint256 private constant ADMIN_KEY = 0xA11CE;
    uint256 private constant BIDDER_KEY = 0xB1DD3;
    address private admin = vm.addr(ADMIN_KEY);
    address private operator = makeAddr("operator");
    address private bidder = vm.addr(BIDDER_KEY);
    address private consignor = makeAddr("consignor");

    bytes32 private constant LOT_ID = bytes32(uint256(1));
    bytes32 private constant ITEM_ID = bytes32(uint256(2));
    uint256 private constant USDC = 1e6;
    uint256 private constant STARTING_BID = 10_000 * USDC;
    uint256 private constant NFT_PRICE = 10 * USDC;
    uint256 private constant STARTING_BALANCE = 100_000 * USDC;

    event WalletBlacklistUpdated(address indexed wallet, bool blacklisted, uint256 blockTimestamp);

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

        token.mint(bidder, STARTING_BALANCE);
    }

    function testOperatorCanBlacklistAndUnblacklistWallet() external {
        vm.expectEmit(true, false, false, true, address(auction));
        emit WalletBlacklistUpdated(bidder, true, block.timestamp);
        vm.prank(operator);
        auction.setWalletBlacklist(bidder, true);
        assertTrue(auction.blacklistedWallets(bidder));

        vm.prank(operator);
        auction.setWalletBlacklist(bidder, false);
        assertFalse(auction.blacklistedWallets(bidder));
    }

    function testNonOperatorCannotManageBlacklist() external {
        bytes32 operatorRole = auction.OPERATOR_ROLE();
        vm.prank(bidder);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bidder, operatorRole)
        );
        auction.setWalletBlacklist(bidder, true);
    }

    function testBlacklistedWalletCannotBuyNft() external {
        _createActiveAuction();
        _blacklist(bidder);

        vm.prank(bidder);
        token.approve(address(auction), NFT_PRICE);
        vm.prank(bidder);
        vm.expectRevert(Auction.BlacklistedWallet.selector);
        auction.buyNFT(LOT_ID, 1);
    }

    function testBlacklistedWalletCannotPlaceManualBid() external {
        _createActiveAuction();
        _buyNft();
        _blacklist(bidder);

        vm.prank(bidder);
        token.approve(address(auction), STARTING_BID / 10);
        vm.prank(bidder);
        vm.expectRevert(Auction.BlacklistedWallet.selector);
        auction.placeBid(LOT_ID, STARTING_BID);
    }

    function testBlacklistedWalletCannotSetMaxBid() external {
        _createActiveAuction();
        _buyNft();
        _blacklist(bidder);

        vm.prank(bidder);
        token.approve(address(auction), STARTING_BID / 10);
        vm.prank(bidder);
        vm.expectRevert(Auction.BlacklistedWallet.selector);
        auction.setMaxBid(LOT_ID, STARTING_BID);
    }

    function testBlacklistedWalletCannotDepositNewConsignment() external {
        Auction.ConsignmentDepositAuthorization memory authorization = _depositAuthorization();
        bytes memory signature = _signDepositAuthorization(authorization);
        _blacklist(bidder);

        vm.prank(bidder);
        token.approve(address(auction), authorization.amount);
        vm.prank(bidder);
        vm.expectRevert(Auction.BlacklistedWallet.selector);
        auction.depositConsignment(authorization, signature);
    }

    function testExistingMaxBidContinuesAfterWalletIsBlacklisted() external {
        _createActiveAuction();
        _buyNft();

        vm.prank(bidder);
        token.approve(address(auction), STARTING_BID / 10);
        vm.prank(bidder);
        auction.setMaxBid(LOT_ID, STARTING_BID);
        _blacklist(bidder);

        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidder, STARTING_BID);

        vm.warp(auction.getAuction(LOT_ID).endTime);
        vm.prank(operator);
        (address winner, uint256 winningBid,) = auction.endAuction(LOT_ID);
        assertEq(winner, bidder);
        assertEq(winningBid, STARTING_BID);
    }

    function testBlacklistedWinnerCanStillCompleteExistingSettlement() external {
        _createActiveAuction();
        _buyNft();

        vm.prank(bidder);
        token.approve(address(auction), STARTING_BID / 10);
        vm.prank(bidder);
        auction.setMaxBid(LOT_ID, STARTING_BID);
        vm.prank(operator);
        auction.placeBidFor(LOT_ID, bidder, STARTING_BID);
        _blacklist(bidder);

        vm.prank(bidder);
        token.approve(address(auction), STARTING_BID);
        vm.warp(auction.getAuction(LOT_ID).endTime);
        vm.prank(operator);
        (address winner,, bool paymentCollected) = auction.endAuction(LOT_ID);

        assertEq(winner, bidder);
        assertTrue(paymentCollected);
        assertTrue(auction.auctionPaymentCollected(LOT_ID));
    }

    function testBlacklistedWalletCanCancelExistingConsignmentDeposit() external {
        Auction.ConsignmentDepositAuthorization memory authorization = _depositAuthorization();
        bytes memory signature = _signDepositAuthorization(authorization);

        vm.prank(bidder);
        token.approve(address(auction), authorization.amount);
        vm.prank(bidder);
        auction.depositConsignment(authorization, signature);
        _blacklist(bidder);

        uint256 balanceBeforeCancel = token.balanceOf(bidder);
        vm.prank(bidder);
        auction.cancelConsignmentDeposit(ITEM_ID);
        assertEq(token.balanceOf(bidder), balanceBeforeCancel + authorization.amount);
    }

    function _blacklist(address wallet) private {
        vm.prank(operator);
        auction.setWalletBlacklist(wallet, true);
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
            nftName: "ignored",
            nftSymbol: "ignored",
            thumbnailUrl: "ipfs://thumbnail",
            metadataUri: "ipfs://metadata/"
        });
        bytes32 nonce = keccak256("create-auction");
        uint256 deadline = block.timestamp + 1 hours;
        auction.createAuction(params, nonce, deadline, _signCreateAuction(params, nonce, deadline));
    }

    function _buyNft() private {
        vm.prank(bidder);
        token.approve(address(auction), NFT_PRICE);
        vm.prank(bidder);
        auction.buyNFT(LOT_ID, 1);
    }

    function _depositAuthorization()
        private
        view
        returns (Auction.ConsignmentDepositAuthorization memory authorization)
    {
        authorization = Auction.ConsignmentDepositAuthorization({
            itemId: ITEM_ID,
            consignor: bidder,
            amount: 100 * USDC,
            nonce: keccak256("deposit-consignment"),
            deadline: block.timestamp + 1 hours
        });
    }

    function _signDepositAuthorization(Auction.ConsignmentDepositAuthorization memory authorization)
        private
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                auction.CONSIGNMENT_DEPOSIT_AUTHORIZATION_TYPEHASH(),
                authorization.itemId,
                authorization.consignor,
                authorization.amount,
                authorization.nonce,
                authorization.deadline
            )
        );
        return _signTypedData(structHash);
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
        return _signTypedData(structHash);
    }

    function _signTypedData(bytes32 structHash) private view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NextVaultAuction"),
                keccak256("1"),
                block.chainid,
                address(auction)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ADMIN_KEY, digest);
        return abi.encodePacked(r, s, v);
    }
}
