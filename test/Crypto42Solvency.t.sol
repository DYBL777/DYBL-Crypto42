// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";

/**
 * @title Crypto42 Solvency Invariant Fuzz Test
 * @notice Proves: prizePot + treasury + jpReserve + unclaimed + tiers + withdrawn
 *         always equals totalDeposited. No funds leak, appear, or vanish.
 * @dev    Run: forge test --match-contract Crypto42SolvencyTest -vvv
 *         Fuzz: forge test --match-contract Crypto42SolvencyTest --fuzz-runs 10000 -vv
 */
contract SolvencyHarness {

    // Accounting buckets (mirrors Crypto42 exactly)
    uint256 public prizePot;
    uint256 public treasuryBalance;
    uint256 public jpReserve;
    uint256 public totalUnclaimedPrizes;
    uint256 public totalWithdrawn;
    uint256[3] public tierPayoutAmounts;

    // Tracking
    uint256 public totalDeposited;
    uint256 public currentWeek;
    uint256 public activeSubscribers;
    mapping(address => uint256) public unclaimedPrizes;

    // Constants (same as Crypto42)
    uint256 public constant POT_SPLIT_BPS = 7500;
    uint256 public constant TREASURY_SPLIT_BPS = 2500;
    uint256 public constant TIER_MATCH3_BPS = 2800;
    uint256 public constant TIER_MATCH4_BPS = 2000;
    uint256 public constant TIER_MATCH5_BPS = 1500;
    uint256 public constant TIER_JP_BPS = 2700;
    uint256 public constant JP_OVERFLOW_BPS = 2000;
    uint256 public constant JP_WINNER_BPS = 9000;
    uint256 public constant JP_WEEK_BONUS_BPS = 200;
    uint256 public constant PRIZE_RATE_BPS = 100;
    uint256 public constant INHALE_WEEKS = 260;
    uint256 public constant EXHALE_WEEKS = 52;

    // ── SUBSCRIBE: money enters the system ──────────────────────────
    function subscribe(uint256 amount) external {
        require(amount > 0 && amount <= 1e12, "bounded");
        totalDeposited += amount;
        activeSubscribers++;

        uint256 toTreasury;
        uint256 toPot;

        if (currentWeek <= INHALE_WEEKS) {
            toPot = amount * POT_SPLIT_BPS / 10000;
            toTreasury = amount - toPot;
        } else {
            uint256 exhaleWeek = currentWeek - INHALE_WEEKS;
            if (exhaleWeek >= EXHALE_WEEKS) {
                toPot = amount;
                toTreasury = 0;
            } else {
                uint256 taperBps = TREASURY_SPLIT_BPS * (EXHALE_WEEKS - exhaleWeek) / EXHALE_WEEKS;
                toTreasury = amount * taperBps / 10000;
                toPot = amount - toTreasury;
            }
        }

        prizePot += toPot;
        treasuryBalance += toTreasury;
    }

    // ── WEEKLY DRAW: pot splits into tiers + JP + seed ──────────────
    function startWeeklyDraw() external {
        require(prizePot > 0, "empty pot");
        // Return any undistributed tiers from previous draw (mirrors drawPhase guard)
        for (uint256 i = 0; i < 3; i++) {
            if (tierPayoutAmounts[i] > 0) {
                prizePot += tierPayoutAmounts[i];
                tierPayoutAmounts[i] = 0;
            }
        }
        uint256 weeklyPool = prizePot * PRIZE_RATE_BPS / 10000;
        if (weeklyPool == 0) return;
        prizePot -= weeklyPool;

        tierPayoutAmounts[0] = weeklyPool * TIER_MATCH3_BPS / 10000;
        tierPayoutAmounts[1] = weeklyPool * TIER_MATCH4_BPS / 10000;
        tierPayoutAmounts[2] = weeklyPool * TIER_MATCH5_BPS / 10000;

        uint256 toJP = weeklyPool * TIER_JP_BPS / 10000;
        jpReserve += toJP;

        uint256 toSeed = weeklyPool - tierPayoutAmounts[0] - tierPayoutAmounts[1]
                       - tierPayoutAmounts[2] - toJP;
        prizePot += toSeed;
    }

    // ── DISTRIBUTE TIER: tier amounts become unclaimed prizes ───────
    function distributeTier(uint8 tier, uint8 winnerCount) external {
        require(tier < 3, "invalid tier");
        uint256 wc = uint256(winnerCount);

        if (wc == 0) {
            // No winners: tier amount returns to pot
            prizePot += tierPayoutAmounts[tier];
            tierPayoutAmounts[tier] = 0;
            return;
        }

        uint256 tierAmount = tierPayoutAmounts[tier];
        uint256 perWinner = tierAmount / wc;
        uint256 dust = tierAmount - (perWinner * wc);

        for (uint256 i = 0; i < wc; i++) {
            address winner = address(uint160(0x2000 + tier * 1000 + i));
            unclaimedPrizes[winner] += perWinner;
            totalUnclaimedPrizes += perWinner;
        }

        if (dust > 0) prizePot += dust;
        tierPayoutAmounts[tier] = 0;
    }

    // ── JP HIT: jpReserve pays winners, seed returns to pot ─────────
    function jpHit(uint8 winnerCount) external {
        require(winnerCount > 0, "need winners");
        require(jpReserve > 0, "no JP");

        uint256 wc = uint256(winnerCount);
        uint256 winnerPayout = jpReserve * JP_WINNER_BPS / 10000;
        uint256 seedReturn = jpReserve - winnerPayout;
        uint256 perWinner = winnerPayout / wc;
        uint256 dust = winnerPayout - (perWinner * wc);

        for (uint256 i = 0; i < wc; i++) {
            address winner = address(uint160(0x5000 + i));
            unclaimedPrizes[winner] += perWinner;
            totalUnclaimedPrizes += perWinner;
        }

        prizePot += seedReturn + dust;

        // JP bonus to lower tiers (same as Crypto42)
        uint256 bonus = prizePot * JP_WEEK_BONUS_BPS / 10000;
        if (bonus > prizePot) bonus = prizePot;
        uint256 lowerTierTotal = TIER_MATCH3_BPS + TIER_MATCH4_BPS + TIER_MATCH5_BPS;
        uint256 m3Bonus = bonus * TIER_MATCH3_BPS / lowerTierTotal;
        uint256 m4Bonus = bonus * TIER_MATCH4_BPS / lowerTierTotal;
        uint256 m5Bonus = bonus - m3Bonus - m4Bonus;
        tierPayoutAmounts[0] += m3Bonus;
        tierPayoutAmounts[1] += m4Bonus;
        tierPayoutAmounts[2] += m5Bonus;
        prizePot -= bonus;

        jpReserve = 0;
    }

    // ── JP MISS: 20% overflows back to pot ──────────────────────────
    function jpOverflow(uint256 thisWeekJPAllocation) external {
        require(thisWeekJPAllocation <= jpReserve, "overflow > reserve");
        uint256 overflow = thisWeekJPAllocation * JP_OVERFLOW_BPS / 10000;
        if (overflow > jpReserve) overflow = jpReserve;
        jpReserve -= overflow;
        prizePot += overflow;
    }

    // ── CLAIM PRIZE: unclaimed becomes withdrawn ────────────────────
    function claimPrize(address user) external {
        uint256 amount = unclaimedPrizes[user];
        require(amount > 0, "nothing");
        unclaimedPrizes[user] = 0;
        totalUnclaimedPrizes -= amount;
        totalWithdrawn += amount;
    }

    // ── AAVE NEGATIVE REBASE: loss waterfall ────────────────────────
    function negativeRebase(uint256 loss) external {
        require(loss > 0 && loss <= totalDeposited, "bounded");
        totalDeposited -= loss;

        if (loss <= prizePot) {
            prizePot -= loss;
        } else {
            uint256 remainder = loss - prizePot;
            prizePot = 0;
            treasuryBalance -= remainder > treasuryBalance ? treasuryBalance : remainder;
        }
    }

    // ── YIELD: new money enters prizePot only ───────────────────────
    function yieldAccrued(uint256 amount) external {
        require(amount <= 1e12, "bounded");
        totalDeposited += amount;
        prizePot += amount;
    }

    // ── DORMANCY: pot splits equally to unclaimed ───────────────────
    function dormancy(uint8 subCount) external {
        require(subCount > 0, "no subs");
        uint256 sc = uint256(subCount);

        // JP folds into pot first
        prizePot += jpReserve;
        jpReserve = 0;

        // Return any stuck tier amounts
        for (uint256 i = 0; i < 3; i++) {
            prizePot += tierPayoutAmounts[i];
            tierPayoutAmounts[i] = 0;
        }

        uint256 perUser = prizePot / sc;
        for (uint256 i = 0; i < sc; i++) {
            address user = address(uint160(0x9000 + i));
            unclaimedPrizes[user] += perUser;
            totalUnclaimedPrizes += perUser;
        }

        uint256 distributed = perUser * sc;
        uint256 dust = prizePot - distributed;
        if (dust > 0) treasuryBalance += dust;
        prizePot = 0;
    }

    // ── TREASURY WITHDRAWAL: treasury becomes withdrawn ─────────────
    function withdrawTreasury(uint256 amount) external {
        require(amount > 0 && amount <= treasuryBalance, "bounded");
        treasuryBalance -= amount;
        totalWithdrawn += amount;
    }

    // ── ADVANCE WEEK ────────────────────────────────────────────────
    function advanceWeek() external {
        currentWeek++;
    }

    // ── THE INVARIANT ───────────────────────────────────────────────
    function checkSolvency() external view returns (bool) {
        uint256 totalAccounted = prizePot
            + treasuryBalance
            + jpReserve
            + totalUnclaimedPrizes
            + tierPayoutAmounts[0]
            + tierPayoutAmounts[1]
            + tierPayoutAmounts[2]
            + totalWithdrawn;
        return totalAccounted == totalDeposited;
    }

    function getAllBuckets() external view returns (
        uint256 pot, uint256 treasury, uint256 jp, uint256 unclaimed,
        uint256 tier0, uint256 tier1, uint256 tier2,
        uint256 withdrawn, uint256 deposited
    ) {
        return (
            prizePot, treasuryBalance, jpReserve, totalUnclaimedPrizes,
            tierPayoutAmounts[0], tierPayoutAmounts[1], tierPayoutAmounts[2],
            totalWithdrawn, totalDeposited
        );
    }
}

