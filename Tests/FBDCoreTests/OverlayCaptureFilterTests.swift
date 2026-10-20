import CoreGraphics
import CoreVideo
import XCTest
@testable import FBDCore

/// The overlay's capture setup (issue: the blank white display).
///
/// The capture pipeline itself needs Screen Recording and a real display,
/// neither of which a unit test has — so what is tested here are the
/// decisions that decide what the user sees: which windows the capture
/// excludes, the level the overlay windows sit at, and the rule that keeps
/// the window invisible until there is a real frame to show.
final class OverlayCaptureFilterTests: XCTestCase {
    // MARK: - The exclusion

    /// The shareable content is an asynchronous snapshot, and the overlay
    /// window is ordered front microseconds before the capture starts — so
    /// the first snapshot usually does not contain it. A capture that
    /// contains the overlay is a feedback loop: the overlay renders the
    /// capture, the next capture contains the overlay, and the first frame
    /// latches forever (a uniform white display).
    ///
    /// So the snapshot that *does* contain the overlay's own window is the
    /// one the exclusion is built from.
    func testTheSnapshotThatContainsTheOverlayIsTheOneUsed() {
        let own: CGWindowID = 42
        let dim: CGWindowID = 43
        let plan = OverlayController.captureExclusion(
            snapshots: [[1, 2, 3], [1, 2, 3, own], [1, 2, 3, own, dim]],
            overlay: [own, dim],
            own: own
        )

        XCTAssertEqual(plan, .excludeWindows([own, dim]),
                       "the freshest snapshot that holds the overlay decides the exclusion")
    }

    /// A snapshot without our window proves nothing: the capture could
    /// contain the overlay, so it cannot be used.
    func testASnapshotWithoutTheOverlayIsNotUsed() {
        let own: CGWindowID = 42
        let plan = OverlayController.captureExclusion(
            snapshots: [[1, 2, 3]],
            overlay: [own],
            own: own
        )

        XCTAssertEqual(plan, .excludeApplication,
                       "without the overlay in the snapshot the capture falls back to excluding the app")
    }

    /// The fallback is the deterministic one: the running application is
    /// excluded, so the capture can never contain the overlay even if the
    /// window list never caught up.
    func testTheFallbackExcludesTheApplication() {
        let own: CGWindowID = 42
        let plan = OverlayController.captureExclusion(
            snapshots: [[1, 2, 3], [1, 2, 3]],
            overlay: [own],
            own: own
        )

        XCTAssertEqual(plan, .excludeApplication)
    }

    /// Only FBD's own windows are excluded — the desktop's windows have to
    /// stay in the capture, that is the whole point of the filter.
    func testOnlyFBDsOwnWindowsAreExcluded() {
        let own: CGWindowID = 42
        let plan = OverlayController.captureExclusion(
            snapshots: [[1, 2, own, 99]],
            overlay: [own],
            own: own
        )

        XCTAssertEqual(plan, .excludeWindows([own]))
    }

    // MARK: - The window level

    /// The overlay used to sit at the shielding level — the one macOS
    /// reserves for content that must not appear in a screen recording. A
    /// capture that covers such a window can come back blanked instead of
    /// showing the desktop, which paints the whole display white.
    func testTheOverlaySitsBelowTheShieldingLevel() {
        XCTAssertLessThan(
            OverlayController.captureSafeLevel.rawValue,
            Int(CGShieldingWindowLevel()),
            "the capture blanks what sits at the shielding level"
        )
    }

    /// …but still above the desktop, the Dock and the menu bar: the filter
    /// has to cover them.
    func testTheOverlayCoversTheDesktop() {
        XCTAssertGreaterThan(
            OverlayController.captureSafeLevel.rawValue,
            Int(CGWindowLevelForKey(.statusWindow)),
            "the filter has to be above the menu bar and its items"
        )
        XCTAssertGreaterThan(
            OverlayController.captureSafeLevel.rawValue,
            Int(CGWindowLevelForKey(.dockWindow)),
            "the filter has to be above the Dock"
        )
        XCTAssertLessThan(
            OverlayController.captureSafeLevel.rawValue,
            Int(CGWindowLevelForKey(.screenSaverWindow)),
            "and below the screen saver"
        )
    }

    /// The software dim and the corner mask sit on top of the filter's
    /// output — they dim and mask what the filter renders, rather than
    /// being hidden behind it. Both stay below the shielding level, though:
    /// they live in the captured region too.
    func testTheDimAndMaskSitAboveTheFilterButBelowTheShieldingLevel() {
        XCTAssertGreaterThan(
            OverlayController.overlayTopLevel.rawValue,
            OverlayController.captureSafeLevel.rawValue
        )
        XCTAssertLessThan(
            OverlayController.overlayTopLevel.rawValue,
            Int(CGShieldingWindowLevel())
        )
    }

