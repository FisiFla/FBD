import CoreGraphics
import Foundation
import os

/// Save + restore the display arrangement (layout protection).
///
/// Positions (CGDisplayBounds.origin) of all active displays are snapshotted
/// into Settings; when the layout changes (external display plugged/unplugged,
/// resolution switch), the saved arrangement is re-applied with
/// CGConfigureDisplayOrigin.
///
/// Plain class; the `.fbdDisplaysChanged` callback hops to the main queue.
public final class LayoutProtectionController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "LayoutProtectionController")

    private var hasRegistered = false
    private var observer: NSObjectProtocol?
    /// Debounced restore work item — display events fire in bursts.
    private var restoreWorkItem: DispatchWorkItem?

    public init() {}

    public var hasSavedArrangement: Bool {
        !Settings.loadLayoutAnchors().isEmpty
    }

    /// Snapshot origins of all online displays (CGDisplayBounds.origin) into Settings.
    public func saveCurrentArrangement() {
        let ids = activeDisplayIDs()
        guard !ids.isEmpty else {
            log.warning("saveCurrentArrangement: no active displays")
            return
        }
        let anchors = ids.map { id -> LayoutAnchor in
            let origin = CGDisplayBounds(id).origin
            return LayoutAnchor(displayID: id, x: Int32(origin.x), y: Int32(origin.y))
        }
        Settings.saveLayoutAnchors(anchors)
        log.debug("saved arrangement of \(anchors.count) display(s)")
    }

    /// Apply the saved arrangement (CGConfigureDisplayOrigin for each anchor).
    /// Anchors whose display is not online are skipped. Returns false on failure.
    @discardableResult
    public func restoreArrangement() -> Bool {
        let anchors = Settings.loadLayoutAnchors()
        guard !anchors.isEmpty else {
            log.warning("restoreArrangement: no saved arrangement")
            return false
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            log.warning("restoreArrangement: CGBeginDisplayConfiguration failed")
            return false
        }
        var restored = 0
        for anchor in anchors where CGDisplayIsOnline(anchor.displayID) != 0 {
            let status = CGConfigureDisplayOrigin(config, anchor.displayID, anchor.x, anchor.y)
            guard status == .success else {
                log.warning("restoreArrangement: CGConfigureDisplayOrigin failed for \(anchor.displayID): \(status.rawValue)")
                CGCancelDisplayConfiguration(config)
                return false
            }
            restored += 1
        }
        guard restored > 0 else {
            log.warning("restoreArrangement: no saved anchor matches an online display")
            CGCancelDisplayConfiguration(config)
            return false
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else {
            log.warning("restoreArrangement: CGCompleteDisplayConfiguration failed: \(complete.rawValue)")
            return false
        }
        log.debug("restored arrangement for \(restored) display(s)")
        return true
    }

    /// Observe .fbdDisplaysChanged; when Settings.layoutProtectionEnabled, restore.
    public func start() {
        guard !hasRegistered else { return }
        hasRegistered = true
        observer = NotificationCenter.default.addObserver(
            forName: .fbdDisplaysChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRestore()
        }
    }

    /// Debounce (1s) then restore — display events fire in bursts and a single
    /// plug/unplug sequence can emit several `.fbdDisplaysChanged` posts.
    private func scheduleRestore() {
        restoreWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, Settings.layoutProtectionEnabled, self.hasSavedArrangement else { return }
            _ = self.restoreArrangement()
        }
        restoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    // MARK: - Topology query

    private func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard ids.withUnsafeMutableBufferPointer({
            CGGetActiveDisplayList(UInt32($0.count), $0.baseAddress, &count)
        }) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
