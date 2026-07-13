// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Auction} from "../src/Auction.sol";
import {FakeUSDC} from "../src/FakeUSDC.sol";

contract AuctionConsignmentDepositTest is Test {
    Auction private auction;
    FakeUSDC private token;

    uint256 private adminKey = 0xA11CE;
    address private admin = vm.addr(adminKey);
    address private consignor = makeAddr("consignor");
    address private stranger = makeAddr("stranger");

    bytes32 private constant ITEM_ID = bytes32(uint256(1));
    uint256 private constant USDC = 1e6;
    uint256 private constant DEPOSIT_AMOUNT = 100 * USDC;

    event ConsignmentDepositCreated(
        bytes32 indexed itemId, address indexed consignor, address indexed token, uint256 amount, uint256 blockTimestamp
    );
    event ConsignmentDepositCancelled(
        bytes32 indexed itemId, address indexed consignor, uint256 refundAmount, uint256 blockTimestamp
    );

    function setUp() external {
        token = new FakeUSDC();
        Auction implementation = new Auction();
        bytes memory initData = abi.encodeCall(Auction.initialize, (token, admin));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        auction = Auction(address(proxy));

        token.mint(consignor, 1_000 * USDC);
    }

    function testDepositConsignmentTransfersTokenAndStoresNonce() external {
        Auction.ConsignmentDepositAuthorization memory authorization = _authorization(ITEM_ID, consignor);
        bytes memory signature = _signAuthorization(authorization, adminKey);

        vm.prank(consignor);
        token.approve(address(auction), authorization.amount);

        vm.expectEmit(true, true, true, true, address(auction));
        emit ConsignmentDepositCreated(
            authorization.itemId, authorization.consignor, address(token), authorization.amount, block.timestamp
        );

        vm.prank(consignor);
        auction.depositConsignment(authorization, signature);

        assertTrue(auction.usedConsignmentDepositNonces(authorization.nonce));
        assertEq(token.balanceOf(address(auction)), authorization.amount);
        assertEq(token.balanceOf(consignor), 1_000 * USDC - authorization.amount);
    }

    function testCancelConsignmentDepositRefundsConsignor() external {
        Auction.ConsignmentDepositAuthorization memory authorization = _deposit(ITEM_ID, consignor);

        vm.expectEmit(true, true, false, true, address(auction));
        emit ConsignmentDepositCancelled(authorization.itemId, consignor, authorization.amount, block.timestamp);

        vm.prank(consignor);
        auction.cancelConsignmentDeposit(authorization.itemId);

        assertEq(token.balanceOf(address(auction)), 0);
        assertEq(token.balanceOf(consignor), 1_000 * USDC);
    }

    function testDepositAndCancelConsignmentDepositInSameBlock() external {
        Auction.ConsignmentDepositAuthorization memory authorization = _authorization(ITEM_ID, consignor);
        bytes memory signature = _signAuthorization(authorization, adminKey);

        vm.prank(consignor);
        token.approve(address(auction), authorization.amount);

        vm.expectEmit(true, true, true, true, address(auction));
        emit ConsignmentDepositCreated(
            authorization.itemId, authorization.consignor, address(token), authorization.amount, block.timestamp
        );

        vm.prank(consignor);
        auction.depositConsignment(authorization, signature);

        assertTrue(auction.usedConsignmentDepositNonces(authorization.nonce));
        assertEq(token.balanceOf(address(auction)), authorization.amount);
        assertEq(token.balanceOf(consignor), 1_000 * USDC - authorization.amount);

        vm.expectEmit(true, true, false, true, address(auction));
        emit ConsignmentDepositCancelled(authorization.itemId, consignor, authorization.amount, block.timestamp);

        vm.prank(consignor);
        auction.cancelConsignmentDeposit(authorization.itemId);

        assertEq(token.balanceOf(address(auction)), 0);
        assertEq(token.balanceOf(consignor), 1_000 * USDC);
    }

    function testDepositCannotBeCreatedAgainAfterCancelInSameBlock() external {
        Auction.ConsignmentDepositAuthorization memory authorization = _deposit(ITEM_ID, consignor);

        vm.prank(consignor);
        auction.cancelConsignmentDeposit(authorization.itemId);

        Auction.ConsignmentDepositAuthorization memory nextAuthorization = _authorization(ITEM_ID, consignor);
        nextAuthorization.nonce = keccak256("second nonce");
        bytes memory signature = _signAuthorization(nextAuthorization, adminKey);

        vm.prank(consignor);
        token.approve(address(auction), nextAuthorization.amount);

        vm.prank(consignor);
        vm.expectRevert(Auction.ConsignmentDepositAlreadyExists.selector);
        auction.depositConsignment(nextAuthorization, signature);
    }

    function testCancelConsignmentDepositTwiceInSameBlockReverts() external {
        Auction.ConsignmentDepositAuthorization memory authorization = _deposit(ITEM_ID, consignor);

        vm.prank(consignor);
        auction.cancelConsignmentDeposit(authorization.itemId);

        vm.prank(consignor);
        vm.expectRevert(Auction.ConsignmentDepositNotActive.selector);
        auction.cancelConsignmentDeposit(authorization.itemId);
    }

    function testCancelConsignmentDepositRevertsForUnauthorizedCaller() external {
        Auction.ConsignmentDepositAuthorization memory authorization = _deposit(ITEM_ID, consignor);

        vm.prank(stranger);
        vm.expectRevert(Auction.UnauthorizedConsignmentDepositCancel.selector);
        auction.cancelConsignmentDeposit(authorization.itemId);
    }

    function testCancelConsignmentDepositRevertsWhenMissing() external {
        vm.expectRevert(Auction.ConsignmentDepositNotFound.selector);
        auction.cancelConsignmentDeposit(ITEM_ID);
    }

    function testDepositConsignmentRevertsForExpiredAuthorization() external {
        Auction.ConsignmentDepositAuthorization memory authorization = _authorization(ITEM_ID, consignor);
        authorization.deadline = block.timestamp - 1;
        bytes memory signature = _signAuthorization(authorization, adminKey);

        vm.prank(consignor);
        vm.expectRevert(Auction.AuthorizationExpired.selector);
        auction.depositConsignment(authorization, signature);
    }

    function testDepositConsignmentRevertsForInvalidSigner() external {
        uint256 wrongKey = 0xB0B;
        Auction.ConsignmentDepositAuthorization memory authorization = _authorization(ITEM_ID, consignor);
        bytes memory signature = _signAuthorization(authorization, wrongKey);

        vm.prank(consignor);
        vm.expectRevert(Auction.InvalidSigner.selector);
        auction.depositConsignment(authorization, signature);
    }

    function testDepositConsignmentRevertsForDuplicateItem() external {
        Auction.ConsignmentDepositAuthorization memory authorization = _deposit(ITEM_ID, consignor);
        Auction.ConsignmentDepositAuthorization memory duplicate = _authorization(ITEM_ID, consignor);
        duplicate.nonce = keccak256("new nonce");
        bytes memory signature = _signAuthorization(duplicate, adminKey);

        vm.prank(consignor);
        token.approve(address(auction), duplicate.amount);

        vm.prank(consignor);
        vm.expectRevert(Auction.ConsignmentDepositAlreadyExists.selector);
        auction.depositConsignment(duplicate, signature);

        assertTrue(auction.usedConsignmentDepositNonces(authorization.nonce));
    }

    function _deposit(bytes32 itemId, address owner)
        private
        returns (Auction.ConsignmentDepositAuthorization memory authorization)
    {
        authorization = _authorization(itemId, owner);
        bytes memory signature = _signAuthorization(authorization, adminKey);

        vm.prank(owner);
        token.approve(address(auction), authorization.amount);

        vm.prank(owner);
        auction.depositConsignment(authorization, signature);
    }

    function _authorization(bytes32 itemId, address owner)
        private
        view
        returns (Auction.ConsignmentDepositAuthorization memory)
    {
        return Auction.ConsignmentDepositAuthorization({
            itemId: itemId,
            consignor: owner,
            amount: DEPOSIT_AMOUNT,
            nonce: keccak256(abi.encodePacked(itemId, owner)),
            deadline: block.timestamp + 30 minutes
        });
    }

    function _signAuthorization(Auction.ConsignmentDepositAuthorization memory authorization, uint256 signerKey)
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
