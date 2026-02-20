# DYBL-Crypto42

## Crypto42 v1.4

A 6-year breathing prediction game. Pick which 6 of 42 cryptocurrencies will outperform the rest each week. No VRF. No randomness. Pure skill.

50 code fixes + 16 documentation notes across 4 versions. 1,663 lines.

Built on the same pot engine as The Official Rug v1. Same Aave V3 yield, same OG endgame. Different game engine: Chainlink Price Feeds replace VRF.

## The Game

- Pick 6 cryptos from 42. Subscribe for weeks or years.
- Each week, all 42 prices are read from Chainlink Price Feeds.
- Top 6 performers by % gain = winning combo.
- Bitmask AND + popcount matches your picks against the winners.
- Match 3/4/5/6 pays out from tiered prize pools.
- Subscribe once, play for years.

## The 42 Cryptos (e.g.)

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
3. resolveWeek() reads all 42 Chainlink Price Feeds
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

JP miss weeks: 20% of that week's JP allocation overflows back to prizePot. Remaining 80% accumulates in jpReserve. Keeps tier prizes growing during long dry spells.

## Breathing Mechanic

- **Inhale (Years 1-5):** Pot builds. 75/25 split (pot/treasury). 1% weekly prize rate.
- **Exhale (Year 6):** OGs only. Prize rate auto-escalates 1% to 2.5%. Treasury taper declines linearly from 25% to 0% over 52 weeks. Pot split declines linearly.
- **Close:** Remaining pot split 80% to OGs, 20% to treasury. Game over.

## Oracle Resilience

Both oracle touchpoints are try/catch protected:

- _resolveWeek(): Dead/stale/paused feed = crypto disqualified (worst performance). Game continues.
- _snapshotStartPrices(): Dead feed stores 0. Resolve will disqualify. Game never stalls.
- Per-feed staleness thresholds. Each of 42 feeds matched to its actual Chainlink heartbeat (e.g. BTC 2hr, low-cap tokens 24hr). No single global constant.
- Performance calculated at 8 decimal precision (PRECISION_MULTIPLIER = 10^10). Ties near-impossible.
- If feeds stay dead > 8 weeks: dormancy triggers, pot pays out equally. Funds never stuck.

## Chainlink Services

- **Price Feeds:** 42 AggregatorV3Interface feeds (one per crypto). Owner-updatable via 7-day timelock. Anyone can execute after delay.
- **Automation:** Weekly resolveWeek() trigger + batch processing. All batch functions permissionless as fallback.
- **No VRF.** No subscription funding risk. No callback dependency.

## Security (v1.4)

### Owner Controls

Owner can do three things:

1. **commitToZeroRevenue()** - Set future date when treasury take drops to zero. One-time, irreversible.
2. **withdrawTreasury()** - Pull from treasury balance only. Capped at 20% per 30 days during exhale. Cannot touch prizePot, jpReserve, or unclaimed prizes.
3. **proposeFeedUpdate()** - Propose Chainlink feed change. 7-day public delay. Anyone can execute after timelock.

Owner cannot touch player funds, rig outcomes, stop the game, or prevent emergency recovery.

### Key Fixes (50 total, see contract header for full changelog)

- **S2-FIX-06:** Feed update timelock. 7-day delay, anyone can execute. (CRITICAL)
- **S2-FIX-11:** changePicks front-running prevention. Picks locked during matching/distributing. (CRITICAL)
- **S2-FIX-25/28/31:** Complete swap-and-pop perimeter. Every mutation path blocked during batch processing. (HIGH)
- **S2-FIX-34:** Per-feed staleness thresholds matching actual Chainlink heartbeats. (MEDIUM)
- **S2-FIX-36/39:** Pick lock window. 3-day freeze before resolution. Deferred start for new subs during lock. (MEDIUM)
- **S2-FIX-40:** Ownable2Step. renounceOwnership blocked. 6-year game cannot become headless. (MEDIUM)
- **S2-FIX-42:** Dead game rescue. Zero subs + zero OGs + 90 days = permissionless fund recovery. (MEDIUM)
- **S2-FIX-46:** Aave negative rebase waterfall. prizePot absorbs loss first, treasury second. (MEDIUM)
- **S2-FIX-50:** JP Overflow. 20% of missed JP allocation returns to prizePot. (MEDIUM)

