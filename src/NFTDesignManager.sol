// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LotNFT} from "./LotNFT.sol";
import {IVRFCoordinatorV2Plus, VRFV2PlusClient} from "./interfaces/IVRFCoordinatorV2Plus.sol";

contract NFTDesignManager is Ownable {
    using Clones for address;

    struct DesignRequest {
        bytes32 lotId;
        address buyer;
        address nftCollection;
        uint256 firstTokenId;
        uint256 quantity;
        bool fulfilled;
    }

    error OnlyAuction();
    error InvalidConfig();
    error AlreadyInitialized();
    error OnlyVRFCoordinator();
    error InvalidDesignRequest();

    event VRFConfigUpdated(
        address indexed coordinator,
        uint256 indexed subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bool nativePayment
    );
    event NFTDesignRandomnessRequested(
        bytes32 indexed lotId,
        address indexed buyer,
        uint256 indexed requestId,
        address nftCollection,
        uint256 firstTokenId,
        uint256 quantity
    );
    event NFTDesignAssigned(
        bytes32 indexed lotId, uint256 indexed requestId, uint256 indexed tokenId, LotNFT.Design design
    );
    event WinnerDesignMinted(bytes32 indexed lotId, address indexed winner, uint256 indexed tokenId);
    event LotNFTCreated(bytes32 indexed lotId, address indexed nftCollection);
    event AuctionInitialized(address indexed auction);

    address public auction;
    address public immutable lotNFTImplementation;
    address public vrfCoordinator;
    uint256 public vrfSubscriptionId;
    bytes32 public vrfKeyHash;
    uint32 public vrfCallbackGasLimit;
    uint16 public vrfRequestConfirmations;
    bool public vrfNativePayment;

    mapping(uint256 => DesignRequest) private designRequests;

    constructor(
        address admin,
        address lotNFTImplementation_,
        address coordinator,
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bool nativePayment
    ) Ownable(admin) {
        if (lotNFTImplementation_ == address(0)) revert InvalidConfig();
        lotNFTImplementation = lotNFTImplementation_;
        _setVRFConfig(coordinator, subscriptionId, keyHash, callbackGasLimit, requestConfirmations, nativePayment);
    }

    function initializeAuction(address auction_) external onlyOwner {
        if (auction_ == address(0)) revert InvalidConfig();
        if (auction != address(0)) revert AlreadyInitialized();
        auction = auction_;
        emit AuctionInitialized(auction_);
    }

    function setVRFConfig(
        address coordinator,
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bool nativePayment
    ) external onlyOwner {
        _setVRFConfig(coordinator, subscriptionId, keyHash, callbackGasLimit, requestConfirmations, nativePayment);
    }

    function requestDesigns(bytes32 lotId, address buyer, address nftCollection, uint256 firstTokenId, uint256 quantity)
        external
        returns (uint256 requestId)
    {
        if (msg.sender != auction) revert OnlyAuction();

        requestId = IVRFCoordinatorV2Plus(vrfCoordinator)
            .requestRandomWords(
                VRFV2PlusClient.RandomWordsRequest({
                    keyHash: vrfKeyHash,
                    subId: vrfSubscriptionId,
                    requestConfirmations: vrfRequestConfirmations,
                    callbackGasLimit: vrfCallbackGasLimit,
                    numWords: 1,
                    extraArgs: VRFV2PlusClient.argsToBytes(
                        VRFV2PlusClient.ExtraArgsV1({nativePayment: vrfNativePayment})
                    )
                })
            );
        designRequests[requestId] = DesignRequest({
            lotId: lotId,
            buyer: buyer,
            nftCollection: nftCollection,
            firstTokenId: firstTokenId,
            quantity: quantity,
            fulfilled: false
        });

        emit NFTDesignRandomnessRequested(lotId, buyer, requestId, nftCollection, firstTokenId, quantity);
    }

    function createLotNFT(
        string calldata name,
        string calldata symbol,
        string calldata baseTokenURI,
        bytes32 lotId,
        uint256 maxSupply,
        uint256 designAQuantity,
        uint256 designBQuantity,
        uint256 designCQuantity
    ) external returns (address nftCollection) {
        if (msg.sender != auction) revert OnlyAuction();

        nftCollection = lotNFTImplementation.clone();
        LotNFT(nftCollection)
            .initialize(
                name,
                symbol,
                baseTokenURI,
                lotId,
                maxSupply,
                designAQuantity,
                designBQuantity,
                designCQuantity,
                auction,
                address(this)
            );
        emit LotNFTCreated(lotId, nftCollection);
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != vrfCoordinator) revert OnlyVRFCoordinator();

        DesignRequest storage request = designRequests[requestId];
        if (request.quantity == 0 || request.fulfilled || randomWords.length == 0) revert InvalidDesignRequest();
        request.fulfilled = true;

        LotNFT nft = LotNFT(request.nftCollection);
        for (uint256 i = 0; i < request.quantity; i++) {
            uint256 tokenId = request.firstTokenId + i;
            uint256 randomWord = uint256(keccak256(abi.encode(randomWords[0], requestId, i)));
            LotNFT.Design design = nft.assignRandomDesign(tokenId, randomWord);
            emit NFTDesignAssigned(request.lotId, requestId, tokenId, design);
        }
    }

    function mintWinnerDesign(bytes32 lotId, address nftCollection, address winner) external returns (uint256 tokenId) {
        if (msg.sender != auction) revert OnlyAuction();
        tokenId = LotNFT(nftCollection).mintWinnerDesign(winner);
        emit WinnerDesignMinted(lotId, winner, tokenId);
    }

    function getDesignRequest(uint256 requestId) external view returns (DesignRequest memory) {
        return designRequests[requestId];
    }

    function _setVRFConfig(
        address coordinator,
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bool nativePayment
    ) private {
        if (
            coordinator == address(0) || subscriptionId == 0 || keyHash == bytes32(0) || callbackGasLimit == 0
                || requestConfirmations == 0
        ) {
            revert InvalidConfig();
        }

        vrfCoordinator = coordinator;
        vrfSubscriptionId = subscriptionId;
        vrfKeyHash = keyHash;
        vrfCallbackGasLimit = callbackGasLimit;
        vrfRequestConfirmations = requestConfirmations;
        vrfNativePayment = nativePayment;

        emit VRFConfigUpdated(
            coordinator, subscriptionId, keyHash, callbackGasLimit, requestConfirmations, nativePayment
        );
    }
}
