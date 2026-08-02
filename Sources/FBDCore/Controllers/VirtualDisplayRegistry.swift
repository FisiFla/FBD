import CoreGraphics
import Foundation

/// Authoritative registry of display IDs that FBD itself created as virtual
/// displays. `VirtualScreenController` registers IDs on create/reconnect and
/// unregisters on destroy/disconnect; `Display.isVirtual` consults it as the
/// primary signal, keeping the legacy magic-ID heuristics as a fallback for
/// displays FBD did not create (Sidecar, AirPlay, other tools).
///
/// Global (not per-controller-instance) so the UI, AppCore, CLI and the
/// Display model all agree even though several VirtualScreenController
/// instances exist across the app.
public final class VirtualDisplayRegistry {
    public static let shared = VirtualDisplayRegistry()

    private var ids: Set<CGDirectDisplayID>
    private let lock = NSLock()

    /// Loads previously registered IDs from Settings so every process (the
    /// CLI included) agrees on which displays are virtual.
    public init() {
        ids = Set(Settings.virtualDisplayIDs.map { CGDirectDisplayID($0) })
    }

    private func persist() {
        Settings.virtualDisplayIDs = ids.sorted().map { UInt32($0) }
    }

    public func register(_ id: CGDirectDisplayID) {
        lock.lock()
        let changed = ids.insert(id).inserted
        if changed { persist() }
        lock.unlock()
    }

    public func unregister(_ id: CGDirectDisplayID) {
        lock.lock()
        let changed = ids.remove(id) != nil
        if changed { persist() }
        lock.unlock()
    }

    public func contains(_ id: CGDirectDisplayID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
    }

    /// Drop IDs that are no longer online (called from DisplayController
    /// refresh, which owns the authoritative display list).
    public func prune(keeping live: Set<CGDirectDisplayID>) {
        lock.lock()
        let removed = ids.subtracting(live)
        if !removed.isEmpty {
            ids = ids.intersection(live)
            persist()
        }
        lock.unlock()
    }
}
