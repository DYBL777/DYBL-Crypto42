# DYBL-Crypto42

## Crypto42 v1.0

A 6-year breathing prediction game. Pick which 6 of 42 cryptocurrencies will outperform the rest each week. No VRF. No randomness. Pure skill.

Built on the same pot engine as The Official Rug v1. Same Aave V3 yield, same OG endgame. Different game engine: Chainlink Price Feeds replace VRF.

## The Game

- Pick 6 cryptos from 42. Subscribe for weeks or years.
- Each week, all 42 prices are read from Chainlink Price Feeds.
- Top 6 performers by % gain = winning combo.
- Bitmask AND + popcount matches your picks against the winners.
- Match 3/4/5/6 pays out from tiered prize pools.
- Subscribe once, play for years.

## The 42 Cryptos

| Index | Ticker | Index | Ticker | Index | Ticker | Index | Ticker |
|-------|--------|-------|--------|-------|--------|-------|--------|
| 0 | BTC | 11 | ATOM | 22 | COMP | 33 | AXS |
| 1 | ETH | 12 | NEAR | 23 | SUSHI | 34 | GALA |
| 2 | BNB | 13 | APT | 24 | DOGE | 35 | ENJ |
| 3 | SOL | 14 | ARB | 25 | SHIB | 36 | FET |
| 4 | XRP | 15 | OP | 26 | PEPE | 37 | RNDR |
| 5 | ADA | 16 | FIL | 27 | WIF | 38 | OCEAN |
| 6 | AVAX | 17 | LTC | 28 | BONK | 39 | AGIX |
| 7 | DOT | 18 | AAVE | 29 | FLOKI | 40 | INJ |
| 8 | LINK | 19 | MKR | 30 | IMX | 41 | TIA |
| 9 | MATIC | 20 | SNX | 31 | MANA | | |
| 10 | UNI | 21 | CRV | 32 | SAND | | |

42C6 = 5,245,786 possible combinations.

## How It Works

1. Players subscribe with 6 crypto picks (indices 0-41)
2. Week passes (7-day cooldown)
3. `resolveWeek()` reads all 42 Chainlink Price Feeds
4. Calculates % change from week start to week end (8 decimal precision)
5. Ranks all 42 by performance. Top 6 = winning combo
6. Tiebreaker: lower index wins (deterministic, known at deploy)
7. Bitmask matching against all subscriber picks (batched)
8. Prize distribution to Match 3/4/5/6 winners (batched)
9. Week finalizes, snapshots next week's start prices

No VRF. No randomness. No callback. No pending request. One synchronous resolve transaction.

## Prize Tiers (immutable)

| Tier | Share | Description |
|------|-------|-------------|
| Match 3 | 28% | "Got my ticket back" |
| Match 4 | 20% | "Dinner's on me" |
| Match 5 | 15% | "Holy shit" |
| Jackpot Reserve | 27% | Rolls over weekly until Match 6 hit |
| Seed | 10% | Returns to pot, compounds via Aave |

JP hit weeks: 90% to winner(s), 10% to seed. Seed drops to 8%, extra 2% to lower tiers.

## Breathing Mechanic

- **Inhale (Years 1-5):** Pot builds. 75/25 split (pot/treasury). 1% weekly prize rate.
- **Exhale (Year 6):** OGs only. Prize rate auto-escalates 1% to 2.5%. Pot split declines linearly.
- **Close:** Remaining pot split equally among OG addresses. Game over.

## Oracle Resilience

Both oracle touchpoints are try/catch protected:

- `_resolveWeek()`: Dead/stale/paused feed = crypto disqualified (worst performance). Game continues.
- `_snapshotStartPrices()`: Dead feed stores 0. Resolve will disqualify. Game never stalls.
- Performance calculated at 8 decimal precision (`PRECISION_MULTIPLIER = 10^10`). Ties near-impossible.
- If feeds stay dead > 8 weeks: dormancy triggers, pot pays out. Funds never stuck.

## Chainlink Services

- **Price Feeds:** 42 AggregatorV3Interface feeds (one per crypto). Owner-updatable for feed migrations.
- **Automation:** Weekly `resolveWeek()` trigger + batch processing. All batch functions permissionless as fallback.
- **No VRF.** No subscription funding risk. No callback dependency.

## Unruggable by Design

- Owner CANNOT withdraw from prizePot
- All critical parameters are immutable constants
- `commitToZeroRevenue()`: one-shot, irreversible
- `closeGame()` callable by ANYONE after grace period
- Treasury withdrawal capped at 20% per 30 days during exhale
- Dormancy: 8 weeks no draws = automatic pot payout to all subscribers
- Deploy owner as timelock/multisig for maximum transparency

## Security Patterns (from S1 audit)

- [S1 FIX-01] Percentage-based solvency tolerance (scale-safe)
- [S1 FIX-07] Constructor max approval
- [S1 FIX-08/09] lastSnapshotAUSDC updated after every Aave supply/withdrawal
- [S1 FIX-13] commitToZeroRevenue() one-shot irreversible
- [S1 FIX-14] _captureYield() called before every Aave supply/withdrawal
- ReentrancyGuard on all external state-changing functions
- Aave withdrawal try/catch with state restore on failure

## Chain Agnostic

Constructor takes all external addresses. Deploy on any EVM L2 with:
- Aave V3 USDC pool
- 42 Chainlink Price Feeds for the listed cryptos

No hardcoded chain-specific addresses. Built for Base, Arbitrum, Optimism, Polygon, or any compatible L2.

## Gas (Base L2 at max capacity 55,555 users)

| Scenario | Per Week | Per Year | 6 Years |
|----------|----------|----------|---------|
| Low | $0.14 | $7 | $44 |
| Medium | $0.71 | $37 | $222 |
| High | $2.85 | $148 | $888 |

Gas is a rounding error against treasury revenue ($6.67M/year at max capacity).

## Contract

- **File:** `Crypto42_v1.sol`
- **Lines:** 1,094
- **License:** BUSL-1.1 (MIT after May 2029)
- **Solidity:** ^0.8.24

## DYBL Foundation

Part of the DYBL protocol suite:
- [DYBL-Lettery-v1](https://github.com/DYBL/DYBL-Lettery-v1) - Flagship lottery (42-char alphabet)
- [The-Eternal-Seed](https://github.com/DYBL/The-Eternal-Seed) - TES primitive
- **DYBL-Crypto42** - This repo. Skill-based prediction game.

No coin. No rug. No VC. No governance. No proxies. No upgrades. No admin key on player funds.
