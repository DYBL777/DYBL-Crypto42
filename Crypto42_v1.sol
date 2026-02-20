// SPDX-License-Identifier: BUSL-1.1
// Licensed under the Business Source License 1.1
// Change Date: 10 May 2029
// On the Change Date, this code becomes available under MIT License.

pragma solidity 0.8.24;

/**
 * @title Crypto42 v1.4
 * @notice A 6-Year Breathing Prediction Game: Pick the Top 6 Performing Cryptos
 * @author DYBL Foundation
 * @dev Crypto42_v1.sol - Chainlink Price Feed Skill Game
 *      v1.0: Initial contract. 1,094 lines.
 *      v1.1: 21 pre-audit fixes (17 code + 4 documentation). See CHANGELOG.
 *      v1.2: Endgame architecture, charity integration, treasury taper. See CHANGELOG.
 *      v1.3: Charity removed, security fixes, NatSpec hardening. See CHANGELOG.
 *
 * BUILT ON: Crypto42 security patterns, yield handling,
 * and batch processing. Same pot mechanics. Different game engine.
 *
 * THE GAME:
 *   Pick 6 cryptos from 42. Each week, all 42 crypto prices are read from
 *   Chainlink Price Feeds. The 6 with the highest % gain = winning combo.
 *   Your picks are checked via bitmask AND + popcount. Same matching engine.
 *   NO VRF. NO RANDOMNESS. PURE SKILL.
 *
 *   Capped at 55,555 subscribers. $5 per ticket, max 2 per week.
 *   42C6 = 5,245,786 combinations. Same tier structure as the Rug game.
 *
 * HOW WEEKLY RESOLUTION WORKS:
 *   1. Previous week finalizes -> snapshots all 42 start prices from feeds
 *   2. Week passes (7 days minimum cooldown)
 *   3. resolveWeek() called: reads all 42 end prices from feeds
 *   4. Calculates % change: (endPrice - startPrice) * PRECISION_MULTIPLIER / startPrice
 *   5. Ranks all 42. Top 6 = winning combo.
 *   6. Tiebreaker: lower index wins (deterministic)
 *   7. Sets winningBitmask. Enters MATCHING. Synchronous. One tx.
 *
 * CHAINLINK SERVICES (NO VRF):
 *   Price Feeds: 42 AggregatorV3Interface feeds (one per crypto)
 *   Automation:  Weekly resolveWeek() trigger + batch processing
 *   Feed staleness: stale/dead feeds disqualified via try/catch. Game continues.
 *   If feeds stale > 8 weeks: dormancy activates. Funds never stuck.
 *
 * EVERYTHING ELSE: IDENTICAL TO LETTER BREATHE v1
 *   Revenue split, Aave V3 yield, OG qualification, dormancy, treasury,
 *   solvency, self-cleaning draws, swap-and-pop, batched matching,
 *   batched distribution, all S1 security patterns.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * CHANGELOG
 * ═══════════════════════════════════════════════════════════════════════
 *
 * S2-FIX-01  Oracle resilience: try/catch on _resolveWeek().
 *            One dead/stale/paused feed disqualifies that crypto.
 *            Game never stalls. (MEDIUM)
 *
 * S2-FIX-02  Oracle resilience: try/catch on _snapshotStartPrices().
 *            Dead feed at snapshot stores 0. resolveWeek disqualifies
 *            startPrice <= 0. Chain of resilience across both touchpoints. (MEDIUM)
 *
 * S2-FIX-03  Precision upgrade: PRECISION_MULTIPLIER 10000 -> 10^10.
 *            Matches Chainlink 8-decimal precision. Eliminates ties.
 *            Two cryptos must move identically to 0.00000001% to tie. (LOW)
 *
 * S2-FIX-04  Stale start price check in _snapshotStartPrices().
 *            Feed alive but stale at snapshot = stores 0 = disqualified.
 *            Prevents performance calculation built on bad data. (MEDIUM)
 *
 * S2-FIX-05  getCurrentPerformance() try/catch.
 *            One dead feed no longer reverts entire view function.
 *            Frontend leaderboard stays live. (LOW)
 *
 * S2-FIX-06  Feed update timelock: proposeFeedUpdate/executeFeedUpdate/
 *            cancelFeedUpdate. 7-day delay. Anyone can execute after
 *            timelock. Owner cannot silently swap feeds to rig outcomes.
 *            Replaces instant updatePriceFeed. (CRITICAL - trust surface)
 *
 * S2-FIX-07  Feed proposal overwrite prevention: AlreadyProposed error.
 *            Must cancel existing proposal before proposing new one for
 *            same index. Prevents silent clock resets. (LOW)
 *
 * S2-FIX-08  Permissionless emergency functions: emergencyResetDraw()
 *            and forceCompleteDistribution() no longer onlyOwner.
 *            14-day timeout IS the protection. If owner vanishes, anyone
 *            can unstick the game. (MEDIUM - decentralisation)
 *
 * S2-FIX-09  NatSpec on emergency functions explaining deliberate
 *            nonReentrant omission. No token transfers = no reentrancy
 *            surface. Documentation, not code change. (INFORMATIONAL)
 *
 * S2-FIX-10  extendSubscription game phase check: GameClosed revert.
 *            Prevents money being taken after closeGame() when no more
 *            draws will ever happen. (HIGH - fund loss)
 *
 * S2-FIX-11  changePicks / changePicksBoth front-running prevention:
 *            drawPhase must be IDLE. Attacker cannot read WeekResolved
 *            event and swap to winning combo before matching runs.
 *            (CRITICAL - direct fund theft)
 *
 * S2-FIX-12  Dormancy race condition closed: performUpkeep, triggerDraw,
 *            and checkUpkeep all check dormancyActive. No draw can start
 *            during dormancy batch processing. (LOW)
 *
 * S2-FIX-13  JP distribution double-bonus prevention: !jpHitThisWeek
 *            guard on JP block entry. Uncapped JP loop (all JP winners
 *            paid in one call). Bonus deducted once. (MEDIUM)
 *
 * S2-FIX-14  [SUPERSEDED by S2-FIX-20] Originally routed 100% to pot
 *            during exhale. Replaced with linear treasury taper.
 *            (MEDIUM - design correction)
 *
 * S2-FIX-15  Independent ticket matching: two tickets = two entries =
 *            two payouts. Same address can appear twice in winner arrays.
 *            distributePrizes handles naturally. Replaces best-of-two
 *            logic. (HIGH - design correction)
 *
 * S2-FIX-16  rescueAbandonedPot(): permissionless, callable after week
 *            312 with zero OGs and zero subs. Pot + JP reserve to
 *            treasury. Prevents permanent fund lock. (LOW)
 *
 * S2-FIX-17  Fixed exhale treasury cap: periodStartTreasuryBalance
 *            snapshots at period start. 20% cap consistent regardless
 *            of withdrawal pattern within 30-day period. (LOW)
 *
 * S2-DOC-01  Gas asymmetry: final distributePrizes batch triggers
 *            _finalizeWeek() with 42 feed reads. ~300-400k extra gas.
 *
 * S2-DOC-02  Degenerate combo: all feeds dead = [0,1,2,3,4,5].
 *            Deterministic, harmless. Dormancy at 8 weeks if persistent.
 *
 * S2-DOC-03  Treasury naming: getCurrentTreasuryTakeBps is a boolean
 *            gate (0 or 2500), not the actual treasury percentage.
 *
 * S2-DOC-04  Yield attribution: all Aave yield to prizePot only.
 *            Treasury and jpReserve get zero yield. Intentional.
 *
 * ─── v1.2 CHANGES ────────────────────────────────────────────────────
 *
 * S2-FIX-18  Endgame split: closeGame distributes 80% OGs, 20% treasury.
 *            Charity commitment is operational (from treasury), not
 *            enforced on-chain. (HIGH - design)
 *
 * S2-FIX-19  [REMOVED in v1.3] Charity wallet timelock removed. Charity
 *            will be handled off-chain from treasury allocation.
 *
 * S2-FIX-20  Treasury taper during exhale: treasury take declines linearly
 *            from 25% to 0% over 52 exhale weeks. Replaces 100%-to-pot.
 *            Smooth decline mirrors breathing mechanic. (MEDIUM - design)
 *
 * S2-FIX-21  rescueAbandonedPot time-based fallback: fires when real
 *            wall-clock time exceeds (TOTAL_WEEKS + CLOSE_GRACE_WEEKS),
 *            not just when currentWeek advances. Fixes fund lock when
 *            game dies mid-run and no draws advance the week counter.
 *            100% to treasury. (HIGH - fund lock prevention)
 *
 * S2-FIX-22  getPotHealth exhale accuracy: inflow calculation now reflects
 *            actual treasury taper during exhale instead of constant 75%
 *            pot split. Dashboard numbers match reality. (LOW)
 *
 * S2-FIX-23  [REMOVED in v1.3] charityBalance in solvency removed with
 *            charity code cleanup.
 *
 * S2-FIX-24  getEstimatedOGShare reflects 80% endgame split. Shows
 *            actual expected payout, not 100% of pot. (LOW)
 *
 * S2-DOC-05  Treasury taper NatSpec updated to reflect linear decline
 *            instead of full bypass during exhale.
 *
 * ─── v1.3 CHANGES ────────────────────────────────────────────────────
 *
 * S2-FIX-25  expireSubscription blocked during dormancy. Swap-and-pop
 *            during dormancy batch skips users behind the cursor.
 *            Direct fund loss for innocent subscribers. (HIGH)
 *
 * S2-FIX-26  triggerDormancy requires drawPhase == IDLE. Prevents
 *            dormancy firing while a draw is mid-flight, which would
 *            corrupt tierPayoutAmounts and prizePot. (MEDIUM)
 *
 * S2-FIX-27  Charity code removed entirely. Charity commitment is
 *            operational: 20% treasury includes charity allocation,
 *            wallet nominated before launch. Not enforced on-chain.
 *            Removed: charityWallet, charityBalance, PendingCharityWallet,
 *            proposeCharityWallet, executeCharityWallet, cancelCharityWallet,
 *            withdrawCharity, CHARITY_WALLET_DELAY, 3 errors, 4 events. (MEDIUM)
 *
 * S2-DOC-06  USDC blacklist risk documented on claimPrize. If Circle
 *            blacklists a winner, their prizes lock permanently.
 *            Mitigation deferred to audit team. (MEDIUM)
 *
 * S2-DOC-07  getCurrentPotSplitBps NatSpec: exhale return value not
 *            used for revenue routing. _processPayment uses treasury
 *            taper instead. (LOW)
 *
 * S2-DOC-08  OG continuous subscription design documented. Gap-year
 *            strategies possible under current code. Team/audit to
 *            decide if claimOGShare requires active sub at close. (LOW)
 *
 * S2-DOC-09  Dormancy NatSpec: intentionally bypasses 80/20 endgame
 *            split. No OGs exist in dormancy scenario. (INFO)
 *
 * S2-DOC-10  getCurrentPerformance staleness: view function does not
 *            check updatedAt. Cosmetic. _resolveWeek has own check. (INFO)
 *
 * S2-DOC-11  Changelog S2-FIX-14 annotated as superseded by S2-FIX-20.
 *            Was "100% to pot", now "linear taper". (INFO)
 *
 * S2-FIX-28  Dormancy guard on subscribe, subscribeDouble, extendSubscription.
 *            Same class as S2-FIX-25. New subscriber during dormancy batch
 *            increases activeSubscribers, causing underflow on completion.
 *            Complete dormancy perimeter: subscribe, subscribeDouble,
 *            extendSubscription, expireSubscription, triggerDraw,
 *            performUpkeep, closeGame. (HIGH)
 *
 * S2-FIX-29  Dormancy guard on closeGame. Dormancy distributing from
 *            prizePot while closeGame splits it = double-spend. (LOW)
 *
 * S2-FIX-30  Removed unused errors: StaleFeed, InvalidFeedPrice.
 *            Dead code since try/catch handles stale feeds. (INFO)
 *
 * S2-DOC-12  Pre-resolution pick changes documented as by design.
 *            Watching market mid-week and adjusting picks IS the skill
 *            game. Post-resolution front-running blocked by drawPhase
 *            check. Pre-resolution adaptation is gameplay. (INFO)
 *
 * S2-DOC-13  Dormancy vs OG interaction documented. Dormancy cannot
 *            fire while OGs exist: picks persist, triggerDraw is
 *            permissionless, active OG subscription keeps draws firing.
 *            Auto-picking unnecessary. Full dormancy-guarded function
 *            list documented. (INFO)
 *
 * S2-FIX-31  expireSubscription blocked during MATCHING/DISTRIBUTING.
 *            Swap-and-pop during matching moves last subscriber behind
 *            cursor, skipping them for prizes. matchAndPopulate handles
 *            expired users internally. (MEDIUM)
 *
 * S2-FIX-32  getContractState returns dormancyActive. Frontends need
 *            this to display game winding down state. (INFO)
 *
 * S2-DOC-14  ExhaleStarted event only fires from claimOGStatus. If
 *            first OG granted via _removeSubscriber or matchAndPopulate,
 *            event does not fire. Frontends should watch currentWeek. (INFO)
 *
 * S2-FIX-33  Pin compiler: ^0.8.24 -> 0.8.24. Standard production
 *            practice. No surprise compiler changes. (LOW)
 *
 * S2-FIX-34  Per-feed staleness thresholds. Replaces single constant
 *            with uint256[42] array. Set per-feed in constructor. Each
 *            feed matches its actual Chainlink heartbeat (e.g. BTC 2hr,
 *            low-cap tokens 24hr). Updated via feed timelock (newStaleness
 *            added to PendingFeedUpdate struct, applied atomically with
 *            new feed address). FeedUpdateProposed event includes
 *            newStaleness. getAllStalenessThresholds() view function
 *            added for frontend convenience. (MEDIUM - operational)
 *
 * S2-FIX-35  _removeSubscriber OG grant: added time check for consistency
 *            with claimOGStatus and matchAndPopulate. All three OG grant
 *            paths now require currentWeek >= startWeek + 208 - 1. (LOW)
 *
 * S2-FIX-36  Pick lock: PICK_LOCK_BEFORE_RESOLVE = 3 days. Picks frozen
 *            3 days before resolve window. Players get 4 days to analyse,
 *            then 3 days of commitment. Applied to: subscribe,
 *            subscribeDouble, changePicks, changePicksBoth. New subs
 *            also blocked during lock to prevent first-week front-running.
 *            Enforces prediction over copying the leaderboard. (MEDIUM)
 *
 * S2-FIX-37  FeedDisqualified event emitted in _snapshotStartPrices when
 *            storing 0. Uses uint8 reason code (1 = stale/invalid, 2 =
 *            dead/reverted). Gas-efficient vs string. (LOW)
 *
 * S2-FIX-38  closeGame decentralization: removed owner grace period.
 *            Previously only owner could call during weeks 313-316.
 *            Now anyone calls once currentWeek > 312 or time expires.
 *            CLOSE_GRACE_WEEKS retained for rescueAbandonedPot
 *            time-based fallback. (MEDIUM - trustlessness)
 *
 * S2-DOC-15  emergencyResetDraw NatSpec: documents that unprocessed
 *            winners lose current week prizes. Tier amounts return to
 *            pot. This is the cost of 14-day system failure. (INFO)
 *
 * S2-FIX-39  Subscribe during pick lock: deferred start week. Instead
 *            of blocking new subs, startWeek = currentWeek + 1. Subscriber
 *            pays from next week. matchAndPopulate skips deferred subs
 *            (startWeek > currentWeek). _addSubscriber takes explicit
 *            startWeek param. Prevents first-week front-running while
 *            keeping the door open for new players. (MEDIUM)
 *
 * S2-FIX-40  Ownable2Step. Two-step ownership transfer prevents loss
 *            to typo. renounceOwnership() overridden to revert. A 6-year
 *            game cannot become headless. (MEDIUM - safety)
 *
 * S2-FIX-41  Aave negative rebase. _captureYield deducts loss from
 *            prizePot instead of silently ignoring. Floors at zero.
 *            Keeps books honest if aUSDC balance drops. (LOW)
 *
 * S2-FIX-42  Dead game rescue shortcut. rescueAbandonedPot third path:
 *            zero subs + zero OGs + 90 days since last draw. Prevents
 *            funds sitting locked for 6 years in a game that died at
 *            week 50. (MEDIUM - fund recovery)
 *
 * S2-FIX-43  arePicksLocked() view function. Frontend convenience to
 *            check if pick lock window is active. (INFO)
 *
 * S2-FIX-44  Removed unused JP_SEED_BPS constant. Dead code. (INFO)
 *
 * S2-FIX-45  Non-OG deferred sub into exhale guard. If deferred
 *            startWeek > INHALE_WEEKS and user is not OG, revert NotOG.
 *            Prevents paying for weeks that would be skipped. (MEDIUM)
 *
 * S2-FIX-46  Aave negative rebase waterfall. prizePot absorbs loss
 *            first. If insufficient, remainder deducted from treasury.
 *            Prevents phantom solvency gap when prizePot is zero. (MEDIUM)
 *
 * S2-FIX-47  rescueAbandonedPot returns orphaned tier payouts to pot
 *            before rescue. If a draw was stuck, tierPayoutAmounts would
 *            be orphaned. Same pattern as emergencyResetDraw. (MEDIUM)
 *
 * S2-FIX-48  renounceOwnership uses dedicated RenounceDisabled error
 *            and pure override. InvalidAddress was misleading for
 *            monitoring tools. No onlyOwner needed for pure revert. (LOW)
 *
 * S2-FIX-49  Removed unused TIER_SEED_BPS constant. Seed is calculated
 *            as remainder (weeklyPool - tiers - JP). Dead code. (INFO)
 *
 * S2-DOC-16  NatSpec on seed remainder calculation. Documents that
 *            seed = 1000 BPS implicitly from remainder, not from a
 *            constant. Tier BPS: 2800+2000+1500+2700 = 9000. (INFO)
 *
 * S2-FIX-50  JP Overflow: when jackpot is not hit, 20% of that week's
 *            JP allocation overflows back to prizePot. Remaining 80%
 *            accumulates in jpReserve. Keeps tier prizes growing during
 *            long JP dry spells. New constant JP_OVERFLOW_BPS = 2000.
 *            New event JackpotOverflow. Applied in distributePrizes
 *            else block (JP miss path). (MEDIUM - game economics)
 *
 * Total: 50 code fixes + 16 documentation notes = 66 changes.
 * Lines: 1,094 (v1.0) -> 1,314 (v1.1) -> 1,457 (v1.2) -> 1,650 (v1.3) -> 1,663 (v1.4)
 * ═══════════════════════════════════════════════════════════════════════
 */

