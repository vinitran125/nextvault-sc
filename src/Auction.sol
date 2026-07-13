// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LotNFT} from "./LotNFT.sol";

contract Auction is Initializable, AccessControlUpgradeable, EIP712Upgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 public constant BPS_DENOMINATOR = 10_000;
    bytes32 public constant CONSIGNMENT_DEPOSIT_AUTHORIZATION_TYPEHASH = keccak256(
        "ConsignmentDepositAuthorization(bytes32 itemId,address consignor,uint256 amount,bytes32 nonce,uint256 deadline)"
    );

    mapping(bytes32 => address) private currentBidderItem;
    mapping(bytes32 => uint256) private currentBidItem;
    mapping(bytes32 => mapping(address => uint256)) private creditMaxBidItem;
    enum AuctionStatus {
        Preview,
        Active,
        Ended,
        Cancelled
    }

    struct AuctionConfig {
        bytes32 lotId;
        address consignor;
        address nftCollection;
        uint256 lowEstimate;
        uint256 highEstimate;
        uint256 startingBid;
        uint256 startTime;
        uint256 endTime;
        uint256 previewDurationSeconds;
        uint256 auctionDurationSeconds;
        uint256 nftMaxSupply;
        uint256 designAQuantity;
        uint256 designBQuantity;
        uint256 designCQuantity;
        uint16 nftPriceRatioBps;
        uint256 nftPrice;
        string thumbnailUrl;
        string metadataUri;
    }

    struct CreateAuctionParams {
        bytes32 lotId;
        address consignor;
        uint256 lowEstimate;
        uint256 highEstimate;
        uint256 startingBid;
        uint256 previewDurationSeconds;
        uint256 auctionDurationSeconds;
        uint256 designAQuantity;
        uint256 designBQuantity;
        uint256 designCQuantity;
        uint16 nftPriceRatioBps;
        string nftName;
        string nftSymbol;
        string thumbnailUrl;
        string metadataUri;
    }

    struct PermitData {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct BidderState {
        uint256 deposit;
        bool activeMaxBid;
    }

    enum ConsignmentDepositStatus {
        None,
        Deposited,
        Cancelled
    }

    struct ConsignmentDepositAuthorization {
        bytes32 itemId;
        address consignor;
        uint256 amount;
        bytes32 nonce;
        uint256 deadline;
    }

    struct ConsignmentDepositState {
        address consignor;
        uint256 amount;
        ConsignmentDepositStatus status;
    }

    error InvalidToken();
    error InvalidLotId();
    error LotAlreadyRegistered();
    error InvalidConsignor();
    error InvalidEstimate();
    error InvalidStartingBid();
    error InvalidAuctionDuration();
    error InvalidNftConfig();
    error InvalidRarityAllocation();
    error AuctionNotFound();
    error AuctionAlreadyCancelled();
    error AuctionIsCancelled();
    error AuctionNotActive();
    error InvalidQuantity();
    error MintLimitExceeded();
    error NotEligibleToBid();
    error InvalidConfig();
    error InvalidBidAmount();
    error InvalidPermitValue();
    error InsufficientBidAllowance(address bidder, uint256 requiredDeposit, uint256 heldDeposit, uint256 allowance);
    error NoMaxBidDeposit();
    error CurrentLeaderCannotWithdrawDeposit();
    error BidModeConflict();
    error InvalidSigner();
    error InvalidAmount();
    error InvalidNftCollection();
    error InvalidBidder();
    error AuthorizationExpired();
    error NonceAlreadyUsed();
    error ConsignmentDepositAlreadyExists();
    error ConsignmentDepositNotFound();
    error ConsignmentDepositNotActive();
    error UnauthorizedConsignmentDepositCancel();

    event AuctionCreated(bytes32 indexed lotId, bytes data, uint256 blockTimestamp);
    event AuctionCancelled(bytes32 indexed lotId, uint256 blockTimestamp);
    event NFTPurchased(
        bytes32 indexed lotId,
        address indexed buyer,
        uint256 quantity,
        uint256 totalPrice,
        uint256 lastTokenId,
        uint256 blockTimestamp
    );
    event BidPlaced(bytes32 indexed lotId, address indexed bidder, uint256 bidAmount, uint256 blockTimestamp);
    event BidStep(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);
    event BidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);
    event MaxBidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);
    event LotNFTTransferred(
        bytes32 indexed lotId,
        address indexed nftCollection,
        address indexed from,
        address to,
        uint256 tokenId,
        uint256 blockTimestamp
    );
    event ConsignmentDepositCreated(
        bytes32 indexed itemId, address indexed consignor, address indexed token, uint256 amount, uint256 blockTimestamp
    );
    event ConsignmentDepositCancelled(
        bytes32 indexed itemId, address indexed consignor, uint256 refundAmount, uint256 blockTimestamp
    );

    IERC20 public token;
    uint256 private tokenDecimal;

    mapping(bytes32 => AuctionConfig) private auctions;
    mapping(bytes32 => bool) public auctionExists;
    mapping(bytes32 => bool) public cancelledAuctions;
    mapping(bytes32 => mapping(address => BidderState)) private bidderStates;
    mapping(bytes32 => ConsignmentDepositState) private consignmentDeposits;
    mapping(bytes32 => bool) public usedConsignmentDepositNonces;
    bytes32[] private lotIds;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 token_, address admin) external initializer {
        if (address(token_) == address(0)) revert InvalidToken();
        if (admin == address(0)) revert InvalidConfig();
        token = token_;
        tokenDecimal = 10 ** IERC20Metadata(address(token_)).decimals();

        __AccessControl_init();
        __EIP712_init("NextVaultAuction", "1");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Upgrade authorization is handled by AccessControl.
    }

    function createAuction(CreateAuctionParams calldata params) external onlyRole(OPERATOR_ROLE) returns (bytes32) {
        if (params.lotId == bytes32(0)) revert InvalidLotId();
        if (auctionExists[params.lotId]) revert LotAlreadyRegistered();
        if (params.consignor == address(0)) revert InvalidConsignor();
        if (params.lowEstimate == 0 || params.highEstimate < params.lowEstimate) {
            revert InvalidEstimate();
        }
        if (params.startingBid == 0 || params.startingBid < params.lowEstimate) {
            revert InvalidStartingBid();
        }
        if (params.auctionDurationSeconds == 0) revert InvalidAuctionDuration();
        if (params.nftPriceRatioBps == 0) revert InvalidNftConfig();

        uint256 nftMaxSupply = params.designAQuantity + params.designBQuantity + params.designCQuantity;
        if (nftMaxSupply == 0) revert InvalidRarityAllocation();

        uint256 nftPrice = (params.lowEstimate * params.nftPriceRatioBps) / BPS_DENOMINATOR / nftMaxSupply;
        if (nftPrice == 0) revert InvalidNftConfig();

        uint256 startTime = block.timestamp + params.previewDurationSeconds;
        uint256 endTime = startTime + params.auctionDurationSeconds;
        LotNFT nft = new LotNFT(
            params.nftName,
            params.nftSymbol,
            params.metadataUri,
            params.lotId,
            nftMaxSupply,
            params.designAQuantity,
            params.designBQuantity,
            params.designCQuantity,
            address(this)
        );

        auctions[params.lotId] = AuctionConfig({
            lotId: params.lotId,
            consignor: params.consignor,
            nftCollection: address(nft),
            lowEstimate: params.lowEstimate,
            highEstimate: params.highEstimate,
            startingBid: params.startingBid,
            startTime: startTime,
            endTime: endTime,
            previewDurationSeconds: params.previewDurationSeconds,
            auctionDurationSeconds: params.auctionDurationSeconds,
            nftMaxSupply: nftMaxSupply,
            designAQuantity: params.designAQuantity,
            designBQuantity: params.designBQuantity,
            designCQuantity: params.designCQuantity,
            nftPriceRatioBps: params.nftPriceRatioBps,
            nftPrice: nftPrice,
            thumbnailUrl: params.thumbnailUrl,
            metadataUri: params.metadataUri
        });
        auctionExists[params.lotId] = true;
        lotIds.push(params.lotId);

        emit AuctionCreated(params.lotId, abi.encode(auctions[params.lotId]), block.timestamp);

        return params.lotId;
    }

    function buyNFT(bytes32 lotId, uint256 quantity) external {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        AuctionConfig memory auction = auctions[lotId];

        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        if (_currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime) != AuctionStatus.Active)
        {
            revert AuctionNotActive();
        }

        if (quantity == 0) revert InvalidQuantity();

        uint256 totalPrice = auction.nftPrice * quantity;
        token.safeTransferFrom(msg.sender, address(this), totalPrice);

        uint256 lastTokenId = LotNFT(auction.nftCollection).mintBatch(msg.sender, quantity);

        emit NFTPurchased(lotId, msg.sender, quantity, totalPrice, lastTokenId, block.timestamp);
    }

    function placeBid(bytes32 lotId, uint256 amount) external {
        if (bidderStates[lotId][msg.sender].activeMaxBid) revert BidModeConflict();
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        AuctionConfig memory auction = auctions[lotId];
        if (_currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime) != AuctionStatus.Active)
        {
            revert AuctionNotActive();
        }
        if (LotNFT(auction.nftCollection).balanceOf(msg.sender) == 0) revert NotEligibleToBid();

        uint256 currentBid = currentBidItem[lotId];
        uint256 expectedBid = currentBid == 0 ? auction.startingBid : currentBid + _bidIncrementFor(currentBid);
        if (amount != expectedBid) revert InvalidBidAmount();

        uint256 depositAmount = amount / 10;
        token.safeTransferFrom(msg.sender, address(this), depositAmount);
        _refundBid(lotId);

        bidderStates[lotId][msg.sender].deposit = depositAmount;
        bidderStates[lotId][msg.sender].activeMaxBid = false;
        currentBidderItem[lotId] = msg.sender;
        currentBidItem[lotId] = amount;
        emit BidPlaced(lotId, msg.sender, amount, block.timestamp);
    }

    function placeBidFor(bytes32 lotId, address bidder, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        if (bidderStates[lotId][bidder].deposit > 0 && !bidderStates[lotId][bidder].activeMaxBid) {
            revert BidModeConflict();
        }

        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        AuctionConfig memory auction = auctions[lotId];
        if (_currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime) != AuctionStatus.Active)
        {
            revert AuctionNotActive();
        }
        if (LotNFT(auction.nftCollection).balanceOf(bidder) == 0) revert NotEligibleToBid();

        uint256 currentBid = currentBidItem[lotId];
        uint256 expectedBid = currentBid == 0 ? auction.startingBid : currentBid + _bidIncrementFor(currentBid);
        if (amount != expectedBid) revert InvalidBidAmount();

        uint256 depositAmount = amount / 10 - creditMaxBidItem[lotId][bidder];
        token.safeTransferFrom(bidder, address(this), depositAmount);
        _refundBid(lotId);

        bidderStates[lotId][bidder].deposit += depositAmount;
        bidderStates[lotId][bidder].activeMaxBid = true;
        currentBidderItem[lotId] = bidder;
        currentBidItem[lotId] = amount;
        creditMaxBidItem[lotId][bidder] += depositAmount;
        emit BidPlaced(lotId, bidder, amount, block.timestamp);
    }

    function _refundBid(bytes32 lotId) internal {
        address currentBidder = currentBidderItem[lotId];
        if (currentBidder == address(0)) return;

        uint256 amount = bidderStates[lotId][currentBidder].deposit;
        if (amount == 0) return;

        if (bidderStates[lotId][currentBidder].activeMaxBid) return;

        bidderStates[lotId][currentBidder].deposit = 0;
        token.safeTransfer(currentBidder, amount);
        emit BidRefunded(lotId, currentBidder, amount, block.timestamp);
    }

    function refundMaxBid(bytes32 lotId, address bidder) external onlyRole(OPERATOR_ROLE) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (currentBidderItem[lotId] == bidder) revert CurrentLeaderCannotWithdrawDeposit();

        BidderState storage bidderState = bidderStates[lotId][bidder];
        uint256 amount = creditMaxBidItem[lotId][bidder];
        if (!bidderState.activeMaxBid || amount == 0) revert NoMaxBidDeposit();
        creditMaxBidItem[lotId][bidder] = 0;
        bidderState.deposit = 0;
        bidderState.activeMaxBid = false;
        token.safeTransfer(bidder, amount);

        emit MaxBidRefunded(lotId, bidder, amount, block.timestamp);
    }

    //    function cancelAuction(bytes32 lotId) external onlyRole(OPERATOR_ROLE) {
    //        if (!auctionExists[lotId]) revert AuctionNotFound();
    //        if (cancelledAuctions[lotId]) {
    //            revert AuctionAlreadyCancelled();
    //        }
    //
    //        cancelledAuctions[lotId] = true;
    //        emit AuctionCancelled(lotId, block.timestamp);
    //    }
    //
    function onLotNFTTransfer(bytes32 lotId, address from, address to, uint256 tokenId) external {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (auctions[lotId].nftCollection != msg.sender) revert InvalidNftCollection();

        emit LotNFTTransferred(lotId, msg.sender, from, to, tokenId, block.timestamp);
    }

    function depositConsignment(ConsignmentDepositAuthorization calldata authorization, bytes calldata signature)
        external
    {
        if (block.timestamp > authorization.deadline) revert AuthorizationExpired();
        if (authorization.consignor == address(0) || authorization.consignor != msg.sender) revert InvalidConsignor();
        if (authorization.amount == 0) revert InvalidAmount();
        if (usedConsignmentDepositNonces[authorization.nonce]) revert NonceAlreadyUsed();
        if (consignmentDeposits[authorization.itemId].status != ConsignmentDepositStatus.None) {
            revert ConsignmentDepositAlreadyExists();
        }

        address signer = ECDSA.recover(_hashConsignmentDepositAuthorization(authorization), signature);
        if (!hasRole(DEFAULT_ADMIN_ROLE, signer)) revert InvalidSigner();

        usedConsignmentDepositNonces[authorization.nonce] = true;
        consignmentDeposits[authorization.itemId] = ConsignmentDepositState({
            consignor: authorization.consignor, amount: authorization.amount, status: ConsignmentDepositStatus.Deposited
        });

        token.safeTransferFrom(msg.sender, address(this), authorization.amount);

        emit ConsignmentDepositCreated(
            authorization.itemId, authorization.consignor, address(token), authorization.amount, block.timestamp
        );
    }

    function cancelConsignmentDeposit(bytes32 itemId) external {
        ConsignmentDepositState storage state = consignmentDeposits[itemId];
        if (state.status == ConsignmentDepositStatus.None) revert ConsignmentDepositNotFound();
        if (state.status != ConsignmentDepositStatus.Deposited) revert ConsignmentDepositNotActive();
        if (state.consignor != msg.sender) revert UnauthorizedConsignmentDepositCancel();

        state.status = ConsignmentDepositStatus.Cancelled;
        token.safeTransfer(state.consignor, state.amount);

        emit ConsignmentDepositCancelled(itemId, msg.sender, state.amount, block.timestamp);
    }

    function getAuction(bytes32 lotId) external view returns (AuctionConfig memory) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        return auctions[lotId];
    }

    function currentStatus(bytes32 lotId) external view returns (AuctionStatus) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) {
            return AuctionStatus.Cancelled;
        }
        return
            _currentStatus(auctions[lotId].startTime, auctions[lotId].previewDurationSeconds, auctions[lotId].endTime);
    }

    function _hashConsignmentDepositAuthorization(ConsignmentDepositAuthorization calldata authorization)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                CONSIGNMENT_DEPOSIT_AUTHORIZATION_TYPEHASH,
                authorization.itemId,
                authorization.consignor,
                authorization.amount,
                authorization.nonce,
                authorization.deadline
            )
        );

        return _hashTypedDataV4(structHash);
    }

    function _currentStatus(uint256 startTime, uint256 previewDurationSeconds, uint256 endTime)
        internal
        view
        returns (AuctionStatus)
    {
        if (previewDurationSeconds == 0 || block.timestamp >= startTime) {
            if (block.timestamp >= endTime) {
                return AuctionStatus.Ended;
            }
            return AuctionStatus.Active;
        }
        return AuctionStatus.Preview;
    }

    function _bidIncrementFor(uint256 amount) internal view returns (uint256) {
        uint256 offset;

        if (amount < 2_000 * tokenDecimal) return 100 * tokenDecimal;
        if (amount < 5_000 * tokenDecimal) {
            offset = amount % (1_000 * tokenDecimal);
            if (offset == 0) return 200 * tokenDecimal;
            if (offset == 200 * tokenDecimal) return 300 * tokenDecimal;
            if (offset == 500 * tokenDecimal) return 300 * tokenDecimal;
            return 200 * tokenDecimal;
        }
        if (amount < 10_000 * tokenDecimal) return 500 * tokenDecimal;
        if (amount < 20_000 * tokenDecimal) return 1_000 * tokenDecimal;
        if (amount < 50_000 * tokenDecimal) {
            offset = amount % (10_000 * tokenDecimal);
            if (offset == 0) return 2_000 * tokenDecimal;
            if (offset == 2_000 * tokenDecimal) return 3_000 * tokenDecimal;
            if (offset == 5_000 * tokenDecimal) return 3_000 * tokenDecimal;
            return 2_000 * tokenDecimal;
        }
        if (amount < 100_000 * tokenDecimal) return 5_000 * tokenDecimal;
        if (amount < 200_000 * tokenDecimal) return 10_000 * tokenDecimal;
        if (amount < 500_000 * tokenDecimal) {
            offset = amount % (100_000 * tokenDecimal);
            if (offset == 0) return 20_000 * tokenDecimal;
            if (offset == 20_000 * tokenDecimal) return 30_000 * tokenDecimal;
            if (offset == 50_000 * tokenDecimal) return 30_000 * tokenDecimal;
            return 20_000 * tokenDecimal;
        }
        if (amount < 1_000_000 * tokenDecimal) return 50_000 * tokenDecimal;
        if (amount < 2_000_000 * tokenDecimal) return 100_000 * tokenDecimal;
        if (amount < 5_000_000 * tokenDecimal) {
            offset = amount % (1_000_000 * tokenDecimal);
            if (offset == 0) return 200_000 * tokenDecimal;
            if (offset == 200_000 * tokenDecimal) return 300_000 * tokenDecimal;
            if (offset == 500_000 * tokenDecimal) return 300_000 * tokenDecimal;
            return 200_000 * tokenDecimal;
        }
        return 500_000 * tokenDecimal;
    }
}
