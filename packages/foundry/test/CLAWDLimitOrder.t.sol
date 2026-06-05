// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { CLAWDLimitOrder, IUniswapV3Pool, ISwapRouter } from "../contracts/CLAWDLimitOrder.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ---------------------------------------------------------------------
// Minimal mock ERC20 — fixed decimals supplied via constructor
// ---------------------------------------------------------------------
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _decimals = d;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ---------------------------------------------------------------------
// Mock Uniswap V3 pool — returns a configurable tick over a window
// ---------------------------------------------------------------------
contract MockPool {
    int24 public avgTick;
    bool public shouldRevert;

    function setAvgTick(int24 _tick) external {
        avgTick = _tick;
    }

    function setShouldRevert(bool _v) external {
        shouldRevert = _v;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (shouldRevert) revert("OLD");
        require(secondsAgos.length == 2, "len");
        tickCumulatives = new int56[](2);
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
        // tickCumulatives[1] - tickCumulatives[0] = avgTick * window
        int56 window = int56(uint56(secondsAgos[0]));
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(avgTick) * window;
    }
}

// ---------------------------------------------------------------------
// Mock SwapRouter — pulls USDC, mints CLAWD at fixed rate
// ---------------------------------------------------------------------
contract MockSwapRouter {
    MockERC20 public clawd;
    uint256 public clawdPerUsdc1e18; // CLAWD units (1e18 each) returned per USDC unit (1e6)

    constructor(MockERC20 _clawd, uint256 _clawdPerUsdc1e18) {
        clawd = _clawd;
        clawdPerUsdc1e18 = _clawdPerUsdc1e18;
    }

    function setRate(uint256 _rate) external {
        clawdPerUsdc1e18 = _rate;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata p) external returns (uint256 amountOut) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = (p.amountIn * clawdPerUsdc1e18) / 1e6;
        require(amountOut >= p.amountOutMinimum, "slippage");
        clawd.mint(p.recipient, amountOut);
    }
}