    // MARK: - The reveal gate

    /// The window is ordered front before the capture exists (it has to be,
    /// so the capture can exclude it), and an undrawn Metal layer is an
    /// undefined (white) surface. So the window stays invisible until a
    /// frame has been rendered.
    func testTheWindowStaysInvisibleUntilAFrameHasBeenRendered() {
        var gate = OverlayController.RevealGate()

        XCTAssertFalse(gate.revealed, "nothing has been rendered yet")
        XCTAssertTrue(gate.frameRendered(), "the first rendered frame may show the window")
        XCTAssertTrue(gate.revealed)
        XCTAssertEqual(gate.framesRendered, 1)
    }

    /// The window is shown once; later frames do not re-trigger it.
    func testTheWindowIsRevealedOnlyOnce() {
        var gate = OverlayController.RevealGate()

        XCTAssertTrue(gate.frameRendered())
        XCTAssertFalse(gate.frameRendered(), "the window is already up")
        XCTAssertEqual(gate.framesRendered, 2)
    }

    // MARK: - Failing closed

    /// A capture that never delivers a frame is not going to work, and the
    /// display is better off without the overlay than painted with an
    /// undrawn one — so the session is torn down after a few seconds.
    func testTheCaptureFailsClosedAfterAFewSeconds() {
        let seconds = OverlayController.firstFrameTimeout.components.seconds

        XCTAssertGreaterThan(seconds, 1, "a slow capture is not a broken one")
        XCTAssertLessThanOrEqual(seconds, 10, "but the user is not left looking at a dead overlay")
    }

    /// The exclusion waits for the window to be published — a bounded number
    /// of snapshots, each a moment apart.
    func testTheExclusionWaitsForTheWindowButOnlyForABoundedTime() {
        XCTAssertGreaterThan(OverlayController.snapshotAttempts, 1,
                             "one snapshot is exactly the race this fixes")
        XCTAssertLessThanOrEqual(OverlayController.snapshotAttempts, 20)
        XCTAssertGreaterThan(OverlayController.snapshotRetryDelay, 0)
    }

    // MARK: - The frame diagnostic

    /// The first frame is the diagnosis of a white display: a frame that
    /// comes back uniformly white says the capture was blanked or contains
    /// the overlay itself.
    func testTheFirstFramesAverageColourIsReported() {
        let white = makeBuffer(width: 32, height: 32, color: (r: 255, g: 255, b: 255))
        let color = white.flatMap { CapturedFrame.averageColor(of: $0) }

        XCTAssertNotNil(color)
        XCTAssertEqual(color?.r ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(color?.g ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(color?.b ?? 0, 1, accuracy: 0.01)
    }

    /// A mid-grey frame is not white — the diagnostic has to tell the two
    /// apart.
    func testTheAverageColourIsNotAlwaysWhite() {
        let grey = makeBuffer(width: 32, height: 32, color: (r: 128, g: 128, b: 128))
        let color = grey.flatMap { CapturedFrame.averageColor(of: $0) }

        XCTAssertNotNil(color)
        XCTAssertEqual(color?.r ?? 0, 128.0 / 255.0, accuracy: 0.02)
        XCTAssertEqual(color?.g ?? 0, 128.0 / 255.0, accuracy: 0.02)
        XCTAssertEqual(color?.b ?? 0, 128.0 / 255.0, accuracy: 0.02)
    }

    /// The channels are read in the right order: the capture is BGRA, so a
    /// red frame must read as red and not as blue.
    func testTheChannelsAreReadInTheCapturesOrder() {
        let red = makeBuffer(width: 16, height: 16, color: (r: 255, g: 0, b: 0))
        let color = red.flatMap { CapturedFrame.averageColor(of: $0) }

        XCTAssertEqual(color?.r ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(color?.g ?? 0, 0, accuracy: 0.01)
        XCTAssertEqual(color?.b ?? 0, 0, accuracy: 0.01)
    }

    /// A frame in a format the diagnostic does not know is reported as
    /// unknown rather than as a wrong colour.
    func testAnUnknownPixelFormatHasNoAverage() {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            16,
            kCVPixelFormatType_OneComponent8,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            return XCTFail("could not create the test buffer")
        }

        XCTAssertNil(CapturedFrame.averageColor(of: buffer))
    }

    // MARK: - Helpers

    /// A uniformly coloured pixel buffer in the capture's own format.
    private func makeBuffer(
        width: Int,
        height: Int,
        color: (r: UInt8, g: UInt8, b: UInt8)
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                bytes[offset + 0] = color.b
                bytes[offset + 1] = color.g
                bytes[offset + 2] = color.r
                bytes[offset + 3] = 255
            }
        }
        return buffer
    }
}
