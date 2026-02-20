// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";

/**
 * @title Crypto42 Swap-and-Pop Fuzz Test
 * @notice Proves: every active subscriber is matched exactly once across
 *         batched matchAndPopulate() calls, despite dynamic array mutations.
 * @dev    Run: forge test --match-contract Crypto42SwapAndPopTest -vvv
 *         Fuzz: forge test --match-contract Crypto42SwapAndPopTest --fuzz-runs 10000
 */
contract SwapAndPopHarness {
    struct Sub {
        uint256 endWeek;
        uint256 listIndex;
        uint256 startWeek;
        bool active;
    }

    address[] public subscriberList;
    mapping(address => Sub) public subs;
    mapping(address => bool) public wasMatched;
    mapping(address => uint256) public matchCount;

    uint256 public currentWeek;
    uint256 public matchingIndex;
    bool public matchingInProgress;
    uint256 public constant MAX_PROCESS_PER_TX = 100;

    function seedSubscribers(uint256 count, uint256 week) external {
        currentWeek = week;
        for (uint256 i = 0; i < count; i++) {
            address user = address(uint160(0x1000 + i));
            subscriberList.push(user);
            subs[user] = Sub({
                endWeek: week + 10,
                listIndex: subscriberList.length,
                startWeek: 1,
                active: true
            });
        }
    }

    function expireSpecific(uint256 index) external {
        require(index < subscriberList.length, "OOB");
        address user = subscriberList[index];
        subs[user].endWeek = currentWeek - 1;
    }

    function matchBatch() external returns (uint256 processed) {
        if (!matchingInProgress) {
            matchingInProgress = true;
            matchingIndex = 0;
        }
        processed = 0;
        while (matchingIndex < subscriberList.length && processed < MAX_PROCESS_PER_TX) {
            address user = subscriberList[matchingIndex];
            Sub storage sub = subs[user];
            if (sub.endWeek < currentWeek) {
                _removeSubscriber(user);
                processed++;
                continue;
            }
            if (sub.startWeek > currentWeek) {
                matchingIndex++;
                processed++;
                continue;
            }
            wasMatched[user] = true;
            matchCount[user]++;
            matchingIndex++;
            processed++;
        }
        if (matchingIndex >= subscriberList.length) {
            matchingInProgress = false;
            matchingIndex = 0;
        }
    }

    function _removeSubscriber(address user) internal {
        Sub storage sub = subs[user];
        uint256 idx = sub.listIndex - 1;
        uint256 lastIdx = subscriberList.length - 1;
        if (idx != lastIdx) {
            address lastUser = subscriberList[lastIdx];
            subscriberList[idx] = lastUser;
            subs[lastUser].listIndex = idx + 1;
        }
        subscriberList.pop();
        sub.listIndex = 0;
        sub.active = false;
    }

    function getSubscriberCount() external view returns (uint256) {
        return subscriberList.length;
    }

    function isMatchingDone() external view returns (bool) {
        return !matchingInProgress;
    }
}

