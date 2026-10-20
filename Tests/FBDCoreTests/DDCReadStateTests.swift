import XCTest
import FBDCore

/// The quarantine state machine (issue #25): a display whose DDC controller
/// stops answering must fail fast instead of hanging every read.
///
/// The machine is pure — it is driven by an injected clock — so it can be
/// tested without a display and without waiting.
final class DDCReadStateTests: XCTestCase {
    /// A clock the test moves by hand.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var now: Date

        init(_ now: Date = Date(timeIntervalSince1970: 1_000_000)) {
            self.now = now
        }

        var current: Date {
            lock.lock()
            defer { lock.unlock() }
            return now
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock()
            now = now.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    func testFailuresAccumulateUntilTheThreshold() {
        let clock = Clock()
        let health = DDCReadHealth(failureThreshold: 3, now: { clock.current })

        XCTAssertFalse(health.recordFailure("a", elapsed: 0.1))
        XCTAssertFalse(health.recordFailure("a", elapsed: 0.1))
        XCTAssertFalse(health.isQuarantined("a"))
        XCTAssertTrue(health.recordFailure("a", elapsed: 0.1))

        XCTAssertTrue(health.isQuarantined("a"))
        XCTAssertEqual(health.failureStreak("a"), 3)
    }

    func testOneDisplayDoesNotAffectAnother() {
        let clock = Clock()
        let health = DDCReadHealth(failureThreshold: 1, now: { clock.current })

        XCTAssertTrue(health.recordFailure("a", elapsed: 0.1))

        XCTAssertTrue(health.isQuarantined("a"))
        XCTAssertFalse(health.isQuarantined("b"))
    }

    func testASuccessClearsTheStreak() {
        let clock = Clock()
        let health = DDCReadHealth(failureThreshold: 3, now: { clock.current })

        _ = health.recordFailure("a", elapsed: 0.1)
        _ = health.recordFailure("a", elapsed: 0.1)
        health.recordSuccess("a")

        XCTAssertEqual(health.failureStreak("a"), 0)
        XCTAssertFalse(health.isQuarantined("a"))
    }

    func testASingleSlowAttemptQuarantinesImmediately() {
        let clock = Clock()
        let health = DDCReadHealth(failureThreshold: 6, now: { clock.current })

        // A channel that takes seconds to answer is not answering at all.
        XCTAssertTrue(health.recordFailure("a", elapsed: 3.5))

        XCTAssertTrue(health.isQuarantined("a"))
    }

    func testTheQuarantineExpiresAfterTheInterval() {
        let clock = Clock()
        let health = DDCReadHealth(
            failureThreshold: 1,
            quarantineInterval: 600,
            now: { clock.current }
        )
        XCTAssertTrue(health.recordFailure("a", elapsed: 0.1))
        XCTAssertTrue(health.isQuarantined("a"))

        clock.advance(601)

        // The window is over: the display gets one fresh probe.
        XCTAssertFalse(health.isQuarantined("a"))
        XCTAssertEqual(health.failureStreak("a"), 0)
    }

    func testAFailureAfterTheWindowQuarantinesAgain() {
        let clock = Clock()
        let health = DDCReadHealth(
            failureThreshold: 1,
            quarantineInterval: 600,
            now: { clock.current }
        )
        XCTAssertTrue(health.recordFailure("a", elapsed: 0.1))
        clock.advance(601)
        XCTAssertFalse(health.isQuarantined("a"))

        // The fresh probe failed too.
        XCTAssertTrue(health.recordFailure("a", elapsed: 0.1))
        XCTAssertTrue(health.isQuarantined("a"))
    }

    func testResetForgetsEverything() {
        let clock = Clock()
        let health = DDCReadHealth(failureThreshold: 1, now: { clock.current })
        XCTAssertTrue(health.recordFailure("a", elapsed: 0.1))

        health.reset("a")

        XCTAssertFalse(health.isQuarantined("a"))
        XCTAssertEqual(health.failureStreak("a"), 0)
    }

    // MARK: - Cache entry

    func testCacheEntryExpiresAfterTheTTL() {
        let entry = DDCReadCacheEntry(currentValue: 50, maxValue: 100, timestamp: Date(timeIntervalSince1970: 0))

        XCTAssertFalse(entry.isExpired(now: Date(timeIntervalSince1970: 4), ttl: 5))
        XCTAssertTrue(entry.isExpired(now: Date(timeIntervalSince1970: 6), ttl: 5))
    }
}
