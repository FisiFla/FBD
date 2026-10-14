import CoreGraphics
import Foundation

/// How a display group decides whether it is *currently active* — whether a
/// brightness sync should run given which of its member displays are connected.
///
/// Mirrors BetterDisplay's five group activation modes. The decision is pure: it
/// looks only at the member set and the connected set, never at hardware, so a
/// group's activation can be evaluated — and tested — with no display attached.
///
/// The two sync **member filters** (which members may act as sources, which as
/// targets) only enter the `anySyncSourceWithTargetMembersPresent` rule; an
/// empty filter means "every member".
public enum GroupActivationPolicy: String, Codable, CaseIterable {
    /// Active unconditionally, whichever members are connected (even none). The
    /// write set may still be empty when nothing is connected, but the policy
    /// itself never refuses.
    case always

    /// Active only while *every* member is connected. An empty group is
    /// inactive — there is nothing to sync.
    case allMembersPresent

    /// Active while *at least one* member is connected.
    case anyMembersPresent

    /// Active while *at least two* members are connected.
    case anyTwoMembersPresent

    /// Active while at least one member eligible to act as a sync **source** and
    /// at least one member eligible to act as a sync **target** are connected.
    /// Eligibility comes from the source/target member filters; an empty filter
    /// means "all members". The source and target need not be different
    /// displays.
    case anySyncSourceWithTargetMembersPresent

    /// Whether the group is active given which members are currently connected.
    ///
    /// Pure and total: no hardware, no traps.
    ///
    /// - Parameters:
    ///   - memberIDs: the group's member displays.
    ///   - connectedIDs: the displays currently connected.
    ///   - syncSourceIDs: member IDs allowed to act as sync sources (empty = all
    ///     members).
    ///   - syncTargetIDs: member IDs allowed to act as sync targets (empty = all
    ///     members).
    /// - Returns: `true` when a sync should run for this group under this policy.
    public func isActive(
        memberIDs: Set<CGDirectDisplayID>,
        connectedIDs: Set<CGDirectDisplayID>,
        syncSourceIDs: Set<CGDirectDisplayID>,
        syncTargetIDs: Set<CGDirectDisplayID>
    ) -> Bool {
        switch self {
        case .always:
            return true
        case .allMembersPresent:
            return !memberIDs.isEmpty && memberIDs.isSubset(of: connectedIDs)
        case .anyMembersPresent:
            return !memberIDs.intersection(connectedIDs).isEmpty
        case .anyTwoMembersPresent:
            return memberIDs.intersection(connectedIDs).count >= 2
        case .anySyncSourceWithTargetMembersPresent:
            let sources = syncSourceIDs.isEmpty ? memberIDs : memberIDs.intersection(syncSourceIDs)
            let targets = syncTargetIDs.isEmpty ? memberIDs : memberIDs.intersection(syncTargetIDs)
            return !sources.intersection(connectedIDs).isEmpty
                && !targets.intersection(connectedIDs).isEmpty
        }
    }
}

/// The ordered brightness writes a group sync would perform.
///
/// A plan is the whole decision — which displays, and with which value — with
/// nothing about *how* a write reaches a display. Applying it is a thin loop;
/// the interesting part is right here, and this type is `Equatable` so tests can
/// assert a plan exactly.
public struct GroupSyncPlan: Equatable {
    /// A single brightness write: the display and the 0…1 value to write to it.
    public struct Write: Equatable {
        public let displayID: CGDirectDisplayID
        public let value: Double

        public init(displayID: CGDirectDisplayID, value: Double) {
            self.displayID = displayID
            self.value = value
        }
    }

    /// Writes in member order (ascending display ID).
    public let writes: [Write]

    public init(writes: [Write]) {
        self.writes = writes
    }

    /// Whether the plan performs no writes (a disabled or inactive group, or no
    /// connected member).
    public var isEmpty: Bool { writes.isEmpty }
}

