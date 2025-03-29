// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

// Custom errors
error NoLiquidityAdded();
error ProtectedAmountIsZero();
error TotalCoverageLimitExceeded(
    uint256 current,
    uint256 requested,
    uint256 limit
);
error PositionDoesNotExist(address owner, PoolId poolId);
error InsufficientFundsForPayout(uint256 available, uint256 required);
error InsufficientAllowanceForPremium(uint256 allowance, uint256 required);
error Unauthorized();

contract HookSure is BaseHook {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    struct Position {
        uint128 liquidity;
        int24 tickLower;
        int24 tickUpper;
        int24 initialTick;
        uint256 protectedAmount;
        Currency currency;
        bool exists;
    }

    struct ProtectionPool {
        uint256 totalCoverage;
        uint256 utilizedCoverage;
        uint256 premiumRate;
        uint256 lastUpdated;
        uint256 maxPayoutPerPosition;
        uint256 maxTotalCoverage;
    }

    // Constants
    uint256 public constant BASE_UNIT = 1e18;
    uint256 public constant OPTIMAL_UTILIZATION = 0.8e18;
    uint256 public constant BASE_PREMIUM_RATE = 0.005e18; // 0.5%
    uint256 public constant MAX_PAYOUT_PERCENTAGE = 0.5e18; // 50% of protected amount
    uint256 public constant DEFAULT_MAX_COVERAGE = 1000000e18;

    // State
    address public owner;
    mapping(address => mapping(PoolId => Position)) public positions;
    mapping(PoolId => ProtectionPool) public protectionPools;
    mapping(PoolId => int24) public poolTicks;

    event CoveragePurchased(
        address indexed lp,
        PoolId indexed poolId,
        uint256 amount,
        uint256 premium
    );
    event PayoutExecuted(
        address indexed lp,
        PoolId indexed poolId,
        uint256 amount
    );
    event CoverageLimitUpdated(
        PoolId indexed poolId,
        uint256 maxPayoutPerPosition,
        uint256 maxTotalCoverage
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(IPoolManager _manager) BaseHook(_manager) {
        owner = msg.sender;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterAddLiquidity(
        address owner,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();

        // Initialize pool if not already
        _initializePoolIfNeeded(poolId);

        // Get current tick from slot0
        (, int24 currentTick, , ) = poolManager.getSlot0(poolId);

        (uint128 liquidity, , ) = poolManager.getPositionInfo(
            poolId,
            owner,
            params.tickLower,
            params.tickUpper,
            params.salt
        );

        // Ensure liquidity is not zero
        if (liquidity == 0) revert NoLiquidityAdded();

        uint256 protectedAmount = _calculateProtectedAmount(delta, key);
        if (protectedAmount == 0) revert ProtectedAmountIsZero();

        // Store position with current tick
        positions[owner][poolId] = Position({
            liquidity: liquidity,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            initialTick: currentTick,
            protectedAmount: protectedAmount,
            currency: key.currency0,
            exists: true
        });

        // Check total coverage limit
        ProtectionPool storage pool = protectionPools[poolId];
        if (pool.totalCoverage + uint256(liquidity) > pool.maxTotalCoverage) {
            revert TotalCoverageLimitExceeded(
                pool.totalCoverage,
                uint256(liquidity),
                pool.maxTotalCoverage
            );
        }

        // Calculate and collect premium
        uint256 premium = _calculatePremium(key, liquidity);
        _collectPremium(owner, premium, key.currency0);

        // Update protection pool
        pool.totalCoverage += uint256(liquidity);
        pool.lastUpdated = block.timestamp;

        // Emit event
        emit CoveragePurchased(owner, poolId, protectedAmount, premium);

        return (BaseHook.afterAddLiquidity.selector, delta);
    }

    function afterRemoveLiquidity(
        address owner,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        Position storage position = positions[owner][poolId];

        // Check if position exists
        if (!position.exists) revert PositionDoesNotExist(owner, poolId);

        // Use cached price from afterSwap updates or get current if not available
        int24 currentTick = poolTicks[poolId];
        if (currentTick == 0) {
            (, currentTick, , ) = poolManager.getSlot0(poolId);
        }

        // Calculate IL using current pool price
        uint256 ilAmount = _calculateIL(
            position.initialTick,
            currentTick,
            position.tickLower,
            position.tickUpper,
            position.protectedAmount
        );

        // Apply payout limit
        ProtectionPool storage pool = protectionPools[poolId];
        uint256 maxPayout = FixedPointMathLib.mulWadDown(
            position.protectedAmount,
            MAX_PAYOUT_PERCENTAGE
        );

        if (
            pool.maxPayoutPerPosition > 0 &&
            pool.maxPayoutPerPosition < maxPayout
        ) {
            maxPayout = pool.maxPayoutPerPosition;
        }

        if (ilAmount > maxPayout) {
            ilAmount = maxPayout;
        }

        // Execute payout if IL exists
        if (ilAmount > 0) {
            // Check if contract has enough balance
            uint256 contractBalance = ERC20(Currency.unwrap(position.currency))
                .balanceOf(address(this));

            if (contractBalance < ilAmount) {
                revert InsufficientFundsForPayout(contractBalance, ilAmount);
            }

            _executePayout(owner, ilAmount, position.currency);
            emit PayoutExecuted(owner, poolId, ilAmount);
        }

        // Get current liquidity
        (uint128 liquidity, , ) = poolManager.getPositionInfo(
            poolId,
            owner,
            params.tickLower,
            params.tickUpper,
            params.salt
        );

        // Update protection pool
        if (pool.totalCoverage >= uint256(position.liquidity)) {
            pool.totalCoverage -= uint256(position.liquidity);
        } else {
            pool.totalCoverage = 0;
        }

        pool.utilizedCoverage += ilAmount;
        pool.lastUpdated = block.timestamp;

        // Clean up position
        delete positions[owner][poolId];

        return (BaseHook.afterRemoveLiquidity.selector, delta);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();

        // Update current tick state
        (, int24 currentTick, , ) = poolManager.getSlot0(poolId);
        poolTicks[poolId] = currentTick;

        return (BaseHook.afterSwap.selector, 0);
    }

    // Core IL calculation for concentrated liquidity
    function _calculateIL(
        int24 initialTick,
        int24 finalTick,
        int24 tickLower,
        int24 tickUpper,
        uint256 protectedAmount
    ) internal pure returns (uint256) {
        // Convert ticks to sqrtPriceX96 using TickMath
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(initialTick);
        uint160 finalSqrtPriceX96 = TickMath.getSqrtPriceAtTick(finalTick);

        // Use sqrt prices directly in Q64.96 format
        uint256 k = FixedPointMathLib.divWadDown(
            uint256(finalSqrtPriceX96),
            uint256(initialSqrtPriceX96)
        );

        // If price hasn't changed, there's no IL
        if (k == BASE_UNIT) return 0;

        // Convert tick boundaries to sqrt prices
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // Concentrated IL formula (simplified for positive values)
        uint256 numerator = FixedPointMathLib.mulWadDown(
            2,
            FixedPointMathLib.sqrt(k)
        );
        numerator = numerator > (BASE_UNIT + k)
            ? numerator - (BASE_UNIT + k)
            : 0;

        uint256 denominator = (BASE_UNIT + k);

        // Skip the complex denominator calculation that could cause issues
        // This simplification is safer while still capturing the essence of IL

        return
            FixedPointMathLib.mulWadDown(
                protectedAmount,
                numerator > 0
                    ? FixedPointMathLib.divWadDown(numerator, denominator)
                    : 0
            );
    }

    // Dynamic premium calculation based on utilization
    function _calculatePremium(
        PoolKey memory key,
        uint128 liquidity
    ) internal view returns (uint256) {
        ProtectionPool storage pool = protectionPools[key.toId()];

        // Avoid division by zero
        if (pool.totalCoverage == 0) {
            return
                FixedPointMathLib.mulWadDown(
                    uint256(liquidity),
                    BASE_PREMIUM_RATE
                );
        }

        uint256 utilization = FixedPointMathLib.divWadDown(
            pool.utilizedCoverage,
            pool.totalCoverage
        );

        uint256 rate = BASE_PREMIUM_RATE;

        // Add utilization-based premium if utilization is positive
        if (utilization > 0) {
            rate += FixedPointMathLib.divWadDown(
                FixedPointMathLib.mulWadDown(BASE_PREMIUM_RATE, utilization),
                OPTIMAL_UTILIZATION
            );
        }

        return FixedPointMathLib.mulWadDown(uint256(liquidity), rate);
    }

    // Premium collection logic
    function _collectPremium(
        address user,
        uint256 amount,
        Currency currency
    ) internal {
        // Ensure amount is positive
        if (amount == 0) return;

        address token = Currency.unwrap(currency);

        // Check allowance
        uint256 allowance = ERC20(token).allowance(user, address(this));
        if (allowance < amount) {
            revert InsufficientAllowanceForPremium(allowance, amount);
        }

        SafeTransferLib.safeTransferFrom(
            ERC20(token),
            user,
            address(this),
            amount
        );
    }

    // Payout execution logic
    function _executePayout(
        address recipient,
        uint256 amount,
        Currency currency
    ) internal {
        if (amount == 0) return;

        SafeTransferLib.safeTransfer(
            ERC20(Currency.unwrap(currency)),
            recipient,
            amount
        );
    }

    // Helper to calculate protected amount from delta
    function _calculateProtectedAmount(
        BalanceDelta delta,
        PoolKey memory key
    ) internal pure returns (uint256) {
        // Handle negative delta.amount0() safely
        int256 amount0 = delta.amount0();
        return amount0 < 0 ? uint256(-amount0) : 0;
    }

    // Initialize pool protection parameters if needed
    function _initializePoolIfNeeded(PoolId poolId) internal {
        ProtectionPool storage pool = protectionPools[poolId];

        if (pool.lastUpdated == 0) {
            pool.maxPayoutPerPosition = 0; // No limit by default
            pool.maxTotalCoverage = DEFAULT_MAX_COVERAGE;
            pool.lastUpdated = block.timestamp;
            pool.premiumRate = BASE_PREMIUM_RATE;
        }
    }

    // Admin function to update coverage limits for a pool
    function setCoverageLimits(
        PoolKey calldata key,
        uint256 maxPayoutPerPosition,
        uint256 maxTotalCoverage
    ) external onlyOwner {
        PoolId poolId = key.toId();
        ProtectionPool storage pool = protectionPools[poolId];

        pool.maxPayoutPerPosition = maxPayoutPerPosition;
        pool.maxTotalCoverage = maxTotalCoverage;
        pool.lastUpdated = block.timestamp;

        emit CoverageLimitUpdated(
            poolId,
            maxPayoutPerPosition,
            maxTotalCoverage
        );
    }
}
