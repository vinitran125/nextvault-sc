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
import {INFTDesignManager} from "./interfaces/INFTDesignManager.sol";

contract Auction is Initializable, AccessControlUpgradeable, EIP712Upgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant DEFAULT_BUYER_PREMIUM_BPS = 1_000;
    uint16 public constant DEFAULT_SELLER_COMMISSION_BPS = 1_000;
    string internal constant NFT_COLLECTION_NAME = "NextVault Auctions";
    string internal constant NFT_COLLECTION_SYMBOL = "NV";
    bytes32 public constant CONSIGNMENT_DEPOSIT_AUTHORIZATION_TYPEHASH = keccak256(
        "ConsignmentDepositAuthorization(bytes32 itemId,address consignor,uint256 amount,bytes32 nonce,uint256 deadline)"
    );
    bytes32 public constant CREATE_AUCTION_AUTHORIZATION_TYPEHASH = keccak256(
        "CreateAuctionAuthorization(bytes32 lotId,address consignor,uint256 lowEstimate,uint256 highEstimate,uint256 startingBid,uint256 previewDurationSeconds,uint256 auctionDurationSeconds,uint256 variant1Quantity,uint256 variant2Quantity,uint256 variant3Quantity,uint256 nftPriceRatioBps,string nftName,string nftSymbol,string thumbnailUrl,string metadataUri,bytes32 nonce,uint256 deadline)"
    );

    enum AuctionStatus {
        Preview,
        Active,
        Ended,
        Cancelled,
        Finalized
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
        uint256 nftPriceRatioBps;
        uint256 nftPrice;
        string thumbnailUrl;
    }

    struct CreateAuctionParams {
        bytes32 lotId;
        address consignor;
        uint256 lowEstimate;
        uint256 highEstimate;
        uint256 startingBid;
        uint256 previewDurationSeconds;
        uint256 auctionDurationSeconds;
        uint256 variant1Quantity;
        uint256 variant2Quantity;
        uint256 variant3Quantity;
        uint256 nftPriceRatioBps;
        string nftName;
        string nftSymbol;
        string thumbnailUrl;
        string metadataUri;
    }

    struct BidderState {
        uint256 deposit;
        bool activeMaxBid;
    }

    enum ItemDepositStatus {
        None,
        Deposited,
        Cancelled,
        Refunded
    }

    struct ConsignmentDepositAuthorization {
        bytes32 itemId;
        address consignor;
        uint256 amount;
        bytes32 nonce;
        uint256 deadline;
    }

    error InvalidToken();
    error InvalidLotId();
    error LotAlreadyRegistered();
    error InvalidConsignor();
    error InvalidEstimate();
    error InvalidStartingBid();
    error InvalidAuctionDuration();
    error InvalidNftConfig();
    error InvalidNftPriceRatio();
    error InvalidVariantAllocation();
    error AuctionNotFound();
    error AuctionAlreadyCancelled();
    error AuctionNotWithdrawn();
    error AuctionAlreadyEnded();
    error AuctionPaymentAlreadyCollected();
    error AuctionIsCancelled();
    error AuctionHasNoWinner();
    error UnauthorizedPaymentCollector();
    error AuctionNotEnded();
    error AuctionNotActive();
    error InvalidQuantity();
    error NotEligibleToBid();
    error InvalidConfig();
    error InvalidBidAmount();
    error CurrentLeaderCannotWithdrawDeposit();
    error InvalidSigner();
    error InvalidAmount();
    error InvalidNftCollection();
    error AuthorizationExpired();
    error NonceAlreadyUsed();
    error ConsignmentDepositAlreadyExists();
    error InvalidItemDepositStatus();
    error UnauthorizedConsignmentDepositCancel();
    error InvalidSettlementConfig();
    error AuctionDetailsLocked();
    error InvalidDesignManager();
    error BlacklistedWallet();

    event AuctionCreated(bytes32 indexed lotId, address indexed nftCollection, uint256 blockTimestamp);
    event AuctionDetailsUpdated(
        bytes32 indexed lotId,
        address indexed consignor,
        uint256 lowEstimate,
        uint256 highEstimate,
        string thumbnailUrl,
        uint256 blockTimestamp
    );
    event AuctionWithdrawn(bytes32 indexed lotId, address indexed highestBidder, uint256 blockTimestamp);
    event AuctionEnded(
        bytes32 indexed lotId, address indexed winner, uint256 winningBid, bool paymentCollected, uint256 blockTimestamp
    );
    event WinnerPaymentCollected(
        bytes32 indexed lotId, address indexed winner, uint256 winningBid, bool paymentCollected, uint256 blockTimestamp
    );
    event SettlementConfigUpdated(
        address indexed treasury, uint16 buyerPremiumBps, uint16 sellerCommissionBps, uint256 blockTimestamp
    );
    event AuctionSettled(
        bytes32 indexed lotId,
        address indexed winner,
        address indexed consignor,
        uint256 hammerPrice,
        uint256 buyerPremium,
        uint256 sellerCommission,
        uint256 consignorProceeds,
        uint256 platformRevenue,
        uint256 blockTimestamp
    );
    event NFTPurchased(
        bytes32 indexed lotId,
        address indexed buyer,
        uint256 quantity,
        uint256 totalPrice,
        uint256 lastTokenId,
        uint256 blockTimestamp
    );
    event NFTRefundClaimed(
        bytes32 indexed lotId, address indexed holder, uint256 quantity, uint256 refundAmount, uint256 blockTimestamp
    );
    event BidPlaced(
        bytes32 indexed lotId, address indexed bidder, uint256 previousBid, uint256 amount, uint256 blockTimestamp
    );
    event AuctionExtended(bytes32 indexed lotId, uint256 newEndTime);
    event BidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);
    event MaxBidSet(
        bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 depositAmount, uint256 blockTimestamp
    );
    event MaxBidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount, uint256 blockTimestamp);
    event LotNFTTransferred(
        bytes32 indexed lotId,
        address indexed nftCollection,
        address indexed from,
        address to,
        uint256 tokenId,
        uint256 blockTimestamp
    );
    event NFTVariantUpdated(
        bytes32 indexed lotId,
        address indexed nftCollection,
        uint256 indexed tokenId,
        uint8 variant,
        uint256 blockTimestamp
    );
    event ConsignmentDepositCreated(
        bytes32 indexed itemId, address indexed consignor, address indexed token, uint256 amount, uint256 blockTimestamp
    );
    event ConsignmentDepositCancelled(
        bytes32 indexed itemId, address indexed consignor, uint256 refundAmount, uint256 blockTimestamp
    );
    event ConsignmentDepositRefunded(
        bytes32 indexed itemId, address indexed consignor, uint256 refundAmount, bool isApproved, uint256 blockTimestamp
    );
    event WalletBlacklistUpdated(address indexed wallet, bool blacklisted, uint256 blockTimestamp);
    event AuctionRestarted(
        bytes32 indexed lotId,
        uint256 indexed previousRound,
        uint256 indexed newRound,
        address defaultedWinner,
        uint256 forfeitedDeposit,
        uint256 startTime,
        uint256 endTime,
        uint256 blockTimestamp
    );

    IERC20 public token;
    uint256 private tokenDecimal;

    mapping(bytes32 => AuctionConfig) private auctions;
    mapping(bytes32 => bool) public auctionExists;
    mapping(bytes32 => bool) public cancelledAuctions;

    mapping(bytes32 => address) private itemDepositConsignor;
    mapping(bytes32 => uint256) private itemDepositAmount;
    mapping(bytes32 => ItemDepositStatus) private itemDepositStatus;

    mapping(bytes32 => bool) public usedNonces;
    mapping(bytes32 => bool) public endedAuctions;
    mapping(bytes32 => bool) public auctionPaymentCollected;

    address public treasury;
    uint16 public buyerPremiumBps;
    uint16 public sellerCommissionBps;

    mapping(bytes32 => uint256) private itemToCurrentBid;
    mapping(bytes32 => address) private itemToCurrentBidder;
    mapping(bytes32 => bool) private itemToAutoBid;

    mapping(bytes32 => mapping(address => uint256)) private itemBidderToMaxBid;
    mapping(bytes32 => uint256) private itemToMaxBid;
    mapping(bytes32 => address) private itemToMaxBidder;
    mapping(bytes32 => uint256) public auctionBidRound;

    address public nftDesignManager;
    mapping(address => bool) public blacklistedWallets;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 token_, address admin, address designManager) external initializer {
        if (address(token_) == address(0)) revert InvalidToken();
        if (admin == address(0)) revert InvalidConfig();
        if (designManager == address(0)) revert InvalidDesignManager();
        token = token_;
        nftDesignManager = designManager;
        tokenDecimal = 10 ** IERC20Metadata(address(token_)).decimals();

        __AccessControl_init();
        __EIP712_init("NextVaultAuction", "1");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);

        treasury = admin;
        buyerPremiumBps = DEFAULT_BUYER_PREMIUM_BPS;
        sellerCommissionBps = DEFAULT_SELLER_COMMISSION_BPS;
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Upgrade authorization is handled by AccessControl.
    }

    function setSettlementConfig(address treasury_, uint16 buyerPremiumBps_, uint16 sellerCommissionBps_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (treasury_ == address(0) || buyerPremiumBps_ > BPS_DENOMINATOR || sellerCommissionBps_ > BPS_DENOMINATOR) revert InvalidSettlementConfig();

        treasury = treasury_;
        buyerPremiumBps = buyerPremiumBps_;
        sellerCommissionBps = sellerCommissionBps_;

        emit SettlementConfigUpdated(treasury_, buyerPremiumBps_, sellerCommissionBps_, block.timestamp);
    }

    function setWalletBlacklist(address wallet, bool blacklisted) external onlyRole(OPERATOR_ROLE) {
        _setWalletBlacklist(wallet, blacklisted);
    }

    function _setWalletBlacklist(address wallet, bool blacklisted) internal {
        if (wallet == address(0)) revert InvalidConfig();

        blacklistedWallets[wallet] = blacklisted;
        emit WalletBlacklistUpdated(wallet, blacklisted, block.timestamp);
    }

    function createAuction(
        CreateAuctionParams calldata params,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bytes32) {
        if (block.timestamp > deadline) revert AuthorizationExpired();
        if (usedNonces[nonce]) revert NonceAlreadyUsed();

        address signer = ECDSA.recover(_hashCreateAuctionAuthorization(params, nonce, deadline), signature);
        if (!hasRole(DEFAULT_ADMIN_ROLE, signer)) revert InvalidSigner();

        usedNonces[nonce] = true;

        if (params.lotId == bytes32(0)) revert InvalidLotId();
        if (auctionExists[params.lotId]) revert LotAlreadyRegistered();
        if (params.consignor == address(0)) revert InvalidConsignor();
        if (params.lowEstimate == 0 || params.highEstimate < params.lowEstimate) {
            revert InvalidEstimate();
        }
        if (params.startingBid == 0 || params.startingBid > params.lowEstimate) {
            revert InvalidStartingBid();
        }
        if (params.auctionDurationSeconds == 0) revert InvalidAuctionDuration();
        if (params.nftPriceRatioBps == 0) revert InvalidNftPriceRatio();

        uint256 nftMaxSupply = params.variant1Quantity + params.variant2Quantity + params.variant3Quantity;
        if (nftMaxSupply == 0) revert InvalidVariantAllocation();

        uint256 nftPrice = (params.lowEstimate * params.nftPriceRatioBps) / BPS_DENOMINATOR / nftMaxSupply;
        if (nftPrice == 0) revert InvalidNftConfig();

        uint256 startTime = block.timestamp + params.previewDurationSeconds;
        uint256 endTime = startTime + params.auctionDurationSeconds;
        address nftCollection = INFTDesignManager(nftDesignManager)
            .createLotNFT(
                NFT_COLLECTION_NAME,
                NFT_COLLECTION_SYMBOL,
                params.metadataUri,
                params.lotId,
                nftMaxSupply,
                params.variant1Quantity,
                params.variant2Quantity,
                params.variant3Quantity
            );

        auctions[params.lotId] = AuctionConfig({
            lotId: params.lotId,
            consignor: params.consignor,
            nftCollection: nftCollection,
            lowEstimate: params.lowEstimate,
            highEstimate: params.highEstimate,
            startingBid: params.startingBid,
            startTime: startTime,
            endTime: endTime,
            previewDurationSeconds: params.previewDurationSeconds,
            auctionDurationSeconds: params.auctionDurationSeconds,
            nftMaxSupply: nftMaxSupply,
            nftPriceRatioBps: params.nftPriceRatioBps,
            nftPrice: nftPrice,
            thumbnailUrl: params.thumbnailUrl
        });
        auctionExists[params.lotId] = true;

        emit AuctionCreated(params.lotId, nftCollection, block.timestamp);

        return params.lotId;
    }

    function updateAuctionDetails(
        bytes32 lotId,
        address consignor,
        uint256 lowEstimate,
        uint256 highEstimate,
        string calldata thumbnailUrl
    ) external onlyRole(OPERATOR_ROLE) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (consignor == address(0)) revert InvalidConsignor();
        if (lowEstimate == 0 || highEstimate < lowEstimate) revert InvalidEstimate();

        AuctionConfig storage auction = auctions[lotId];
        AuctionStatus status = _currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime);
        if (
            cancelledAuctions[lotId] || endedAuctions[lotId] || auctionPaymentCollected[lotId]
                || (status != AuctionStatus.Preview && status != AuctionStatus.Active)
        ) {
            revert AuctionDetailsLocked();
        }

        auction.consignor = consignor;
        auction.lowEstimate = lowEstimate;
        auction.highEstimate = highEstimate;
        auction.thumbnailUrl = thumbnailUrl;

        emit AuctionDetailsUpdated(lotId, consignor, lowEstimate, highEstimate, thumbnailUrl, block.timestamp);
    }

    function buyNFT(bytes32 lotId, uint256 quantity) external {
        if (blacklistedWallets[msg.sender]) revert BlacklistedWallet();
        if (!auctionExists[lotId]) revert AuctionNotFound();
        AuctionConfig storage auction = auctions[lotId];

        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        if (_currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime) != AuctionStatus.Active)
        {
            revert AuctionNotActive();
        }

        if (quantity == 0) revert InvalidQuantity();

        uint256 totalPrice = auction.nftPrice * quantity;
        token.safeTransferFrom(msg.sender, address(this), totalPrice);

        uint256 lastTokenId = LotNFT(auction.nftCollection).mintBatch(msg.sender, quantity);
        uint256 firstTokenId = lastTokenId - quantity + 1;
        INFTDesignManager(nftDesignManager)
            .requestVariants(lotId, msg.sender, auction.nftCollection, firstTokenId, quantity);

        emit NFTPurchased(lotId, msg.sender, quantity, totalPrice, lastTokenId, block.timestamp);
    }

    function placeBid(bytes32 lotId, uint256 amount) external {
        if (blacklistedWallets[msg.sender]) revert BlacklistedWallet();
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        AuctionConfig storage auction = auctions[lotId];
        if (_currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime) != AuctionStatus.Active)
        {
            revert AuctionNotActive();
        }
        if (LotNFT(auction.nftCollection).balanceOf(msg.sender) == 0) revert NotEligibleToBid();

        uint256 currentBid = itemToCurrentBid[lotId];
        uint256 expectedBid = currentBid == 0 ? auction.startingBid : currentBid + _bidIncrementFor(currentBid);
        if (amount != expectedBid) revert InvalidBidAmount();
        if (amount < itemToMaxBid[lotId]) revert InvalidBidAmount();

        token.safeTransferFrom(msg.sender, address(this), amount / 10);
        _refundBid(lotId);

        itemToCurrentBidder[lotId] = msg.sender;
        itemToCurrentBid[lotId] = amount;
        itemToAutoBid[lotId] = false;

        emit BidPlaced(lotId, msg.sender, currentBid, amount, block.timestamp);
        _extendAuctionIfNeeded(lotId);
    }

    function placeBidFor(bytes32 lotId, address bidder, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        AuctionConfig storage auction = auctions[lotId];
        if (_currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime) != AuctionStatus.Active)
        {
            revert AuctionNotActive();
        }
        if (LotNFT(auction.nftCollection).balanceOf(bidder) == 0) revert NotEligibleToBid();

        uint256 currentBid = _validateBidOnLadder(lotId, auction.startingBid, amount);

        if (amount > itemBidderToMaxBid[lotId][bidder]) revert InvalidBidAmount();

        _refundBid(lotId);

        itemToCurrentBidder[lotId] = bidder;
        itemToCurrentBid[lotId] = amount;
        itemToAutoBid[lotId] = true;

        uint256 previousBid = currentBid == 0 ? auction.startingBid : currentBid;

        emit BidPlaced(lotId, bidder, previousBid, amount, block.timestamp);
        _extendAuctionIfNeeded(lotId);
    }

    function setMaxBid(bytes32 lotId, uint256 amount) external {
        if (blacklistedWallets[msg.sender]) revert BlacklistedWallet();
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        AuctionConfig memory auction = auctions[lotId];
        if (_currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime) != AuctionStatus.Active)
        {
            revert AuctionNotActive();
        }
        if (LotNFT(auction.nftCollection).balanceOf(msg.sender) == 0) revert NotEligibleToBid();

        _validateBidOnLadder(lotId, auction.startingBid, amount);

        if (itemToCurrentBid[lotId] > amount) revert InvalidBidAmount();

        uint256 previousMaxBid = itemBidderToMaxBid[lotId][msg.sender];
        if (amount <= previousMaxBid) revert InvalidBidAmount();

        uint256 requiredDeposit = amount / 10;
        uint256 previousDeposit = previousMaxBid / 10;
        if (requiredDeposit > previousDeposit) {
            token.safeTransferFrom(msg.sender, address(this), requiredDeposit - previousDeposit);
        }

        itemBidderToMaxBid[lotId][msg.sender] = amount;
        if (amount > itemToMaxBid[lotId]) {
            itemToMaxBid[lotId] = amount;
            itemToMaxBidder[lotId] = msg.sender;
        }

        emit MaxBidSet(lotId, msg.sender, amount, requiredDeposit, block.timestamp);
    }

    function _refundBid(bytes32 lotId) internal {
        address currentBidder = itemToCurrentBidder[lotId];
        if (currentBidder == address(0)) return;
        if (itemToAutoBid[lotId]) return;

        uint256 refundAmount = itemToCurrentBid[lotId] / 10;

        token.safeTransfer(currentBidder, refundAmount);
        emit BidRefunded(lotId, currentBidder, refundAmount, block.timestamp);
    }

    function refundMaxBid(bytes32 lotId, address bidder) external onlyRole(OPERATOR_ROLE) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (!cancelledAuctions[lotId]) {
            if (itemToCurrentBidder[lotId] == bidder) revert CurrentLeaderCannotWithdrawDeposit();
        }

        uint256 refundAmount = itemBidderToMaxBid[lotId][bidder] / 10;
        if (refundAmount == 0) revert InvalidAmount();

        itemBidderToMaxBid[lotId][bidder] = 0;
        if (itemToMaxBidder[lotId] == bidder) {
            itemToMaxBidder[lotId] = address(0);
            itemToMaxBid[lotId] = 0;
        }
        token.safeTransfer(bidder, refundAmount);

        emit MaxBidRefunded(lotId, bidder, refundAmount, block.timestamp);
    }

    function endAuction(bytes32 lotId)
        external
        onlyRole(OPERATOR_ROLE)
        returns (address winner, uint256 winningBid, bool paymentCollected)
    {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        if (endedAuctions[lotId]) revert AuctionAlreadyEnded();
        if (block.timestamp < auctions[lotId].endTime) revert AuctionNotEnded();

        endedAuctions[lotId] = true;
        winner = itemToCurrentBidder[lotId];
        winningBid = itemToCurrentBid[lotId];
        paymentCollected = _trySettleAuctionPayment(lotId, winner, winningBid);
        auctionPaymentCollected[lotId] = paymentCollected;

        emit AuctionEnded(lotId, winner, winningBid, paymentCollected, block.timestamp);
    }

    function _trySettleAuctionPayment(bytes32 lotId, address winner, uint256 winningBid) internal returns (bool) {
        if (winner == address(0)) return false;
        if (treasury == address(0)) revert InvalidSettlementConfig();
        uint256 buyerPremium = (winningBid * buyerPremiumBps) / BPS_DENOMINATOR;
        uint256 totalPayment = winningBid + buyerPremium;
        uint256 deposited = itemToAutoBid[lotId] ? itemBidderToMaxBid[lotId][winner] / 10 : winningBid / 10;
        uint256 remainingPayment = totalPayment > deposited ? totalPayment - deposited : 0;
        uint256 excessDeposit = deposited > totalPayment ? deposited - totalPayment : 0;
        if (token.balanceOf(winner) < remainingPayment || token.allowance(winner, address(this)) < remainingPayment) {
            return false;
        }

        if (remainingPayment > 0) {
            try token.transferFrom(winner, address(this), remainingPayment) returns (bool transferred) {
                if (!transferred) return false;
            } catch {
                return false;
            }
        }
        if (excessDeposit > 0) {
            token.safeTransfer(winner, excessDeposit);
            emit MaxBidRefunded(lotId, winner, excessDeposit, block.timestamp);
        }

        AuctionConfig storage auction = auctions[lotId];
        uint256 sellerCommission = (winningBid * sellerCommissionBps) / BPS_DENOMINATOR;
        uint256 consignorProceeds = winningBid - sellerCommission;
        uint256 platformRevenue = buyerPremium + sellerCommission;

        token.safeTransfer(auction.consignor, consignorProceeds);
        token.safeTransfer(treasury, platformRevenue);

        INFTDesignManager(nftDesignManager).mintWinnerVariant(lotId, auction.nftCollection, winner);

        emit AuctionSettled(
            lotId,
            winner,
            auction.consignor,
            winningBid,
            buyerPremium,
            sellerCommission,
            consignorProceeds,
            platformRevenue,
            block.timestamp
        );
        return true;
    }

    function settleAuctionPayment(bytes32 lotId) external returns (bool paymentCollected) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (!endedAuctions[lotId]) revert AuctionNotEnded();
        if (auctionPaymentCollected[lotId]) revert AuctionPaymentAlreadyCollected();

        address winner = itemToCurrentBidder[lotId];
        if (winner == address(0)) revert AuctionHasNoWinner();
        if (msg.sender != winner && !hasRole(OPERATOR_ROLE, msg.sender)) revert UnauthorizedPaymentCollector();

        uint256 winningBid = itemToCurrentBid[lotId];
        paymentCollected = _trySettleAuctionPayment(lotId, winner, winningBid);
        auctionPaymentCollected[lotId] = paymentCollected;

        emit WinnerPaymentCollected(lotId, winner, winningBid, paymentCollected, block.timestamp);

        if (!paymentCollected && hasRole(OPERATOR_ROLE, msg.sender)) {
            _setWalletBlacklist(winner, true);
            _restartAuction(lotId, winner, winningBid);
        }
    }

    function _restartAuction(bytes32 lotId, address defaultedWinner, uint256 winningBid) internal {
        uint256 forfeitedDeposit =
            itemToAutoBid[lotId] ? itemBidderToMaxBid[lotId][defaultedWinner] / 10 : winningBid / 10;

        if (itemToAutoBid[lotId]) {
            itemBidderToMaxBid[lotId][defaultedWinner] = 0;
        }
        if (forfeitedDeposit > 0) token.safeTransfer(treasury, forfeitedDeposit);

        uint256 previousRound = auctionBidRound[lotId];
        uint256 newRound = previousRound + 1;
        AuctionConfig storage auction = auctions[lotId];

        itemToCurrentBid[lotId] = 0;
        itemToCurrentBidder[lotId] = address(0);
        itemToAutoBid[lotId] = false;
        itemToMaxBid[lotId] = 0;
        itemToMaxBidder[lotId] = address(0);
        auctionBidRound[lotId] = newRound;

        auction.startTime = block.timestamp;
        auction.endTime = block.timestamp + auction.auctionDurationSeconds;
        auction.previewDurationSeconds = 0;
        endedAuctions[lotId] = false;
        auctionPaymentCollected[lotId] = false;
        cancelledAuctions[lotId] = false;

        emit AuctionRestarted(
            lotId,
            previousRound,
            newRound,
            defaultedWinner,
            forfeitedDeposit,
            auction.startTime,
            auction.endTime,
            block.timestamp
        );
    }

    function withdrawAuction(bytes32 lotId) external onlyRole(OPERATOR_ROLE) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) revert AuctionAlreadyCancelled();

        AuctionConfig memory auction = auctions[lotId];
        if (
            endedAuctions[lotId]
                || _currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime)
                    != AuctionStatus.Active
        ) revert AuctionNotActive();

        cancelledAuctions[lotId] = true;

        emit AuctionWithdrawn(lotId, itemToCurrentBidder[lotId], block.timestamp);

        if (itemToCurrentBidder[lotId] != address(0)) {
            _refundBid(lotId);
        }
    }

    function claimNFTRefund(bytes32 lotId, uint256[] calldata tokenIds) external {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (!cancelledAuctions[lotId]) revert AuctionNotWithdrawn();

        uint256 quantity = tokenIds.length;
        if (quantity == 0) revert InvalidQuantity();

        AuctionConfig storage auction = auctions[lotId];
        LotNFT nftCollection = LotNFT(auction.nftCollection);
        nftCollection.burnBatchForRefund(msg.sender, tokenIds);

        uint256 refundAmount = auction.nftPrice * quantity;
        token.safeTransfer(msg.sender, refundAmount);

        emit NFTRefundClaimed(lotId, msg.sender, quantity, refundAmount, block.timestamp);
    }

    function getNFTRefundAmount(bytes32 lotId, address holder)
        external
        view
        returns (uint256 quantity, uint256 refundAmount)
    {
        if (!auctionExists[lotId]) revert AuctionNotFound();

        AuctionConfig storage auction = auctions[lotId];
        quantity = LotNFT(auction.nftCollection).balanceOf(holder);
        if (cancelledAuctions[lotId]) refundAmount = quantity * auction.nftPrice;
    }

    function onLotNFTTransfer(bytes32 lotId, address from, address to, uint256 tokenId) external {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (auctions[lotId].nftCollection != msg.sender) revert InvalidNftCollection();

        emit LotNFTTransferred(lotId, msg.sender, from, to, tokenId, block.timestamp);
    }

    function onLotNFTVariantAssigned(bytes32 lotId, uint256 tokenId, uint8 variant) external {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (auctions[lotId].nftCollection != msg.sender) revert InvalidNftCollection();

        emit NFTVariantUpdated(lotId, msg.sender, tokenId, variant, block.timestamp);
    }

    function depositConsignment(ConsignmentDepositAuthorization calldata authorization, bytes calldata signature)
        external
    {
        if (blacklistedWallets[msg.sender]) revert BlacklistedWallet();
        if (block.timestamp > authorization.deadline) revert AuthorizationExpired();
        if (authorization.consignor == address(0) || authorization.consignor != msg.sender) revert InvalidConsignor();
        if (authorization.amount == 0) revert InvalidAmount();
        if (usedNonces[authorization.nonce]) revert NonceAlreadyUsed();
        if (itemDepositStatus[authorization.itemId] != ItemDepositStatus.None) {
            revert ConsignmentDepositAlreadyExists();
        }

        address signer = ECDSA.recover(_hashConsignmentDepositAuthorization(authorization), signature);
        if (!hasRole(DEFAULT_ADMIN_ROLE, signer)) revert InvalidSigner();

        usedNonces[authorization.nonce] = true;
        itemDepositAmount[authorization.itemId] = authorization.amount;
        itemDepositConsignor[authorization.itemId] = msg.sender;
        itemDepositStatus[authorization.itemId] = ItemDepositStatus.Deposited;

        token.safeTransferFrom(msg.sender, address(this), authorization.amount);

        emit ConsignmentDepositCreated(
            authorization.itemId, msg.sender, address(token), authorization.amount, block.timestamp
        );
    }

    function cancelConsignmentDeposit(bytes32 itemId) external {
        if (itemDepositStatus[itemId] != ItemDepositStatus.Deposited) revert InvalidItemDepositStatus();
        if (itemDepositConsignor[itemId] != msg.sender) revert UnauthorizedConsignmentDepositCancel();

        uint256 amount = itemDepositAmount[itemId];
        itemDepositStatus[itemId] = ItemDepositStatus.Cancelled;
        token.safeTransfer(msg.sender, amount);

        emit ConsignmentDepositCancelled(itemId, msg.sender, amount, block.timestamp);
    }

    function refundConsignmentDeposit(bytes32 itemId, bool isApproved) external onlyRole(OPERATOR_ROLE) {
        if (itemDepositStatus[itemId] != ItemDepositStatus.Deposited) revert InvalidItemDepositStatus();

        address consignor = itemDepositConsignor[itemId];
        uint256 amount = itemDepositAmount[itemId];
        itemDepositStatus[itemId] = ItemDepositStatus.Refunded;
        token.safeTransfer(consignor, amount);

        emit ConsignmentDepositRefunded(itemId, consignor, amount, isApproved, block.timestamp);
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
        if (auctionPaymentCollected[lotId]) {
            return AuctionStatus.Finalized;
        }
        if (endedAuctions[lotId]) {
            return AuctionStatus.Ended;
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

    function _hashCreateAuctionAuthorization(CreateAuctionParams calldata params, bytes32 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_AUCTION_AUTHORIZATION_TYPEHASH,
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

    function _validateBidOnLadder(bytes32 lotId, uint256 startingBid, uint256 amount) internal view returns (uint256) {
        uint256 currentBid = itemToCurrentBid[lotId];
        uint256 validBid = currentBid == 0 ? startingBid : currentBid + _bidIncrementFor(currentBid);
        if (amount < validBid) revert InvalidBidAmount();

        while (validBid < amount) {
            validBid += _bidIncrementFor(validBid);
        }
        if (validBid != amount) revert InvalidBidAmount();

        return currentBid;
    }

    function _extendAuctionIfNeeded(bytes32 lotId) internal {
        if (block.timestamp + 5 minutes < auctions[lotId].endTime) return;

        uint256 newEndTime = block.timestamp + 5 minutes;
        auctions[lotId].endTime = newEndTime;
        emit AuctionExtended(lotId, newEndTime);
    }
}
