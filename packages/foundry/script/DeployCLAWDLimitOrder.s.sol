// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployHelpers.s.sol";
import "../contracts/CLAWDLimitOrder.sol";

/**
 * @notice Deploy script for CLAWDLimitOrder on Base mainnet.
 * @dev Inherits ScaffoldETHDeploy for SE-2 deployer/ABI-export integration.
 *
 * TREASURY is read from the TREASURY_ADDRESS env var; set it to the client wallet
 * (0xcfb32a7d01ca2b4b538c83b2b38656d3502d76ea). Never hardcode a private key here.
 *
 * Example:
 *   TREASURY_ADDRESS=0xcfb32a7d01ca2b4b538c83b2b38656d3502d76ea \
 *   yarn deploy --file DeployCLAWDLimitOrder.s.sol --network base
 */
contract DeployCLAWDLimitOrder is ScaffoldETHDeploy {
    function run() external ScaffoldEthDeployerRunner {
        address treasury = vm.envAddress("TREASURY_ADDRESS"); // client wallet

        CLAWDLimitOrder limitOrder = new CLAWDLimitOrder(
            0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, // USDC
            0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07, // CLAWD
            0xb72A6e1091D43e19284050b7132e0646509EBa5d, // CLAWD/USDC pool (1% fee tier)
            0x2626664c2603336E57B271c5C0b26F421741e481, // SwapRouter02 on Base
            treasury, // TREASURY (client wallet)
            10000, // POOL_FEE (1%)
            1800, // TWAP_WINDOW_SECS (30 min)
            100_000_000 // MIN_ORDER_SIZE_USDC ($100)
        );

        console.log("CLAWDLimitOrder deployed at:", address(limitOrder));
        console.log("TREASURY:", treasury);
    }
}
