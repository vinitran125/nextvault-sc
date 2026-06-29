// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LotNFT} from "./LotNFT.sol";

contract Auction is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 public constant BPS_DENOMINATOR = 10_000;

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
        uint256 bidIncrement;
        uint256 startTime;
        uint256 endTime;
        uint256 previewDurationSeconds;
        uint256 auctionDurationSeconds;
        uint256 nftMaxSupply;
        uint16 nftPriceRatioBps;
        uint256 nftPrice;
        string metadataUri;
    }

    struct CreateAuctionParams {
        bytes32 lotId;
        address consignor;
        uint256 lowEstimate;
        uint256 highEstimate;
        uint256 startingBid;
        uint256 bidIncrement;
        uint256 previewDurationSeconds;
        uint256 auctionDurationSeconds;
        uint256 nftMaxSupply;
        uint16 nftPriceRatioBps;
        string nftName;
        string nftSymbol;
        string metadataUri;
    }

    struct PermitData {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct BidState {
        address currentBidder;
        uint256 currentBid;
        uint256 totalBids;
    }

    struct BidderState {
        uint256 maxBid;
        uint256 deposit;
        uint256 permitValue;
        uint256 permitDeadline;
        bool activeAutoBid;
    }

    error InvalidToken();
    error InvalidLotId();
    error LotAlreadyRegistered();
    error InvalidConsignor();
    error InvalidEstimate();
    error InvalidStartingBid();
    error InvalidAuctionDuration();
    error InvalidNftConfig();
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
    error BidNotIncreased();

    event AuctionCreated(bytes32 indexed lotId, bytes data);
    event AuctionCancelled(bytes32 indexed lotId);
    event NFTPurchased(bytes32 indexed lotId, address indexed buyer, uint256 quantity, uint256 totalPrice);
    event BidPlaced(bytes32 indexed lotId, address indexed bidder, uint256 bidAmount, uint256 maxBid);
    event BidStep(bytes32 indexed lotId, address indexed bidder, uint256 amount);
    event BidRefunded(bytes32 indexed lotId, address indexed bidder, uint256 amount);
    event AuctionExtended(bytes32 indexed lotId, uint256 oldEndTime, uint256 newEndTime);

    IERC20 public usdc;
    IERC20Permit public usdcPermit;

    uint16 public buyerPremiumBps;
    uint16 public depositBps;
    uint256 public antiSnipeWindowSeconds;

    mapping(bytes32 => AuctionConfig) private auctions;
    mapping(bytes32 => BidState) private bidStates;
    mapping(bytes32 => bool) public auctionExists;
    mapping(bytes32 => bool) public cancelledAuctions;
    mapping(bytes32 => mapping(address => BidderState)) private bidderStates;
    bytes32[] private lotIds;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20Permit usdc_, address admin) external initializer {
        if (address(usdc_) == address(0)) revert InvalidToken();
        if (admin == address(0)) revert InvalidConfig();
        usdc = IERC20(address(usdc_));
        usdcPermit = usdc_;
        buyerPremiumBps = 1_000;
        depositBps = 1_000;
        antiSnipeWindowSeconds = 5 minutes;

        __AccessControl_init();
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
        if (params.bidIncrement == 0) revert InvalidStartingBid();
        if ((params.startingBid - params.lowEstimate) % params.bidIncrement != 0) revert InvalidStartingBid();
        if (params.auctionDurationSeconds == 0) revert InvalidAuctionDuration();
        if (params.nftMaxSupply == 0 || params.nftPriceRatioBps == 0) {
            revert InvalidNftConfig();
        }

        uint256 nftPrice = (params.lowEstimate * params.nftPriceRatioBps) / BPS_DENOMINATOR / params.nftMaxSupply;
        if (nftPrice == 0) revert InvalidNftConfig();

        uint256 startTime = block.timestamp + params.previewDurationSeconds;
        uint256 endTime = startTime + params.auctionDurationSeconds;
        LotNFT nft =
            new LotNFT(params.nftName, params.nftSymbol, params.metadataUri, params.nftMaxSupply, address(this));

        auctions[params.lotId] = AuctionConfig({
            lotId: params.lotId,
            consignor: params.consignor,
            nftCollection: address(nft),
            lowEstimate: params.lowEstimate,
            highEstimate: params.highEstimate,
            startingBid: params.startingBid,
            bidIncrement: params.bidIncrement,
            startTime: startTime,
            endTime: endTime,
            previewDurationSeconds: params.previewDurationSeconds,
            auctionDurationSeconds: params.auctionDurationSeconds,
            nftMaxSupply: params.nftMaxSupply,
            nftPriceRatioBps: params.nftPriceRatioBps,
            nftPrice: nftPrice,
            metadataUri: params.metadataUri
        });
        auctionExists[params.lotId] = true;
        lotIds.push(params.lotId);

        emit AuctionCreated(params.lotId, abi.encode(auctions[params.lotId]));

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
        usdc.safeTransferFrom(msg.sender, address(this), totalPrice);

        LotNFT(auction.nftCollection).mintBatch(msg.sender, quantity);

        emit NFTPurchased(lotId, msg.sender, quantity, totalPrice);
    }

    function placeBid(bytes32 lotId, uint256 bidAmount, PermitData calldata permit) external {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        AuctionConfig memory auction = auctions[lotId];

        if (cancelledAuctions[lotId]) revert AuctionIsCancelled();
        if (_currentStatus(auction.startTime, auction.previewDurationSeconds, auction.endTime) != AuctionStatus.Active)
        {
            revert AuctionNotActive();
        }

        uint256 startingBid = auction.startingBid;
        uint256 bidIncrement = auction.bidIncrement;

        if (LotNFT(auction.nftCollection).balanceOf(msg.sender) == 0) revert NotEligibleToBid();

        BidState storage state = bidStates[lotId];
        uint256 nextBid = state.currentBid == 0 ? startingBid : state.currentBid + bidIncrement;
        if (bidAmount < nextBid) revert InvalidBidAmount();
        if ((bidAmount - startingBid) % bidIncrement != 0) revert InvalidBidAmount();

        if (bidderStates[lotId][msg.sender].maxBid != 0 && bidAmount <= bidderStates[lotId][msg.sender].maxBid) {
            bidderStates[lotId][msg.sender].activeAutoBid = true;
            revert BidNotIncreased();
        }

        {
            uint256 requiredDeposit = depositRequired(bidAmount);

            if (permit.value < bidAmount - requiredDeposit + buyerPremium(bidAmount)) {
                revert InvalidPermitValue();
            }

            uint256 currentDeposit = bidderStates[lotId][msg.sender].deposit;
            if (requiredDeposit > currentDeposit) {
                uint256 additionalDeposit = requiredDeposit - currentDeposit;
                bidderStates[lotId][msg.sender].deposit = requiredDeposit;
                usdc.safeTransferFrom(msg.sender, address(this), additionalDeposit);
            }
        }

        usdcPermit.permit(msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s);
        bidderStates[lotId][msg.sender].permitValue = permit.value;
        bidderStates[lotId][msg.sender].permitDeadline = permit.deadline;
        bidderStates[lotId][msg.sender].maxBid = bidAmount;
        bidderStates[lotId][msg.sender].activeAutoBid = true;

        uint256 previousBid = state.currentBid;

        if (state.currentBidder == address(0)) {
            state.currentBidder = msg.sender;
            state.currentBid = startingBid;
            state.totalBids += 1;
            emit BidPlaced(lotId, msg.sender, startingBid, bidAmount);
        } else if (state.currentBidder == msg.sender) {
            emit BidPlaced(lotId, msg.sender, state.currentBid, bidAmount);
        } else {
            address previousLeader = state.currentBidder;
            uint256 previousMax = bidderStates[lotId][previousLeader].maxBid;

            if (bidAmount <= previousMax) {
                uint256 nextAfterIncoming = bidAmount + bidIncrement;
                state.currentBid = bidAmount == previousMax
                    ? previousMax
                    : (previousMax < nextAfterIncoming ? previousMax : nextAfterIncoming);
                _refundDeposit(lotId, msg.sender);
            } else {
                uint256 nextAfterPreviousMax = previousMax + bidIncrement;
                state.currentBid = bidAmount < nextAfterPreviousMax ? bidAmount : nextAfterPreviousMax;
                state.currentBidder = msg.sender;
                bidderStates[lotId][previousLeader].activeAutoBid = false;
                _refundDeposit(lotId, previousLeader);
            }

            state.totalBids += 1;
        }

        if (state.currentBid > previousBid) {
            uint256 step = previousBid == 0 ? state.currentBid : previousBid + bidIncrement;
            while (step < state.currentBid) {
                emit BidStep(lotId, state.currentBidder, step);
                step += bidIncrement;
            }
            emit BidStep(lotId, state.currentBidder, state.currentBid);
        }

        if (block.timestamp + antiSnipeWindowSeconds >= auction.endTime) {
            uint256 oldEndTime = auction.endTime;
            auctions[lotId].endTime = block.timestamp + antiSnipeWindowSeconds;
            emit AuctionExtended(lotId, oldEndTime, auctions[lotId].endTime);
        }
    }

    function cancelAuction(bytes32 lotId) external onlyRole(OPERATOR_ROLE) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (cancelledAuctions[lotId]) {
            revert AuctionAlreadyCancelled();
        }

        cancelledAuctions[lotId] = true;
        emit AuctionCancelled(lotId);
    }

    function setBuyerPremiumBps(uint16 buyerPremiumBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (buyerPremiumBps_ > BPS_DENOMINATOR) revert InvalidConfig();
        buyerPremiumBps = buyerPremiumBps_;
    }

    function setAntiSnipeWindowSeconds(uint256 antiSnipeWindowSeconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        antiSnipeWindowSeconds = antiSnipeWindowSeconds_;
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

    function nextValidBid(bytes32 lotId) external view returns (uint256) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        if (bidStates[lotId].currentBid == 0) return auctions[lotId].startingBid;
        return bidStates[lotId].currentBid + auctions[lotId].bidIncrement;
    }

    function isValidBidAmount(bytes32 lotId, uint256 amount) external view returns (bool) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        uint256 nextBid = bidStates[lotId].currentBid == 0
            ? auctions[lotId].startingBid
            : bidStates[lotId].currentBid + auctions[lotId].bidIncrement;
        return amount >= nextBid && (amount - auctions[lotId].startingBid) % auctions[lotId].bidIncrement == 0;
    }

    function buyerPremium(uint256 amount) public view returns (uint256) {
        return (amount * buyerPremiumBps) / BPS_DENOMINATOR;
    }

    function depositRequired(uint256 amount) public view returns (uint256) {
        return (amount * depositBps) / BPS_DENOMINATOR;
    }

    function getBidState(bytes32 lotId) external view returns (BidState memory) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        return bidStates[lotId];
    }

    function getBidderState(bytes32 lotId, address bidder) external view returns (BidderState memory) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        return bidderStates[lotId][bidder];
    }

    function initialMintLimit(bytes32 lotId) external view returns (uint256) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        return LotNFT(auctions[lotId].nftCollection).initialMintLimit();
    }

    function mintedByWallet(bytes32 lotId, address wallet) external view returns (uint256) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        return LotNFT(auctions[lotId].nftCollection).mintedByWallet(wallet);
    }

    function isEligibleToBid(bytes32 lotId, address bidder) external view returns (bool) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        return LotNFT(auctions[lotId].nftCollection).balanceOf(bidder) > 0;
    }

    function nftCollectionOf(bytes32 lotId) external view returns (address) {
        if (!auctionExists[lotId]) revert AuctionNotFound();
        return auctions[lotId].nftCollection;
    }

    function lotCount() external view returns (uint256) {
        return lotIds.length;
    }

    function lotIdAt(uint256 index) external view returns (bytes32) {
        return lotIds[index];
    }

    function _refundDeposit(bytes32 lotId, address bidder) internal {
        uint256 amount = bidderStates[lotId][bidder].deposit;
        if (amount == 0) return;
        bidderStates[lotId][bidder].deposit = 0;
        bidderStates[lotId][bidder].activeAutoBid = false;
        usdc.safeTransfer(bidder, amount);
        emit BidRefunded(lotId, bidder, amount);
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
}