contract Crypto42SwapAndPopTest is Test {
    SwapAndPopHarness harness;

    function setUp() public {
        harness = new SwapAndPopHarness();
    }

    // FUZZ TEST 1: Random subscriber count, random expirations
    function testFuzz_allActiveSubscribersMatchedExactlyOnce(
        uint8 subCount,
        uint256 expireSeed
    ) public {
        uint256 count = bound(uint256(subCount), 1, 200);
        uint256 week = 10;
        harness.seedSubscribers(count, week);
        uint256 expiredCount = 0;
        for (uint256 i = 0; i < count; i++) {
            bool shouldExpire = uint256(keccak256(abi.encode(expireSeed, i))) % 3 == 0;
            if (shouldExpire) {
                harness.expireSpecific(i);
                expiredCount++;
            }
        }
        uint256 expectedActive = count - expiredCount;
        uint256 maxIterations = (count / 100) + 5;
        uint256 iterations = 0;
        do {
            harness.matchBatch();
            iterations++;
            if (iterations > maxIterations) break;
        } while (!harness.isMatchingDone());
        assertTrue(harness.isMatchingDone(), "Matching did not complete");
        uint256 totalMatched = 0;
        for (uint256 i = 0; i < count; i++) {
            address user = address(uint160(0x1000 + i));
            (uint256 endWeek,,,) = harness.subs(user);
            bool wasExpired = endWeek < week;
            if (wasExpired) {
                assertEq(harness.matchCount(user), 0, "Expired subscriber was matched");
            } else {
                assertEq(harness.matchCount(user), 1, "Active subscriber matched != 1 time");
                totalMatched++;
            }
        }
        assertEq(totalMatched, expectedActive, "Total matched != expected active");
        assertEq(harness.getSubscriberCount(), expectedActive, "Final list size != active count");
    }

    // FUZZ TEST 2: All subscribers expired
    function testFuzz_allExpired(uint8 subCount) public {
        uint256 count = bound(uint256(subCount), 1, 200);
        harness.seedSubscribers(count, 10);
        for (uint256 i = 0; i < count; i++) {
            harness.expireSpecific(i);
        }
        do {
            harness.matchBatch();
        } while (!harness.isMatchingDone());
        for (uint256 i = 0; i < count; i++) {
            address user = address(uint160(0x1000 + i));
            assertEq(harness.matchCount(user), 0, "Expired user was matched");
        }
        assertEq(harness.getSubscriberCount(), 0, "List not empty after all expired");
    }

    // FUZZ TEST 3: No expirations (clean pass)
    function testFuzz_noExpirations(uint8 subCount) public {
        uint256 count = bound(uint256(subCount), 1, 200);
        harness.seedSubscribers(count, 10);
        do {
            harness.matchBatch();
        } while (!harness.isMatchingDone());
        for (uint256 i = 0; i < count; i++) {
            address user = address(uint160(0x1000 + i));
            assertEq(harness.matchCount(user), 1, "Clean-pass subscriber not matched once");
        }
        assertEq(harness.getSubscriberCount(), count, "List size changed unexpectedly");
    }

    // FUZZ TEST 4: Consecutive expirations at end (chain reaction)
    function testFuzz_consecutiveExpirationsAtEnd(uint8 subCount) public {
        uint256 count = bound(uint256(subCount), 3, 200);
        harness.seedSubscribers(count, 10);
        uint256 expireFrom = count / 2;
        for (uint256 i = expireFrom; i < count; i++) {
            harness.expireSpecific(i);
        }
        uint256 expectedActive = expireFrom;
        do {
            harness.matchBatch();
        } while (!harness.isMatchingDone());
        uint256 matched = 0;
        for (uint256 i = 0; i < count; i++) {
            address user = address(uint160(0x1000 + i));
            if (harness.matchCount(user) > 0) matched++;
            assertTrue(harness.matchCount(user) <= 1, "Double match detected");
        }
        assertEq(matched, expectedActive, "Chain-reaction: wrong match count");
        assertEq(harness.getSubscriberCount(), expectedActive, "Chain-reaction: wrong list size");
    }

    // FUZZ TEST 5: Single subscriber
    function testFuzz_singleSubscriber(bool expired) public {
        harness.seedSubscribers(1, 10);
        if (expired) harness.expireSpecific(0);
        harness.matchBatch();
        address user = address(uint160(0x1000));
        if (expired) {
            assertEq(harness.matchCount(user), 0);
            assertEq(harness.getSubscriberCount(), 0);
        } else {
            assertEq(harness.matchCount(user), 1);
            assertEq(harness.getSubscriberCount(), 1);
        }
    }

    // FUZZ TEST 6: Batch boundary stress test (250 subs = 3+ batches)
    function testFuzz_batchBoundaryWithExpirations(uint256 expireSeed) public {
        uint256 count = 250;
        harness.seedSubscribers(count, 10);
        uint256 expiredCount = 0;
        for (uint256 i = 0; i < count; i++) {
            if (uint256(keccak256(abi.encode(expireSeed, i))) % 3 == 0) {
                harness.expireSpecific(i);
                expiredCount++;
            }
        }
        uint256 batches = 0;
        do {
            harness.matchBatch();
            batches++;
            require(batches < 20, "Too many batches");
        } while (!harness.isMatchingDone());
        assertTrue(batches >= 2, "Should require multiple batches");
        uint256 matched = 0;
        for (uint256 i = 0; i < count; i++) {
            address user = address(uint160(0x1000 + i));
            if (harness.matchCount(user) == 1) matched++;
            assertTrue(harness.matchCount(user) <= 1, "Double match in batch boundary test");
        }
        assertEq(matched, count - expiredCount, "Batch boundary: wrong total matched");
    }

    // FUZZ TEST 7: Expire at position 0 (first element)
    function testFuzz_expireFirstElement(uint8 subCount) public {
        uint256 count = bound(uint256(subCount), 2, 200);
        harness.seedSubscribers(count, 10);
        harness.expireSpecific(0);
        do {
            harness.matchBatch();
        } while (!harness.isMatchingDone());
        uint256 matched = 0;
        for (uint256 i = 0; i < count; i++) {
            address user = address(uint160(0x1000 + i));
            if (harness.matchCount(user) == 1) matched++;
        }
        assertEq(matched, count - 1, "Expire-first: wrong match count");
        assertEq(harness.getSubscriberCount(), count - 1);
    }
}