import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";

contract Crypto42 is Ownable2Step, ReentrancyGuard, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;

    error GameFull();
    error GameClosed();
    error DrawInProgress();
    error InvalidPickIndex();
    error DuplicatePick();
    error DuplicatePickSets();
    error InsufficientBalance();
    error InvalidAddress();
    error RenounceDisabled();
    error InvalidWeeks();
    error TooEarly();
    error NothingToClaim();
    error WrongPhase();
    error AaveLiquidityLow();
    error SolvencyCheckFailed();
    error NoActiveSubscribers();
    error CooldownActive();
    error ExceedsLimit();
    error NotSubscriber();
    error NotOG();
    error NotClosed();
    error AlreadyClaimed();
    error AlreadyOG();
    error AlreadySubscribed();
    error NotQualified();
    error AlreadyCommitted();
    error TooSoon();
    error ExhaleWithdrawalCap();
    error SubscriptionNotExpired();
    error ExceedsInhale();
    error WrongTicketCount();
    error NotStuck();
    error StartPricesNotCaptured();
    error NoPendingUpdate();
    error TimelockNotExpired();
    error AlreadyProposed();
    error DormancyInProgress();
    error GameNotAbandoned();
    error InvalidStaleness();
    error PicksLocked();

    enum DrawPhase { IDLE, MATCHING, DISTRIBUTING }
    enum GamePhase { INHALE, EXHALE, CLOSED }

    struct Subscription {
        uint8[6] picks1;
        uint8[6] picks2;
        uint64 pickBitmask1;
        uint64 pickBitmask2;
        uint256 startWeek;
        uint256 endWeek;
        uint256 listIndex;
        uint8 ticketsPerWeek;
        bool active;
    }

    // Immutables
    address public immutable USDC;
    address public immutable aUSDC;
    address public immutable AAVE_POOL;
    uint256 public immutable DEPLOY_TIMESTAMP;

    // Chainlink Price Feeds (owner-updatable for feed migrations)
    AggregatorV3Interface[42] public priceFeeds;

    // Prize rate
    uint256 public constant PRIZE_RATE_BPS = 100;
    uint256 public constant PRIZE_RATE_CEILING = 250;
    uint256 public zeroRevenueTimestamp;
    bool public zeroRevenueActive;

    // Display tickers
    string[42] public CRYPTO_TICKERS = [
        "BTC","ETH","BNB","SOL","XRP","ADA","AVAX","DOT",
        "LINK","MATIC","UNI","ATOM","NEAR","APT","ARB","OP",
        "FIL","LTC","AAVE","MKR","SNX","CRV","COMP","SUSHI",
        "DOGE","SHIB","PEPE","WIF","BONK","FLOKI","IMX","MANA",
        "SAND","AXS","GALA","ENJ","FET","RNDR","OCEAN","AGIX",
        "INJ","TIA"
    ];

    // Constants (identical to Crypto42)
    uint256 public constant MAX_USERS = 55_555;
    uint256 public constant TICKET_PRICE = 5e6;
    uint256 public constant PICK_COUNT = 6;
    uint256 public constant POOL_SIZE = 42;
    uint256 public constant MAX_TICKETS_PER_WEEK = 2;
    uint256 public constant INHALE_WEEKS = 260;
    uint256 public constant EXHALE_WEEKS = 52;
    uint256 public constant TOTAL_WEEKS = 312;
    uint256 public constant CLOSE_GRACE_WEEKS = 4;
    uint256 public constant POT_SPLIT_BPS = 7500;
    uint256 public constant TREASURY_SPLIT_BPS = 2500;
    uint256 public constant TIER_MATCH3_BPS = 2800;
    uint256 public constant TIER_MATCH4_BPS = 2000;
    uint256 public constant TIER_MATCH5_BPS = 1500;
    uint256 public constant TIER_JP_BPS = 2700;
    /// @dev Seed is not a constant. It is the remainder after tiers + JP allocation.
    ///      10000 - 2800 match3 - 2000 match4 - 1500 match5 - 2700 JP = 1000 BPS seed.
    ///      Calculated as: weeklyPool - tier0 - tier1 - tier2 - jpAlloc.
    uint256 public constant JP_WEEK_BONUS_BPS = 200;
    uint256 public constant JP_WINNER_BPS = 9000;
    /// @dev When JP is not hit, 20% of that week's JP allocation overflows back
    ///      to prizePot. Remaining 80% accumulates in jpReserve as normal.
    ///      Keeps tier prizes growing even during long JP dry spells.
    uint256 public constant JP_OVERFLOW_BPS = 2000;            // 20% overflow to prizePot on JP miss
    /// @dev OG status requires a single unbroken subscription of 208+ weeks.
    ///      If a subscriber lapses and resubscribes, startWeek resets. Their
    ///      prior history is lost. isOG is permanent once granted. Design intent:
    ///      OGs should maintain continuous subscription for the full game lifecycle.
    ///      Gap-year strategies (OG at week 208, lapse year 5, return for exhale)
    ///      are possible under current code. Team/audit to decide if claimOGShare
    ///      should additionally require active subscription at close time.
    uint256 public constant OG_WEEKS_REQUIRED = 208;
    uint256 public constant OG_CLAIM_EARLY_WEEKS = 4;
    uint256 public constant MAX_PROCESS_PER_TX = 100;
    uint256 public constant MAX_PAYOUTS_PER_TX = 100;
    uint256 public constant DRAW_COOLDOWN = 7 days;
    uint256 public constant DRAW_STUCK_TIMEOUT = 14 days;
    uint256 public constant PICK_LOCK_BEFORE_RESOLVE = 3 days;  // picks frozen 3 days before resolution window opens
    uint256 public constant EXHALE_TREASURY_CAP_BPS = 2000;
    uint256 public constant EXHALE_TREASURY_PERIOD = 30 days;
    uint256 public constant OG_CLAIM_DEADLINE = 90 days;
    uint256 public constant DORMANCY_THRESHOLD = 8 weeks;
    uint256 public constant SOLVENCY_FLOOR = 10000;
    uint256[42] public feedStalenessThresholds;                 // per-feed staleness, set in constructor, updatable via feed timelock
    uint256 public constant PRECISION_MULTIPLIER = 10_000_000_000; // 8 decimal places, matches Chainlink feed precision
    uint256 public constant FEED_UPDATE_DELAY = 7 days;         // timelock on feed changes, visible on-chain before execution
    /// @dev Endgame split: 80% to OGs, 20% to treasury. The 20% treasury
    ///      allocation includes a commitment to direct funds to a nominated
    ///      charity wallet. Charity wallet will be published before launch.
    ///      This is an operational commitment, not enforced on-chain.
    uint256 public constant ENDGAME_OG_BPS = 8000;             // 80% to OGs at closeGame
    uint256 public constant ENDGAME_TREASURY_BPS = 2000;       // 20% to treasury at closeGame

    // State
    uint256 public prizePot;
    uint256 public treasuryBalance;
    uint256 public jpReserve;
    uint256 public totalUnclaimedPrizes;
    uint256 public currentWeek;
    uint256 public lastDrawTimestamp;
    uint256 public lastResolveTimestamp;
    uint256 public activeSubscribers;
    bool public finalDistributionDone;
    uint256 public closeTimestamp;
    bool public jpHitThisWeek;
    DrawPhase public drawPhase;
    bool public matchingInProgress;
    uint256 public matchingIndex;
    uint256 public distributionTierIndex;
    uint256 public distributionWinnerIndex;
    uint256 public totalWinnersThisDraw;
    uint64 public winningBitmask;
    uint256 public lastSnapshotAUSDC;
    uint256[3] public tierPayoutAmounts;
    uint256 public lastTreasuryWithdrawTimestamp;
    uint256 public treasuryWithdrawnThisPeriod;
    uint256 public periodStartTreasuryBalance;
    uint256 public lastWeekActiveTickets;
    int256[42] public weekStartPrices;
    bool public startPricesCaptured;

    // Feed update timelock: owner proposes, 7-day delay, anyone executes
    struct PendingFeedUpdate {
        address newFeed;
        uint256 newStaleness;
        uint256 executeAfter;
    }
    mapping(uint256 => PendingFeedUpdate) public pendingFeedUpdates;

    // Subscriber storage
    address[] public subscriberList;
    mapping(address => Subscription) public subscriptions;
    mapping(address => uint256) public unclaimedPrizes;
    mapping(address => uint256) public totalPrizesWon;
    mapping(address => bool) public isOG;
    uint256 public totalOGs;
    mapping(address => bool) public ogShareClaimed;
    uint256 public ogShareAmount;
    bool public dormancyActive;
    uint256 public dormancyPerUser;
    uint256 public dormancyProcessed;

    struct WeeklyResult {
        uint8[6] combo;
        address[] jackpotWinners;
        address[] match5;
        address[] match4;
        address[] match3;
        bool jpHit;
        uint256 jpPayout;
        uint256 prizePool;
    }
    mapping(uint256 => WeeklyResult) public weeklyResults;

    // Events
    event Subscribed(address indexed user, uint256 startWeek, uint256 endWeek, uint8 ticketsPerWeek, uint256 totalCost);
    event SubscriptionExtended(address indexed user, uint256 newEndWeek, uint256 additionalCost);
    event SubscriptionExpired(address indexed user, uint256 endedAtWeek);
    event PicksChanged(address indexed user, uint8[6] picks1, uint8[6] picks2);
    event WeekResolved(uint256 indexed week, uint8[6] topPerformers);
    event WinnerSelected(address indexed winner, uint256 amount, uint256 matchLevel);
    event JackpotHit(uint256 indexed week, uint256 totalPayout, uint256 numWinners, uint256 seedReturn);
    event JackpotRollover(uint256 indexed week, uint256 reserveTotal);
    event JackpotOverflow(uint256 indexed week, uint256 overflowAmount, uint256 remainingReserve);
    event JackpotBonusApplied(uint256 indexed week, uint256 bonusAmount);
    event PrizeClaimed(address indexed winner, uint256 amount);
    event SeedReturned(uint256 indexed week, uint256 amount);
    event MatchingComplete(uint256 indexed week, uint256 totalWinners, uint256 activeTickets);
    event MatchingBatchProcessed(uint256 indexed week, uint256 processed, uint256 total);
    event DistributionComplete(uint256 indexed week);
    event TierPayoutDeferred(uint256 indexed week, uint256 tier, uint256 amount);
    event WeekFinalized(uint256 indexed week);
    event OGStatusClaimed(address indexed user, uint256 duration);
    /// @dev ExhaleStarted only fires from claimOGStatus when totalOGs reaches 1.
    ///      If the first OG is granted via _removeSubscriber or matchAndPopulate,
    ///      this event does not fire. Frontends should watch currentWeek crossing
    ///      INHALE_WEEKS rather than relying solely on this event.
    event ExhaleStarted(uint256 indexed week, uint256 potAtStart);
    event FinalDistribution(uint256 remainingPot, uint256 totalOGs, uint256 perOGShare);
    event OGShareClaimed(address indexed og, uint256 amount);
    event UnclaimedOGSharesSwept(uint256 amount, uint256 newTreasuryBalance);
    event TreasuryWithdrawal(uint256 amount, address recipient);
    event DrawReset(uint256 indexed week, string reason);
    event EmergencyReset(uint256 indexed week, DrawPhase fromPhase, string reason);
    event PriceFeedUpdated(uint256 indexed cryptoIndex, address oldFeed, address newFeed);
    event FeedUpdateProposed(uint256 indexed cryptoIndex, address newFeed, uint256 newStaleness, uint256 executeAfter);
    event FeedUpdateCancelled(uint256 indexed cryptoIndex);
    event ZeroRevenueCommitted(uint256 targetTimestamp);
    event TreasuryTakeZeroed();
    event StartPricesSnapshotted(uint256 indexed week);
    /// @dev reason: 1 = stale or invalid price at snapshot, 2 = feed dead or reverted
    event FeedDisqualified(uint256 indexed cryptoIndex, uint8 reason);
    event EndgameDistribution(uint256 toOGs, uint256 toTreasury);

    constructor(
        address[42] memory _priceFeeds,
        uint256[42] memory _stalenessThresholds,
        address _usdc,
        address _aavePool,
        address _aUSDC
    ) Ownable(msg.sender) {
        if (_usdc == address(0)) revert InvalidAddress();
        if (_aavePool == address(0)) revert InvalidAddress();
        if (_aUSDC == address(0)) revert InvalidAddress();
        for (uint256 i = 0; i < 42; i++) {
            if (_priceFeeds[i] == address(0)) revert InvalidAddress();
            if (_stalenessThresholds[i] == 0) revert InvalidStaleness();
            priceFeeds[i] = AggregatorV3Interface(_priceFeeds[i]);
            feedStalenessThresholds[i] = _stalenessThresholds[i];
        }
        USDC = _usdc;
        AAVE_POOL = _aavePool;
        aUSDC = _aUSDC;
        DEPLOY_TIMESTAMP = block.timestamp;
        lastDrawTimestamp = block.timestamp;
        drawPhase = DrawPhase.IDLE;
        currentWeek = 1;
        IERC20(_usdc).approve(_aavePool, type(uint256).max);
        _snapshotStartPrices();
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // GAME PHASE LOGIC (identical to Crypto42)
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function getGamePhase() public view returns (GamePhase) {
        if (finalDistributionDone) return GamePhase.CLOSED;
        if (currentWeek > INHALE_WEEKS) return GamePhase.EXHALE;
        return GamePhase.INHALE;
    }

    /// @notice Returns the pot split BPS for prize distribution calculation.
    ///         During exhale, _processPayment uses a separate treasury taper
    ///         (TREASURY_SPLIT_BPS declining to 0). This function's exhale
    ///         return value is not used for revenue routing.
    function getCurrentPotSplitBps() public view returns (uint256) {
        if (currentWeek <= INHALE_WEEKS) return POT_SPLIT_BPS;
        uint256 exhaleWeek = currentWeek - INHALE_WEEKS;
        if (exhaleWeek >= EXHALE_WEEKS) return 0;
        return POT_SPLIT_BPS * (EXHALE_WEEKS - exhaleWeek) / EXHALE_WEEKS;
    }

    function getEffectivePrizeRateBps() public view returns (uint256) {
        if (currentWeek <= INHALE_WEEKS) return PRIZE_RATE_BPS;
        uint256 exhaleWeek = currentWeek - INHALE_WEEKS;
        uint256 effective = PRIZE_RATE_BPS + (exhaleWeek * 5);
        return effective > PRIZE_RATE_CEILING ? PRIZE_RATE_CEILING : effective;
    }

    /// @notice Returns the treasury take rate as a boolean gate (0 or 2500).
    ///         During normal operation the actual treasury allocation is
    ///         (10000 - getCurrentPotSplitBps()) applied to subscription revenue.
    ///         This function controls WHETHER treasury takes, not HOW MUCH.
    ///         During exhale, treasury take tapers linearly from 25% to 0%
    ///         over 52 weeks (calculated in _processPayment, not here).
    function getCurrentTreasuryTakeBps() public view returns (uint256) {
        if (zeroRevenueActive) return 0;
        if (zeroRevenueTimestamp != 0 && block.timestamp >= zeroRevenueTimestamp) return 0;
        return TREASURY_SPLIT_BPS;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // AAVE YIELD CAPTURE (S1 FIX-14)
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @notice All Aave yield accrues to prizePot. Treasury and jpReserve do not
    ///         grow from yield. This is intentional: treasury is funded from
    ///         subscription revenue only. Yield benefits players exclusively.
    function _captureYield() internal {
        uint256 currentAUSDC = IERC20(aUSDC).balanceOf(address(this));
        if (lastSnapshotAUSDC == 0) { lastSnapshotAUSDC = currentAUSDC; return; }
        if (currentAUSDC < lastSnapshotAUSDC) {
            // Aave negative rebase (extremely rare). Waterfall: prizePot first, treasury second.
            uint256 loss = lastSnapshotAUSDC - currentAUSDC;
            if (loss <= prizePot) {
                prizePot -= loss;
            } else {
                uint256 remainder = loss - prizePot;
                prizePot = 0;
                treasuryBalance -= remainder > treasuryBalance ? treasuryBalance : remainder;
            }
            lastSnapshotAUSDC = currentAUSDC;
            return;
        }
        if (currentAUSDC == lastSnapshotAUSDC) return;
        prizePot += currentAUSDC - lastSnapshotAUSDC;
        lastSnapshotAUSDC = currentAUSDC;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // SUBSCRIBE: 1 TICKET PER WEEK
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function subscribe(uint8[6] calldata picks, uint256 weeks) external nonReentrant {
        if (dormancyActive) revert DormancyInProgress();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (getGamePhase() == GamePhase.CLOSED) revert GameClosed();
        if (weeks == 0) revert InvalidWeeks();
        if (getGamePhase() == GamePhase.EXHALE && !isOG[msg.sender]) revert NotOG();
        _validatePicks(picks);

        Subscription storage sub = subscriptions[msg.sender];
        if (sub.active) revert AlreadySubscribed();

        // Deferred start: if subscribing during pick lock, first playable week is next week.
        // Prevents first-week front-running with near-complete price data.
        bool duringLock = block.timestamp >= lastDrawTimestamp + DRAW_COOLDOWN - PICK_LOCK_BEFORE_RESOLVE;
        uint256 startWeek = duringLock ? currentWeek + 1 : currentWeek;
        if (startWeek > INHALE_WEEKS && !isOG[msg.sender]) revert NotOG();
        uint256 maxWeek = isOG[msg.sender] ? TOTAL_WEEKS : INHALE_WEEKS;
        if (startWeek > maxWeek) revert ExceedsInhale();
        uint256 endWeek = startWeek + weeks - 1;
        if (endWeek > maxWeek) { endWeek = maxWeek; weeks = endWeek - startWeek + 1; }

        uint256 totalCost = weeks * TICKET_PRICE;
        _processPayment(msg.sender, totalCost);

        uint64 mask1 = _toBitmask(picks);
        uint8[6] memory empty;
        _addSubscriber(msg.sender, picks, empty, mask1, 0, startWeek, endWeek, 1);
        emit Subscribed(msg.sender, startWeek, endWeek, 1, totalCost);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // SUBSCRIBE: 2 TICKETS PER WEEK
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function subscribeDouble(uint8[6] calldata picks1, uint8[6] calldata picks2, uint256 weeks) external nonReentrant {
        if (dormancyActive) revert DormancyInProgress();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (getGamePhase() == GamePhase.CLOSED) revert GameClosed();
        if (weeks == 0) revert InvalidWeeks();
        if (getGamePhase() == GamePhase.EXHALE && !isOG[msg.sender]) revert NotOG();
        _validatePicks(picks1);
        _validatePicks(picks2);
        if (_toBitmask(picks1) == _toBitmask(picks2)) revert DuplicatePickSets();

        Subscription storage sub = subscriptions[msg.sender];
        if (sub.active) revert AlreadySubscribed();

        bool duringLock = block.timestamp >= lastDrawTimestamp + DRAW_COOLDOWN - PICK_LOCK_BEFORE_RESOLVE;
        uint256 startWeek = duringLock ? currentWeek + 1 : currentWeek;
        if (startWeek > INHALE_WEEKS && !isOG[msg.sender]) revert NotOG();
        uint256 maxWeek = isOG[msg.sender] ? TOTAL_WEEKS : INHALE_WEEKS;
        if (startWeek > maxWeek) revert ExceedsInhale();
        uint256 endWeek = startWeek + weeks - 1;
        if (endWeek > maxWeek) { endWeek = maxWeek; weeks = endWeek - startWeek + 1; }

        uint256 totalCost = weeks * TICKET_PRICE * 2;
        _processPayment(msg.sender, totalCost);

        uint64 mask1 = _toBitmask(picks1);
        uint64 mask2 = _toBitmask(picks2);
        _addSubscriber(msg.sender, picks1, picks2, mask1, mask2, startWeek, endWeek, 2);
        emit Subscribed(msg.sender, startWeek, endWeek, 2, totalCost);
    }

    function extendSubscription(uint256 additionalWeeks) external nonReentrant {
        if (dormancyActive) revert DormancyInProgress();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (getGamePhase() == GamePhase.CLOSED) revert GameClosed();
        if (additionalWeeks == 0) revert InvalidWeeks();
        Subscription storage sub = subscriptions[msg.sender];
        if (!sub.active) revert NotSubscriber();
        uint256 newEndWeek = sub.endWeek + additionalWeeks;
        uint256 maxWeek = isOG[msg.sender] ? TOTAL_WEEKS : INHALE_WEEKS;
        if (newEndWeek > maxWeek) {
            newEndWeek = maxWeek;
            additionalWeeks = maxWeek - sub.endWeek;
            if (additionalWeeks == 0) revert ExceedsInhale();
        }
        uint256 totalCost = additionalWeeks * TICKET_PRICE * uint256(sub.ticketsPerWeek);
        _processPayment(msg.sender, totalCost);
        sub.endWeek = newEndWeek;
        emit SubscriptionExtended(msg.sender, newEndWeek, totalCost);
    }

    /// @notice Changing picks while drawPhase == IDLE (before resolution) is by design.
    ///         This is a skill-based prediction game. Watching market movements mid-week
    ///         and adjusting picks is the core gameplay loop. Post-resolution front-running
    ///         is blocked by the drawPhase check. Pre-resolution adaptation is skill.
    ///         Picks lock PICK_LOCK_BEFORE_RESOLVE (3 days) before the resolve window
    ///         opens. Players get 4 days to analyse and adjust, then 3 days of commitment.
    ///         If a draw is delayed (Automation down), the lock persists until the
    ///         delayed draw fires. This is correct: resolution is overdue and imminent.
    function changePicks(uint8[6] calldata newPicks) external {
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (block.timestamp >= lastDrawTimestamp + DRAW_COOLDOWN - PICK_LOCK_BEFORE_RESOLVE) revert PicksLocked();
        Subscription storage sub = subscriptions[msg.sender];
        if (!sub.active) revert NotSubscriber();
        _validatePicks(newPicks);
        if (sub.ticketsPerWeek == 2) {
            if (_toBitmask(newPicks) == sub.pickBitmask2) revert DuplicatePickSets();
        }
        sub.picks1 = newPicks;
        sub.pickBitmask1 = _toBitmask(newPicks);
        emit PicksChanged(msg.sender, newPicks, sub.picks2);
    }

    function changePicksBoth(uint8[6] calldata newPicks1, uint8[6] calldata newPicks2) external {
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (block.timestamp >= lastDrawTimestamp + DRAW_COOLDOWN - PICK_LOCK_BEFORE_RESOLVE) revert PicksLocked();
        Subscription storage sub = subscriptions[msg.sender];
        if (!sub.active) revert NotSubscriber();
        if (sub.ticketsPerWeek != 2) revert WrongTicketCount();
        _validatePicks(newPicks1);
        _validatePicks(newPicks2);
        if (_toBitmask(newPicks1) == _toBitmask(newPicks2)) revert DuplicatePickSets();
        sub.picks1 = newPicks1;
        sub.picks2 = newPicks2;
        sub.pickBitmask1 = _toBitmask(newPicks1);
        sub.pickBitmask2 = _toBitmask(newPicks2);
        emit PicksChanged(msg.sender, newPicks1, newPicks2);
    }

    function expireSubscription(address user) external {
        if (dormancyActive) revert DormancyInProgress();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        Subscription storage sub = subscriptions[user];
        if (!sub.active) revert NotSubscriber();
        if (sub.endWeek >= currentWeek) revert SubscriptionNotExpired();
        _removeSubscriber(user);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // INTERNAL: PAYMENT + SUBSCRIBER MANAGEMENT (identical to Crypto42)
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function _processPayment(address user, uint256 totalCost) internal {
        _captureYield();
        IERC20(USDC).safeTransferFrom(user, address(this), totalCost);
        IPool(AAVE_POOL).supply(USDC, totalCost, address(this), 0);
        lastSnapshotAUSDC = IERC20(aUSDC).balanceOf(address(this));
        if (!zeroRevenueActive && zeroRevenueTimestamp != 0 && block.timestamp >= zeroRevenueTimestamp) {
            zeroRevenueActive = true;
            emit TreasuryTakeZeroed();
        }
        uint256 treasuryTakeBps = getCurrentTreasuryTakeBps();
        uint256 toPot;
        uint256 toTreasury;
        if (treasuryTakeBps == 0) {
            toPot = totalCost; toTreasury = 0;
        } else if (getGamePhase() == GamePhase.EXHALE) {
            uint256 exhaleWeek = currentWeek - INHALE_WEEKS;
            if (exhaleWeek >= EXHALE_WEEKS) {
                toPot = totalCost; toTreasury = 0;
            } else {
                uint256 taperBps = TREASURY_SPLIT_BPS * (EXHALE_WEEKS - exhaleWeek) / EXHALE_WEEKS;
                toTreasury = totalCost * taperBps / 10000;
                toPot = totalCost - toTreasury;
            }
        } else {
            uint256 potSplitBps = getCurrentPotSplitBps();
            toPot = totalCost * potSplitBps / 10000;
            toTreasury = totalCost - toPot;
        }
        prizePot += toPot;
        treasuryBalance += toTreasury;
    }

    function _addSubscriber(address user, uint8[6] memory p1, uint8[6] memory p2, uint64 mask1, uint64 mask2, uint256 startWeek, uint256 endWeek, uint8 ticketsPerWeek) internal {
        if (activeSubscribers >= MAX_USERS) revert GameFull();
        subscriberList.push(user);
        Subscription storage sub = subscriptions[user];
        sub.picks1 = p1; sub.picks2 = p2;
        sub.pickBitmask1 = mask1; sub.pickBitmask2 = mask2;
        sub.startWeek = startWeek; sub.endWeek = endWeek;
        sub.listIndex = subscriberList.length;
        sub.active = true; sub.ticketsPerWeek = ticketsPerWeek;
        activeSubscribers++;
    }

    function _removeSubscriber(address user) internal {
        Subscription storage sub = subscriptions[user];
        uint256 idx = sub.listIndex - 1;
        if (!isOG[user] && sub.startWeek > 0) {
            uint256 duration = sub.endWeek - sub.startWeek + 1;
            if (duration >= OG_WEEKS_REQUIRED && currentWeek >= sub.startWeek + OG_WEEKS_REQUIRED - 1) {
                isOG[user] = true; totalOGs++;
                emit OGStatusClaimed(user, duration);
            }
        }
        uint256 lastIdx = subscriberList.length - 1;
        if (idx != lastIdx) {
            address lastUser = subscriberList[lastIdx];
            subscriberList[idx] = lastUser;
            subscriptions[lastUser].listIndex = idx + 1;
        }
        subscriberList.pop();
        sub.listIndex = 0; sub.active = false;
        activeSubscribers--;
        emit SubscriptionExpired(user, sub.endWeek);
    }

    function claimOGStatus() external {
        if (isOG[msg.sender]) revert AlreadyOG();
        if (currentWeek < INHALE_WEEKS - OG_CLAIM_EARLY_WEEKS) revert TooEarly();
        Subscription storage sub = subscriptions[msg.sender];
        if (sub.startWeek == 0) revert NotQualified();
        uint256 duration = sub.endWeek - sub.startWeek + 1;
        if (duration < OG_WEEKS_REQUIRED) revert NotQualified();
        if (currentWeek < sub.startWeek + OG_WEEKS_REQUIRED - 1) revert TooEarly();
        isOG[msg.sender] = true; totalOGs++;
        emit OGStatusClaimed(msg.sender, duration);
        if (totalOGs == 1) emit ExhaleStarted(currentWeek, prizePot);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // AUTOMATION + MANUAL DRAW TRIGGER -> RESOLVE WEEK (no VRF)
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory) {
        upkeepNeeded = (
            block.timestamp >= lastDrawTimestamp + DRAW_COOLDOWN &&
            drawPhase == DrawPhase.IDLE &&
            !dormancyActive &&
            subscriberList.length > 0 &&
            getGamePhase() != GamePhase.CLOSED &&
            startPricesCaptured
        );
        return (upkeepNeeded, "");
    }

    function performUpkeep(bytes calldata) external override nonReentrant {
        if (block.timestamp < lastDrawTimestamp + DRAW_COOLDOWN) revert CooldownActive();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (dormancyActive) revert DormancyInProgress();
        if (subscriberList.length == 0) revert NoActiveSubscribers();
        if (getGamePhase() == GamePhase.CLOSED) revert GameClosed();
        if (!startPricesCaptured) revert StartPricesNotCaptured();
        _resolveWeek();
    }

    function triggerDraw() external nonReentrant {
        if (block.timestamp < lastDrawTimestamp + DRAW_COOLDOWN) revert CooldownActive();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (dormancyActive) revert DormancyInProgress();
        if (subscriberList.length == 0) revert NoActiveSubscribers();
        if (getGamePhase() == GamePhase.CLOSED) revert GameClosed();
        if (!startPricesCaptured) revert StartPricesNotCaptured();
        if (!subscriptions[msg.sender].active && msg.sender != owner()) revert NotSubscriber();
        _resolveWeek();
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // WEEK RESOLUTION: READ 42 FEEDS, RANK TOP 6, SET WINNING COMBO
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function _resolveWeek() internal {
        int256[42] memory performance;

        for (uint256 i = 0; i < POOL_SIZE; i++) {
            try priceFeeds[i].latestRoundData() returns (
                uint80, int256 endPrice, uint256, uint256 updatedAt, uint80
            ) {
                int256 startPrice = weekStartPrices[i];
                if (
                    block.timestamp - updatedAt > feedStalenessThresholds[i] ||
                    endPrice <= 0 ||
                    startPrice <= 0
                ) {
                    performance[i] = type(int256).min;
                } else {
                    performance[i] = (endPrice - startPrice) * int256(PRECISION_MULTIPLIER) / startPrice;
                }
            } catch {
                performance[i] = type(int256).min;
            }
        }

        uint8[6] memory topSix;
        bool[42] memory used;

        for (uint256 pick = 0; pick < PICK_COUNT; pick++) {
            int256 bestPerf = type(int256).min;
            uint8 bestIdx = 0;
            for (uint256 j = 0; j < POOL_SIZE; j++) {
                if (used[j]) continue;
                if (performance[j] > bestPerf) {
                    bestPerf = performance[j];
                    bestIdx = uint8(j);
                }
            }
            topSix[pick] = bestIdx;
            used[bestIdx] = true;
        }

        weeklyResults[currentWeek].combo = topSix;
        winningBitmask = _toBitmask(topSix);
        drawPhase = DrawPhase.MATCHING;
        totalWinnersThisDraw = 0;
        lastResolveTimestamp = block.timestamp;
        emit WeekResolved(currentWeek, topSix);
    }

    function _snapshotStartPrices() internal {
        for (uint256 i = 0; i < POOL_SIZE; i++) {
            try priceFeeds[i].latestRoundData() returns (
                uint80, int256 price, uint256, uint256 updatedAt, uint80
            ) {
                if (price <= 0 || block.timestamp - updatedAt > feedStalenessThresholds[i]) {
                    weekStartPrices[i] = 0;
                    emit FeedDisqualified(i, 1);
                } else {
                    weekStartPrices[i] = price;
                }
            } catch {
                weekStartPrices[i] = 0;
                emit FeedDisqualified(i, 2);
            }
        }
        startPricesCaptured = true;
        emit StartPricesSnapshotted(currentWeek);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // PHASE 2: MATCH AND POPULATE (identical to Crypto42)
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function matchAndPopulate() external nonReentrant {
        if (drawPhase != DrawPhase.MATCHING) revert WrongPhase();
        bool isExhale = currentWeek > INHALE_WEEKS;

        if (!matchingInProgress) {
            _captureYield();
            uint256 totalValue = IERC20(aUSDC).balanceOf(address(this));
            uint256 totalAllocated = prizePot + treasuryBalance + jpReserve + totalUnclaimedPrizes;
            uint256 tolerance = totalAllocated / 10000;
            if (tolerance < SOLVENCY_FLOOR) tolerance = SOLVENCY_FLOOR;
            if (totalValue + tolerance < totalAllocated) revert SolvencyCheckFailed();

            uint256 effectiveRate = getEffectivePrizeRateBps();
            uint256 weeklyPool = prizePot * effectiveRate / 10000;
            prizePot -= weeklyPool;
            weeklyResults[currentWeek].prizePool = weeklyPool;

            tierPayoutAmounts[0] = weeklyPool * TIER_MATCH3_BPS / 10000;
            tierPayoutAmounts[1] = weeklyPool * TIER_MATCH4_BPS / 10000;
            tierPayoutAmounts[2] = weeklyPool * TIER_MATCH5_BPS / 10000;

            uint256 toJPReserve = weeklyPool * TIER_JP_BPS / 10000;
            jpReserve += toJPReserve;

            uint256 toSeed = weeklyPool - tierPayoutAmounts[0] - tierPayoutAmounts[1]
                           - tierPayoutAmounts[2] - toJPReserve;
            prizePot += toSeed;
            emit SeedReturned(currentWeek, toSeed);

            lastWeekActiveTickets = 0;
            matchingInProgress = true;
            matchingIndex = 0;
        }

        uint64 winMask = winningBitmask;
        uint256 processed = 0;

        while (matchingIndex < subscriberList.length && processed < MAX_PROCESS_PER_TX) {
            address user = subscriberList[matchingIndex];
            Subscription storage sub = subscriptions[user];

            if (sub.endWeek < currentWeek) {
                _removeSubscriber(user);
                processed++;
                continue;
            }

            // Deferred start: subscriber joined during pick lock, starts next week
            if (sub.startWeek > currentWeek) { matchingIndex++; processed++; continue; }

            if (isExhale) {
                bool userIsOG = isOG[user];
                if (!userIsOG) {
                    uint256 duration = sub.endWeek - sub.startWeek + 1;
                    if (duration >= OG_WEEKS_REQUIRED && currentWeek >= sub.startWeek + OG_WEEKS_REQUIRED - 1) {
                        isOG[user] = true; totalOGs++;
                        emit OGStatusClaimed(user, duration);
                        userIsOG = true;
                    }
                }
                if (!userIsOG) { matchingIndex++; processed++; continue; }
            }

            uint256 m1 = _popcount(winMask & sub.pickBitmask1);
            lastWeekActiveTickets++;

            if (m1 == 6) { weeklyResults[currentWeek].jackpotWinners.push(user); totalWinnersThisDraw++; }
            else if (m1 == 5) { weeklyResults[currentWeek].match5.push(user); totalWinnersThisDraw++; }
            else if (m1 == 4) { weeklyResults[currentWeek].match4.push(user); totalWinnersThisDraw++; }
            else if (m1 >= 3) { weeklyResults[currentWeek].match3.push(user); totalWinnersThisDraw++; }

            if (sub.ticketsPerWeek == 2) {
                uint256 m2 = _popcount(winMask & sub.pickBitmask2);
                lastWeekActiveTickets++;

                if (m2 == 6) { weeklyResults[currentWeek].jackpotWinners.push(user); totalWinnersThisDraw++; }
                else if (m2 == 5) { weeklyResults[currentWeek].match5.push(user); totalWinnersThisDraw++; }
                else if (m2 == 4) { weeklyResults[currentWeek].match4.push(user); totalWinnersThisDraw++; }
                else if (m2 >= 3) { weeklyResults[currentWeek].match3.push(user); totalWinnersThisDraw++; }
            }

            matchingIndex++;
            processed++;
        }

        if (matchingIndex >= subscriberList.length) {
            matchingInProgress = false; matchingIndex = 0;
            drawPhase = DrawPhase.DISTRIBUTING;
            distributionTierIndex = 0; distributionWinnerIndex = 0;
            emit MatchingComplete(currentWeek, totalWinnersThisDraw, lastWeekActiveTickets);
        } else {
            emit MatchingBatchProcessed(currentWeek, matchingIndex, subscriberList.length);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // PHASE 3: PRIZE DISTRIBUTION (identical to Crypto42)
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function distributePrizes() external nonReentrant {
        if (drawPhase != DrawPhase.DISTRIBUTING) revert WrongPhase();
        uint256 creditsThisTx = 0;

        if (distributionTierIndex == 0 && distributionWinnerIndex == 0 && !jpHitThisWeek) {
            address[] storage jpWinners = weeklyResults[currentWeek].jackpotWinners;
            if (jpWinners.length > 0) {
                jpHitThisWeek = true;
                weeklyResults[currentWeek].jpHit = true;
                uint256 winnerPayout = jpReserve * JP_WINNER_BPS / 10000;
                uint256 seedReturn = jpReserve - winnerPayout;
                uint256 perWinner = winnerPayout / jpWinners.length;
                uint256 dust = winnerPayout - (perWinner * jpWinners.length);
                for (uint256 i = 0; i < jpWinners.length; i++) {
                    unclaimedPrizes[jpWinners[i]] += perWinner;
                    totalUnclaimedPrizes += perWinner;
                    emit WinnerSelected(jpWinners[i], perWinner, 6);
                    creditsThisTx++;
                }
                prizePot += seedReturn + dust;
                weeklyResults[currentWeek].jpPayout = winnerPayout;
                emit JackpotHit(currentWeek, winnerPayout, jpWinners.length, seedReturn);

                uint256 weeklyPool = weeklyResults[currentWeek].prizePool;
                uint256 bonus = weeklyPool * JP_WEEK_BONUS_BPS / 10000;
                if (bonus > prizePot) bonus = prizePot;
                uint256 lowerTierTotal = TIER_MATCH3_BPS + TIER_MATCH4_BPS + TIER_MATCH5_BPS;
                uint256 m3Bonus = bonus * TIER_MATCH3_BPS / lowerTierTotal;
                uint256 m4Bonus = bonus * TIER_MATCH4_BPS / lowerTierTotal;
                uint256 m5Bonus = bonus - m3Bonus - m4Bonus;
                tierPayoutAmounts[0] += m3Bonus;
                tierPayoutAmounts[1] += m4Bonus;
                tierPayoutAmounts[2] += m5Bonus;
                prizePot -= bonus;
                emit JackpotBonusApplied(currentWeek, bonus);
                jpReserve = 0;
            } else {
                // JP Overflow: 20% of this week's JP allocation returns to prizePot.
                // Remaining 80% stays in jpReserve. Keeps the pot growing for tier
                // winners even during long JP dry spells. JP still accumulates.
                uint256 thisWeekJP = weeklyResults[currentWeek].prizePool * TIER_JP_BPS / 10000;
                uint256 overflow = thisWeekJP * JP_OVERFLOW_BPS / 10000;
                jpReserve -= overflow;
                prizePot += overflow;
                emit JackpotOverflow(currentWeek, overflow, jpReserve);
                emit JackpotRollover(currentWeek, jpReserve);
            }
        }

        while (distributionTierIndex < 3 && creditsThisTx < MAX_PAYOUTS_PER_TX) {
            address[] storage winners = _getWinnersForTier(distributionTierIndex);
            uint256 tierAmount = tierPayoutAmounts[distributionTierIndex];
            if (winners.length == 0) {
                prizePot += tierAmount;
                tierPayoutAmounts[distributionTierIndex] = 0;
                emit TierPayoutDeferred(currentWeek, distributionTierIndex, tierAmount);
                distributionTierIndex++; distributionWinnerIndex = 0;
                continue;
            }
            uint256 perWinner = tierAmount / winners.length;
            if (distributionWinnerIndex == 0) {
                uint256 roundingDust = tierAmount - (perWinner * winners.length);
                if (roundingDust > 0) prizePot += roundingDust;
            }
            while (distributionWinnerIndex < winners.length && creditsThisTx < MAX_PAYOUTS_PER_TX) {
                unclaimedPrizes[winners[distributionWinnerIndex]] += perWinner;
                totalUnclaimedPrizes += perWinner;
                emit WinnerSelected(winners[distributionWinnerIndex], perWinner, distributionTierIndex + 3);
                distributionWinnerIndex++; creditsThisTx++;
            }
            if (distributionWinnerIndex >= winners.length) {
                distributionTierIndex++; distributionWinnerIndex = 0;
            }
        }

        if (distributionTierIndex >= 3) {
            _finalizeWeek();
            emit DistributionComplete(currentWeek - 1);
        }
    }

    function _getWinnersForTier(uint256 tier) internal view returns (address[] storage) {
        if (tier == 0) return weeklyResults[currentWeek].match3;
        if (tier == 1) return weeklyResults[currentWeek].match4;
        return weeklyResults[currentWeek].match5;
    }

    function _finalizeWeek() internal {
        jpHitThisWeek = false;
        lastDrawTimestamp = block.timestamp;
        emit WeekFinalized(currentWeek);
        currentWeek++;
        drawPhase = DrawPhase.IDLE;
        _snapshotStartPrices();
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // PRIZE CLAIMS
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function claimPrize() external nonReentrant {
        uint256 amount = unclaimedPrizes[msg.sender];
        if (amount == 0) revert NothingToClaim();
        _captureYield();
        unclaimedPrizes[msg.sender] = 0;
        totalUnclaimedPrizes -= amount;
        try IPool(AAVE_POOL).withdraw(USDC, amount, address(this)) {
            lastSnapshotAUSDC = IERC20(aUSDC).balanceOf(address(this));
            IERC20(USDC).safeTransfer(msg.sender, amount);
            totalPrizesWon[msg.sender] += amount;
            emit PrizeClaimed(msg.sender, amount);
        } catch {
            unclaimedPrizes[msg.sender] = amount;
            totalUnclaimedPrizes += amount;
            revert AaveLiquidityLow();
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // FINAL DISTRIBUTION
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function closeGame() external nonReentrant {
        if (dormancyActive) revert DormancyInProgress();
        bool weeksExpired = currentWeek > TOTAL_WEEKS;
        bool timeExpired = block.timestamp >= DEPLOY_TIMESTAMP + ((TOTAL_WEEKS + CLOSE_GRACE_WEEKS) * 1 weeks);
        if (!weeksExpired && !timeExpired) revert TooEarly();
        if (finalDistributionDone) revert AlreadyClaimed();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (totalOGs == 0) revert ExceedsLimit();
        _captureYield();
        prizePot += jpReserve; jpReserve = 0;
        uint256 totalPot = prizePot;
        uint256 toOGs = totalPot * ENDGAME_OG_BPS / 10000;
        uint256 toTreasury = totalPot - toOGs;
        ogShareAmount = toOGs / totalOGs;
        treasuryBalance += toTreasury;
        prizePot = toOGs;
        finalDistributionDone = true;
        closeTimestamp = block.timestamp;
        emit EndgameDistribution(toOGs, toTreasury);
        emit FinalDistribution(toOGs, totalOGs, ogShareAmount);
    }

    function claimOGShare() external nonReentrant {
        if (!finalDistributionDone) revert NotClosed();
        if (!isOG[msg.sender]) revert NotOG();
        if (ogShareClaimed[msg.sender]) revert AlreadyClaimed();
        _captureYield();
        ogShareClaimed[msg.sender] = true;
        uint256 share = ogShareAmount;
        prizePot -= share;
        try IPool(AAVE_POOL).withdraw(USDC, share, address(this)) {
            lastSnapshotAUSDC = IERC20(aUSDC).balanceOf(address(this));
            IERC20(USDC).safeTransfer(msg.sender, share);
            emit OGShareClaimed(msg.sender, share);
        } catch {
            ogShareClaimed[msg.sender] = false;
            prizePot += share;
            revert AaveLiquidityLow();
        }
    }

    function sweepUnclaimedOGShares() external nonReentrant {
        if (!finalDistributionDone) revert NotClosed();
        if (block.timestamp < closeTimestamp + OG_CLAIM_DEADLINE) revert TooEarly();
        if (prizePot == 0) revert NothingToClaim();
        _captureYield();
        uint256 remaining = prizePot; prizePot = 0;
        treasuryBalance += remaining;
        emit UnclaimedOGSharesSwept(remaining, treasuryBalance);
    }

    function rescueAbandonedPot() external nonReentrant {
        bool weeksExpired = currentWeek > TOTAL_WEEKS;
        bool timeExpired = block.timestamp >= DEPLOY_TIMESTAMP + ((TOTAL_WEEKS + CLOSE_GRACE_WEEKS) * 1 weeks);
        bool dormantLongEnough = activeSubscribers == 0 && totalOGs == 0 && block.timestamp >= lastDrawTimestamp + 90 days;
        if (!weeksExpired && !timeExpired && !dormantLongEnough) revert TooEarly();
        if (totalOGs > 0) revert GameNotAbandoned();
        if (activeSubscribers > 0) revert GameNotAbandoned();
        if (finalDistributionDone) revert AlreadyClaimed();
        for (uint256 i = 0; i < 3; i++) {
            if (tierPayoutAmounts[i] > 0) { prizePot += tierPayoutAmounts[i]; tierPayoutAmounts[i] = 0; }
        }
        _captureYield();
        uint256 remaining = prizePot + jpReserve;
        prizePot = 0;
        jpReserve = 0;
        treasuryBalance += remaining;
        finalDistributionDone = true;
        closeTimestamp = block.timestamp;
        emit FinalDistribution(remaining, 0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // DORMANCY: THE SQUID GAME CLAUSE (batched)
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function triggerDormancy() external nonReentrant {
        if (finalDistributionDone) revert NotClosed();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (block.timestamp < lastDrawTimestamp + DORMANCY_THRESHOLD) revert TooEarly();
        if (activeSubscribers == 0) revert NoActiveSubscribers();
        if (!dormancyActive) {
            _captureYield();
            prizePot += jpReserve; jpReserve = 0;
            dormancyPerUser = prizePot / activeSubscribers;
            dormancyActive = true; dormancyProcessed = 0;
            return;
        }
        uint256 processed = 0;
        uint256 i = dormancyProcessed;
        while (i < subscriberList.length && processed < MAX_PROCESS_PER_TX) {
            address user = subscriberList[i];
            if (subscriptions[user].active) {
                unclaimedPrizes[user] += dormancyPerUser;
                totalUnclaimedPrizes += dormancyPerUser;
            }
            i++; processed++;
        }
        dormancyProcessed = i;
        if (i >= subscriberList.length) {
            uint256 distributed = dormancyPerUser * activeSubscribers;
            uint256 dust = prizePot - distributed;
            if (dust > 0) treasuryBalance += dust;
            prizePot = 0; finalDistributionDone = true;
            closeTimestamp = block.timestamp;
            emit FinalDistribution(0, activeSubscribers, dormancyPerUser);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // PICK VALIDATION + BITMASK
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function _validatePicks(uint8[6] calldata picks) internal pure {
        uint64 seen = 0;
        for (uint256 i = 0; i < PICK_COUNT; i++) {
            if (picks[i] >= POOL_SIZE) revert InvalidPickIndex();
            uint64 bit = uint64(1) << picks[i];
            if (seen & bit != 0) revert DuplicatePick();
            seen |= bit;
        }
    }

    function _toBitmask(uint8[6] memory picks) internal pure returns (uint64) {
        uint64 mask = 0;
        for (uint256 i = 0; i < PICK_COUNT; i++) { mask |= uint64(1) << picks[i]; }
        return mask;
    }

    function _popcount(uint64 x) internal pure returns (uint256) {
        uint256 count = 0;
        while (x != 0) { count++; x &= x - 1; }
        return count;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function getSubscriberCount() external view returns (uint256) { return subscriberList.length; }

    function getRemainingSlots() external view returns (uint256) {
        if (activeSubscribers >= MAX_USERS) return 0;
        return MAX_USERS - activeSubscribers;
    }

    function getSubscription(address user) external view returns (
        uint8[6] memory picks1, uint8[6] memory picks2,
        uint256 startWeek, uint256 endWeek,
        bool active, uint8 ticketsPerWeek, uint256 duration
    ) {
        Subscription storage sub = subscriptions[user];
        uint256 dur = (sub.endWeek >= sub.startWeek && sub.startWeek > 0) ? sub.endWeek - sub.startWeek + 1 : 0;
        return (sub.picks1, sub.picks2, sub.startWeek, sub.endWeek, sub.active, sub.ticketsPerWeek, dur);
    }

    function getSubscriptionCost(uint256 weeks, uint8 ticketsPerWeek) external pure returns (uint256) {
        return weeks * TICKET_PRICE * uint256(ticketsPerWeek);
    }

    function getSolvencyStatus() external view returns (uint256 totalValue, uint256 totalAllocated, bool isSolvent) {
        totalValue = IERC20(aUSDC).balanceOf(address(this));
        totalAllocated = prizePot + treasuryBalance + jpReserve + totalUnclaimedPrizes;
        uint256 tolerance = totalAllocated / 10000;
        if (tolerance < SOLVENCY_FLOOR) tolerance = SOLVENCY_FLOOR;
        isSolvent = totalValue + tolerance >= totalAllocated;
    }

    function getEstimatedOGShare() external view returns (uint256 perOG, uint256 pot, uint256 ogCount) {
        pot = (prizePot + jpReserve) * ENDGAME_OG_BPS / 10000;
        ogCount = totalOGs;
        perOG = ogCount > 0 ? pot / ogCount : 0;
    }

    function isOGQualified(address user) external view returns (bool qualified, bool alreadyClaimed, uint256 duration, uint256 weeksNeeded) {
        Subscription storage sub = subscriptions[user];
        uint256 dur = (sub.endWeek >= sub.startWeek && sub.startWeek > 0) ? sub.endWeek - sub.startWeek + 1 : 0;
        bool hasTime = currentWeek >= sub.startWeek + OG_WEEKS_REQUIRED - 1;
        qualified = dur >= OG_WEEKS_REQUIRED && hasTime && currentWeek >= INHALE_WEEKS - OG_CLAIM_EARLY_WEEKS;
        return (qualified, isOG[user], dur, OG_WEEKS_REQUIRED);
    }

    function getPotHealth() external view returns (uint256 pot, uint256 weeklyInflow, uint256 weeklyOutflow, uint256 healthRatio, uint256 currentRateBps) {
        pot = prizePot;
        if (getGamePhase() == GamePhase.EXHALE) {
            uint256 exhaleWeek = currentWeek - INHALE_WEEKS;
            uint256 taperBps = exhaleWeek >= EXHALE_WEEKS ? 0 : TREASURY_SPLIT_BPS * (EXHALE_WEEKS - exhaleWeek) / EXHALE_WEEKS;
            uint256 potBps = 10000 - taperBps;
            weeklyInflow = lastWeekActiveTickets * TICKET_PRICE * potBps / 10000;
        } else {
            weeklyInflow = lastWeekActiveTickets * TICKET_PRICE * POT_SPLIT_BPS / 10000;
        }
        currentRateBps = getEffectivePrizeRateBps();
        weeklyOutflow = pot * currentRateBps / 10000;
        healthRatio = weeklyOutflow > 0 ? weeklyInflow * 10000 / weeklyOutflow : type(uint256).max;
    }

    function getWeeklyCombo(uint256 week) external view returns (uint8[6] memory) { return weeklyResults[week].combo; }

    function getWeeklyComboTickers(uint256 week) external view returns (string[6] memory tickers) {
        uint8[6] memory combo = weeklyResults[week].combo;
        for (uint256 i = 0; i < 6; i++) { tickers[i] = CRYPTO_TICKERS[combo[i]]; }
    }

    function getWeeklyWinners(uint256 week, uint256 tier) external view returns (address[] memory) {
        if (tier == 6) return weeklyResults[week].jackpotWinners;
        if (tier == 5) return weeklyResults[week].match5;
        if (tier == 4) return weeklyResults[week].match4;
        return weeklyResults[week].match3;
    }

    function getContractState() external view returns (
        DrawPhase phase, GamePhase gamePhase, uint256 week,
        uint256 pot, uint256 jpRes, uint256 treasury, uint256 unclaimed,
        uint256 subs, bool matching, uint256 ogCount, bool dormancy
    ) {
        return (drawPhase, getGamePhase(), currentWeek, prizePot, jpReserve, treasuryBalance, totalUnclaimedPrizes, activeSubscribers, matchingInProgress, totalOGs, dormancyActive);
    }

    function isValidPicks(uint8[6] calldata picks) external pure returns (bool valid, string memory reason) {
        uint64 seen = 0;
        for (uint256 i = 0; i < PICK_COUNT; i++) {
            if (picks[i] >= POOL_SIZE) return (false, "Index must be 0-41");
            uint64 bit = uint64(1) << picks[i];
            if (seen & bit != 0) return (false, "Duplicate crypto. Each must be unique.");
            seen |= bit;
        }
        return (true, "");
    }

    function getAllTickers() external view returns (string[42] memory) { return CRYPTO_TICKERS; }
    function getWeekStartPrices() external view returns (int256[42] memory) { return weekStartPrices; }
    function getAllStalenessThresholds() external view returns (uint256[42] memory) { return feedStalenessThresholds; }
    function arePicksLocked() external view returns (bool) { return block.timestamp >= lastDrawTimestamp + DRAW_COOLDOWN - PICK_LOCK_BEFORE_RESOLVE; }

    function getCurrentPerformance() external view returns (int256[42] memory perf) {
        for (uint256 i = 0; i < POOL_SIZE; i++) {
            try priceFeeds[i].latestRoundData() returns (
                uint80, int256 endPrice, uint256, uint256, uint80
            ) {
                int256 startPrice = weekStartPrices[i];
                if (startPrice > 0 && endPrice > 0) {
                    perf[i] = (endPrice - startPrice) * int256(PRECISION_MULTIPLIER) / startPrice;
                } else {
                    perf[i] = 0;
                }
            } catch {
                perf[i] = 0;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // OWNER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    function commitToZeroRevenue(uint256 targetTimestamp) external onlyOwner {
        if (zeroRevenueTimestamp != 0) revert AlreadyCommitted();
        if (targetTimestamp < block.timestamp + 365 days) revert TooSoon();
        zeroRevenueTimestamp = targetTimestamp;
        emit ZeroRevenueCommitted(targetTimestamp);
    }

    function withdrawTreasury(uint256 amount, address recipient) external onlyOwner nonReentrant {
        if (amount > treasuryBalance) revert InsufficientBalance();
        if (recipient == address(0)) revert InvalidAddress();
        if (getGamePhase() == GamePhase.EXHALE) {
            if (block.timestamp >= lastTreasuryWithdrawTimestamp + EXHALE_TREASURY_PERIOD) {
                treasuryWithdrawnThisPeriod = 0;
                lastTreasuryWithdrawTimestamp = block.timestamp;
                periodStartTreasuryBalance = treasuryBalance;
            }
            uint256 maxThisPeriod = periodStartTreasuryBalance * EXHALE_TREASURY_CAP_BPS / 10000;
            if (treasuryWithdrawnThisPeriod + amount > maxThisPeriod) revert ExhaleWithdrawalCap();
            treasuryWithdrawnThisPeriod += amount;
        }
        _captureYield();
        treasuryBalance -= amount;
        uint256 balanceBefore = IERC20(USDC).balanceOf(address(this));
        IPool(AAVE_POOL).withdraw(USDC, amount, address(this));
        uint256 received = IERC20(USDC).balanceOf(address(this)) - balanceBefore;
        lastSnapshotAUSDC = IERC20(aUSDC).balanceOf(address(this));
        if (received < amount) revert AaveLiquidityLow();
        IERC20(USDC).safeTransfer(recipient, received);
        emit TreasuryWithdrawal(received, recipient);
    }

    function proposeFeedUpdate(uint256 index, address newFeed, uint256 newStaleness) external onlyOwner {
        if (index >= POOL_SIZE) revert InvalidPickIndex();
        if (newFeed == address(0)) revert InvalidAddress();
        if (newStaleness == 0) revert InvalidStaleness();
        if (pendingFeedUpdates[index].newFeed != address(0)) revert AlreadyProposed();
        pendingFeedUpdates[index] = PendingFeedUpdate({
            newFeed: newFeed,
            newStaleness: newStaleness,
            executeAfter: block.timestamp + FEED_UPDATE_DELAY
        });
        emit FeedUpdateProposed(index, newFeed, newStaleness, block.timestamp + FEED_UPDATE_DELAY);
    }

    function executeFeedUpdate(uint256 index) external {
        if (index >= POOL_SIZE) revert InvalidPickIndex();
        PendingFeedUpdate memory pending = pendingFeedUpdates[index];
        if (pending.newFeed == address(0)) revert NoPendingUpdate();
        if (block.timestamp < pending.executeAfter) revert TimelockNotExpired();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        address oldFeed = address(priceFeeds[index]);
        priceFeeds[index] = AggregatorV3Interface(pending.newFeed);
        feedStalenessThresholds[index] = pending.newStaleness;
        delete pendingFeedUpdates[index];
        emit PriceFeedUpdated(index, oldFeed, pending.newFeed);
    }

    function cancelFeedUpdate(uint256 index) external onlyOwner {
        if (pendingFeedUpdates[index].newFeed == address(0)) revert NoPendingUpdate();
        delete pendingFeedUpdates[index];
        emit FeedUpdateCancelled(index);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // EMERGENCY / RECOVERY
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function emergencyResetDraw() external {
        if (block.timestamp <= lastResolveTimestamp + DRAW_STUCK_TIMEOUT) revert TooEarly();
        DrawPhase currentPhase = drawPhase;
        if (currentPhase == DrawPhase.IDLE) revert NotStuck();
        for (uint256 i = 0; i < 3; i++) {
            if (tierPayoutAmounts[i] > 0) {
                prizePot += tierPayoutAmounts[i];
                emit TierPayoutDeferred(currentWeek, i, tierPayoutAmounts[i]);
                tierPayoutAmounts[i] = 0;
            }
        }
        matchingInProgress = false; matchingIndex = 0;
        distributionTierIndex = 0; distributionWinnerIndex = 0;
        totalWinnersThisDraw = 0;
        _finalizeWeek();
        emit EmergencyReset(currentWeek - 1, currentPhase, "Manual reset");
    }

    function forceCompleteDistribution() external {
        if (drawPhase != DrawPhase.DISTRIBUTING) revert WrongPhase();
        if (block.timestamp <= lastResolveTimestamp + DRAW_STUCK_TIMEOUT) revert TooEarly();
        for (uint256 i = distributionTierIndex; i < 3; i++) {
            if (tierPayoutAmounts[i] > 0) {
                prizePot += tierPayoutAmounts[i];
                emit TierPayoutDeferred(currentWeek, i, tierPayoutAmounts[i]);
                tierPayoutAmounts[i] = 0;
            }
        }
        _finalizeWeek();
        emit DrawReset(currentWeek - 1, "Forced completion");
    }
}
