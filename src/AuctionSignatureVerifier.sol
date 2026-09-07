// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice Stateless EIP-712 verifier shared by an Auction implementation.
/// @dev The Auction proxy address is supplied explicitly so signatures remain
/// bound to the proxy rather than this helper contract.
contract AuctionSignatureVerifier {
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("NextVaultAuction");
    bytes32 private constant VERSION_HASH = keccak256("1");

    function recoverSigner(bytes32 structHash, address verifyingContract, bytes calldata signature)
        external
        view
        returns (address)
    {
        bytes32 domainSeparator = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, verifyingContract)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        return ECDSA.recover(digest, signature);
    }
}
