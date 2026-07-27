// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IAuctionLotNFTHook {
    function onLotNFTTransfer(bytes32 lotId, address from, address to, uint256 tokenId) external;
    function onLotNFTDesignAssigned(bytes32 lotId, uint256 tokenId, uint8 design) external;
}

contract LotNFT is Initializable, ERC721Upgradeable {
    enum Design {
        Pending,
        A,
        B,
        C,
        D
    }

    error OnlyAuction();
    error MaxSupplyReached();
    error MintLimitExceeded();
    error InvalidRarityAllocation();
    error DesignAlreadyAssigned();
    error WinnerDesignAlreadyMinted();

    address public auction;
    address public designManager;
    bytes32 public lotId;
    uint256 public maxSupply;
    uint256 public designAQuantity;
    uint256 public designBQuantity;
    uint256 public designCQuantity;
    string private baseTokenURI;
    uint256 private nextTokenId;
    uint256 public designARemaining;
    uint256 public designBRemaining;
    uint256 public designCRemaining;
    bool public winnerDesignMinted;

    mapping(address => uint256) public mintedByWallet;
    mapping(uint256 => Design) public designOf;

    event DesignAssigned(uint256 indexed tokenId, Design design);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes one ERC721 clone for an auction lot.
    /// @param name_ Collection name shown by wallets and marketplaces.
    /// @param symbol_ Collection symbol shown by wallets and marketplaces.
    /// @param baseTokenURI_ Base URI used to build each tokenURI.
    /// @param lotId_ Auction lot ID that owns this collection.
    /// @param maxSupply_ Maximum NFTs that can ever be minted for this lot.
    /// @param designAQuantity_ Number of Design A NFTs allocated for this lot.
    /// @param designBQuantity_ Number of Design B NFTs allocated for this lot.
    /// @param designCQuantity_ Number of Design C NFTs allocated for this lot.
    /// @param auction_ Auction contract allowed to mint NFTs.
    /// @param designManager_ Contract allowed to assign random designs and mint Design D.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata baseTokenURI_,
        bytes32 lotId_,
        uint256 maxSupply_,
        uint256 designAQuantity_,
        uint256 designBQuantity_,
        uint256 designCQuantity_,
        address auction_,
        address designManager_
    ) external initializer {
        if (designAQuantity_ + designBQuantity_ + designCQuantity_ != maxSupply_) {
            revert InvalidRarityAllocation();
        }

        __ERC721_init(name_, symbol_);
        auction = auction_;
        designManager = designManager_;
        lotId = lotId_;
        baseTokenURI = baseTokenURI_;
        maxSupply = maxSupply_;
        designAQuantity = designAQuantity_;
        designBQuantity = designBQuantity_;
        designCQuantity = designCQuantity_;
        designARemaining = designAQuantity_;
        designBRemaining = designBQuantity_;
        designCRemaining = designCQuantity_;
        nextTokenId = 1;
    }

    /// @notice Mints one NFT to a buyer during the initial sale.
    /// @dev Only the Auction contract can call this and the per-wallet mint cap is enforced here.
    function mint(address to) external returns (uint256 tokenId) {
        if (msg.sender != auction) revert OnlyAuction();
        _checkMintLimit(to, 1);
        mintedByWallet[to] += 1;
        tokenId = _mintNext(to);
    }

    /// @notice Mints multiple NFTs to a buyer during the initial sale.
    /// @dev Only the Auction contract can call this; secondary transfers are not limited by this cap.
    function mintBatch(address to, uint256 quantity) external returns (uint256 lastTokenId) {
        if (msg.sender != auction) revert OnlyAuction();
        _checkMintLimit(to, quantity);
        mintedByWallet[to] += quantity;
        for (uint256 i = 0; i < quantity; i++) {
            lastTokenId = _mintNext(to);
        }
    }

    /// @notice Assigns an A, B, or C design to a previously minted pending NFT.
    /// @dev Draws from the remaining rarity pool, so every assignment consumes exactly one configured slot.
    function assignRandomDesign(uint256 tokenId, uint256 randomWord) external returns (Design design) {
        if (msg.sender != designManager) revert OnlyAuction();
        _requireOwned(tokenId);
        if (designOf[tokenId] != Design.Pending) revert DesignAlreadyAssigned();

        uint256 remaining = designARemaining + designBRemaining + designCRemaining;
        uint256 draw = randomWord % remaining;

        if (draw < designARemaining) {
            design = Design.A;
            designARemaining--;
        } else if (draw < designARemaining + designBRemaining) {
            design = Design.B;
            designBRemaining--;
        } else {
            design = Design.C;
            designCRemaining--;
        }

        designOf[tokenId] = design;
        emit DesignAssigned(tokenId, design);
        IAuctionLotNFTHook(auction).onLotNFTDesignAssigned(lotId, tokenId, uint8(design));
    }

    /// @notice Mints the one-of-one Design D NFT to the settled auction winner.
    /// @dev Design D is outside maxSupply and can only be minted once.
    function mintWinnerDesign(address winner) external returns (uint256 tokenId) {
        if (msg.sender != designManager) revert OnlyAuction();
        if (winnerDesignMinted) revert WinnerDesignAlreadyMinted();

        winnerDesignMinted = true;
        tokenId = maxSupply + 1;
        designOf[tokenId] = Design.D;
        _mint(winner, tokenId);

        emit DesignAssigned(tokenId, Design.D);
        IAuctionLotNFTHook(auction).onLotNFTDesignAssigned(lotId, tokenId, uint8(Design.D));
    }

    /// @notice Returns the maximum number of NFTs one wallet can mint during initial sale.
    /// @dev The cap is 5% of maxSupply, with a minimum of 1 NFT for small supplies.
    function initialMintLimit() public view returns (uint256) {
        uint256 cap = maxSupply / 20;
        return cap == 0 ? 1 : cap;
    }

    /// @dev Reverts if `to` would exceed the cumulative initial mint cap.
    function _checkMintLimit(address to, uint256 quantity) internal view {
        if (mintedByWallet[to] + quantity > initialMintLimit()) {
            revert MintLimitExceeded();
        }
    }

    /// @dev Mints the next sequential token ID and enforces maxSupply.
    function _mintNext(address to) internal returns (uint256 tokenId) {
        if (nextTokenId > maxSupply) revert MaxSupplyReached();
        tokenId = nextTokenId;
        nextTokenId++;
        _safeMint(to, tokenId);
    }

    /// @notice Returns the total number of NFTs minted so far.
    function totalMinted() external view returns (uint256) {
        return nextTokenId - 1;
    }

    /// @notice Returns the metadata URI for a token.
    /// @dev The URI is built as baseTokenURI + tokenId.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (bytes(baseTokenURI).length == 0) return "";
        return string.concat(baseTokenURI, Strings.toString(tokenId));
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        IAuctionLotNFTHook(auction).onLotNFTTransfer(lotId, from, to, tokenId);
    }
}
