// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal Uniswap V3 pool interface (only what we need)
interface IUniswapV3Pool {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @notice Minimal Uniswap V3 SwapRouter02 interface
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title CLAWDLimitOrder
 * @notice Permissionless on-chain limit-order book for buying CLAWD with USDC on Base
 * @dev Users deposit USDC and specify a max USDC-per-CLAWD price. When the Uniswap V3
 *      TWAP price moves at or below the limit, any keeper can execute the order and
 *      collect a 0.1% reward. Treasury and buyback reserve each receive 0.1%; the
 *      remaining 99.7% is swapped for CLAWD on Uniswap V3 and delivered to the user.
 *      Buyback reserve is permissionlessly swappable to CLAWD which is then burned.
 */
contract CLAWDLimitOrder is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Immutables / constants
    // ---------------------------------------------------------------------

    IERC20 public immutable USDC;
    IERC20 public immutable CLAWD;
    IUniswapV3Pool public immutable CLAWD_USDC_POOL;
    ISwapRouter public immutable SWAP_ROUTER;
    address public immutable TREASURY;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint24 public immutable POOL_FEE;
    uint32 public immutable TWAP_WINDOW_SECS;
    uint256 public immutable MIN_ORDER_SIZE_USDC;

    uint256 public constant KEEPER_FEE_BPS = 10; // 0.1%
    uint256 public constant TREASURY_FEE_BPS = 10; // 0.1%
    uint256 public constant BUYBACK_FEE_BPS = 10; // 0.1%
    uint256 public constant SWAP_BPS = 9970; // 99.7%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    struct Order {
        address owner;
        uint256 usdcAmount; // 6 decimals, full deposit
        uint256 limitPrice; // max USDC-per-CLAWD (6 decimals) user will pay
        uint256 minAmountOut; // minimum CLAWD out for user (after 99.7% swap)
        bool executed;
        bool cancelled;
    }

    mapping(uint256 => Order) public orders;
    uint256 public orderCount;
    uint256 public buybackReserveUSDC;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed owner,
        uint256 usdcAmount,
        uint256 limitPrice,
        uint256 minAmountOut
    );
    event OrderCancelled(uint256 indexed orderId, address indexed owner);
    event OrderExecuted(
        uint256 indexed orderId,
        address indexed keeper,
        uint256 usdcIn,
        uint256 swapAmount,
        uint256 keeperFee,
        uint256 treasuryFee,
        uint256 buybackFee,
        uint256 clawdOut
    );
    event BuybackExecuted(address indexed caller, uint256 usdcIn, uint256 clawdBurned);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(
        IERC20 _usdc,
        IERC20 _clawd,
        IUniswapV3Pool _pool,
        ISwapRouter _swapRouter,
        address _treasury,
        uint24 _poolFee,
        uint32 _twapWindowSecs,
        uint256 _minOrderSizeUsdc
    ) {
        require(address(_usdc) != address(0), "USDC=0");
        require(address(_clawd) != address(0), "CLAWD=0");
        require(address(_pool) != address(0), "POOL=0");
        require(address(_swapRouter) != address(0), "ROUTER=0");
        require(_treasury != address(0), "TREASURY=0");
        require(_twapWindowSecs > 0, "TWAP=0");
        // Sanity-check BPS split
        require(
            KEEPER_FEE_BPS + TREASURY_FEE_BPS + BUYBACK_FEE_BPS + SWAP_BPS == BPS_DENOMINATOR,
            "BPS mismatch"
        );

        USDC = _usdc;
        CLAWD = _clawd;
        CLAWD_USDC_POOL = _pool;
        SWAP_ROUTER = _swapRouter;
        TREASURY = _treasury;
        POOL_FEE = _poolFee;
        TWAP_WINDOW_SECS = _twapWindowSecs;
        MIN_ORDER_SIZE_USDC = _minOrderSizeUsdc;
    }

    // ---------------------------------------------------------------------
    // User actions
    // ---------------------------------------------------------------------

    function placeOrder(uint256 usdcAmount, uint256 limitPrice, uint256 minAmountOut)
        external
        returns (uint256 orderId)
    {
        require(usdcAmount >= MIN_ORDER_SIZE_USDC, "below min");
        require(limitPrice > 0, "limit=0");
        require(minAmountOut > 0, "minOut=0");

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcAmount);

        orderId = orderCount;
        orders[orderId] = Order({
            owner: msg.sender,
            usdcAmount: usdcAmount,
            limitPrice: limitPrice,
            minAmountOut: minAmountOut,
            executed: false,
            cancelled: false
        });
        unchecked {
            orderCount = orderId + 1;
        }

        emit OrderPlaced(orderId, msg.sender, usdcAmount, limitPrice, minAmountOut);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        require(o.owner == msg.sender, "not owner");
        require(!o.executed, "executed");
        require(!o.cancelled, "cancelled");

        o.cancelled = true;
        // NOTE: pure USDC return; this path MUST NEVER read the TWAP oracle.
        IERC20(USDC).safeTransfer(o.owner, o.usdcAmount);

        emit OrderCancelled(orderId, o.owner);
    }

    // ---------------------------------------------------------------------
    // Keeper actions
    // ---------------------------------------------------------------------

    function executeOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        require(o.owner != address(0), "no order");
        require(!o.executed, "executed");
        require(!o.cancelled, "cancelled");

        uint256 currentTwapPrice = _getTwapPrice();
        require(currentTwapPrice <= o.limitPrice, "price > limit");

        // CEI: flip executed flag first
        o.executed = true;

        uint256 usdcAmount = o.usdcAmount;
        uint256 keeperFee = (usdcAmount * KEEPER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 treasuryFee = (usdcAmount * TREASURY_FEE_BPS) / BPS_DENOMINATOR;
        uint256 buybackFee = (usdcAmount * BUYBACK_FEE_BPS) / BPS_DENOMINATOR;
        uint256 swapAmount = usdcAmount - keeperFee - treasuryFee - buybackFee;

        IERC20(USDC).safeTransfer(msg.sender, keeperFee);
        IERC20(USDC).safeTransfer(TREASURY, treasuryFee);
        buybackReserveUSDC += buybackFee;

        IERC20(USDC).forceApprove(address(SWAP_ROUTER), swapAmount);
        uint256 clawdOut = SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(USDC),
                tokenOut: address(CLAWD),
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: swapAmount,
                amountOutMinimum: o.minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );

        IERC20(CLAWD).safeTransfer(o.owner, clawdOut);

        emit OrderExecuted(orderId, msg.sender, usdcAmount, swapAmount, keeperFee, treasuryFee, buybackFee, clawdOut);
    }

    function executeBuyback(uint256 minClawdOut) external nonReentrant {
        uint256 amount = buybackReserveUSDC;
        require(amount > 0, "no reserve");

        // CEI
        buybackReserveUSDC = 0;

        IERC20(USDC).forceApprove(address(SWAP_ROUTER), amount);
        uint256 clawdOut = SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(USDC),
                tokenOut: address(CLAWD),
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: amount,
                amountOutMinimum: minClawdOut,
                sqrtPriceLimitX96: 0
            })
        );

        IERC20(CLAWD).safeTransfer(BURN_ADDRESS, clawdOut);

        emit BuybackExecuted(msg.sender, amount, clawdOut);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /**
     * @notice Returns the TWAP USDC-per-CLAWD price quoted in 6 USDC decimals for 1e18 CLAWD.
     * @dev Reads tick cumulatives over [TWAP_WINDOW_SECS, 0] from the V3 pool, averages
     *      the tick, then converts via `getQuoteAtTick(avgTick, 1e18, CLAWD, USDC)`.
     *      Reverts if the pool lacks the observations to cover the window.
     */
    function _getTwapPrice() internal view returns (uint256 usdcPerClawd) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW_SECS;
        secondsAgos[1] = 0;

        try CLAWD_USDC_POOL.observe(secondsAgos) returns (
            int56[] memory tickCumulatives,
            uint160[] memory /* secondsPerLiquidityCumulativeX128s */
        ) {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int24 avgTick = int24(delta / int56(uint56(TWAP_WINDOW_SECS)));
            // Round toward negative infinity (matches Uniswap OracleLibrary consumeQuoteAtTick semantics)
            if (delta < 0 && (delta % int56(uint56(TWAP_WINDOW_SECS)) != 0)) {
                avgTick--;
            }
            usdcPerClawd = _getQuoteAtTick(avgTick, 1e18, address(CLAWD), address(USDC));
        } catch {
            revert("TWAP unavailable");
        }
    }

    // ---------------------------------------------------------------------
    // Inline Uniswap V3 math (TickMath + FullMath + getQuoteAtTick)
    // Verbatim from @uniswap/v3-core / @uniswap/v3-periphery, unlicensed reuse.
    // ---------------------------------------------------------------------

    /// @notice TickMath.getSqrtRatioAtTick — returns sqrt(1.0001^tick) * 2^96
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= 887272, "T");

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        // Downcast to uint160. Round up: ratio / 2^32 rounded up to a Q64.96
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    /// @notice FullMath.mulDiv — calculates floor(a * b / denominator) with full precision
    /// @dev Reverts on division by zero or if result overflows uint256
    function _mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                require(denominator > 0);
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            // Make sure the result is less than 2**256.
            // Also prevents denominator == 0
            require(denominator > prod1);

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0]
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            // Subtract 256 bit number from 512 bit number
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator
            // Compute largest power of two divisor of denominator.
            // Always >= 1.
            uint256 twos = denominator & (~denominator + 1);
            // Divide denominator by power of two
            assembly {
                denominator := div(denominator, twos)
            }

            // Divide [prod1 prod0] by the factors of two
            assembly {
                prod0 := div(prod0, twos)
            }
            // Shift in bits from prod1 into prod0. For this we need
            // to flip `twos` such that it is 2**256 / twos.
            // If twos is zero, then it becomes one
            assembly {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2**256
            // Now that denominator is an odd number, it has an inverse
            // modulo 2**256 such that denominator * inv = 1 mod 2**256.
            // Compute the inverse by starting with a seed that is correct
            // correct for four bits. That is, denominator * inv = 1 mod 2**4
            uint256 inv = (3 * denominator) ^ 2;
            // Now use Newton-Raphson iteration to improve the precision.
            // Thanks to Hensel's lifting lemma, this also works in modular
            // arithmetic, doubling the correct bits in each step.
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256

            // Because the division is now exact we can divide by multiplying
            // with the modular inverse of denominator. This will give us the
            // correct result modulo 2**256. Since the precoditions guarantee
            // that the outcome is less than 2**256, this is the final result.
            // We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inv;
            return result;
        }
    }

    /// @notice OracleLibrary.getQuoteAtTick — quotes baseAmount of baseToken in terms of quoteToken at the given tick
    function _getQuoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = _getSqrtRatioAtTick(tick);

        // Calculate quoteAmount with better precision if it doesn't overflow when multiplied by itself
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? _mulDiv(ratioX192, baseAmount, 1 << 192)
                : _mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = _mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? _mulDiv(ratioX128, baseAmount, 1 << 128)
                : _mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
