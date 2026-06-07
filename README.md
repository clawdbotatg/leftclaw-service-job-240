# CLAWD Limit Order

Permissionless onchain limit orders for buying CLAWD with USDC on Base. No backend, no upgradability, no admin — fully autonomous.

## What It Does

Users deposit USDC and specify a target CLAWD/USDC price. Any keeper can execute the order when the 30-minute Uniswap V3 TWAP hits the limit price. A flat 0.3% protocol fee is split: 0.1% to the executing keeper, 0.1% to the treasury, 0.1% accumulated in a permissionless buyback reserve.

## Live

Frontend: deployed on IPFS via bgipfs — see `DEPLOYMENT.md`

## Contract

**CLAWDLimitOrder** on Base mainnet:
- Address: [`0xf32db9C489273713D037312E7b689e885Aa50F58`](https://basescan.org/address/0xf32db9C489273713D037312E7b689e885Aa50F58)
- Verified on [Sourcify](https://sourcify.dev/#/lookup/0xf32db9C489273713D037312E7b689e885Aa50F58)
- No owner, no admin, no upgradeability

### Key Addresses (Base)
| Token | Address |
|-------|---------|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| CLAWD | `0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07` |
| CLAWD/USDC Pool (1% fee) | `0xb72A6e1091D43e19284050b7132e0646509EBa5d` |
| Uniswap SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` |
| Treasury | `0xcfb32a7d01ca2b4b538c83b2b38656d3502d76ea` |

### Fee Structure
| Fee | BPS | Description |
|-----|-----|-------------|
| Keeper | 10 (0.1%) | Paid immediately to executor |
| Treasury | 10 (0.1%) | Paid immediately to treasury |
| Buyback | 10 (0.1%) | Accumulated, burned via `executeBuyback()` |
| Swap | 9970 (99.7%) | Swapped to CLAWD for user |

## Pages

- `/` — Order Dashboard: place and cancel orders, view your order history
- `/keeper` — Keeper Dashboard: execute open orders, trigger CLAWD buybacks

## Running Locally

```bash
yarn install

# Start local chain (fork Base)
yarn fork --network base

# Deploy contracts locally
yarn deploy

# Start frontend
yarn start
```

## Tech Stack

- Scaffold-ETH 2 (Foundry flavor)
- Next.js (static export → IPFS)
- Uniswap V3 TWAP oracle + swap
- bgipfs for decentralized frontend hosting
- Base mainnet
