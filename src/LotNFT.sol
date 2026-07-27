// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IAuctionLotNFTHook {
    function onLotNFTTransfer(bytes32 lotId, address from, address to, uint256 tokenId) external;
    function onLotNFTVariantAssigned(bytes32 lotId, uint256 tokenId, uint8 variant) external;
}

contract LotNFT is Initializable, ERC721Upgradeable {
    uint8 public constant VARIANT_1 = 1;
    uint8 public constant VARIANT_2 = 2;
    uint8 public constant VARIANT_3 = 3;
    uint8 public constant VARIANT_4 = 4;

    error OnlyAuction();
    error MaxSupplyReached();
    error MintLimitExceeded();
    error InvalidVariantAllocation();
    error VariantAlreadyAssigned();
    error WinnerVariantAlreadyMinted();

    address public auction;
    address public designManager;
    bytes32 public lotId;
    uint256 public maxSupply;
    uint256 public variant1Quantity;
    uint256 public variant2Quantity;
    uint256 public variant3Quantity;
    string private baseTokenURI;
    uint256 private nextTokenId;
    uint256 public variant1Remaining;
    uint256 public variant2Remaining;
    uint256 public variant3Remaining;
    bool public winnerVariantMinted;

    mapping(address => uint256) public mintedByWallet;
    mapping(uint256 => uint8) public variantOf;

    event VariantAssigned(uint256 indexed tokenId, uint8 variant);

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
    /// @param variant1Quantity_ Number of variant 1 NFTs allocated for this lot.
    /// @param variant2Quantity_ Number of variant 2 NFTs allocated for this lot.
    /// @param variant3Quantity_ Number of variant 3 NFTs allocated for this lot.
    /// @param auction_ Auction contract allowed to mint NFTs.
    /// @param designManager_ Contract allowed to assign random variants and mint variant 4.
    function initialize(
        string calldata name_,
        string calldata symbol_,
        string calldata baseTokenURI_,
        bytes32 lotId_,
        uint256 maxSupply_,
        uint256 variant1Quantity_,
        uint256 variant2Quantity_,
        uint256 variant3Quantity_,
        address auction_,
        address designManager_
    ) external initializer {
        if (variant1Quantity_ + variant2Quantity_ + variant3Quantity_ != maxSupply_) {
            revert InvalidVariantAllocation();
        }

        __ERC721_init(name_, symbol_);
        auction = auction_;
        designManager = designManager_;
        lotId = lotId_;
        baseTokenURI = baseTokenURI_;
        maxSupply = maxSupply_;
        variant1Quantity = variant1Quantity_;
        variant2Quantity = variant2Quantity_;
        variant3Quantity = variant3Quantity_;
        variant1Remaining = variant1Quantity_;
        variant2Remaining = variant2Quantity_;
        variant3Remaining = variant3Quantity_;
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

    /// @notice Assigns variant 1, 2, or 3 to a previously minted pending NFT.
    /// @dev Draws from the remaining rarity pool, so every assignment consumes exactly one configured slot.
    function assignRandomVariant(uint256 tokenId, uint256 randomWord) external returns (uint8 variant) {
        if (msg.sender != designManager) revert OnlyAuction();
        _requireOwned(tokenId);
        if (variantOf[tokenId] != 0) revert VariantAlreadyAssigned();

        uint256 remaining = variant1Remaining + variant2Remaining + variant3Remaining;
        uint256 draw = randomWord % remaining;

        if (draw < variant1Remaining) {
            variant = VARIANT_1;
            variant1Remaining--;
        } else if (draw < variant1Remaining + variant2Remaining) {
            variant = VARIANT_2;
            variant2Remaining--;
        } else {
            variant = VARIANT_3;
            variant3Remaining--;
        }

        variantOf[tokenId] = variant;
        emit VariantAssigned(tokenId, variant);
        IAuctionLotNFTHook(auction).onLotNFTVariantAssigned(lotId, tokenId, variant);
    }

    /// @notice Mints the one-of-one variant 4 NFT to the settled auction winner.
    /// @dev Variant 4 is outside maxSupply and can only be minted once.
    function mintWinnerVariant(address winner) external returns (uint256 tokenId) {
        if (msg.sender != designManager) revert OnlyAuction();
        if (winnerVariantMinted) revert WinnerVariantAlreadyMinted();

        winnerVariantMinted = true;
        tokenId = maxSupply + 1;
        variantOf[tokenId] = VARIANT_4;
        _mint(winner, tokenId);

        emit VariantAssigned(tokenId, VARIANT_4);
        IAuctionLotNFTHook(auction).onLotNFTVariantAssigned(lotId, tokenId, VARIANT_4);
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
    /// @dev Builds the token URI from the base URI and token ID, regardless of variant assignment.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return string.concat(baseTokenURI, Strings.toString(tokenId));
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        IAuctionLotNFTHook(auction).onLotNFTTransfer(lotId, from, to, tokenId);
    }
}