### Unruggable by Design

- Owner CANNOT withdraw from prizePot
- All critical parameters are immutable constants
- commitToZeroRevenue(): one-shot, irreversible
- closeGame() callable by ANYONE after week 312 or time expiry
- emergencyResetDraw() and forceCompleteDistribution() permissionless after 14 days
- Treasury withdrawal capped at 20% per 30 days during exhale
- Dormancy: 8 weeks no draws = automatic equal pot payout to all subscribers
- Ownable2Step with renounceOwnership blocked

## Fuzz Tests

Foundry fuzz test suites verify the contract's highest-risk patterns. All tests are standalone harnesses that isolate the logic under test. No external dependencies.

### Swap-and-Pop (test/Crypto42SwapAndPop.t.sol)

Proves every active subscriber is matched exactly once across batched matchAndPopulate() calls, despite dynamic array mutations from expired subscriber removal.

7 tests, 70,000 randomized scenarios, 0 failures.

- Random subscriber counts with random expirations
- All subscribers expired (empty list edge case)
- Zero expirations (clean traversal)
- Consecutive expirations triggering chain-reaction removals
- Single subscriber (minimum viable case)
- 250 subscribers forcing 3+ batch boundary crossings
- Expire at position 0 (immediate swap-and-pop at cursor)

### Solvency Invariant (test/Crypto42Solvency.t.sol)

Proves prizePot + treasury + jpReserve + unclaimed + tiers + withdrawn always equals totalDeposited. No funds leak, appear, or vanish across any operation.

10 tests, 100,000 randomized scenarios, 0 failures.

- Full game lifecycle with random operations
- Subscription split at any week (inhale and exhale)
- Weekly draw tier allocation
- JP hit distribution and bonus redistribution
- JP overflow recirculation
- Aave negative rebase waterfall
- Dormancy equal distribution
- Full claim cycle
- Treasury withdrawal
- Exhale taper linear decline

### Run Locally

1. Install Foundry: https://book.getfoundry.sh
2. Clone this repo
3. Run: forge install foundry-rs/forge-std
4. Run: forge test --match-contract Crypto42SwapAndPopTest --fuzz-runs 10000 -vv
5. Run: forge test --match-contract Crypto42SolvencyTest --fuzz-runs 10000 -vv

## Gas (Base L2 at max capacity 55,555 users)

| Scenario | Per Week | Per Year | 6 Years |
|----------|----------|----------|---------|
| Low | $0.14 | $7 | $44 |
| Medium | $0.71 | $37 | $222 |
| High | $2.85 | $148 | $888 |

Gas is a rounding error against treasury revenue ($6.67M/year at max capacity).

## Contract

- **File:** Crypto42_v1.sol
- **Lines:** 1,663
- **Version:** v1.4 (50 code fixes + 16 documentation notes)
- **License:** BUSL-1.1 (MIT after May 2029)
- **Solidity:** 0.8.24

## Chain Agnostic

Constructor takes all external addresses. Deploy on any EVM L2 with:
- Aave V3 USDC pool
- 42 Chainlink Price Feeds for the listed cryptos

No hardcoded chain-specific addresses. Built for Base, Arbitrum, Optimism, Polygon, or any compatible L2.

## DYBL Foundation

Part of the DYBL protocol suite:
- [DYBL-Lettery-v1](https://github.com/DYBL777/DYBL-Lettery-v1) - Flagship lottery (42-char alphabet)
- [The-Eternal-Seed](https://github.com/DYBL777/The-Eternal-Seed) - TES primitive
- [Protocol-Protection-Layer](https://github.com/DYBL777/Protocol-Protection-Layer) - PPL v2.0
- **DYBL-Crypto42** - This repo. Skill-based prediction game.

No coin. No rug. No VC. No governance. No proxies. No upgrades. No admin key on player funds.
