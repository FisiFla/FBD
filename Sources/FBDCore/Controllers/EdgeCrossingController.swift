import AppKit
import CoreGraphics
import Foundation
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "EdgeCrossingController")

/// Lets the pointer cross between displays whose facing edges do not line up.
///
/// macOS moves the pointer across a shared edge only where the two displays
/// actually overlap. Push at the bottom of a short display that sits beside a
/// taller one and the pointer pins against its edge and goes no further, even
/// though there is a display right there. This watches for that push and warps
/// the pointer to the equivalent place on the display being pushed towards.
///
/// The geometry is `EdgeCrossingMath`, which is pure and testable without
/// moving anyone's pointer; this class only supplies the event source, the
/// display bounds and the warp.
///
/// **Hardware deltas, not a polling timer.** Measured on macOS 27: the pointer
/// is clamped to the union of the displays, so once it is pinned at an edge
/// successive positions report *zero* movement — there is nothing for a poll to
/// see. The push direction therefore has to come from an event's own delta,
/// which is why this listens to `mouseMoved` rather than reading
/// `CGEvent(source: nil)?.location` on a timer the way
/// `CursorContainmentController` does. (`CGGetLastMouseDelta` would be the
/// obvious source for that delta but the Swift SDK marks it unavailable.)
///
/// **A mouse-moved monitor needs no Accessibility grant** — only *key* events
/// require the process to be trusted — so this can watch the pointer without
/// asking the user for permission to watch their keyboard. That is the trade
/// `CursorContainmentController` refuses, but it refuses it for a *key* tap, so
/// it does not arise here. If a monitor never fires the failure mode is inert:
/// the feature does nothing at all, and it can never fight the user for the
/// pointer.
///
/// Off unless `Settings.edgeCrossingEnabled`, which is off by default because
/// it moves the user's pointer.
@MainActor
public final class EdgeCrossingController {
    /// Re-read the preference this often. `fbdcli layout edge-crossing on` is a
    /// write from another process, and `UserDefaults` does not notify across
    /// processes — the same reason AppCore polls for the HTTP server setting.
    private let interval: TimeInterval = 1.5

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var bounds: [CGRect] = []
    private var hasStarted = false

    public init() {}

    /// True while the pointer is being watched.
    public var isActive: Bool { globalMonitor != nil }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        observer = NotificationCenter.default.addObserver(
            forName: .fbdDisplaysChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshBounds() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
        reconcile()
    }

    public func stop() {
        hasStarted = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
        removeMonitors()
        bounds = []
    }

    /// Bring the monitors into line with the stored preference.
    private func reconcile() {
        guard Settings.edgeCrossingEnabled else {
            removeMonitors()
            return
        }
        refreshBounds()
        // One display, or a single logical screen: there is no edge to cross,
        // so stay inert rather than watch the pointer for something that cannot
        // happen.
        guard bounds.count > 1 else {
            removeMonitors()
            return
        }
        installMonitors()
    }

    private func refreshBounds() {
        bounds = activeDisplayIDs().map { CGDisplayBounds($0) }
    }

    private func installMonitors() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Self.cross(for: event, on: self)
        }
        // The global monitor does not receive events delivered to this app, so a
        // push that happens over FBD's own panel or Settings window would be
        // missed without this second, local monitor.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Self.cross(for: event, on: self)
            return event
        }
        log.debug("edge crossing: watching the pointer across \(self.bounds.count) display(s)")
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    /// Read one pointer move off the event and hand it to the main actor.
    ///
    /// The two numbers are pulled out here rather than inside the actor hop
    /// because `NSEvent` is not `Sendable` and a `CGPoint`/`CGVector` is.
    ///
    /// Everything is read in CoreGraphics' global frame — where `CGDisplayBounds`
    /// lives, top-left origin with y down — because that is the frame the
    /// geometry is written in. `NSEvent.mouseLocation` is Cocoa's frame
    /// (bottom-left origin) and would have to be converted; the event's own
    /// `CGEvent` is already in the one that matters.
    private nonisolated static func cross(for event: NSEvent, on controller: EdgeCrossingController?) {
        guard let cgEvent = event.cgEvent else { return }
        let point = cgEvent.location
        let push = CGVector(
            dx: CGFloat(cgEvent.getIntegerValueField(.mouseEventDeltaX)),
            dy: CGFloat(cgEvent.getIntegerValueField(.mouseEventDeltaY))
        )
        Task { @MainActor in controller?.cross(at: point, push: push) }
    }

    /// Warp the pointer to the display on the other side of the push, if one is
    /// there to move onto.
    private func cross(at point: CGPoint, push: CGVector) {
        guard let target = EdgeCrossingMath.landing(from: point, push: push, displays: bounds) else { return }
        // A warp holds hardware input back for a quarter of a second by
        // default, which reads as the pointer sticking. Only zeroing the
        // suppression interval lifts it on macOS 27 —
        // `CGAssociateMouseAndMouseCursorPosition` does not.
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        CGWarpMouseCursorPosition(target)
    }

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