contract Crypto42SolvencyTest is Test {
    SolvencyHarness h;

    function setUp() public {
        h = new SolvencyHarness();
    }

    // ── FUZZ TEST 1: Full game lifecycle with random operations ─────
    function testFuzz_fullLifecycleSolvency(
        uint256 seed,
        uint8 numOps
    ) public {
        uint256 ops = bound(uint256(numOps), 5, 50);

        for (uint256 i = 0; i < ops; i++) {
            uint256 action = uint256(keccak256(abi.encode(seed, i))) % 6;
            uint256 param = uint256(keccak256(abi.encode(seed, i, "param")));

            if (action == 0) {
                // Subscribe
                uint256 amount = bound(param, 5e6, 500e6);
                h.subscribe(amount);
            } else if (action == 1) {
                // Weekly draw (only if pot has funds)
                try h.startWeeklyDraw() {} catch {}
            } else if (action == 2) {
                // Distribute a tier
                uint8 tier = uint8(param % 3);
                uint8 winners = uint8(bound(param >> 8, 0, 20));
                try h.distributeTier(tier, winners) {} catch {}
            } else if (action == 3) {
                // JP overflow
                if (h.jpReserve() > 0) {
                    uint256 jpAlloc = bound(param, 1, h.jpReserve());
                    try h.jpOverflow(jpAlloc) {} catch {}
                }
            } else if (action == 4) {
                // Yield accrual
                uint256 yield = bound(param, 1, 10e6);
                h.yieldAccrued(yield);
            } else {
                // Advance week
                h.advanceWeek();
            }

            assertTrue(h.checkSolvency(), "SOLVENCY BROKEN after operation");
        }
    }

    // ── FUZZ TEST 2: Subscribe always balances ──────────────────────
    function testFuzz_subscriptionSolvency(
        uint256 amount,
        uint8 weekNum
    ) public {
        uint256 amt = bound(amount, 5e6, 1000e6);
        uint256 numWeeks = bound(uint256(weekNum), 0, 312);
        for (uint256 i = 0; i < numWeeks; i++) { h.advanceWeek(); }
        h.subscribe(amt);
        assertTrue(h.checkSolvency(), "Subscribe broke solvency");
    }

    // ── FUZZ TEST 3: Weekly draw never leaks ────────────────────────
    function testFuzz_weeklyDrawSolvency(
        uint256 subAmount,
        uint8 numDraws
    ) public {
        uint256 amt = bound(subAmount, 100e6, 10000e6);
        h.subscribe(amt);

        uint256 draws = bound(uint256(numDraws), 1, 30);
        for (uint256 i = 0; i < draws; i++) {
            try h.startWeeklyDraw() {} catch { break; }
            assertTrue(h.checkSolvency(), "Draw broke solvency");

            // Distribute all tiers
            for (uint8 t = 0; t < 3; t++) {
                uint8 winners = uint8(uint256(keccak256(abi.encode(subAmount, i, t))) % 10);
                try h.distributeTier(t, winners) {} catch {}
                assertTrue(h.checkSolvency(), "Distribution broke solvency");
            }
        }
    }

    // ── FUZZ TEST 4: JP hit never leaks ─────────────────────────────
    function testFuzz_jpHitSolvency(
        uint256 subAmount,
        uint8 winnerCount
    ) public {
        uint256 amt = bound(subAmount, 1000e6, 50000e6);
        h.subscribe(amt);
        h.startWeeklyDraw();

        uint8 wc = uint8(bound(uint256(winnerCount), 1, 50));
        try h.jpHit(wc) {
            assertTrue(h.checkSolvency(), "JP hit broke solvency");
        } catch {}
    }

    // ── FUZZ TEST 5: JP overflow never leaks ────────────────────────
    function testFuzz_jpOverflowSolvency(
        uint256 subAmount,
        uint8 numWeeks
    ) public {
        uint256 amt = bound(subAmount, 1000e6, 50000e6);
        h.subscribe(amt);

        uint256 wks = bound(uint256(numWeeks), 1, 20);
        for (uint256 i = 0; i < wks; i++) {
            try h.startWeeklyDraw() {} catch { break; }

            // JP miss: overflow 20%
            if (h.jpReserve() > 0) {
                uint256 weeklyPool = h.prizePot() * PRIZE_RATE_BPS / 10000;
                uint256 jpAlloc = weeklyPool * TIER_JP_BPS / 10000;
                if (jpAlloc <= h.jpReserve()) {
                    try h.jpOverflow(jpAlloc) {} catch {}
                }
            }

            // Distribute tiers with no winners (return to pot)
            for (uint8 t = 0; t < 3; t++) {
                try h.distributeTier(t, 0) {} catch {}
            }

            assertTrue(h.checkSolvency(), "JP overflow broke solvency");
        }
    }

    uint256 constant PRIZE_RATE_BPS = 100;
    uint256 constant TIER_JP_BPS = 2700;

    // ── FUZZ TEST 6: Negative rebase waterfall ──────────────────────
    function testFuzz_negativeRebaseSolvency(
        uint256 subAmount,
        uint256 lossSeed
    ) public {
        uint256 amt = bound(subAmount, 1000e6, 50000e6);
        h.subscribe(amt);
        h.startWeeklyDraw();

        // Distribute some prizes so money is spread across buckets
        for (uint8 t = 0; t < 3; t++) {
            try h.distributeTier(t, 3) {} catch {}
        }

        (uint256 pot, uint256 treasury,,,,,,, uint256 deposited) = h.getAllBuckets();
        uint256 maxLoss = pot + treasury;
        if (maxLoss == 0) return;
        uint256 loss = bound(lossSeed, 1, maxLoss);
        h.negativeRebase(loss);
        assertTrue(h.checkSolvency(), "Negative rebase broke solvency");
    }

    // ── FUZZ TEST 7: Dormancy distribution ──────────────────────────
    function testFuzz_dormancySolvency(
        uint256 subAmount,
        uint8 subCount
    ) public {
        uint256 amt = bound(subAmount, 1000e6, 50000e6);
        h.subscribe(amt);

        // Run a draw to spread money into JP and tiers
        h.startWeeklyDraw();
        // Leave tiers and JP populated

        uint8 sc = uint8(bound(uint256(subCount), 1, 200));
        h.dormancy(sc);
        assertTrue(h.checkSolvency(), "Dormancy broke solvency");
    }

    // ── FUZZ TEST 8: Full claim cycle ───────────────────────────────
    function testFuzz_claimCycleSolvency(
        uint256 subAmount,
        uint8 winnerCount
    ) public {
        uint256 amt = bound(subAmount, 1000e6, 50000e6);
        h.subscribe(amt);
        h.startWeeklyDraw();

        uint8 wc = uint8(bound(uint256(winnerCount), 1, 20));
        for (uint8 t = 0; t < 3; t++) {
            try h.distributeTier(t, wc) {} catch {}
        }
        assertTrue(h.checkSolvency(), "Pre-claim solvency failed");

        // Claim all prizes
        for (uint8 t = 0; t < 3; t++) {
            for (uint256 i = 0; i < uint256(wc); i++) {
                address winner = address(uint160(0x2000 + uint256(t) * 1000 + i));
                try h.claimPrize(winner) {} catch {}
            }
        }
        assertTrue(h.checkSolvency(), "Post-claim solvency failed");
    }

    // ── FUZZ TEST 9: Treasury withdrawal ────────────────────────────
    function testFuzz_treasuryWithdrawSolvency(
        uint256 subAmount,
        uint256 withdrawSeed
    ) public {
        uint256 amt = bound(subAmount, 1000e6, 50000e6);
        h.subscribe(amt);

        uint256 treasury = h.treasuryBalance();
        if (treasury == 0) return;
        uint256 withdrawAmt = bound(withdrawSeed, 1, treasury);
        h.withdrawTreasury(withdrawAmt);
        assertTrue(h.checkSolvency(), "Treasury withdrawal broke solvency");
    }

    // ── FUZZ TEST 10: Exhale taper solvency ─────────────────────────
    function testFuzz_exhaleTaperSolvency(
        uint256 subAmount,
        uint8 exhaleWeek
    ) public {
        // Advance into exhale period
        uint256 targetWeek = bound(uint256(exhaleWeek), 1, 52);
        for (uint256 i = 0; i < 260 + targetWeek; i++) { h.advanceWeek(); }

        uint256 amt = bound(subAmount, 5e6, 1000e6);
        h.subscribe(amt);
        assertTrue(h.checkSolvency(), "Exhale subscribe broke solvency");

        // Verify taper is working: more to pot as exhale progresses
        (uint256 pot, uint256 treasury,,,,,,,) = h.getAllBuckets();
        assertTrue(pot > 0, "Pot should have funds");
        // At exhale week 52, treasury should be 0
        if (targetWeek >= 52) {
            assertEq(treasury, 0, "Treasury should be 0 at end of exhale");
        }
    }
}
