import XCTest
import FBDCore

/// The DDC traffic gate and the topology hold (issue #25).
///
/// The gate exists because WindowServer's display enable waits behind an
/// in-flight I2C transaction and freezes the whole Mac with it; the hold is
/// how a topology change gets the bus to itself.
final class DDCQueuePoolTests: XCTestCase {
    /// A flag that can be read from another thread without a data race.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    func testTheSameDisplayAlwaysGetsTheSameQueue() {
        let pool = DDCQueuePool()

        XCTAssertEqual(pool.queue(for: "a"), pool.queue(for: "a"))
        XCTAssertNotEqual(pool.queue(for: "a"), pool.queue(for: "b"))
    }

    func testATransactionIsAllowedWhileTrafficIsFree() {
        let pool = DDCQueuePool()

        XCTAssertTrue(pool.beginTransaction())
        pool.endTransaction()
        XCTAssertTrue(pool.beginTransaction())
        pool.endTransaction()
    }

    func testTransactionsAreRefusedWhileTrafficIsPaused() {
        let pool = DDCQueuePool()

        let hold = pool.hold()

        XCTAssertTrue(pool.isPaused)
        XCTAssertFalse(pool.beginTransaction(), "the bus must not be touched while a topology change is in progress")

        hold.release()

        XCTAssertFalse(pool.isPaused)
        XCTAssertTrue(pool.beginTransaction())
        pool.endTransaction()
    }

    func testNestedHoldsKeepTrafficPausedUntilTheLastOneIsReleased() {
        let pool = DDCQueuePool()

        let outer = pool.hold()
        let inner = pool.hold()

        XCTAssertFalse(pool.beginTransaction())
        inner.release()
        XCTAssertFalse(pool.beginTransaction(), "the outer hold still pauses traffic")
        outer.release()
        XCTAssertTrue(pool.beginTransaction())
        pool.endTransaction()
    }

    func testTheHoldWaitsForTheTransactionInFlightToDrain() {
        let pool = DDCQueuePool()
        let started = expectation(description: "transaction started")
        let release = DispatchSemaphore(value: 0)
        let returned = Flag()

        DispatchQueue.global().async {
            XCTAssertTrue(pool.beginTransaction())
            started.fulfill()
            release.wait()
            pool.endTransaction()
        }
        wait(for: [started], timeout: 2)

        let holdReturned = expectation(description: "hold returned")
        DispatchQueue.global().async {
            let hold = pool.hold(timeout: 5)
            returned.set()
            holdReturned.fulfill()
            hold.release()
        }

        // While the transaction is in flight the hold must not have returned:
        // that wait is the whole point of the hold.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(returned.isSet, "the hold returned while a transaction was still in flight")

        release.signal()
        wait(for: [holdReturned], timeout: 5)
        XCTAssertTrue(returned.isSet)
    }

    func testWithTrafficPausedRunsTheBodyAndResumesTraffic() {
        let pool = DDCQueuePool()
        var pausedDuringBody = false

        pool.withTrafficPaused {
            pausedDuringBody = pool.isPaused
        }

        XCTAssertTrue(pausedDuringBody)
        XCTAssertFalse(pool.isPaused)
    }

    func testWithTrafficPausedResumesTrafficWhenTheBodyThrows() {
        struct Boom: Error {}
        let pool = DDCQueuePool()

        XCTAssertThrowsError(try pool.withTrafficPaused { throw Boom() })

        XCTAssertFalse(pool.isPaused, "a failed topology change must not silence DDC for the rest of the session")
    }

    func testAnAbandonedHoldReleasesItself() {
        let pool = DDCQueuePool()
        var hold: DDCQueuePool.Hold? = pool.hold()
        XCTAssertTrue(pool.isPaused)

        hold = nil

        XCTAssertFalse(pool.isPaused)
    }
}
