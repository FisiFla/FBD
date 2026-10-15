import CoreGraphics
import XCTest
@testable import FBDCore

/// The geometry behind the edge-crossing pointer (Crisp item 9).
///
/// These are pure: every case is a point, a push and a set of display bounds, so
/// the whole rule is pinned here without moving anyone's pointer. The controller
/// that feeds the real pointer through it has nothing of its own to get wrong.
final class EdgeCrossingMathTests: XCTestCase {
    /// A 1080-tall display on the left: the classic "my second monitor is taller"
    /// arrangement, with the taller one shifted down so half of it is level with
    /// the shorter one and half is not.
    private let shortLeft = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let tallRightLowered = CGRect(x: 1920, y: 360, width: 2560, height: 1440)

    private func push(_ dx: CGFloat, _ dy: CGFloat) -> CGVector { CGVector(dx: dx, dy: dy) }

    // MARK: - Moves macOS makes on its own

    /// Where the two displays are level, macOS crosses by itself — the pointer is
    /// moving into a display that is genuinely under it, and there is nothing to
    /// do. This is also what keeps an aligned arrangement behaving exactly as it
    /// did before the feature existed.
    func testAnAlignedEdgeIsLeftToMacOS() {
        let left = CGRect(x: 0, y: 0, width: 100, height: 100)
        let right = CGRect(x: 100, y: 0, width: 100, height: 100)
        XCTAssertNil(EdgeCrossingMath.landing(
            from: CGPoint(x: 99, y: 50), push: push(1, 0), displays: [left, right]
        ))
    }

    /// The pointer has to be *at* the pushed edge for a push to mean anything.
    func testAPushInTheMiddleOfADisplayIsIgnored() {
        XCTAssertNil(EdgeCrossingMath.landing(
            from: CGPoint(x: 900, y: 500), push: push(1, 0), displays: [shortLeft, tallRightLowered]
        ))
    }

    /// Pushing the other way moves the pointer across the display, not out of it.
    func testAPushAwayFromTheEdgeIsIgnored() {
        XCTAssertNil(EdgeCrossingMath.landing(
            from: CGPoint(x: 1919, y: 100), push: push(-1, 0), displays: [shortLeft, tallRightLowered]
        ))
    }

    func testASingleDisplayNeverMoves() {
        XCTAssertNil(EdgeCrossingMath.landing(
            from: CGPoint(x: 1919, y: 500), push: push(1, 0), displays: [shortLeft]
        ))
    }

    func testNoDisplaysNeverMoves() {
        XCTAssertNil(EdgeCrossingMath.landing(
            from: CGPoint(x: 100, y: 100), push: push(1, 0), displays: []
        ))
    }

    /// A push of zero carries no direction, so there is no edge to cross.
    func testAZeroPushDoesNothing() {
        XCTAssertNil(EdgeCrossingMath.landing(
            from: CGPoint(x: 1919, y: 100), push: push(0, 0), displays: [shortLeft, tallRightLowered]
        ))
    }

    // MARK: - The dead space beside a shorter display

    /// Above the taller display's top edge: the pointer is pushed at the short
    /// display's right edge, and is moved up the neighbour's side to its top
    /// corner — where the neighbour actually starts.
    func testPointerLevelWithTheNeighbourIsLeftToMacOS() {
        // Level with both displays, this is macOS's own crossing.
        XCTAssertNil(EdgeCrossingMath.landing(
            from: CGPoint(x: 1919, y: 800), push: push(1, 0), displays: [shortLeft, tallRightLowered]
        ))
    }

    func testPointerAboveTheNeighbourLandsOnItsTopEdge() {
        let landing = EdgeCrossingMath.landing(
            from: CGPoint(x: 1919, y: 100), push: push(1, 0), displays: [shortLeft, tallRightLowered]
        )
        XCTAssertEqual(landing, CGPoint(x: 1920, y: 360))
    }

    /// Below the neighbour's bottom edge the landing is clamped inside it, not
    /// onto its boundary row.
    func testPointerBelowTheNeighbourLandsInsideIt() {
        let shorterRight = CGRect(x: 1920, y: 0, width: 2560, height: 1000)
        let landing = EdgeCrossingMath.landing(
            from: CGPoint(x: 1919, y: 1050), push: push(1, 0), displays: [shortLeft, shorterRight]
        )
        XCTAssertEqual(landing, CGPoint(x: 1920, y: 999))
        XCTAssertTrue(shorterRight.contains(landing!))
    }

    // MARK: - Leftwards, and along the other axis

    func testPushFromALeftEdgeCrossesToTheNeighboursBottomEdge() {
        // Below the left display's bottom edge, so macOS would not cross here.
        let landing = EdgeCrossingMath.landing(
            from: CGPoint(x: 1921, y: 1200), push: push(-1, 0), displays: [shortLeft, tallRightLowered]
        )
        XCTAssertEqual(landing, CGPoint(x: 1919, y: 1079))
        XCTAssertTrue(shortLeft.contains(landing!))
    }

    func testPushDownSlidesToTheNeighboursLeftEdge() {
        let below = CGRect(x: 200, y: 1080, width: 1600, height: 900)
        let landing = EdgeCrossingMath.landing(
            from: CGPoint(x: 100, y: 1079), push: push(0, 1), displays: [shortLeft, below]
        )
        XCTAssertEqual(landing, CGPoint(x: 200, y: 1080))
        XCTAssertTrue(below.contains(landing!))
    }

