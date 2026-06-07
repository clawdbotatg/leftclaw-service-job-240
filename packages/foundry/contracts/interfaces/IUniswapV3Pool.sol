// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Uniswap V3 pool interface — only the function this project uses.
interface IUniswapV3Pool {
    /// @notice Returns cumulative tick and liquidity values as of each timestamp `secondsAgo` from the current block.
    /// @param secondsAgos From how long ago each cumulative value should be returned.
    /// @return tickCumulatives Cumulative tick values as of each `secondsAgos`.
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds-per-liquidity-in-range values.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice The first of the two tokens of the pool, sorted by address.
    function token0() external view returns (address);

    /// @notice The second of the two tokens of the pool, sorted by address.
    function token1() external view returns (address);
}
