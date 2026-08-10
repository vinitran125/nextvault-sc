// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface INFTDesignManager {
    function auction() external view returns (address);

    function createLotNFT(
        string calldata name,
        string calldata symbol,
        string calldata baseTokenURI,
        bytes32 lotId,
        uint256 maxSupply,
        uint256 variant1Quantity,
        uint256 variant2Quantity,
        uint256 variant3Quantity
    ) external returns (address nftCollection);

    function requestVariants(
        bytes32 lotId,
        address buyer,
        address nftCollection,
        uint256 firstTokenId,
        uint256 quantity
    ) external returns (uint256 requestId);

    function mintWinnerVariant(bytes32 lotId, address nftCollection, address winner) external returns (uint256 tokenId);
}
