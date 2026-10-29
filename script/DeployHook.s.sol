
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {PointsHook} from "../src/PointsHook.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

contract DeployHook is Script {
    address constant CREATE2_DEPLOYER =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);

        // Deploy a fresh PoolManager on the local blockchain.
        PoolManager manager = new PoolManager(deployer);

        vm.stopBroadcast();

        // Find a valid address for our AFTER_SWAP hook.
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(manager))
        );

        (address expectedAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(PointsHook).creationCode,
            constructorArgs
        );

        console2.log("PoolManager:", address(manager));
        console2.log("Expected hook:", expectedAddress);

        vm.startBroadcast(privateKey);

        // Foundry uses the CREATE2 deployer for salted creation.
        PointsHook hook = new PointsHook{salt: salt}(
            IPoolManager(address(manager))
        );

        require(
            address(hook) == expectedAddress,
            "Hook address mismatch"
        );

        vm.stopBroadcast();

        console2.log("Deployed hook:", address(hook));
    }
}
