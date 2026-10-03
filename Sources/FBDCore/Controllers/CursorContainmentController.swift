import CoreGraphics
import Foundation
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "CursorContainmentController")

/// Keeps the pointer off a display while it is being streamed (#14), so a
/// cursor that has wandered onto it never appears in the stream.
///
/// **A polling timer, not a `CGEventTap`.** Warping the pointer needs no
/// permission at all, whereas *listening* to events needs Accessibility — and
/// asking the user for Accessibility in order to hide a cursor would be a poor
/// trade. The geometry lives in `CursorContainment` so it is testable without
/// moving anyone's pointer; this class only supplies the display bounds and the
/// timer.
///
/// Experimental upstream (BetterDisplay 5.0.4+), and gated in FBD behind
/// `Settings.experimentalCursorContainment` — it moves the user's pointer, so
/// it is never on unless a stream asks for it *and* the setting allows it.
@MainActor
public final class CursorContainmentController {
    private var timer: Timer?
    private var forbidden: CGRect = .zero
    private var fallback: CGRect = .zero

    /// Polled at 60 Hz. The work per tick is a containment test that fails
    /// immediately for a pointer that is anywhere else — the usual case.
    private let interval: TimeInterval = 1.0 / 60.0

    public init() {}

    /// True while a containment request is active.
    public var isActive: Bool { timer != nil }

    /// Start keeping the pointer off `displayID`.
    ///
    /// Refuses — rather than spinning a timer — when there is **no other
    /// display to move the pointer to**. On a single-display Mac containment
    /// would mean fighting the user for the only screen there is.
    public func start(keepingPointerOff displayID: CGDirectDisplayID) {
        stop()
        let others = activeDisplays().filter { $0 != displayID }.map { CGDisplayBounds($0) }
        guard let first = others.first else {
            log.warning("cursor containment: no other display to move the pointer to; not starting")
            return
        }
        forbidden = CGDisplayBounds(displayID)
        fallback = others.dropFirst().reduce(first) { $0.union($1) }
        guard CursorContainment.repelledPosition(
            cursor: .zero, forbidden: .init(x: -10, y: -10, width: 5, height: 5), fallback: fallback
        ) == nil else { return }  // fallback too small to receive the pointer
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.repelIfNeeded() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func repelIfNeeded() {
        guard let event = CGEvent(source: nil) else { return }
        guard let target = CursorContainment.repelledPosition(
            cursor: event.location, forbidden: forbidden, fallback: fallback
        ) else { return }
        CGWarpMouseCursorPosition(target)
    }

    private func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
