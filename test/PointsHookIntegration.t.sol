
 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PointsHook} from "../src/PointsHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {
    SwapParams,
    ModifyLiquidityParams
} from "v4-core/types/PoolOperation.sol";

import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";

contract PointsHookIntegrationTest is Test, ERC1155TokenReceiver {
    IPoolManager manager;
    PointsHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;

    MockERC20 token;
    PoolKey key;

    address constant MANAGER_ADDRESS =
        0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0;

    address constant HOOK_ADDRESS =
        0xBbFFc254033968f257fBe4b58A9211d665420040;

    function setUp() public {
        // Connect to the already-deployed contracts on the fork.
        manager = IPoolManager(MANAGER_ADDRESS);
        hook = PointsHook(HOOK_ADDRESS);

        require(
            MANAGER_ADDRESS.code.length > 0,
            "PoolManager not deployed"
        );
        require(HOOK_ADDRESS.code.length > 0, "Hook not deployed");

        // Routers use the existing PoolManager.
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        // Create a fresh token for this isolated test.
        token = new MockERC20("Integration Token", "ITEST", 18);
        token.mint(address(this), 1000 ether);

        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });

        // Initialize a 1:1 ETH/token pool.
        manager.initialize(key, uint160(1 << 96));

        // Add liquidity across a range around the initial price.
        modifyLiquidityRouter.modifyLiquidity{value: 0.1 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(1 ether),
                salt: bytes32(0)
            }),
            bytes("")
        );
    }

    function test_deployedHookAwardsPointsAfterSwap() public {
        uint256 poolId = uint256(PoolId.unwrap(key.toId()));

        uint256 balanceBefore = hook.balanceOf(address(this), poolId);
        uint256 countBefore = hook.swapCount(key.toId(), address(this));

        // The hook uses this address to identify the points recipient.
        bytes memory hookData = abi.encode(address(this));

        swapRouter.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 balanceAfter = hook.balanceOf(address(this), poolId);
        uint256 countAfter = hook.swapCount(key.toId(), address(this));

        assertEq(
            countAfter,
            countBefore + 1,
            "Swap count did not increase"
        );

        assertEq(
            balanceAfter - balanceBefore,
            0.001 ether * 20 / 100,
            "Expected 20 percent loyalty points"
        );
    }

    receive() external payable {}
}
