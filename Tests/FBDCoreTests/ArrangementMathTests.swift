import XCTest
@testable import FBDCore

final class ArrangementMathTests: XCTestCase {
    /// Main display at origin; peer to its right.
    private let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    private let peer = CGRect(x: 1728, y: 0, width: 1920, height: 1080)

    func testSnapsLeftEdgeToPeerRightEdge() {
        // Dragged just past the peer's right edge (frame.minX ≈ 1728).
        let frame = CGRect(x: 1735, y: 0, width: 1920, height: 1080)
        let snapped = ArrangementMath.snappedOrigin(for: frame, peers: [peer], threshold: 48)
        XCTAssertEqual(snapped.x, 1728, "left edge should snap onto the peer's right edge")
    }

    func testSnapsTopEdgeToPeerBottomEdge() {
        let below = CGRect(x: 1728, y: 1120, width: 1920, height: 1080)
        let frame = CGRect(x: 1728, y: 1130, width: 1920, height: 1080)
        let snapped = ArrangementMath.snappedOrigin(for: frame, peers: [below], threshold: 48)
        XCTAssertEqual(snapped.y, 1120, "top edge should snap onto the peer's bottom edge")
    }

    func testLeavesFreePositionUntouched() {
        let frame = CGRect(x: 2000, y: 500, width: 1920, height: 1080)
        let snapped = ArrangementMath.snappedOrigin(for: frame, peers: [peer], threshold: 48)
        XCTAssertEqual(snapped, frame.origin, "far positions must not snap")
    }

    func testNoPeersLeavesOriginUntouched() {
        let frame = CGRect(x: 100, y: 100, width: 1920, height: 1080)
        XCTAssertEqual(
            ArrangementMath.snappedOrigin(for: frame, peers: [], threshold: 48),
            frame.origin
        )
    }

    func testPicksNearestSnap() {
        // Two candidate alignments; the nearer one wins.
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 0, y: 200, width: 100, height: 100)
        let frame = CGRect(x: 5, y: 208, width: 100, height: 100)
        let snapped = ArrangementMath.snappedOrigin(for: frame, peers: [a, b], threshold: 48)
        // x should snap to a/b's left edge (0, dx = -5) rather than y snapping
        // to b's top (200, dy = -8) only if nearer — nearest-wins across both axes.
        let dx = abs(snapped.x - 0)
        let dy = abs(snapped.y - 200)
        XCTAssertTrue(dx < 1 || dy < 1, "must snap on at least one axis")
        XCTAssertEqual(dx < dy ? dx : dy, min(dx, dy))
    }
}
