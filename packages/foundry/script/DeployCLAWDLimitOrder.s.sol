// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployHelpers.s.sol";
import { CLAWDLimitOrder, IUniswapV3Pool, ISwapRouter } from "../contracts/CLAWDLimitOrder.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Deploys CLAWDLimitOrder with Base-mainnet addresses pre-wired.
 * @dev Run via:
 *   yarn deploy --file DeployCLAWDLimitOrder.s.sol --network base
 */
contract DeployCLAWDLimitOrder is ScaffoldETHDeploy {
    // Base mainnet constants (verified onchain)
    address internal constant USDC_ADDR = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CLAWD_ADDR = 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07;
    address internal constant CLAWD_USDC_POOL_ADDR = 0xb72A6e1091D43e19284050b7132e0646509EBa5d;
    address internal constant SWAP_ROUTER_ADDR = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant TREASURY_ADDR = 0xCfB32a7d01Ca2B4B538C83B2b38656D3502D76EA;

    uint24 internal constant POOL_FEE = 10000;
    uint32 internal constant TWAP_WINDOW_SECS = 1800;
    uint256 internal constant MIN_ORDER_SIZE_USDC = 100_000_000; // $100 in 6-decimal USDC

    function run() external ScaffoldEthDeployerRunner {
        CLAWDLimitOrder limitOrder = new CLAWDLimitOrder(
            IERC20(USDC_ADDR),
            IERC20(CLAWD_ADDR),
            IUniswapV3Pool(CLAWD_USDC_POOL_ADDR),
            ISwapRouter(SWAP_ROUTER_ADDR),
            TREASURY_ADDR,
            POOL_FEE,
            TWAP_WINDOW_SECS,
            MIN_ORDER_SIZE_USDC
        );

        deployments.push(Deployment({ name: "CLAWDLimitOrder", addr: address(limitOrder) }));
    }
}
