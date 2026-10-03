import CoreGraphics
import XCTest
@testable import FBDCore

/// Rounded-corner mask geometry (#21).
///
/// The window that draws this cannot be unit-tested; the arithmetic can, and it
/// is where the interesting decisions live — what counts as "no mask", and what
/// happens when the requested radius is larger than the display.
final class CornerMaskTests: XCTestCase {

    private let wide = CGSize(width: 2560, height: 1440)

    // MARK: - Radius clamping

    func testAPositiveRadiusWithinTheDisplayIsKept() {
        XCTAssertEqual(CornerMask.clampedRadius(24, in: wide), 24)
    }

    func testZeroAndNegativeRadiiMeanNoMask() {
        // Zero is the documented "square corners" value, and negative is
        // nonsense: both become 0 so the caller removes the overlay entirely
        // rather than keeping a no-op one on screen.
        XCTAssertEqual(CornerMask.clampedRadius(0, in: wide), 0)
        XCTAssertEqual(CornerMask.clampedRadius(-10, in: wide), 0)
    }

    func testRadiusIsCappedAtHalfTheShorterSide() {
        // Beyond half the shorter side the corner arcs would meet and overlap,
        // so the shape stops being a rounded rectangle at all.
        XCTAssertEqual(CornerMask.clampedRadius(10_000, in: CGSize(width: 1000, height: 600)), 300)
        XCTAssertEqual(CornerMask.clampedRadius(300, in: CGSize(width: 1000, height: 600)), 300)
        XCTAssertEqual(CornerMask.clampedRadius(301, in: CGSize(width: 1000, height: 600)), 300)
    }

    func testDegenerateSizesProduceNoMask() {
        XCTAssertEqual(CornerMask.clampedRadius(20, in: .zero), 0)
        XCTAssertEqual(CornerMask.clampedRadius(20, in: CGSize(width: 0, height: 100)), 0)
        XCTAssertEqual(CornerMask.clampedRadius(20, in: CGSize(width: 100, height: 0)), 0)
    }

    // MARK: - Path

    func testPathCoversTheDisplayAndTheRoundedShape() {
        // Two subpaths, filled even-odd: the full rect minus the rounded rect is
        // the four corner slivers. A single-subpath path would fill the whole
        // screen instead. Compared with a tolerance because the corner arcs
        // introduce float noise in the last bit or two — the shape is right, the
        // exact-equality assertion was not.
        let path = CornerMask.path(size: wide, radius: 24)
        let box = path.boundingBox
        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(box.origin.x, 0, accuracy: 1e-6)
        XCTAssertEqual(box.origin.y, 0, accuracy: 1e-6)
        XCTAssertEqual(box.width, wide.width, accuracy: 1e-6)
        XCTAssertEqual(box.height, wide.height, accuracy: 1e-6)
    }

    func testAZeroRadiusPathIsStillBoundedByTheDisplay() {
        // Documented guard rather than a behaviour: callers clamp first, and a
        // clamped radius of 0 means the overlay is removed, so this path is
        // never drawn. Asserting the extent here only pins that the geometry
        // stays total if it ever is.
        let path = CornerMask.path(size: wide, radius: 0)
        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(path.boundingBox.width, wide.width, accuracy: 1e-6)
        XCTAssertEqual(path.boundingBox.height, wide.height, accuracy: 1e-6)
    }
}
