// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@solady-v0.0.245/tokens/ERC20.sol";

contract TestERC20 is ERC20 {
    function name() public pure override returns (string memory) {
        return "TestERC20";
    }

    function symbol() public pure override returns (string memory) {
        return "TEST";
    }
}
