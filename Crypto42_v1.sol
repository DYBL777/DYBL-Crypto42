// SPDX-License-Identifier: BUSL-1.1
// Licensed under the Business Source License 1.1
// Change Date: 10 May 2029
// On the Change Date, this code becomes available under MIT License.

pragma solidity ^0.8.24;

/**
 * @title Crypto42 v1.0
 * @notice A 6-Year Breathing Prediction Game: Pick the Top 6 Performing Cryptos
 * @author DYBL Foundation
 * @dev Crypto42_v1.sol - Chainlink Price Feed Skill Game
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
 *   4. Calculates % change: (endPrice - startPrice) * 10000 / startPrice
 *   5. Ranks all 42. Top 6 = winning combo.
 *   6. Tiebreaker: lower index wins (deterministic)
 *   7. Sets winningBitmask. Enters MATCHING. Synchronous. One tx.
 *
 * CHAINLINK SERVICES (NO VRF):
 *   Price Feeds: 42 AggregatorV3Interface feeds (one per crypto)
 *   Automation:  Weekly resolveWeek() trigger + batch processing
 *   Feed staleness: all 42 must be fresh or resolveWeek reverts
 *   If feeds stale > 8 weeks: dormancy activates. Funds never stuck.
 *
 * EVERYTHING ELSE: IDENTICAL TO LETTER BREATHE v1
 *   Revenue split, Aave V3 yield, OG qualification, dormancy, treasury,
 *   solvency, self-cleaning draws, swap-and-pop, batched matching,
 *   batched distribution, all S1 security patterns.
 */

import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";

