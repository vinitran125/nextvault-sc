// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Script, console2} from "forge-std/Script.sol";
import {Auction} from "../src/Auction.sol";
import {LotNFT} from "../src/LotNFT.sol";
import {NFTDesignManager} from "../src/NFTDesignManager.sol";
import {IVRFCoordinatorV2Plus} from "../src/interfaces/IVRFCoordinatorV2Plus.sol";

contract AuctionScript is Script {
    function run() public returns (Auction auction) {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address admin = vm.envOr("AUCTION_ADMIN", msg.sender);
        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR");
        uint256 vrfSubscriptionId = vm.envUint("VRF_SUBSCRIPTION_ID");
        bytes32 vrfKeyHash = vm.envBytes32("VRF_KEY_HASH");
        uint32 vrfCallbackGasLimit = uint32(vm.envUint("VRF_CALLBACK_GAS_LIMIT"));
        uint16 vrfRequestConfirmations = uint16(vm.envUint("VRF_REQUEST_CONFIRMATIONS"));
        bool vrfNativePayment = vm.envBool("VRF_NATIVE_PAYMENT");
        uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        uint256 adminPrivateKey = vm.envOr("AUCTION_ADMIN_PRIVATE_KEY", uint256(0));
        address deployer = deployerPrivateKey == 0 ? msg.sender : vm.addr(deployerPrivateKey);

        if (deployerPrivateKey == 0) vm.startBroadcast();
        else vm.startBroadcast(deployerPrivateKey);
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
        Auction implementation = new Auction();
        bytes memory initData = abi.encodeCall(Auction.initialize, (IERC20(usdc), admin, address(designManager)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        designManager.initializeAuction(address(proxy));
        designManager.transferOwnership(admin);
        vm.stopBroadcast();

        if (vm.envOr("VRF_ADD_CONSUMER", false)) {
            if (adminPrivateKey == 0) vm.startBroadcast();
            else vm.startBroadcast(adminPrivateKey);
            IVRFCoordinatorV2Plus(vrfCoordinator).addConsumer(vrfSubscriptionId, address(designManager));
            vm.stopBroadcast();
        }

        auction = Auction(address(proxy));

        console2.log("Auction proxy deployed at:", address(proxy));
        console2.log("Auction implementation deployed at:", address(implementation));
        console2.log("LotNFT implementation deployed at:", address(lotNFTImplementation));
        console2.log("USDC token:", usdc);
        console2.log("Admin:", admin);
        console2.log("VRF coordinator:", vrfCoordinator);
        console2.log("VRF subscription ID:", vrfSubscriptionId);
        console2.log("NFT design manager:", address(designManager));
    }
}
