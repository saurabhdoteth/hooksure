# HookSure

HookSure is a Uniswap v4 hook that calculates and compensates for impermanent loss in concentrated liquidity positions.

## Overview

HookSure implements an IL protection mechanism for liquidity providers (LPs) in Uniswap v4 pools by:

1. Calculating and collecting premium payments when LPs add liquidity
2. Tracking position details including initial price and liquidity amount
3. Computing impermanent loss (IL) when LPs remove liquidity
4. Automatically executing payouts when IL is detected

## Inspiration

HookSure adapts Andre Cronje's Protection Market model (designed for Uniswap v2) to work with Uniswap v4's hook system. The implementation uses v4 hooks to intercept liquidity addition/removal events, integrating protection directly in the position lifecycle rather than requiring separate protection contracts.

Original inspiration: [Protection Market by Andre Cronje](https://gist.github.com/andrecronje/6db9aa9873a37f9c69a6519448074690)

## Features

- **Dynamic Premiums**: Calculates premiums based on pool utilization metrics (0.5% base + utilization factor)
- **Configurable Risk Parameters**: Allows setting maximum payout limits per position and pool
- **Concentrated Liquidity Compatibility**: Implements IL calculations tuned for concentrated positions

## Technical Details

### Hook Integration

HookSure implements Uniswap v4's `BaseHook` and utilizes the following hook points:
- `afterAddLiquidity`: Records position details and collects premiums
- `afterRemoveLiquidity`: Calculates IL and executes payouts
- `afterSwap`: Tracks price changes within the pool

### Premium Calculation

Premiums are calculated using a dynamic formula based on:
- Base premium rate (0.5%)
- Pool utilization ratio
- Amount of liquidity added to a range

### Impermanent Loss Calculation

IL is calculated by comparing position values between entry and exit price:
- Uses the exact initial tick and final tick
- Applies concentrated liquidity-specific IL formula
- Limits payouts to configurable maximums

The IL calculation is based on the formula derived in [Impermanent Loss in Uniswap V3](https://medium.com/auditless/impermanent-loss-in-uniswap-v3-6c7161d3b445) by Peteris Erins, which specifically accounts for the amplified IL effect in concentrated liquidity positions.

### Coverage Limits

- `maxPayoutPerPosition`: Limits the payout for any single position (default 50% of protected amount)
- `maxTotalCoverage`: Caps the total coverage for a pool (default 1,000,000 tokens)