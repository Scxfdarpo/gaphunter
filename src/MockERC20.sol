// SPDX-License-Identifier: MIT

pragma solidity ^0.8.29;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @notice Faucet-style mock ERC20 used for the GapHunter demo pair.
 *         Anyone can mint — this is a testnet demonstration token with no value.
 */
contract MockERC20 is ERC20 {
    uint8 private immutable customDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        customDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return customDecimals;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}
