import CoreGraphics
import CoreMedia
import XCTest
@testable import FBDCore

/// Per-stream frame rate (#14) and cursor-containment geometry.
///
/// Both are pure precisely so they can be tested here: the rate must agree
/// between the parser's validation and the configuration builder, and the
/// containment decision must be provable without moving anyone's pointer.
final class StreamFrameRateTests: XCTestCase {

    // MARK: - Rate

    func testUnspecifiedFallsBackToTheHistoricalValue() {
        // 15 fps is what FBD used before the rate was configurable, so an
        // existing invocation keeps behaving exactly as it did.
        XCTAssertEqual(StreamFrameRate.resolved(fps: nil), 15)
        XCTAssertEqual(StreamFrameRate.default, 15)
    }

    func testASpecifiedRateIsUsed() {
        XCTAssertEqual(StreamFrameRate.resolved(fps: 60), 60)
        XCTAssertEqual(StreamFrameRate.resolved(fps: 1), 1)
        XCTAssertEqual(StreamFrameRate.resolved(fps: 120), 120)
    }

    func testAnOutOfRangeRateFallsBackRatherThanDividingByZero() {
        // Defence in depth: the parser rejects these, and the resolver refuses
        // to build a zero or negative CMTime timebase if one ever reached it.
        XCTAssertEqual(StreamFrameRate.resolved(fps: 0), StreamFrameRate.default)
        XCTAssertEqual(StreamFrameRate.resolved(fps: -1), StreamFrameRate.default)
        XCTAssertEqual(StreamFrameRate.resolved(fps: 9999), StreamFrameRate.default)
    }

    func testTheIntervalIsTheReciprocalOfTheRate() {
        // minimumFrameInterval is the MAXIMUM gap between frames, so 60 fps is
        // a 1/60 s interval. Getting this backwards would make the cap a floor.
        let sixty = StreamFrameRate.interval(forFPS: 60)
        XCTAssertEqual(sixty.value, 1)
        XCTAssertEqual(sixty.timescale, 60)
        XCTAssertEqual(CMTimeGetSeconds(sixty), 1.0 / 60.0, accuracy: 1e-9)

        let fifteen = StreamFrameRate.interval(forFPS: 15)
        XCTAssertEqual(CMTimeGetSeconds(fifteen), 1.0 / 15.0, accuracy: 1e-9)

        // A higher rate is a shorter interval — the direction that makes a cap.
        XCTAssertLessThan(CMTimeGetSeconds(sixty), CMTimeGetSeconds(fifteen))
    }

    func testLabelReportsTheResolvedRate() {
        XCTAssertEqual(StreamFrameRate.label(fps: 30), "30 fps")
        XCTAssertEqual(StreamFrameRate.label(fps: nil), "15 fps")
    }
}

final class CursorContainmentTests: XCTestCase {

    /// A 1440-wide right-hand display, as on the development machine.
    private let right = CGRect(x: 1728, y: 0, width: 2560, height: 1440)
    /// The built-in panel to its left, used as the fallback.
    private let left = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    func testAPointerOutsideTheForbiddenDisplayIsLeftAlone() {
        // The overwhelmingly common case, and the one that must stay free: a
        // user who has not opted in never notices anything.
        XCTAssertNil(CursorContainment.repelledPosition(
            cursor: CGPoint(x: 100, y: 100), forbidden: right, fallback: left
        ))
    }

    func testAPointerInsideIsPushedOut() {
        let cursor = CGPoint(x: 2000, y: 500)
        guard let target = CursorContainment.repelledPosition(
            cursor: cursor, forbidden: right, fallback: left
        ) else {
            return XCTFail("expected the pointer to be pushed out")
        }
        XCTAssertFalse(right.contains(target))
        XCTAssertTrue(left.contains(target), "the pointer must land on a real display")
    }

    func testThePointerLeavesByTheNearestEdge() {
        // Entering just past the left edge should come back out of the left
        // edge, not teleport to the far side of the desktop.
        let cursor = CGPoint(x: 1730, y: 500)
        guard let target = CursorContainment.repelledPosition(
            cursor: cursor, forbidden: right, fallback: left
        ) else {
            return XCTFail("expected the pointer to be pushed out")
        }
        XCTAssertGreaterThan(target.x, 1700, "should exit rightwards, staying near where it entered")
        XCTAssertEqual(target.y, cursor.y, accuracy: 1e-9, "the other axis should be preserved")
    }

    func testADegenerateFallbackIsRefusedRatherThanWarpedToNowhere() {
        // Refusing is better than warping the pointer to a coordinate that is on
        // no display at all.
        XCTAssertNil(CursorContainment.repelledPosition(
            cursor: CGPoint(x: 2000, y: 500),
            forbidden: right,
            fallback: CGRect(x: 1728, y: 0, width: 1, height: 1)
        ))
    }

    func testASingleDisplayMacCannotContain() {
        // The controller refuses to start in this case; this pins the geometry
        // that makes that right — there is nowhere to push the pointer.
        XCTAssertNil(CursorContainment.repelledPosition(
            cursor: CGPoint(x: 2000, y: 500), forbidden: right, fallback: .zero
        ))
    }
}
