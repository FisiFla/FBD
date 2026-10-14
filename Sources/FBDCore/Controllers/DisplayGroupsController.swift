import CoreGraphics
import Foundation
import os

/// Display groups: brightness syncing, mirroring, UI-scale matching.
///
/// Groups are persisted as JSON in UserDefaults under "displayGroups.v1"
/// (id, name, displayIDs). Each group's sync configuration — the enabled flag,
/// the activation policy and the source/target member filters — is persisted
/// per group under "groupSync.v1.<id>.*" (see `GroupSyncStore`). Plain class;
/// callers and notification callbacks run on the main thread —
/// MainActor-isolated work (DisplayController) is entered via
/// `MainActor.assumeIsolated` after hopping to the main queue when needed.
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

    // MARK: - Sync policy & configuration

    /// Whether the group's brightness sync is enabled. Persisted per group in the
    /// injected suite; defaults to `true`.
    public func isEnabled(groupID: String) -> Bool {
        GroupSyncStore.isEnabled(groupID: groupID, defaults: defaults)
    }

    public func setEnabled(_ enabled: Bool, forGroup id: String) {
        GroupSyncStore.setEnabled(enabled, groupID: id, defaults: defaults)
    }

    /// The group's activation policy. Persisted per group; defaults to `.always`.
    public func activationPolicy(forGroup id: String) -> GroupActivationPolicy {
        GroupSyncStore.activationPolicy(groupID: id, defaults: defaults)
    }

    public func setActivationPolicy(_ policy: GroupActivationPolicy, forGroup id: String) {
        GroupSyncStore.setActivationPolicy(policy, groupID: id, defaults: defaults)
    }

    /// Members allowed to act as sync sources (empty = all members).
    public func syncSourceIDs(forGroup id: String) -> Set<CGDirectDisplayID> {
        GroupSyncStore.syncSourceIDs(groupID: id, defaults: defaults)
    }

    public func setSyncSourceIDs(_ ids: Set<CGDirectDisplayID>, forGroup id: String) {
        GroupSyncStore.setSyncSourceIDs(ids, groupID: id, defaults: defaults)
    }

    /// Members allowed to act as sync targets (empty = all members).
    public func syncTargetIDs(forGroup id: String) -> Set<CGDirectDisplayID> {
        GroupSyncStore.syncTargetIDs(groupID: id, defaults: defaults)
    }

    public func setSyncTargetIDs(_ ids: Set<CGDirectDisplayID>, forGroup id: String) {
        GroupSyncStore.setSyncTargetIDs(ids, groupID: id, defaults: defaults)
    }

    /// Whether virtual screens may take part in the group's sync; defaults to
    /// `false`.
    public func includeVirtualScreens(forGroup id: String) -> Bool {
        GroupSyncStore.includeVirtualScreens(groupID: id, defaults: defaults)
    }

    public func setIncludeVirtualScreens(_ include: Bool, forGroup id: String) {
        GroupSyncStore.setIncludeVirtualScreens(include, groupID: id, defaults: defaults)
    }

    // MARK: - Sync planning

    /// The pure, hardware-free plan for syncing `value` across a group.
    ///
    /// Reads the group's persisted sync configuration (enabled flag, activation
    /// policy, source/target member filters, virtual-screen participation) from
    /// the injected suite and returns the ordered brightness writes the sync
    /// would perform — without touching any display. Returns an EMPTY plan when
    /// the group is unknown, disabled, or its activation policy reports the group
    /// inactive, so "disabled/inactive is a no-op" is a property of the plan
    /// itself rather than of the write loop.
    ///
    /// `ceilingNits` supplies each display's native ceiling; the planner never
    /// reads hardware itself.
    public func syncPlan(
        inGroup id: String,
        value: Double,
        connectedIDs: Set<CGDirectDisplayID>,
        virtualDisplayIDs: Set<CGDirectDisplayID> = [],
        referenceDisplayID: CGDirectDisplayID? = nil,
        matchBrightnessInNits: Bool = true,
        ceilingNits: (CGDirectDisplayID) -> Int = { _ in 0 }
    ) -> GroupSyncPlan {
        guard let group = groups.first(where: { $0.id == id }) else {
            log.warning("syncPlan: no group with id \(id)")
            return GroupSyncPlan(writes: [])
        }
        guard isEnabled(groupID: group.id) else {
            log.debug("syncPlan: group \(id) is disabled — no-op")
            return GroupSyncPlan(writes: [])
        }
        let sources = syncSourceIDs(forGroup: group.id)
        let targets = syncTargetIDs(forGroup: group.id)
        let policy = activationPolicy(forGroup: group.id)
        guard policy.isActive(
            memberIDs: group.displayIDs,
            connectedIDs: connectedIDs,
            syncSourceIDs: sources,
            syncTargetIDs: targets
        ) else {
            log.debug("syncPlan: group \(id) inactive under '\(policy.rawValue)' — no-op")
            return GroupSyncPlan(writes: [])
        }

        let members = group.displayIDs.sorted()
        let sourceID: CGDirectDisplayID?
        if let reference = referenceDisplayID, members.contains(reference) {
            sourceID = reference
        } else {
            sourceID = members.first
        }
        let ceilings = Dictionary(uniqueKeysWithValues: members.map { ($0, ceilingNits($0)) })
        let request = GroupSyncRequest(
            members: members,
            connectedIDs: connectedIDs,
            syncSourceIDs: sources,
            syncTargetIDs: targets,
            virtualDisplayIDs: virtualDisplayIDs,
            includeVirtualScreens: includeVirtualScreens(forGroup: group.id),
            sourceDisplayID: sourceID,
            sourceCeilingNits: sourceID.map { ceilings[$0] ?? 0 },
            targetCeilingNits: ceilings,
            value: value,
            matchBrightnessInNits: matchBrightnessInNits
        )
        return GroupSyncPlanner.plan(request)
    }

    /// Compute the group's sync plan and apply it through the brightness seam
    /// (`DisplayController.setBrightness`), returning the number of displays
    /// actually written.
    ///
    /// A no-op returning 0 when the group is disabled, when its activation policy
    /// reports it inactive, or when no member is connected — the plan is empty in
    /// each case (see `syncPlan`). Writes go straight to the controller and never
    /// back through this method, so a sync cannot re-trigger itself.
    @discardableResult
    public func applyGroupSync(
        _ value: Double,
        inGroup id: String,
        controller: DisplayController,
        referenceDisplayID: CGDirectDisplayID? = nil,
        matchBrightnessInNits: Bool = true
    ) -> Int {
        let apply: @MainActor () -> Int = { [self] in
            let connectedIDs = Set(controller.displays.map { $0.id })
            let virtualDisplayIDs = Set(controller.displays.filter { $0.isVirtual }.map { $0.id })
            let ceilings = Dictionary(
                uniqueKeysWithValues: controller.displays.map { ($0.id, controller.hardwareCeilingNits(for: $0)) }
            )
            let plan = self.syncPlan(
                inGroup: id,
                value: value,
                connectedIDs: connectedIDs,
                virtualDisplayIDs: virtualDisplayIDs,
                referenceDisplayID: referenceDisplayID,
                matchBrightnessInNits: matchBrightnessInNits,
                ceilingNits: { ceilings[$0] ?? 0 }
            )
            var written = 0
            for write in plan.writes {
                guard let display = controller.display(withID: write.displayID) else { continue }
                if controller.setBrightness(write.value, on: display) {
                    written += 1
                }
            }
            return written
        }
        if Thread.isMainThread {
            return MainActor.assumeIsolated(apply)
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(apply) }
    }

    /// Apply the same brightness (0…1) to every display in the group via `controller`.
    /// Synchronise brightness across a group **by luminance**, not by slider
    /// position: the source value is converted to nits and re-expressed against
    /// each member's own ceiling, so a 1600-nit XDR panel and a 300-nit monitor
    /// end up equally bright instead of merely equally far along their sliders.
    ///
    /// `referenceDisplayID` is the display the value came from; nil uses the
    /// group's first member. Writes go through `controller.setBrightness`
    /// directly and never back through this method, so a sync cannot re-trigger
    /// itself.
    public func syncBrightness(
        _ value: Double,
        inGroup id: String,
        controller: DisplayController,
        referenceDisplayID: CGDirectDisplayID? = nil
    ) {
        guard let group = groups.first(where: { $0.id == id }) else {
            log.warning("syncBrightness: no group with id \(id)")
            return
        }
        let displayIDs = group.displayIDs
        let apply: @MainActor () -> Void = {
            let members = displayIDs.compactMap { displayID in
                controller.displays.first(where: { $0.id == displayID })
            }
            // An empty group is a no-op, not an error: a group can outlive the
            // displays it names.
            guard let source = members.first(where: { $0.id == referenceDisplayID }) ?? members.first else {
                return
            }
            let sourceCeiling = controller.hardwareCeilingNits(for: source)
            for display in members {
                let mapped = BrightnessSync.equivalentValue(
                    value,
                    sourceCeilingNits: sourceCeiling,
                    targetCeilingNits: controller.hardwareCeilingNits(for: display)
                )
                controller.setBrightness(mapped, on: display)
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
