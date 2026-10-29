// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";

import "forge-std/console.sol";
import {PointsHook} from "../src/PointsHook.sol";

contract TestPointsHook is Test, Deployers, ERC1155TokenReceiver {
    MockERC20 token;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    PointsHook hook;

    function setUp() public {
        // Step 1 + 2
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy our TOKEN contract
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);

        // Deploy hook to an address that has the proper flags set
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG);
        deployCodeTo("PointsHook.sol", abi.encode(manager), address(flags));

        // Deploy our hook
        hook = PointsHook(address(flags));

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool
        (key, ) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = TOKEN
            hook, // Hook Contract
            3000, // Swap Fees
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );

        // Add some liquidity to the pool
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

        uint256 ethToAdd = 0.1 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            SQRT_PRICE_1_1,
            sqrtPriceAtTickUpper,
            ethToAdd
        );

        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: int256(uint256(liquidityDelta)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_swap() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        uint256 pointsBalanceOriginal = hook.balanceOf(
            address(this),
            poolIdUint
        );

        // Set user address in hook data
        bytes memory hookData = abi.encode(address(this));

        // Now we swap
        // We will swap 0.001 ether for tokens
        // We should get 20% of 0.001 * 10**18 points
        // = 2 * 10**14
        swapRouter.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // Exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );
        uint256 pointsBalanceAfterSwap = hook.balanceOf(
            address(this),
            poolIdUint
        );
        assertEq(pointsBalanceAfterSwap - pointsBalanceOriginal, 2 * 10 ** 14);
    }

    function test_loyaltyBonus() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));
        PoolId poolId = key.toId();

        bytes memory hookData = abi.encode(address(this));

        uint256 swapAmount = 0.001 ether;

        // ---------------------------------
        // SWAP 1 -> 20%
        // ---------------------------------

        uint256 balanceBefore = hook.balanceOf(address(this), poolIdUint);

        swapRouter.swap{value: swapAmount}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 balanceAfter = hook.balanceOf(address(this), poolIdUint);

        assertEq(
            balanceAfter - balanceBefore,
            (swapAmount * 20) / 100,
            "First swap should award 20%"
        );

        assertEq(
            hook.swapCount(poolId, address(this)),
            1,
            "Swap count should be 1"
        );

        // ---------------------------------
        // SWAP 2 -> 25%
        // ---------------------------------

        balanceBefore = balanceAfter;

        swapRouter.swap{value: swapAmount}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        balanceAfter = hook.balanceOf(address(this), poolIdUint);

        assertEq(
            balanceAfter - balanceBefore,
            (swapAmount * 25) / 100,
            "Second swap should award 25%"
        );

        assertEq(
            hook.swapCount(poolId, address(this)),
            2,
            "Swap count should be 2"
        );

        // ---------------------------------
        // SWAP 3 -> 30%
        // ---------------------------------

        balanceBefore = balanceAfter;

        swapRouter.swap{value: swapAmount}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        balanceAfter = hook.balanceOf(address(this), poolIdUint);

        assertEq(
            balanceAfter - balanceBefore,
            (swapAmount * 30) / 100,
            "Third swap should award 30%"
        );

        assertEq(
            hook.swapCount(poolId, address(this)),
            3,
            "Swap count should be 3"
        );

        // ---------------------------------
        // SWAP 4 -> 35%
        // ---------------------------------

        balanceBefore = balanceAfter;

        swapRouter.swap{value: swapAmount}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        balanceAfter = hook.balanceOf(address(this), poolIdUint);

        assertEq(
            balanceAfter - balanceBefore,
            (swapAmount * 35) / 100,
            "Fourth swap should award 35%"
        );

        assertEq(
            hook.swapCount(poolId, address(this)),
            4,
            "Swap count should be 4"
        );
    }

    function test_noPointsForReverseSwap() public {
        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));

        uint256 balanceBefore = hook.balanceOf(
            address(this),
            poolIdUint
        );

        // Swap TOKEN for ETH, not ETH for TOKEN
        bytes memory hookData = abi.encode(address(this));

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(0.001 ether),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 balanceAfter = hook.balanceOf(
            address(this),
            poolIdUint
        );

        assertEq(balanceAfter, balanceBefore);
        assertEq(hook.swapCount(key.toId(), address(this)), 0);
    }

    function testFuzz_invalidRecipientGetsNoPoints(
        uint256 swapAmount
    ) public {
        swapAmount = bound(
            swapAmount,
            0.00001 ether,
            0.0001 ether
        );

        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));

        uint256 balanceBefore = hook.balanceOf(
            address(this),
            poolIdUint
        );

        // Zero address is not a valid recipient
        bytes memory hookData = abi.encode(address(0));

        swapRouter.swap{value: swapAmount}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            hookData
        );

        uint256 balanceAfter = hook.balanceOf(
            address(this),
            poolIdUint
        );

        assertEq(balanceAfter, balanceBefore);
        assertEq(hook.swapCount(key.toId(), address(0)), 0);
    }

    function testFuzz_missingHookDataGetsNoPoints(
        uint256 swapAmount
    ) public {
        vm.assume(
            swapAmount >= 0.00001 ether &&
            swapAmount <= 0.0001 ether
        );

        uint256 poolIdUint = uint256(PoolId.unwrap(key.toId()));

        uint256 balanceBefore = hook.balanceOf(
            address(this),
            poolIdUint
        );

        swapRouter.swap{value: swapAmount}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ""
        );

        uint256 balanceAfter = hook.balanceOf(
            address(this),
            poolIdUint
        );

        assertEq(balanceAfter, balanceBefore);
        assertEq(hook.swapCount(key.toId(), address(this)), 0);
    }
}
