import CoreGraphics
import Foundation

/// BetterDisplay-parity connection-management actions, expressed as a pure plan
/// so they can be reasoned about and unit-tested without touching the
/// WindowServer.
///
/// A `ConnectionAction` is a high-level intent (connect everything, leave only
/// the main display, swap two identical displays); `ConnectionPlanner` turns it
/// into an ordered list of `ConnectionStep`s, and
/// `DisconnectController.apply(_:)` runs those steps through the single guarded
/// `setEnabled` chokepoint. The planner is pure, total and deterministic — it
/// never traps and never touches hardware, so it is safe to call from any
/// thread and cheap to test.
public enum ConnectionAction: String, CaseIterable, Codable {
    /// Enable every currently-offline display.
    case connectAll
    /// Disable every online display except the main one.
    case disconnectAllButMain
    /// Swap the main/online roles of two displays that share a vendor+model.
    case swapIdentical
}

/// The pure input to the planner: everything about a display that a connection
/// decision depends on, decoupled from the live `Display` object.
public struct DisplayDescriptor: Equatable {
    public let displayID: CGDirectDisplayID
    public let isOnline: Bool
    public let isBuiltin: Bool
    public let isMain: Bool
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32

    public init(
        displayID: CGDirectDisplayID,
        isOnline: Bool,
        isBuiltin: Bool,
        isMain: Bool,
        vendor: UInt32,
        model: UInt32,
        serial: UInt32
    ) {
        self.displayID = displayID
        self.isOnline = isOnline
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }
}

/// One planned change to a display's enabled state, with a human-readable
/// reason suitable for logging.
public struct ConnectionStep: Equatable {
    public let displayID: CGDirectDisplayID
    public let enable: Bool
    public let reason: String

    public init(displayID: CGDirectDisplayID, enable: Bool, reason: String) {
        self.displayID = displayID
        self.enable = enable
        self.reason = reason
    }
}

/// Pure, total, deterministic connection planner.
///
/// Refusal cases (each returns an empty list rather than guessing):
/// - `disconnectAllButMain` when there is no main display — without a main
///   there is nothing to keep, so "all but main" is undefined.
/// - `swapIdentical` when fewer than two displays share a vendor+model, when
///   more than two share it (ambiguous), or when more than one such group
///   exists (ambiguous).
///
/// Safety invariant: `disconnectAllButMain` never emits a step that disables a
/// built-in display unless `allowsAffectedBuiltInDisconnect` is true — it fails
/// closed on the built-in-disconnect hardware hazard (see
/// `BuiltInDisconnectGuard`). A disable-nothing result is always preferable to
/// a wrong disable.
public enum ConnectionPlanner {
    /// Build the ordered steps for `action`. See the type doc for refusals.
    public static func plan(
        action: ConnectionAction,
        displays: [DisplayDescriptor],
        allowsAffectedBuiltInDisconnect: Bool
    ) -> [ConnectionStep] {
        switch action {
        case .connectAll:
            return planConnectAll(displays)
        case .disconnectAllButMain:
            return planDisconnectAllButMain(
                displays,
                allowsAffectedBuiltInDisconnect: allowsAffectedBuiltInDisconnect
            )
        case .swapIdentical:
            return planSwapIdentical(displays)
        }
    }

    // MARK: - connectAll

    private static func planConnectAll(_ displays: [DisplayDescriptor]) -> [ConnectionStep] {
        displays
            .filter { !$0.isOnline }
            .sorted { $0.displayID < $1.displayID }
            .map { descriptor in
                ConnectionStep(
                    displayID: descriptor.displayID,
                    enable: true,
                    reason: "connectAll: enable offline display \(descriptor.displayID)"
                )
            }
    }

    // MARK: - disconnectAllButMain

    private static func planDisconnectAllButMain(
        _ displays: [DisplayDescriptor],
        allowsAffectedBuiltInDisconnect: Bool
    ) -> [ConnectionStep] {
        // No main display → nothing to keep; refuse the whole action.
        guard displays.contains(where: { $0.isMain }) else { return [] }

        return displays
            .filter { $0.isOnline && !$0.isMain }
            .filter { descriptor in
                // A built-in display may only be disabled when the explicit
                // override is on — fail closed on the hardware hazard.
                !descriptor.isBuiltin || allowsAffectedBuiltInDisconnect
            }
            .sorted { $0.displayID < $1.displayID }
            .map { descriptor in
                let kind = descriptor.isBuiltin ? "built-in" : "external"
                let note = descriptor.isBuiltin ? " (override on)" : ""
                return ConnectionStep(
                    displayID: descriptor.displayID,
                    enable: false,
                    reason: "disconnectAllButMain: disable non-main \(kind) display \(descriptor.displayID)\(note)"
                )
            }
    }

    // MARK: - swapIdentical

    private static func planSwapIdentical(_ displays: [DisplayDescriptor]) -> [ConnectionStep] {
        // Group by vendor+model identity; the serial is deliberately ignored so
        // two displays that differ only by serial count as identical.
        var groups: [Identity: [DisplayDescriptor]] = [:]
        for display in displays {
            groups[Identity(vendor: display.vendor, model: display.model), default: []].append(display)
        }
        let identicalGroups = groups.values.filter { $0.count >= 2 }

        // Fewer than two identical displays → nothing to swap.
        // More than two (or more than one identical group) → ambiguous → refuse.
        guard identicalGroups.count == 1, let pair = identicalGroups.first, pair.count == 2 else {
            return []
        }

        let ordered = pair.sorted { $0.displayID < $1.displayID }
        let online = ordered.filter { $0.isOnline }
        let offline = ordered.filter { !$0.isOnline }

        if online.count == 1, offline.count == 1 {
            let releasing = online[0]
            let takingOver = offline[0]
            return [
                ConnectionStep(
                    displayID: releasing.displayID,
                    enable: false,
                    reason: "swapIdentical: release online display \(releasing.displayID)"
                ),
                ConnectionStep(
                    displayID: takingOver.displayID,
                    enable: true,
                    reason: "swapIdentical: bring online display \(takingOver.displayID)"
                ),
            ]
        }

        // Degenerate case: both online or both offline. Cycle the member that
        // currently holds the main role (prefer the main, else the higher id)
        // so the OS re-elects the pair — never disable both at once.
        let cycled = ordered.first { $0.isMain } ?? ordered[1]
        return [
            ConnectionStep(
                displayID: cycled.displayID,
                enable: false,
                reason: "swapIdentical: release display \(cycled.displayID) to re-elect the pair"
            ),
            ConnectionStep(
                displayID: cycled.displayID,
                enable: true,
                reason: "swapIdentical: re-seat display \(cycled.displayID)"
            ),
        ]
    }

    /// vendor+model identity — the serial is intentionally part of neither the
    /// key nor the comparison.
    private struct Identity: Hashable {
        let vendor: UInt32
        let model: UInt32
    }
}
