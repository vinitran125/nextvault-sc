// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {Auction} from "../src/Auction.sol";
import {LotNFT} from "../src/LotNFT.sol";
import {NFTDesignManager} from "../src/NFTDesignManager.sol";
import {IVRFCoordinatorV2Plus} from "../src/interfaces/IVRFCoordinatorV2Plus.sol";

contract UpgradeAuctionAndLotNFTScript is Script {
    bytes32 private constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    function run() public returns (Auction upgradedAuction) {
        address proxy = vm.envAddress("AUCTION_ADDRESS");
        address admin = vm.envAddress("AUCTION_ADMIN");
        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR");
        uint256 vrfSubscriptionId = vm.envUint("VRF_SUBSCRIPTION_ID");
        bytes32 vrfKeyHash = vm.envBytes32("VRF_KEY_HASH");
        uint32 vrfCallbackGasLimit = uint32(vm.envUint("VRF_CALLBACK_GAS_LIMIT"));
        uint16 vrfRequestConfirmations = uint16(vm.envUint("VRF_REQUEST_CONFIRMATIONS"));
        bool vrfNativePayment = vm.envBool("VRF_NATIVE_PAYMENT");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        LotNFT lotNFTImplementation = new LotNFT();
        NFTDesignManager designManager = new NFTDesignManager(
            deployer,
            address(lotNFTImplementation),
            vrfCoordinator,
            vrfSubscriptionId,
            vrfKeyHash,
            vrfCallbackGasLimit,
            vrfRequestConfirmations,
            vrfNativePayment
        );
        Auction auctionImplementation = new Auction();

        Auction(payable(proxy)).upgradeToAndCall(address(auctionImplementation), "");
        designManager.initializeAuction(proxy);
        Auction(proxy).setNFTDesignManager(address(designManager));
        designManager.transferOwnership(admin);

        if (vm.envOr("VRF_ADD_CONSUMER", false)) {
            IVRFCoordinatorV2Plus(vrfCoordinator).addConsumer(vrfSubscriptionId, address(designManager));
        }

        vm.stopBroadcast();

        upgradedAuction = Auction(proxy);

        console2.log("Auction proxy preserved:", proxy);
        console2.log("New Auction implementation:", address(auctionImplementation));
        console2.log("New LotNFT implementation:", address(lotNFTImplementation));
        console2.log("New NFT design manager:", address(designManager));
        console2.log("Proxy implementation slot:", _implementationOf(proxy));
    }

    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }
}