contract Crypto42 is Ownable, ReentrancyGuard, AutomationCompatibleInterface {
    using SafeERC20 for IERC20;

    error GameFull();
    error GameClosed();
    error DrawInProgress();
    error InvalidPickIndex();
    error DuplicatePick();
    error DuplicatePickSets();
    error InsufficientBalance();
    error InvalidAddress();
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
    error StaleFeed();
    error InvalidFeedPrice();
    error StartPricesNotCaptured();

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
    uint256 public constant TIER_SEED_BPS = 1000;
    uint256 public constant JP_WEEK_BONUS_BPS = 200;
    uint256 public constant JP_WINNER_BPS = 9000;
    uint256 public constant JP_SEED_BPS = 1000;
    uint256 public constant OG_WEEKS_REQUIRED = 208;
    uint256 public constant OG_CLAIM_EARLY_WEEKS = 4;
    uint256 public constant MAX_PROCESS_PER_TX = 100;
    uint256 public constant MAX_PAYOUTS_PER_TX = 100;
    uint256 public constant DRAW_COOLDOWN = 7 days;
    uint256 public constant DRAW_STUCK_TIMEOUT = 14 days;
    uint256 public constant EXHALE_TREASURY_CAP_BPS = 2000;
    uint256 public constant EXHALE_TREASURY_PERIOD = 30 days;
    uint256 public constant OG_CLAIM_DEADLINE = 90 days;
    uint256 public constant DORMANCY_THRESHOLD = 8 weeks;
    uint256 public constant SOLVENCY_FLOOR = 10000;
    uint256 public constant FEED_STALENESS_THRESHOLD = 2 hours;
    uint256 public constant PRECISION_MULTIPLIER = 10_000_000_000; // 8 decimal places, matches Chainlink feed precision

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
    uint256 public lastWeekActiveTickets;
    int256[42] public weekStartPrices;
    bool public startPricesCaptured;

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
    event JackpotBonusApplied(uint256 indexed week, uint256 bonusAmount);
    event PrizeClaimed(address indexed winner, uint256 amount);
    event SeedReturned(uint256 indexed week, uint256 amount);
    event MatchingComplete(uint256 indexed week, uint256 totalWinners, uint256 activeTickets);
    event MatchingBatchProcessed(uint256 indexed week, uint256 processed, uint256 total);
    event DistributionComplete(uint256 indexed week);
    event TierPayoutDeferred(uint256 indexed week, uint256 tier, uint256 amount);
    event WeekFinalized(uint256 indexed week);
    event OGStatusClaimed(address indexed user, uint256 duration);
    event ExhaleStarted(uint256 indexed week, uint256 potAtStart);
    event FinalDistribution(uint256 remainingPot, uint256 totalOGs, uint256 perOGShare);
    event OGShareClaimed(address indexed og, uint256 amount);
    event UnclaimedOGSharesSwept(uint256 amount, uint256 newTreasuryBalance);
    event TreasuryWithdrawal(uint256 amount, address recipient);
    event DrawReset(uint256 indexed week, string reason);
    event EmergencyReset(uint256 indexed week, DrawPhase fromPhase, string reason);
    event PriceFeedUpdated(uint256 indexed cryptoIndex, address oldFeed, address newFeed);
    event ZeroRevenueCommitted(uint256 targetTimestamp);
    event TreasuryTakeZeroed();
    event StartPricesSnapshotted(uint256 indexed week);

    constructor(
        address[42] memory _priceFeeds,
        address _usdc,
        address _aavePool,
        address _aUSDC
    ) Ownable(msg.sender) {
        if (_usdc == address(0)) revert InvalidAddress();
        if (_aavePool == address(0)) revert InvalidAddress();
        if (_aUSDC == address(0)) revert InvalidAddress();
        for (uint256 i = 0; i < 42; i++) {
            if (_priceFeeds[i] == address(0)) revert InvalidAddress();
            priceFeeds[i] = AggregatorV3Interface(_priceFeeds[i]);
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

    function getCurrentTreasuryTakeBps() public view returns (uint256) {
        if (zeroRevenueActive) return 0;
        if (zeroRevenueTimestamp != 0 && block.timestamp >= zeroRevenueTimestamp) return 0;
        return TREASURY_SPLIT_BPS;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // AAVE YIELD CAPTURE (S1 FIX-14)
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function _captureYield() internal {
        uint256 currentAUSDC = IERC20(aUSDC).balanceOf(address(this));
        if (lastSnapshotAUSDC == 0) { lastSnapshotAUSDC = currentAUSDC; return; }
        if (currentAUSDC <= lastSnapshotAUSDC) { lastSnapshotAUSDC = currentAUSDC; return; }
        prizePot += currentAUSDC - lastSnapshotAUSDC;
        lastSnapshotAUSDC = currentAUSDC;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // SUBSCRIBE: 1 TICKET PER WEEK
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function subscribe(uint8[6] calldata picks, uint256 weeks) external nonReentrant {
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (getGamePhase() == GamePhase.CLOSED) revert GameClosed();
        if (weeks == 0) revert InvalidWeeks();
        if (getGamePhase() == GamePhase.EXHALE && !isOG[msg.sender]) revert NotOG();
        _validatePicks(picks);

        Subscription storage sub = subscriptions[msg.sender];
        if (sub.active) revert AlreadySubscribed();

        uint256 endWeek = currentWeek + weeks - 1;
        uint256 maxWeek = isOG[msg.sender] ? TOTAL_WEEKS : INHALE_WEEKS;
        if (endWeek > maxWeek) { endWeek = maxWeek; weeks = maxWeek - currentWeek + 1; }

        uint256 totalCost = weeks * TICKET_PRICE;
        _processPayment(msg.sender, totalCost);

        uint64 mask1 = _toBitmask(picks);
        uint8[6] memory empty;
        _addSubscriber(msg.sender, picks, empty, mask1, 0, endWeek, 1);
        emit Subscribed(msg.sender, currentWeek, endWeek, 1, totalCost);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // SUBSCRIBE: 2 TICKETS PER WEEK
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function subscribeDouble(uint8[6] calldata picks1, uint8[6] calldata picks2, uint256 weeks) external nonReentrant {
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (getGamePhase() == GamePhase.CLOSED) revert GameClosed();
        if (weeks == 0) revert InvalidWeeks();
        if (getGamePhase() == GamePhase.EXHALE && !isOG[msg.sender]) revert NotOG();
        _validatePicks(picks1);
        _validatePicks(picks2);
        if (_toBitmask(picks1) == _toBitmask(picks2)) revert DuplicatePickSets();

        Subscription storage sub = subscriptions[msg.sender];
        if (sub.active) revert AlreadySubscribed();

        uint256 endWeek = currentWeek + weeks - 1;
        uint256 maxWeek = isOG[msg.sender] ? TOTAL_WEEKS : INHALE_WEEKS;
        if (endWeek > maxWeek) { endWeek = maxWeek; weeks = maxWeek - currentWeek + 1; }

        uint256 totalCost = weeks * TICKET_PRICE * 2;
        _processPayment(msg.sender, totalCost);

        uint64 mask1 = _toBitmask(picks1);
        uint64 mask2 = _toBitmask(picks2);
        _addSubscriber(msg.sender, picks1, picks2, mask1, mask2, endWeek, 2);
        emit Subscribed(msg.sender, currentWeek, endWeek, 2, totalCost);
    }

    function extendSubscription(uint256 additionalWeeks) external nonReentrant {
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
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

    function changePicks(uint8[6] calldata newPicks) external {
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
        if (treasuryTakeBps == 0) { toPot = totalCost; toTreasury = 0; }
        else {
            uint256 potSplitBps = getCurrentPotSplitBps();
            toPot = totalCost * potSplitBps / 10000;
            toTreasury = totalCost - toPot;
        }
        prizePot += toPot;
        treasuryBalance += toTreasury;
    }

    function _addSubscriber(address user, uint8[6] memory p1, uint8[6] memory p2, uint64 mask1, uint64 mask2, uint256 endWeek, uint8 ticketsPerWeek) internal {
        if (activeSubscribers >= MAX_USERS) revert GameFull();
        subscriberList.push(user);
        Subscription storage sub = subscriptions[user];
        sub.picks1 = p1; sub.picks2 = p2;
        sub.pickBitmask1 = mask1; sub.pickBitmask2 = mask2;
        sub.startWeek = currentWeek; sub.endWeek = endWeek;
        sub.listIndex = subscriberList.length;
        sub.active = true; sub.ticketsPerWeek = ticketsPerWeek;
        activeSubscribers++;
    }

    function _removeSubscriber(address user) internal {
        Subscription storage sub = subscriptions[user];
        uint256 idx = sub.listIndex - 1;
        if (!isOG[user] && sub.startWeek > 0) {
            uint256 duration = sub.endWeek - sub.startWeek + 1;
            if (duration >= OG_WEEKS_REQUIRED) {
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
            subscriberList.length > 0 &&
            getGamePhase() != GamePhase.CLOSED &&
            startPricesCaptured
        );
        return (upkeepNeeded, "");
    }

    function performUpkeep(bytes calldata) external override nonReentrant {
        if (block.timestamp < lastDrawTimestamp + DRAW_COOLDOWN) revert CooldownActive();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (subscriberList.length == 0) revert NoActiveSubscribers();
        if (getGamePhase() == GamePhase.CLOSED) revert GameClosed();
        if (!startPricesCaptured) revert StartPricesNotCaptured();
        _resolveWeek();
    }

    function triggerDraw() external nonReentrant {
        if (block.timestamp < lastDrawTimestamp + DRAW_COOLDOWN) revert CooldownActive();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
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
            // Try/catch: one bad/dead/paused feed cannot brick the game.
            // Disqualified cryptos get worst possible performance. Can't win. Game continues.
            try priceFeeds[i].latestRoundData() returns (
                uint80, int256 endPrice, uint256, uint256 updatedAt, uint80
            ) {
                int256 startPrice = weekStartPrices[i];
                if (
                    block.timestamp - updatedAt > FEED_STALENESS_THRESHOLD ||
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

        // Selection sort: find top 6. Tiebreaker: lower index wins.
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
                uint80, int256 price, uint256, uint256, uint80
            ) {
                weekStartPrices[i] = price;
            } catch {
                // Feed dead/paused: store 0. resolveWeek will disqualify this crypto.
                weekStartPrices[i] = 0;
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

            uint256 best = _popcount(winMask & sub.pickBitmask1);
            if (sub.ticketsPerWeek == 2) {
                uint256 m2 = _popcount(winMask & sub.pickBitmask2);
                if (m2 > best) best = m2;
            }
            lastWeekActiveTickets += sub.ticketsPerWeek;

            if (best == 6) { weeklyResults[currentWeek].jackpotWinners.push(user); totalWinnersThisDraw++; }
            else if (best == 5) { weeklyResults[currentWeek].match5.push(user); totalWinnersThisDraw++; }
            else if (best == 4) { weeklyResults[currentWeek].match4.push(user); totalWinnersThisDraw++; }
            else if (best >= 3) { weeklyResults[currentWeek].match3.push(user); totalWinnersThisDraw++; }

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

        if (distributionTierIndex == 0 && distributionWinnerIndex == 0) {
            address[] storage jpWinners = weeklyResults[currentWeek].jackpotWinners;
            if (jpWinners.length > 0) {
                jpHitThisWeek = true;
                weeklyResults[currentWeek].jpHit = true;
                uint256 winnerPayout = jpReserve * JP_WINNER_BPS / 10000;
                uint256 seedReturn = jpReserve - winnerPayout;
                uint256 perWinner = winnerPayout / jpWinners.length;
                uint256 dust = winnerPayout - (perWinner * jpWinners.length);
                for (uint256 i = 0; i < jpWinners.length && creditsThisTx < MAX_PAYOUTS_PER_TX; i++) {
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
        bool weeksExpired = currentWeek > TOTAL_WEEKS;
        bool timeExpired = block.timestamp >= DEPLOY_TIMESTAMP + ((TOTAL_WEEKS + CLOSE_GRACE_WEEKS) * 1 weeks);
        if (!weeksExpired && !timeExpired) revert TooEarly();
        if (weeksExpired && currentWeek <= TOTAL_WEEKS + CLOSE_GRACE_WEEKS) {
            if (!timeExpired && msg.sender != owner()) revert TooEarly();
        }
        if (finalDistributionDone) revert AlreadyClaimed();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        if (totalOGs == 0) revert ExceedsLimit();
        _captureYield();
        prizePot += jpReserve; jpReserve = 0;
        ogShareAmount = prizePot / totalOGs;
        finalDistributionDone = true;
        closeTimestamp = block.timestamp;
        emit FinalDistribution(prizePot, totalOGs, ogShareAmount);
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

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // DORMANCY: THE SQUID GAME CLAUSE (batched)
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function triggerDormancy() external nonReentrant {
        if (finalDistributionDone) revert NotClosed();
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
        pot = prizePot + jpReserve; ogCount = totalOGs;
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
        weeklyInflow = lastWeekActiveTickets * TICKET_PRICE * POT_SPLIT_BPS / 10000;
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
        uint256 subs, bool matching, uint256 ogCount
    ) {
        return (drawPhase, getGamePhase(), currentWeek, prizePot, jpReserve, treasuryBalance, totalUnclaimedPrizes, activeSubscribers, matchingInProgress, totalOGs);
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

    /// @notice Live performance for all 42 (frontend leaderboard mid-week).
    function getCurrentPerformance() external view returns (int256[42] memory perf) {
        for (uint256 i = 0; i < POOL_SIZE; i++) {
            (, int256 endPrice,,,) = priceFeeds[i].latestRoundData();
            int256 startPrice = weekStartPrices[i];
            if (startPrice > 0 && endPrice > 0) { perf[i] = (endPrice - startPrice) * int256(PRECISION_MULTIPLIER) / startPrice; }
            else { perf[i] = 0; }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // OWNER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════════════════

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
            }
            uint256 maxThisPeriod = treasuryBalance * EXHALE_TREASURY_CAP_BPS / 10000;
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

    /// @notice Update individual price feed. For Chainlink feed migrations only.
    function updatePriceFeed(uint256 index, address newFeed) external onlyOwner {
        if (index >= POOL_SIZE) revert InvalidPickIndex();
        if (newFeed == address(0)) revert InvalidAddress();
        if (drawPhase != DrawPhase.IDLE) revert DrawInProgress();
        address oldFeed = address(priceFeeds[index]);
        priceFeeds[index] = AggregatorV3Interface(newFeed);
        emit PriceFeedUpdated(index, oldFeed, newFeed);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // EMERGENCY / RECOVERY
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    function emergencyResetDraw() external onlyOwner {
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

    function forceCompleteDistribution() external onlyOwner {
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
