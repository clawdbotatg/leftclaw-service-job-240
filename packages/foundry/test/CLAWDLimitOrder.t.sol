// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { CLAWDLimitOrder } from "../contracts/CLAWDLimitOrder.sol";
import { ISwapRouter } from "../contracts/interfaces/ISwapRouter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ---------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract MockUniswapV3Pool {
    address public token0;
    address public token1;

    // configurable cumulative ticks returned by observe()
    int56 public tickCumulativePast; // value at secondsAgos[0] (window ago)
    int56 public tickCumulativeNow; // value at secondsAgos[1] (now)

    bool public shouldRevert;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function setTicks(int56 past, int56 now_) external {
        tickCumulativePast = past;
        tickCumulativeNow = now_;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    // `observe` is `view` to match the real Uniswap V3 pool (the contract STATICCALLs it).
    function observe(uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(!shouldRevert, "OLD");
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = tickCumulativePast;
        tickCumulatives[1] = tickCumulativeNow;
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
    }
}

contract MockSwapRouter {
    MockERC20 public immutable tokenOutToken;
    uint256 public clawdOutToReturn;

    constructor(MockERC20 _tokenOut) {
        tokenOutToken = _tokenOut;
    }

    function setClawdOut(uint256 v) external {
        clawdOutToReturn = v;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        // pull tokenIn from caller
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = clawdOutToReturn;
        require(amountOut >= params.amountOutMinimum, "Too little received");
        // deliver tokenOut to recipient
        tokenOutToken.mint(params.recipient, amountOut);
    }
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

contract CLAWDLimitOrderTest is Test {
    MockERC20 usdc;
    MockERC20 clawd;
    MockUniswapV3Pool pool;
    MockSwapRouter router;
    CLAWDLimitOrder limitOrder;

    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    uint24 constant POOL_FEE = 10000;
    uint32 constant TWAP_WINDOW = 1800;
    uint256 constant MIN_ORDER = 100_000_000; // $100

    // A standard order used in several tests
    uint256 constant ORDER_USDC = 1_000_000_000; // $1000
    // At tick 0 the TWAP price is exactly 1e18 (USDC-units per 1e18 CLAWD) since CLAWD is token0.
    // Use a generous limit above that so the standard order executes.
    uint256 constant LIMIT_PRICE = 2e18;
    uint256 constant MIN_OUT = 1;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        clawd = new MockERC20("CLAWD", "CLAWD", 18);
        // token0/token1 ordering: make CLAWD token0 for determinism
        pool = new MockUniswapV3Pool(address(clawd), address(usdc));
        router = new MockSwapRouter(clawd);

        limitOrder = new CLAWDLimitOrder(
            address(usdc),
            address(clawd),
            address(pool),
            address(router),
            treasury,
            POOL_FEE,
            TWAP_WINDOW,
            MIN_ORDER
        );

        // default: TWAP tick = 0 -> price ~ 1e18 (way above any small limit); we use generous limit
        pool.setTicks(0, 0);
        router.setClawdOut(500e18);

        usdc.mint(alice, 10_000_000_000);
        usdc.mint(bob, 10_000_000_000);
    }

    function _placeAliceOrder() internal returns (uint256 orderId) {
        vm.startPrank(alice);
        usdc.approve(address(limitOrder), ORDER_USDC);
        orderId = limitOrder.orderCount();
        limitOrder.placeOrder(ORDER_USDC, LIMIT_PRICE, MIN_OUT);
        vm.stopPrank();
    }

    // ---------------- placeOrder ----------------

    function test_placeOrder_success() public {
        uint256 orderId = _placeAliceOrder();
        CLAWDLimitOrder.Order memory o = limitOrder.getOrder(orderId);
        assertEq(o.owner, alice);
        assertEq(o.usdcAmount, ORDER_USDC);
        assertEq(o.limitPrice, LIMIT_PRICE);
        assertEq(o.minAmountOut, MIN_OUT);
        assertFalse(o.executed);
        assertFalse(o.cancelled);
        assertEq(limitOrder.orderCount(), 1);
        assertEq(usdc.balanceOf(address(limitOrder)), ORDER_USDC);
    }

    function test_placeOrder_reverts_belowMinSize() public {
        vm.startPrank(alice);
        usdc.approve(address(limitOrder), MIN_ORDER);
        vm.expectRevert(bytes("below min order size"));
        limitOrder.placeOrder(MIN_ORDER - 1, LIMIT_PRICE, MIN_OUT);
        vm.stopPrank();
    }

    function test_placeOrder_reverts_zeroLimitPrice() public {
        vm.startPrank(alice);
        usdc.approve(address(limitOrder), ORDER_USDC);
        vm.expectRevert(bytes("limitPrice=0"));
        limitOrder.placeOrder(ORDER_USDC, 0, MIN_OUT);
        vm.stopPrank();
    }

    function test_placeOrder_reverts_zeroMinAmountOut() public {
        vm.startPrank(alice);
        usdc.approve(address(limitOrder), ORDER_USDC);
        vm.expectRevert(bytes("minAmountOut=0"));
        limitOrder.placeOrder(ORDER_USDC, LIMIT_PRICE, 0);
        vm.stopPrank();
    }

    // ---------------- cancelOrder ----------------

    function test_cancelOrder_success() public {
        uint256 orderId = _placeAliceOrder();
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        limitOrder.cancelOrder(orderId);
        CLAWDLimitOrder.Order memory o = limitOrder.getOrder(orderId);
        assertTrue(o.cancelled);
        assertEq(usdc.balanceOf(alice), balBefore + ORDER_USDC);
        assertEq(usdc.balanceOf(address(limitOrder)), 0);
    }

    function test_cancelOrder_never_reads_oracle() public {
        uint256 orderId = _placeAliceOrder();
        // Arm the oracle to revert on ANY observe() call. If cancelOrder touched the
        // oracle, this cancel would revert; a clean cancel proves it never reads the pool.
        pool.setShouldRevert(true);
        vm.prank(alice);
        limitOrder.cancelOrder(orderId);
        CLAWDLimitOrder.Order memory o = limitOrder.getOrder(orderId);
        assertTrue(o.cancelled, "cancel succeeded without reading oracle");
    }

    function test_cancelOrder_reverts_notOwner() public {
        uint256 orderId = _placeAliceOrder();
        vm.prank(bob);
        vm.expectRevert(bytes("not owner"));
        limitOrder.cancelOrder(orderId);
    }

    function test_cancelOrder_reverts_executed() public {
        uint256 orderId = _placeAliceOrder();
        pool.setTicks(0, 0); // tick 0 -> low price, under limit
        vm.prank(keeper);
        limitOrder.executeOrder(orderId);
        vm.prank(alice);
        vm.expectRevert(bytes("executed"));
        limitOrder.cancelOrder(orderId);
    }

    function test_cancelOrder_reverts_cancelled() public {
        uint256 orderId = _placeAliceOrder();
        vm.prank(alice);
        limitOrder.cancelOrder(orderId);
        vm.prank(alice);
        vm.expectRevert(bytes("cancelled"));
        limitOrder.cancelOrder(orderId);
    }

    // ---------------- executeOrder ----------------

    function test_executeOrder_feeSplit_exactBps() public {
        uint256 orderId = _placeAliceOrder();
        pool.setTicks(0, 0);

        uint256 treasBefore = usdc.balanceOf(treasury);
        uint256 keeperBefore = usdc.balanceOf(keeper);

        vm.prank(keeper);
        limitOrder.executeOrder(orderId);

        uint256 keeperFee = (ORDER_USDC * 10) / 10_000;
        uint256 treasuryFee = (ORDER_USDC * 10) / 10_000;
        uint256 buybackFee = (ORDER_USDC * 10) / 10_000;
        uint256 swapAmount = ORDER_USDC - keeperFee - treasuryFee - buybackFee;

        // four amounts sum exactly to usdcAmount
        assertEq(keeperFee + treasuryFee + buybackFee + swapAmount, ORDER_USDC, "splits must sum to total");

        assertEq(usdc.balanceOf(keeper) - keeperBefore, keeperFee, "keeper fee");
        assertEq(usdc.balanceOf(treasury) - treasBefore, treasuryFee, "treasury fee");
        assertEq(limitOrder.buybackReserveUSDC(), buybackFee, "buyback reserve");

        // swapAmount of USDC was pulled by router; user got CLAWD
        assertEq(usdc.balanceOf(address(router)), swapAmount, "router received swapAmount");
        assertEq(clawd.balanceOf(alice), 500e18, "alice got clawd");

        CLAWDLimitOrder.Order memory o = limitOrder.getOrder(orderId);
        assertTrue(o.executed);
    }

    function test_executeOrder_reverts_twapAboveLimit() public {
        // Place an order with a very tight limit price.
        vm.startPrank(alice);
        usdc.approve(address(limitOrder), ORDER_USDC);
        uint256 orderId = limitOrder.orderCount();
        limitOrder.placeOrder(ORDER_USDC, 1, MIN_OUT); // limit price = 1 (extremely low)
        vm.stopPrank();

        // tick 0 -> price = 1e18 USDC-units per 1e18 CLAWD, well above limit of 1
        pool.setTicks(0, 0);

        vm.prank(keeper);
        vm.expectRevert(bytes("twap above limit"));
        limitOrder.executeOrder(orderId);
    }

    function test_executeOrder_reverts_alreadyExecuted() public {
        uint256 orderId = _placeAliceOrder();
        pool.setTicks(0, 0);
        vm.prank(keeper);
        limitOrder.executeOrder(orderId);
        vm.prank(keeper);
        vm.expectRevert(bytes("executed"));
        limitOrder.executeOrder(orderId);
    }

    function test_executeOrder_reverts_cancelled() public {
        uint256 orderId = _placeAliceOrder();
        vm.prank(alice);
        limitOrder.cancelOrder(orderId);
        vm.prank(keeper);
        vm.expectRevert(bytes("cancelled"));
        limitOrder.executeOrder(orderId);
    }

    function test_executeOrder_reverts_noOrder() public {
        vm.prank(keeper);
        vm.expectRevert(bytes("no order"));
        limitOrder.executeOrder(999);
    }

    function test_executeOrder_reverts_oracleInsufficientHistory() public {
        uint256 orderId = _placeAliceOrder();
        pool.setShouldRevert(true);
        vm.prank(keeper);
        vm.expectRevert(bytes("OLD"));
        limitOrder.executeOrder(orderId);
    }

    // ---------------- executeBuyback ----------------

    function _seedBuybackReserve() internal returns (uint256 buybackFee) {
        uint256 orderId = _placeAliceOrder();
        pool.setTicks(0, 0);
        vm.prank(keeper);
        limitOrder.executeOrder(orderId);
        buybackFee = (ORDER_USDC * 10) / 10_000;
        assertEq(limitOrder.buybackReserveUSDC(), buybackFee);
    }

    function test_executeBuyback_success() public {
        uint256 buybackFee = _seedBuybackReserve();
        router.setClawdOut(123e18);

        uint256 burnBefore = clawd.balanceOf(limitOrder.BURN_ADDRESS());

        vm.prank(bob);
        limitOrder.executeBuyback(1);

        assertEq(limitOrder.buybackReserveUSDC(), 0, "reserve drained");
        assertEq(clawd.balanceOf(limitOrder.BURN_ADDRESS()) - burnBefore, 123e18, "burned clawd");
        // router pulled the buyback USDC
        assertEq(usdc.balanceOf(address(router)) >= buybackFee, true);
    }

    function test_executeBuyback_reverts_emptyReserve() public {
        vm.prank(bob);
        vm.expectRevert(bytes("empty reserve"));
        limitOrder.executeBuyback(1);
    }

    function test_executeBuyback_permissionless() public {
        // Seed a reserve and let three different callers each top it up and execute.
        address[3] memory callers = [address(0xC1), address(0xC2), address(0xC3)];
        for (uint256 i = 0; i < 3; i++) {
            // create + execute an order to seed reserve
            vm.startPrank(alice);
            usdc.approve(address(limitOrder), ORDER_USDC);
            uint256 orderId = limitOrder.orderCount();
            limitOrder.placeOrder(ORDER_USDC, LIMIT_PRICE, MIN_OUT);
            vm.stopPrank();
            pool.setTicks(0, 0);
            vm.prank(keeper);
            limitOrder.executeOrder(orderId);

            assertGt(limitOrder.buybackReserveUSDC(), 0);
            router.setClawdOut(10e18);
            vm.prank(callers[i]);
            limitOrder.executeBuyback(1);
            assertEq(limitOrder.buybackReserveUSDC(), 0);
        }
    }
}