// =====================================================================
// CLAWDLimitOrder tests
// =====================================================================
contract CLAWDLimitOrderTest is Test {
    CLAWDLimitOrder internal limitOrder;
    MockERC20 internal usdc;
    MockERC20 internal clawd;
    MockPool internal pool;
    MockSwapRouter internal router;

    address internal user = address(0xBEEF);
    address internal keeper = address(0xCAFE);
    address internal treasury = address(0x7E45);

    uint24 internal constant POOL_FEE = 10000;
    uint32 internal constant TWAP_WINDOW = 1800;
    uint256 internal constant MIN_ORDER = 100_000_000; // $100

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        clawd = new MockERC20("CLAWD", "CLAWD", 18);
        pool = new MockPool();
        // Default: 1 USDC -> 1 CLAWD (1 USDC = 1e6 units, 1 CLAWD = 1e18 units, so 1e18 CLAWD per 1e6 USDC)
        router = new MockSwapRouter(clawd, 1e18);

        limitOrder = new CLAWDLimitOrder(
            IERC20(address(usdc)),
            IERC20(address(clawd)),
            IUniswapV3Pool(address(pool)),
            ISwapRouter(address(router)),
            treasury,
            POOL_FEE,
            TWAP_WINDOW,
            MIN_ORDER
        );

        // Set a tick that yields a small TWAP price (so it's <= any reasonable limit).
        // tick=0 means sqrtRatioX96 = 2^96, i.e. token1/token0 = 1.
        // With pool token0=CLAWD-mock token1=USDC-mock... wait, our mocks have no fixed
        // ordering. The contract's getQuoteAtTick uses (baseToken < quoteToken) on raw
        // addresses, so the price depends on the address-sort of the mock tokens.
        // For tests we just pick a tick that yields a sane price either way.
        pool.setAvgTick(0); // ratio = 1, so 1e18 CLAWD => 1e18 quote — but USDC has 6 dec,
            // so price will be 1e18 USDC-units per CLAWD which is a huge limit.
            // That's fine for the "below limit" branch.

        // Fund user with USDC
        usdc.mint(user, 1_000_000_000_000); // $1M
        vm.prank(user);
        usdc.approve(address(limitOrder), type(uint256).max);
    }

    // -----------------------------------------------------------------
    // placeOrder
    // -----------------------------------------------------------------

    function test_placeOrder_success() public {
        uint256 amount = 500_000_000; // $500
        uint256 limit = 1_000_000; // $1.00
        uint256 minOut = 1e18; // 1 CLAWD

        vm.prank(user);
        uint256 id = limitOrder.placeOrder(amount, limit, minOut);

        assertEq(id, 0);
        assertEq(limitOrder.orderCount(), 1);

        CLAWDLimitOrder.Order memory o = limitOrder.getOrder(0);
        assertEq(o.owner, user);
        assertEq(o.usdcAmount, amount);
        assertEq(o.limitPrice, limit);
        assertEq(o.minAmountOut, minOut);
        assertFalse(o.executed);
        assertFalse(o.cancelled);

        assertEq(usdc.balanceOf(address(limitOrder)), amount);
    }

    function test_placeOrder_reverts_belowMinSize() public {
        vm.prank(user);
        vm.expectRevert(bytes("below min"));
        limitOrder.placeOrder(MIN_ORDER - 1, 1_000_000, 1e18);
    }

    function test_placeOrder_reverts_zeroLimitPrice() public {
        vm.prank(user);
        vm.expectRevert(bytes("limit=0"));
        limitOrder.placeOrder(MIN_ORDER, 0, 1e18);
    }

    function test_placeOrder_reverts_zeroMinOut() public {
        vm.prank(user);
        vm.expectRevert(bytes("minOut=0"));
        limitOrder.placeOrder(MIN_ORDER, 1_000_000, 0);
    }

    // -----------------------------------------------------------------
    // cancelOrder
    // -----------------------------------------------------------------

    function test_cancelOrder_success() public {
        uint256 amount = 500_000_000;
        vm.prank(user);
        uint256 id = limitOrder.placeOrder(amount, 1_000_000, 1e18);

        uint256 userBalBefore = usdc.balanceOf(user);

        vm.prank(user);
        limitOrder.cancelOrder(id);

        assertTrue(limitOrder.getOrder(id).cancelled);
        assertEq(usdc.balanceOf(user) - userBalBefore, amount);
        assertEq(usdc.balanceOf(address(limitOrder)), 0);
    }

    function test_cancelOrder_doesNotReadOracle() public {
        // If cancel touches the oracle, this would revert because we force OLD on pool.
        vm.prank(user);
        uint256 id = limitOrder.placeOrder(500_000_000, 1_000_000, 1e18);

        pool.setShouldRevert(true);

        vm.prank(user);
        limitOrder.cancelOrder(id); // must succeed regardless of pool state
        assertTrue(limitOrder.getOrder(id).cancelled);
    }

    function test_cancelOrder_reverts_notOwner() public {
        vm.prank(user);
        uint256 id = limitOrder.placeOrder(500_000_000, 1_000_000, 1e18);

        vm.prank(keeper);
        vm.expectRevert(bytes("not owner"));
        limitOrder.cancelOrder(id);
    }

    function test_cancelOrder_reverts_alreadyCancelled() public {
        vm.prank(user);
        uint256 id = limitOrder.placeOrder(500_000_000, 1_000_000, 1e18);

        vm.prank(user);
        limitOrder.cancelOrder(id);

        vm.prank(user);
        vm.expectRevert(bytes("cancelled"));
        limitOrder.cancelOrder(id);
    }

    // -----------------------------------------------------------------
    // executeOrder
    // -----------------------------------------------------------------

    function test_feeSplit_exactBps() public {
        // $1000 order -> each fee should be $1.00 (1_000_000), swap = 997_000_000, sum = 1_000_000_000
        uint256 amount = 1_000_000_000;
        // Pick a limit price big enough that any TWAP returned by the inlined math at tick=0 passes.
        // tick=0 with our mock tokens may yield a "price" in the 1e18 ballpark since CLAWD has
        // 18 decimals and USDC has 6, but the math is address-order dependent. Use max uint as limit.
        uint256 limit = type(uint256).max;
        uint256 minOut = 1; // accept any swap output

        vm.prank(user);
        uint256 id = limitOrder.placeOrder(amount, limit, minOut);

        uint256 keeperBalBefore = usdc.balanceOf(keeper);
        uint256 treasuryBalBefore = usdc.balanceOf(treasury);
        uint256 buybackBefore = limitOrder.buybackReserveUSDC();

        vm.prank(keeper);
        limitOrder.executeOrder(id);

        uint256 keeperFee = usdc.balanceOf(keeper) - keeperBalBefore;
        uint256 treasuryFee = usdc.balanceOf(treasury) - treasuryBalBefore;
        uint256 buybackFee = limitOrder.buybackReserveUSDC() - buybackBefore;
        uint256 swapAmount = amount - keeperFee - treasuryFee - buybackFee;

        // Each 0.1% slice on $1000 = $1.00 (1_000_000 with 6 decimals)
        assertEq(keeperFee, 1_000_000, "keeper fee");
        assertEq(treasuryFee, 1_000_000, "treasury fee");
        assertEq(buybackFee, 1_000_000, "buyback fee");
        // 99.7% slice = $997
        assertEq(swapAmount, 997_000_000, "swap amount");
        // Sum equals usdcAmount
        assertEq(keeperFee + treasuryFee + buybackFee + swapAmount, amount, "sum");

        // Order flagged executed
        assertTrue(limitOrder.getOrder(id).executed);
        // User received CLAWD (mock returns 1e18 per 1e6 USDC -> 997 * 1e18)
        assertEq(clawd.balanceOf(user), 997_000_000 * 1e18 / 1e6);
    }

    function test_executeOrder_reverts_priceAboveLimit() public {
        vm.prank(user);
        uint256 id = limitOrder.placeOrder(500_000_000, 1, 1); // limit=1 (microscopic)

        vm.prank(keeper);
        vm.expectRevert(bytes("price > limit"));
        limitOrder.executeOrder(id);
    }

    function test_executeOrder_reverts_twapUnavailable() public {
        vm.prank(user);
        uint256 id = limitOrder.placeOrder(500_000_000, type(uint256).max, 1);

        pool.setShouldRevert(true);

        vm.prank(keeper);
        vm.expectRevert(bytes("TWAP unavailable"));
        limitOrder.executeOrder(id);
    }

    function test_executeOrder_reverts_alreadyExecuted() public {
        vm.prank(user);
        uint256 id = limitOrder.placeOrder(500_000_000, type(uint256).max, 1);

        vm.prank(keeper);
        limitOrder.executeOrder(id);

        vm.prank(keeper);
        vm.expectRevert(bytes("executed"));
        limitOrder.executeOrder(id);
    }

    function test_executeOrder_reverts_cancelled() public {
        vm.prank(user);
        uint256 id = limitOrder.placeOrder(500_000_000, type(uint256).max, 1);

        vm.prank(user);
        limitOrder.cancelOrder(id);

        vm.prank(keeper);
        vm.expectRevert(bytes("cancelled"));
        limitOrder.executeOrder(id);
    }

    // -----------------------------------------------------------------
    // executeBuyback
    // -----------------------------------------------------------------

    function test_executeBuyback_reverts_emptyReserve() public {
        vm.expectRevert(bytes("no reserve"));
        limitOrder.executeBuyback(1);
    }

    function test_executeBuyback_burnsClawd() public {
        // Seed reserve via an executed order
        uint256 amount = 1_000_000_000;
        vm.prank(user);
        uint256 id = limitOrder.placeOrder(amount, type(uint256).max, 1);
        vm.prank(keeper);
        limitOrder.executeOrder(id);

        uint256 reserve = limitOrder.buybackReserveUSDC();
        assertEq(reserve, 1_000_000); // $1 buyback fee

        uint256 burnBefore = clawd.balanceOf(0x000000000000000000000000000000000000dEaD);
        limitOrder.executeBuyback(1);
        uint256 burnAfter = clawd.balanceOf(0x000000000000000000000000000000000000dEaD);

        assertGt(burnAfter, burnBefore);
        assertEq(limitOrder.buybackReserveUSDC(), 0);
    }
}