/// Inputs to the pure group-sync planner. Every value is supplied by the caller,
/// so the planner never reads hardware or settings — it is a pure function.
public struct GroupSyncRequest: Equatable {
    /// Group member displays, in the order the plan should emit writes.
    public var members: [CGDirectDisplayID]
    /// Displays currently connected.
    public var connectedIDs: Set<CGDirectDisplayID>
    /// Members allowed to act as sync sources (empty = all members).
    public var syncSourceIDs: Set<CGDirectDisplayID>
    /// Members allowed to act as sync targets (empty = all members).
    public var syncTargetIDs: Set<CGDirectDisplayID>
    /// Which of the connected displays are virtual screens.
    public var virtualDisplayIDs: Set<CGDirectDisplayID>
    /// Whether virtual screens may take part in the sync.
    public var includeVirtualScreens: Bool
    /// The display the value came from; when nil — or when it is not an eligible
    /// source — the first eligible source is used.
    public var sourceDisplayID: CGDirectDisplayID?
    /// The source display's nits ceiling; nil derives it from
    /// `targetCeilingNits[sourceDisplayID]`, so the source filter's choice is
    /// reflected in the plan.
    public var sourceCeilingNits: Int?
    /// Per-display nits ceilings (a missing entry means "unknown" → the value
    /// passes through unchanged).
    public var targetCeilingNits: [CGDirectDisplayID: Int]
    /// The source brightness, 0…1.
    public var value: Double
    /// When true, the value is mapped by luminance through the source and target
    /// ceilings (`BrightnessSync`); when false it is copied unchanged.
    public var matchBrightnessInNits: Bool

    public init(
        members: [CGDirectDisplayID],
        connectedIDs: Set<CGDirectDisplayID> = [],
        syncSourceIDs: Set<CGDirectDisplayID> = [],
        syncTargetIDs: Set<CGDirectDisplayID> = [],
        virtualDisplayIDs: Set<CGDirectDisplayID> = [],
        includeVirtualScreens: Bool = false,
        sourceDisplayID: CGDirectDisplayID? = nil,
        sourceCeilingNits: Int? = nil,
        targetCeilingNits: [CGDirectDisplayID: Int] = [:],
        value: Double,
        matchBrightnessInNits: Bool = true
    ) {
        self.members = members
        self.connectedIDs = connectedIDs
        self.syncSourceIDs = syncSourceIDs
        self.syncTargetIDs = syncTargetIDs
        self.virtualDisplayIDs = virtualDisplayIDs
        self.includeVirtualScreens = includeVirtualScreens
        self.sourceDisplayID = sourceDisplayID
        self.sourceCeilingNits = sourceCeilingNits
        self.targetCeilingNits = targetCeilingNits
        self.value = value
        self.matchBrightnessInNits = matchBrightnessInNits
    }
}

/// Pure planner turning a group-sync request into the ordered writes to apply.
///
/// Reuses `BrightnessSync` for nits matching rather than duplicating that maths:
/// the source value and both ceilings go through the same helpers the single
/// `syncBrightness` path already uses, so the two cannot drift.
public enum GroupSyncPlanner {
    /// The writes to perform for `request`, in member order.
    ///
    /// The plan is empty when no eligible source is present (nothing to sync
    /// *from*). Only eligible targets are written; the source itself is written
    /// too when it is also an eligible target, which re-asserts its own value.
    public static func plan(_ request: GroupSyncRequest) -> GroupSyncPlan {
        let value = min(max(request.value, 0), 1)

        let sourceID: CGDirectDisplayID?
        if let reference = request.sourceDisplayID, isEligibleSource(reference, request) {
            sourceID = reference
        } else {
            sourceID = request.members.first { isEligibleSource($0, request) }
        }
        guard let sourceID else {
            return GroupSyncPlan(writes: [])
        }
        let sourceCeiling = request.sourceCeilingNits ?? request.targetCeilingNits[sourceID] ?? 0

        var writes: [GroupSyncPlan.Write] = []
        for member in request.members where isEligibleTarget(member, request) {
            let mapped: Double
            if request.matchBrightnessInNits {
                mapped = BrightnessSync.equivalentValue(
                    value,
                    sourceCeilingNits: sourceCeiling,
                    targetCeilingNits: request.targetCeilingNits[member] ?? 0
                )
            } else {
                mapped = value
            }
            writes.append(GroupSyncPlan.Write(displayID: member, value: mapped))
        }
        return GroupSyncPlan(writes: writes)
    }

    /// A member participates when it is connected and either virtual screens are
    /// allowed or it is not a virtual screen.
    private static func participates(_ id: CGDirectDisplayID, _ request: GroupSyncRequest) -> Bool {
        guard request.connectedIDs.contains(id) else { return false }
        if request.virtualDisplayIDs.contains(id) && !request.includeVirtualScreens { return false }
        return true
    }

