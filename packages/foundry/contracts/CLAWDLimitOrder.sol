// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { IUniswapV3Pool } from "./interfaces/IUniswapV3Pool.sol";
import { ISwapRouter } from "./interfaces/ISwapRouter.sol";
import { TickMath } from "./libraries/TickMath.sol";

/// @title CLAWDLimitOrder
/// @notice Immutable, permissionless TWAP-gated limit-order vault for buying CLAWD with USDC on Base.
/// @dev No owner, no admin, no upgradeability. Orders are TWAP-gated on execution; cancellation never
///      touches the oracle. Fees are split in exact BPS that sum to BPS_DENOMINATOR.
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

    uint256 public constant KEEPER_FEE_BPS = 10; // 0.1% -> msg.sender at execute
    uint256 public constant TREASURY_FEE_BPS = 10; // 0.1% -> TREASURY at execute
    uint256 public constant BUYBACK_FEE_BPS = 10; // 0.1% -> buybackReserveUSDC
    uint256 public constant SWAP_BPS = 9970; // 99.7% -> swap to CLAWD
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    struct Order {
        address owner;
        uint256 usdcAmount; // 6 decimals, full deposit
        uint256 limitPrice; // max USDC-per-CLAWD price (6 decimals per 1e18 CLAWD)
        uint256 minAmountOut; // minimum CLAWD out for the USER (after 99.7% swap)
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
        uint256 indexed orderId, address indexed owner, uint256 usdcAmount, uint256 limitPrice, uint256 minAmountOut
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
        address usdc,
        address clawd,
        address clawdUsdcPool,
        address swapRouter,
        address treasury,
        uint24 poolFee,
        uint32 twapWindowSecs,
        uint256 minOrderSizeUsdc
    ) {
        require(usdc != address(0), "USDC=0");
        require(clawd != address(0), "CLAWD=0");
        require(clawdUsdcPool != address(0), "POOL=0");
        require(swapRouter != address(0), "ROUTER=0");
        require(treasury != address(0), "TREASURY=0");
        require(twapWindowSecs > 0, "WINDOW=0");

        USDC = IERC20(usdc);
        CLAWD = IERC20(clawd);
        CLAWD_USDC_POOL = IUniswapV3Pool(clawdUsdcPool);
        SWAP_ROUTER = ISwapRouter(swapRouter);
        TREASURY = treasury;
        POOL_FEE = poolFee;
        TWAP_WINDOW_SECS = twapWindowSecs;
        MIN_ORDER_SIZE_USDC = minOrderSizeUsdc;
    }

    // ---------------------------------------------------------------------
    // Orders
    // ---------------------------------------------------------------------

    /// @notice Deposit USDC and create a limit order to buy CLAWD when TWAP <= limitPrice.
    function placeOrder(uint256 usdcAmount, uint256 limitPrice, uint256 minAmountOut) external {
        require(usdcAmount >= MIN_ORDER_SIZE_USDC, "below min order size");
        require(limitPrice > 0, "limitPrice=0");
        require(minAmountOut > 0, "minAmountOut=0");

        uint256 orderId = orderCount;
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

        USDC.safeTransferFrom(msg.sender, address(this), usdcAmount);

        emit OrderPlaced(orderId, msg.sender, usdcAmount, limitPrice, minAmountOut);
    }

    /// @notice Cancel an open order and refund the full deposit. Never reads the oracle.
    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];
        require(msg.sender == order.owner, "not owner");
        require(!order.executed, "executed");
        require(!order.cancelled, "cancelled");

        order.cancelled = true;

        USDC.safeTransfer(order.owner, order.usdcAmount);

        emit OrderCancelled(orderId, order.owner);
    }

    /// @notice Permissionless: execute an open order when the TWAP price is at/under its limit.
    /// @dev Caller (keeper) earns KEEPER_FEE_BPS of the order's USDC.
    function executeOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        require(order.owner != address(0), "no order");
        require(!order.executed, "executed");
        require(!order.cancelled, "cancelled");

        uint256 currentTwapPrice = _getTwapPrice();
        require(currentTwapPrice <= order.limitPrice, "twap above limit");

        // CEI: mark executed before any external interaction.
        order.executed = true;

        uint256 usdcAmount = order.usdcAmount;
        uint256 keeperFee = (usdcAmount * KEEPER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 treasuryFee = (usdcAmount * TREASURY_FEE_BPS) / BPS_DENOMINATOR;
        uint256 buybackFee = (usdcAmount * BUYBACK_FEE_BPS) / BPS_DENOMINATOR;
        // Remainder goes to the swap so the four amounts sum exactly to usdcAmount.
        uint256 swapAmount = usdcAmount - keeperFee - treasuryFee - buybackFee;

        USDC.safeTransfer(msg.sender, keeperFee);
        USDC.safeTransfer(TREASURY, treasuryFee);
        buybackReserveUSDC += buybackFee;

        USDC.forceApprove(address(SWAP_ROUTER), swapAmount);
        uint256 clawdOut = SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(USDC),
                tokenOut: address(CLAWD),
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: swapAmount,
                amountOutMinimum: order.minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );

        CLAWD.safeTransfer(order.owner, clawdOut);

        emit OrderExecuted(
            orderId, msg.sender, usdcAmount, swapAmount, keeperFee, treasuryFee, buybackFee, clawdOut
        );
    }

    /// @notice Permissionless: swap the accumulated buyback reserve to CLAWD and burn it.
    function executeBuyback(uint256 minClawdOut) external nonReentrant {
        uint256 amount = buybackReserveUSDC;
        require(amount > 0, "empty reserve");

        // CEI: zero the reserve before external interaction.
        buybackReserveUSDC = 0;

        USDC.forceApprove(address(SWAP_ROUTER), amount);
        uint256 clawdOut = SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(USDC),
                tokenOut: address(CLAWD),
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: minClawdOut,
                sqrtPriceLimitX96: 0
            })
        );

        CLAWD.safeTransfer(BURN_ADDRESS, clawdOut);

        emit BuybackExecuted(msg.sender, amount, clawdOut);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /// @notice TWAP USDC value (6 decimals) you'd receive for 1e18 CLAWD over TWAP_WINDOW_SECS.
    /// @dev Reverts if the pool lacks observation history for the window (observe reverts).
    function _getTwapPrice() internal view returns (uint256) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW_SECS;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = CLAWD_USDC_POOL.observe(secondsAgos);

        int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 meanTick = int24(tickDelta / int56(int32(TWAP_WINDOW_SECS)));
        // Round toward negative infinity to match Uniswap's OracleLibrary consensus behavior.
        if (tickDelta < 0 && (tickDelta % int56(int32(TWAP_WINDOW_SECS)) != 0)) {
            meanTick--;
        }

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(meanTick);

        // price(token0 in token1) = (sqrtPriceX96 / 2^96)^2.
        // We want USDC (6 dp) you'd get for 1e18 CLAWD, regardless of token ordering.
        // sqrtPriceX96^2 can exceed uint256, so square via two staged mulDiv-by-2^96 ops
        // (Q96 -> Q96 -> Q0 with the 1e18 numerator folded in to preserve precision).
        bool clawdIsToken0 = CLAWD_USDC_POOL.token0() == address(CLAWD);
        uint256 sqrtP = uint256(sqrtPriceX96);
        uint256 Q96 = 1 << 96;

        uint256 usdcPer1e18Clawd;
        if (clawdIsToken0) {
            // USDC = token1; for 1e18 CLAWD: 1e18 * (sqrtP/2^96)^2.
            // = ((1e18 * sqrtP / 2^96) * sqrtP) / 2^96
            uint256 stage = Math.mulDiv(1e18, sqrtP, Q96);
            usdcPer1e18Clawd = Math.mulDiv(stage, sqrtP, Q96);
        } else {
            // USDC = token0; for 1e18 CLAWD: 1e18 * (2^96/sqrtP)^2.
            // = ((1e18 * 2^96 / sqrtP) * 2^96) / sqrtP
            uint256 stage = Math.mulDiv(1e18, Q96, sqrtP);
            usdcPer1e18Clawd = Math.mulDiv(stage, Q96, sqrtP);
        }

        return usdcPer1e18Clawd;
    }
}
