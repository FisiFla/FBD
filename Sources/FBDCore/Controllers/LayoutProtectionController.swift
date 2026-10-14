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
        return apply(anchors: anchors)
    }

    /// Apply an explicit arrangement in one transaction.
    ///
    /// Split out so a virtual screen's associated arrangement goes through the same
    /// CG configuration sequence as the global one — two copies of that dance would
    /// be two places to get the begin/complete/cancel bookkeeping wrong. Anchors
    /// whose display is not online are skipped.
    @discardableResult
    public func apply(anchors: [LayoutAnchor]) -> Bool {
        guard !anchors.isEmpty else {
            log.warning("apply: no anchors")
            return false
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            log.warning("apply: CGBeginDisplayConfiguration failed")
            return false
        }
        var restored = 0
        for anchor in anchors where CGDisplayIsOnline(anchor.displayID) != 0 {
            let status = CGConfigureDisplayOrigin(config, anchor.displayID, anchor.x, anchor.y)
            guard status == .success else {
                log.warning("apply: CGConfigureDisplayOrigin failed for \(anchor.displayID): \(status.rawValue)")
                CGCancelDisplayConfiguration(config)
                return false
            }
            restored += 1
        }
        guard restored > 0 else {
            log.warning("apply: no anchor matches an online display")
            CGCancelDisplayConfiguration(config)
            return false
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else {
            log.warning("apply: CGCompleteDisplayConfiguration failed: \(complete.rawValue)")
            return false
        }
        log.debug("applied arrangement for \(restored) display(s)")
        return true
    }

    /// Apply the arrangement associated with a virtual screen, if there is one.
    ///
    /// Fails closed at every step: nothing stored, an empty association, a missing
    /// display, or an identity that does not resolve all mean no arrangement is
    /// applied. Arranging the displays that happen to be present into positions
    /// chosen for a layout that is not here would be worse than doing nothing.
    @discardableResult
    public func applyAssociation(
        forVirtualScreen id: String,
        attached: [(identity: String, displayID: CGDirectDisplayID)],
        associations: [VirtualScreenAssociation]
    ) -> Bool {
        let order = VirtualScreenAssociations.order(
            for: id,
            associations: associations,
            attachedIdentities: attached.map(\.identity)
        )
        guard let placements = order.placementsToApply,
              let anchors = VirtualScreenAssociations.anchors(for: placements, attached: attached) else {
            return false
        }
        return apply(anchors: anchors)
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
            guard let self else { return }
            if Settings.layoutProtectionEnabled, self.hasSavedArrangement {
                _ = self.restoreArrangement()
            }
            // The association recall reads the display list, which is main-actor
            // state, so it hops rather than reading it from a plain work item.
            Task { @MainActor [weak self] in self?.recallVirtualScreenAssociations() }
        }
        restoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    /// Recall the arrangement of every virtual screen that is attached right now.
    ///
    /// Runs *after* the global restore, so a screen-specific arrangement is the one
    /// left standing — which is the point of associating it in the first place. The
    /// attached screens come from `VirtualScreenController.shared`, so a CLI process
    /// (whose own `shared` has no screens) simply does nothing.
    @MainActor
    private func recallVirtualScreenAssociations() {
        let associations = Settings.loadVirtualScreenAssociations()
        guard !associations.isEmpty else { return }
        let screens = VirtualScreenController.shared.screens
        guard !screens.isEmpty else { return }
        // Identity, not display id: a display id is reassigned across a reconnect,
        // and the association is meant to outlive exactly that.
        let attached = DisplayController.shared.displays.map {
            (identity: $0.identityKey, displayID: $0.id)
        }
        for screen in screens {
            _ = applyAssociation(forVirtualScreen: screen.id, attached: attached, associations: associations)
        }
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