    private static func isEligibleSource(_ id: CGDirectDisplayID, _ request: GroupSyncRequest) -> Bool {
        guard request.members.contains(id), participates(id, request) else { return false }
        return request.syncSourceIDs.isEmpty || request.syncSourceIDs.contains(id)
    }

    private static func isEligibleTarget(_ id: CGDirectDisplayID, _ request: GroupSyncRequest) -> Bool {
        guard request.members.contains(id), participates(id, request) else { return false }
        return request.syncTargetIDs.isEmpty || request.syncTargetIDs.contains(id)
    }
}

/// UserDefaults accessors for a display group's sync configuration.
///
/// Per-group state lives under `groupSync.v1.<groupID>.<field>` in the *injected*
/// suite, following the same per-identity pattern as `configProtection.` and
/// `ddcFeatures.` — the app and the CLI (which share the suite) read one copy,
/// and distinct groups use distinct keys so two groups cannot interfere. These
/// are the only write path for the state; `Settings.defaults` is not used here
/// because the group store is deliberately suite-injectable for tests.
public enum GroupSyncStore {
    private static let prefix = "groupSync.v1"
    private static let enabledField = "enabled"
    private static let policyField = "activationPolicy"
    private static let sourcesField = "sources"
    private static let targetsField = "targets"
    private static let includeVirtualField = "includeVirtualScreens"

    private static func key(_ field: String, _ groupID: String) -> String {
        "\(prefix).\(groupID).\(field)"
    }

    /// Whether the group's sync is enabled. Defaults to `true` so a group the
    /// user created syncs out of the box (BetterDisplay parity).
    public static func isEnabled(groupID: String, defaults: UserDefaults) -> Bool {
        let storageKey = key(enabledField, groupID)
        guard defaults.object(forKey: storageKey) != nil else { return true }
        return defaults.bool(forKey: storageKey)
    }

    public static func setEnabled(_ enabled: Bool, groupID: String, defaults: UserDefaults) {
        defaults.set(enabled, forKey: key(enabledField, groupID))
    }

    /// The group's activation policy. Defaults to `.always`.
    public static func activationPolicy(groupID: String, defaults: UserDefaults) -> GroupActivationPolicy {
        guard let raw = defaults.string(forKey: key(policyField, groupID)),
              let policy = GroupActivationPolicy(rawValue: raw) else {
            return .always
        }
        return policy
    }

    public static func setActivationPolicy(
        _ policy: GroupActivationPolicy,
        groupID: String,
        defaults: UserDefaults
    ) {
        defaults.set(policy.rawValue, forKey: key(policyField, groupID))
    }

    /// Members allowed to act as sync sources (empty = all members).
    public static func syncSourceIDs(groupID: String, defaults: UserDefaults) -> Set<CGDirectDisplayID> {
        displaySet(defaults, key(sourcesField, groupID))
    }

    public static func setSyncSourceIDs(
        _ ids: Set<CGDirectDisplayID>,
        groupID: String,
        defaults: UserDefaults
    ) {
        defaults.set(ids.map { Int($0) }.sorted(), forKey: key(sourcesField, groupID))
    }

    /// Members allowed to act as sync targets (empty = all members).
    public static func syncTargetIDs(groupID: String, defaults: UserDefaults) -> Set<CGDirectDisplayID> {
        displaySet(defaults, key(targetsField, groupID))
    }

    public static func setSyncTargetIDs(
        _ ids: Set<CGDirectDisplayID>,
        groupID: String,
        defaults: UserDefaults
    ) {
        defaults.set(ids.map { Int($0) }.sorted(), forKey: key(targetsField, groupID))
    }

    /// Whether virtual screens may take part in the group's sync. Defaults to
    /// `false` — a virtual screen is created at a fixed brightness and adding it
    /// to a sync silently would be surprising.
    public static func includeVirtualScreens(groupID: String, defaults: UserDefaults) -> Bool {
        let storageKey = key(includeVirtualField, groupID)
        guard defaults.object(forKey: storageKey) != nil else { return false }
        return defaults.bool(forKey: storageKey)
    }

    public static func setIncludeVirtualScreens(
        _ include: Bool,
        groupID: String,
        defaults: UserDefaults
    ) {
        defaults.set(include, forKey: key(includeVirtualField, groupID))
    }

    private static func displaySet(_ defaults: UserDefaults, _ key: String) -> Set<CGDirectDisplayID> {
        let raw = defaults.array(forKey: key) as? [Int] ?? []
        return Set(raw.map { CGDirectDisplayID($0) })
    }
}