    func testPushUpSlidesToTheNeighboursLeftEdge() {
        let above = CGRect(x: 200, y: -900, width: 1600, height: 900)
        let landing = EdgeCrossingMath.landing(
            from: CGPoint(x: 100, y: 1), push: push(0, -1), displays: [shortLeft, above]
        )
        XCTAssertEqual(landing, CGPoint(x: 200, y: -1))
        XCTAssertTrue(above.contains(landing!))
    }

    /// Stacked flush, a downward push in the overlap is macOS's own crossing.
    func testAStackedOverlapIsLeftToMacOS() {
        let below = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        XCTAssertNil(EdgeCrossingMath.landing(
            from: CGPoint(x: 1000, y: 1079), push: push(0, 1), displays: [shortLeft, below]
        ))
    }

    // MARK: - Arrangements that must not change

    /// A gap between displays is a deliberate choice about the arrangement: the
    /// edges do not meet, so nothing crosses.
    func testADeliberateGapIsRespected() {
        let gapped = CGRect(x: 1940, y: 360, width: 2560, height: 1440)
        XCTAssertNil(EdgeCrossingMath.landing(
            from: CGPoint(x: 1919, y: 100), push: push(1, 0), displays: [shortLeft, gapped]
        ))
    }

    /// The pointer is clamped a fraction inside the display, and can also be left
    /// a fraction past an edge; either way the display it belongs to is found.
    func testPointerJustPastTheEdgeStillCrosses() {
        let landing = EdgeCrossingMath.landing(
            from: CGPoint(x: 1925, y: 100), push: push(1, 0), displays: [shortLeft, tallRightLowered]
        )
        XCTAssertEqual(landing, CGPoint(x: 1920, y: 360))
    }

    // MARK: - Choosing between neighbours

    /// Two displays to the right, neither covering the pointer's line: the one
    /// that moves the pointer least wins, so a two-row nudge beats a long slide.
    func testTheNearestNeighbourWins() {
        let here = CGRect(x: 0, y: 0, width: 100, height: 100)
        let upperRight = CGRect(x: 100, y: 0, width: 100, height: 40)
        let lowerRight = CGRect(x: 100, y: 60, width: 100, height: 40)
        let landing = EdgeCrossingMath.landing(
            from: CGPoint(x: 99, y: 50), push: push(1, 0), displays: [here, upperRight, lowerRight]
        )
        XCTAssertEqual(landing, CGPoint(x: 100, y: 60))
        XCTAssertTrue(lowerRight.contains(landing!))
    }

    /// Displays that meet at a corner take the push on either axis, so a diagonal
    /// shove out of the bottom-right corner still lands on the neighbour.
    func testACornerNeighbourTakesThePushOnEitherAxis() {
        let here = CGRect(x: 0, y: 0, width: 100, height: 100)
        let corner = CGRect(x: 100, y: 100, width: 100, height: 100)
        XCTAssertEqual(
            EdgeCrossingMath.landing(from: CGPoint(x: 99, y: 99), push: push(1, 0), displays: [here, corner]),
            CGPoint(x: 100, y: 100)
        )
        XCTAssertEqual(
            EdgeCrossingMath.landing(from: CGPoint(x: 99, y: 99), push: push(0, 1), displays: [here, corner]),
            CGPoint(x: 100, y: 100)
        )
    }

    // MARK: - The invariant that actually matters

    /// Every landing has to be a point the neighbour really has: a warp anywhere
    /// else would be bounced straight back by macOS's own clamping and the
    /// pointer would appear not to have moved at all.
    func testEveryLandingLiesInsideTheDisplayItCrossesTo() {
        let situations: [(point: CGPoint, push: CGVector, displays: [CGRect], target: CGRect)] = [
            (CGPoint(x: 1919, y: 100), push(1, 0), [shortLeft, tallRightLowered], tallRightLowered),
            (CGPoint(x: 1919, y: 1070), push(1, 0),
             [shortLeft, CGRect(x: 1920, y: 1100, width: 2560, height: 1440)],
             CGRect(x: 1920, y: 1100, width: 2560, height: 1440)),
            (CGPoint(x: 1921, y: 1200), push(-1, 0), [shortLeft, tallRightLowered], shortLeft),
            (CGPoint(x: 100, y: 1079), push(0, 1),
             [shortLeft, CGRect(x: 200, y: 1080, width: 1600, height: 900)],
             CGRect(x: 200, y: 1080, width: 1600, height: 900)),
            (CGPoint(x: 100, y: 1), push(0, -1),
             [shortLeft, CGRect(x: 200, y: -900, width: 1600, height: 900)],
             CGRect(x: 200, y: -900, width: 1600, height: 900)),
        ]
        for situation in situations {
            let landing = EdgeCrossingMath.landing(
                from: situation.point, push: situation.push, displays: situation.displays
            )
            XCTAssertNotNil(landing, "expected a crossing from \(situation.point)")
            XCTAssertTrue(
                situation.target.contains(landing ?? .zero),
                "landing \(landing.map(String.init(describing:)) ?? "nil") is outside \(situation.target)"
            )
        }
    }
}
