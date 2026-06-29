// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract FakeUSDC is ERC20Permit {
    uint8 private constant USDC_DECIMALS = 6;

    constructor() ERC20("Fake USD Coin", "USDC") ERC20Permit("Fake USD Coin") {}

    function decimals() public pure override returns (uint8) {
        return USDC_DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
