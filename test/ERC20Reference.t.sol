// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IERC20} from "@openzeppelin-contracts/interfaces/IERC20.sol";
import {ERC20} from "@solady-v0.0.245/tokens/ERC20.sol";

import {Relayer} from "../src/test/Relayer.sol";
import {ERC20Reference} from "../src/experiment/ERC20Reference.sol";
import {ICreate2Deployer} from "../src/interfaces/ICreate2Deployer.sol";
import {PreinstallAddresses} from "../src/libraries/PreinstallAddresses.sol";

import {TestERC20} from "./TestERC20.sol";

contract ERC20ReferenceTest is StdUtils, Test, Relayer {
    ICreate2Deployer public deployer = ICreate2Deployer(PreinstallAddresses.CREATE2_DEPLOYER);

    bytes32 public salt = bytes32(0);
    address public spender = address(0x1);

    ERC20 public erc20;
    ERC20Reference public remoteERC20;

    uint256 public chainA;
    uint256 public chainB;

    // Run against supersim locally so forking is fast
    string[] public rpcUrls = ["http://127.0.0.1:9545", "http://127.0.0.1:9546"];

    constructor() Relayer(rpcUrls) {
        chainA = forkIds[0];
        chainB = forkIds[1];
    }

    function setUp() public virtual {
        // ERC20 only exists on A
        vm.selectFork(chainA);
        erc20 = new TestERC20();

        // Remotely controlled on B
        bytes memory args = abi.encode(chainIdByForkId[chainA], address(erc20), chainIdByForkId[chainB]);
        bytes memory remoteERC20CreationCode = abi.encodePacked(type(ERC20Reference).creationCode, args);
        remoteERC20 = ERC20Reference(deployer.computeAddress(salt, keccak256(remoteERC20CreationCode)));

        // Deploy Remote on A
        deployer.deploy(0, salt, remoteERC20CreationCode);

        // Deploy Remote on B
        vm.selectFork(chainB);
        deployer.deploy(0, salt, remoteERC20CreationCode);
    }

    function test_approve() public {
        vm.assume(spender != address(this));

        vm.selectFork(chainA);
        vm.assume(erc20.balanceOf(address(this)) == 0);

        deal(address(erc20), address(this), 1e18);
        assertEq(erc20.balanceOf(address(this)), 1e18);

        // Approve
        vm.startPrank(address(this));
        erc20.approve(address(remoteERC20), 1e18);
        remoteERC20.approve(spender, 1e18);
        assertEq(erc20.balanceOf(address(this)), 0);

        // Check local allowance
        relayAllMessages();
        vm.selectFork(chainB);
        assertEq(remoteERC20.balanceOf(address(this)), 1e18);
        assertEq(remoteERC20.balanceOf(spender), 0);
        assertEq(remoteERC20.allowance(address(this), spender), 1e18);

        vm.stopPrank();
    }

    function test_transferFrom() public {
        vm.assume(spender != address(this));

        test_approve();

        vm.selectFork(chainB);

        // Claim approval
        vm.startPrank(spender);
        remoteERC20.transferFrom(address(this), spender, 1e18);
        vm.stopPrank();

        assertEq(remoteERC20.balanceOf(address(this)), 0);
        assertEq(remoteERC20.balanceOf(spender), 1e18);
        assertEq(remoteERC20.allowance(address(this), spender), 0);
    }

    function test_transfer() public {
        test_transferFrom();

        vm.selectFork(chainB);

        // Transfer back to the holder (remote tokens burned)
        vm.startPrank(spender);
        remoteERC20.transfer(address(this), 1e18);
        assertEq(remoteERC20.balanceOf(spender), 0);
        assertEq(remoteERC20.balanceOf(address(this)), 0);
        vm.stopPrank();

        // Tokens only transferred on the home chain.
        relayAllMessages();
        vm.selectFork(chainA);
        assertEq(erc20.balanceOf(address(this)), 1e18);
    }
}
