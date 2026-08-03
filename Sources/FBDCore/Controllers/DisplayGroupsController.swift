import CoreGraphics
import Foundation
import os

/// Display groups: brightness syncing, mirroring, UI-scale matching.
///
/// Groups are persisted as JSON in UserDefaults under "displayGroups.v1"
/// (id, name, displayIDs). Plain class; callers and notification callbacks run
/// on the main thread — MainActor-isolated work (DisplayController) is entered
/// via `MainActor.assumeIsolated` after hopping to the main queue when needed.
public final class DisplayGroupsController {
    private static let storageKey = "displayGroups.v1"
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "DisplayGroupsController")

    /// Observable groups (persisted via JSON under "displayGroups.v1").
    public private(set) var groups: [DisplayGroup] = []

    /// Persistence domain. Defaults to the shared FBD suite so the app and
    /// the CLI see the same groups (UserDefaults.standard differs per
    /// process bundle id and silently split the state).
    private let defaults: UserDefaults

    /// Codable mirror of `DisplayGroup` for persistence.
    private struct StoredGroup: Codable {
        var id: String
        var name: String
        var displayIDs: [CGDirectDisplayID]
    }

    public init(defaults: UserDefaults = Settings.defaults) {
        self.defaults = defaults
        groups = Self.load(from: defaults)
    }

    // MARK: - Group management

    public func createGroup(name: String, displayIDs: Set<CGDirectDisplayID> = []) {
        let group = DisplayGroup(name: name, displayIDs: displayIDs)
        groups.append(group)
        save()
        log.debug("created group '\(name)' (\(group.id))")
    }

    public func deleteGroup(id: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else {
            log.warning("deleteGroup: no group with id \(id)")
            return
        }
        groups.remove(at: index)
        save()
        log.debug("deleted group \(id)")
    }

    public func addDisplay(_ displayID: CGDirectDisplayID, toGroup id: String) {
        guard let group = groups.first(where: { $0.id == id }) else {
            log.warning("addDisplay: no group with id \(id)")
            return
        }
        guard !group.displayIDs.contains(displayID) else { return }
        group.displayIDs.insert(displayID)
        save()
    }

    public func removeDisplay(_ displayID: CGDirectDisplayID, fromGroup id: String) {
        guard let group = groups.first(where: { $0.id == id }) else {
            log.warning("removeDisplay: no group with id \(id)")
            return
        }
        guard group.displayIDs.remove(displayID) != nil else { return }
        save()
    }

    /// Apply the same brightness (0…1) to every display in the group via `controller`.
    public func syncBrightness(_ value: Double, inGroup id: String, controller: DisplayController) {
        guard let group = groups.first(where: { $0.id == id }) else {
            log.warning("syncBrightness: no group with id \(id)")
            return
        }
        let displayIDs = group.displayIDs
        let apply: @MainActor () -> Void = {
            for displayID in displayIDs {
                guard let display = controller.displays.first(where: { $0.id == displayID }) else { continue }
                controller.setBrightness(value, on: display)
            }
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(apply)
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated(apply) }
        }
    }

    // MARK: - Mirroring

    /// Mirror all displays in the group onto the first display (CGConfigureDisplayMirrorOfDisplay).
    /// Returns false on failure or when fewer than two online displays are in the group.
    @discardableResult
    public func mirror(inGroup id: String) -> Bool {
        guard let group = groups.first(where: { $0.id == id }) else {
            log.warning("mirror: no group with id \(id)")
            return false
        }
        let members = group.displayIDs.filter { CGDisplayIsOnline($0) != 0 }.sorted()
        guard let primary = members.first, members.count > 1 else {
            log.debug("mirror: need at least two online displays in group \(id)")
            return false
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            log.warning("mirror: CGBeginDisplayConfiguration failed")
            return false
        }
        for displayID in members where displayID != primary {
            let status = CGConfigureDisplayMirrorOfDisplay(config, displayID, primary)
            guard status == .success else {
                log.warning("mirror: CGConfigureDisplayMirrorOfDisplay failed for \(displayID): \(status.rawValue)")
                CGCancelDisplayConfiguration(config)
                return false
            }
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else {
            log.warning("mirror: CGCompleteDisplayConfiguration failed: \(complete.rawValue)")
            return false
        }
        log.debug("mirrored \(members.count - 1) display(s) onto \(primary) (\(CGDisplayIsInMirrorSet(primary) != 0 ? "verified" : "unverified"))")
        return true
    }

    /// Remove mirroring for the group's displays (CGConfigureDisplayMirrorOfDisplay with master 0).
    @discardableResult
    public func unmirror(inGroup id: String) -> Bool {
        guard let group = groups.first(where: { $0.id == id }) else {
            log.warning("unmirror: no group with id \(id)")
            return false
        }
        let mirrored = group.displayIDs.filter { $0 != 0 && CGDisplayIsInMirrorSet($0) != 0 }
        guard !mirrored.isEmpty else { return true } // nothing to unmirror
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            log.warning("unmirror: CGBeginDisplayConfiguration failed")
            return false
        }
        for displayID in mirrored {
            let status = CGConfigureDisplayMirrorOfDisplay(config, displayID, 0)
            guard status == .success else {
                log.warning("unmirror: CGConfigureDisplayMirrorOfDisplay failed for \(displayID): \(status.rawValue)")
                CGCancelDisplayConfiguration(config)
                return false
            }
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else {
            log.warning("unmirror: CGCompleteDisplayConfiguration failed: \(complete.rawValue)")
            return false
        }
        log.debug("unmirrored \(mirrored.count) display(s)")
        return true
    }

    // MARK: - Queries

    public func group(named name: String) -> DisplayGroup? {
        groups.first { $0.name == name }
    }

    // MARK: - Persistence

    private static func load(from defaults: UserDefaults) -> [DisplayGroup] {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([StoredGroup].self, from: data) else {
            return []
        }
        return stored.map { DisplayGroup(id: $0.id, name: $0.name, displayIDs: Set($0.displayIDs)) }
    }

    private func save() {
        let stored = groups.map { StoredGroup(id: $0.id, name: $0.name, displayIDs: $0.displayIDs.sorted()) }
        guard let data = try? JSONEncoder().encode(stored) else {
            log.warning("save: failed to encode groups")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
