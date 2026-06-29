// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract LotNFT is ERC721 {
    error OnlyAuction();
    error MaxSupplyReached();
    error MintLimitExceeded();

    address public immutable auction;
    uint256 public immutable maxSupply;
    string private baseTokenURI;
    uint256 private nextTokenId = 1;

    mapping(address => uint256) public mintedByWallet;

    /// @notice Creates the ERC721 collection for one auction lot.
    /// @param name_ Collection name shown by wallets and marketplaces.
    /// @param symbol_ Collection symbol shown by wallets and marketplaces.
    /// @param baseTokenURI_ Base URI used to build each tokenURI.
    /// @param maxSupply_ Maximum NFTs that can ever be minted for this lot.
    /// @param auction_ Auction contract allowed to mint NFTs.
    constructor(
        string memory name_,
        string memory symbol_,
        string memory baseTokenURI_,
        uint256 maxSupply_,
        address auction_
    ) ERC721(name_, symbol_) {
        auction = auction_;
        baseTokenURI = baseTokenURI_;
        maxSupply = maxSupply_;
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
    function mintBatch(address to, uint256 quantity) external {
        if (msg.sender != auction) revert OnlyAuction();
        _checkMintLimit(to, quantity);
        mintedByWallet[to] += quantity;
        for (uint256 i = 0; i < quantity; i++) {
            _mintNext(to);
        }
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
}
