import CoreGraphics
import Foundation

/// Ties a virtual screen to real displays, so an arrangement can be recalled when
/// that screen attaches.
///
/// Displays are named by **identity key** (`vendor-model-serial` — see
/// `DisplayIdentity`) rather than by `CGDirectDisplayID`. A display id is reassigned
/// across a detach/reconnect, which is the whole reason an association is worth
/// storing: it has to outlive the screen being gone.
///
/// There is deliberately **no mirroring field**. Mirroring a virtual screen means
/// addressing it as a display, and ADR-0001 records the live finding that a virtual
/// screen FBD created does not appear in `CGGetActiveDisplayList` for its own
/// process, so such a request cannot be addressed and cannot be verified here.
/// Storing a flag that nothing could ever apply would be exactly the
/// dead-configuration this codebase has had to remove twice already.
public struct VirtualScreenAssociation: Codable, Equatable, Sendable {
    /// One display's place in the arrangement.
    public struct Placement: Codable, Equatable, Sendable {
        public let identity: String
        public let x: Int32
        public let y: Int32

        public init(identity: String, x: Int32, y: Int32) {
            self.identity = identity
            self.x = x
            self.y = y
        }
    }

    /// `VirtualScreenConfig.id` this belongs to.
    public var virtualScreenID: String
    /// The arrangement to restore, one entry per display that must be present.
    public var placements: [Placement]

    public init(virtualScreenID: String, placements: [Placement]) {
        self.virtualScreenID = virtualScreenID
        self.placements = placements
    }
}

/// What should happen when a virtual screen attaches.
public enum VirtualScreenAttachmentOrder: Equatable, Sendable {
    /// Nothing is stored for this screen.
    case nothingStored
    /// Some associated displays are not attached. Nothing is arranged, because a
    /// partial arrangement would move the displays that *are* present into positions
    /// chosen for a layout that does not exist yet.
    case waitingForDisplays(missing: [String])
    /// Arrange these placements, in this order.
    case arrange([VirtualScreenAssociation.Placement])

    /// The arrangement to apply, or nil when there is nothing to apply.
    public var placementsToApply: [VirtualScreenAssociation.Placement]? {
        if case .arrange(let placements) = self { return placements }
        return nil
    }
}

public enum VirtualScreenAssociations {
    /// Decide what to arrange when `virtualScreenID` attaches.
    ///
    /// Pure: the caller says which displays are attached, so both branches are
    /// testable without a display — and testable for the case this machine cannot
    /// produce, since ADR-0001 means an SL virtual display never shows up in its own
    /// process's display list.
    public static func order(
        for virtualScreenID: String,
        associations: [VirtualScreenAssociation],
        attachedIdentities: [String]
    ) -> VirtualScreenAttachmentOrder {
        guard let association = associations.first(where: { $0.virtualScreenID == virtualScreenID }),
              !association.placements.isEmpty else {
            return .nothingStored
        }
        let attached = Set(attachedIdentities)
        let missing = association.placements.map(\.identity).filter { !attached.contains($0) }
        guard missing.isEmpty else { return .waitingForDisplays(missing: missing) }
        return .arrange(association.placements)
    }

    /// Turn placements into anchors the display layer can apply, or nil when any
    /// identity cannot be resolved to an attached display.
    ///
    /// Resolution is by identity, never by position in the list: two identical
    /// monitors report the same name and would otherwise be happily swapped.
    public static func anchors(
        for placements: [VirtualScreenAssociation.Placement],
        attached: [(identity: String, displayID: CGDirectDisplayID)]
    ) -> [LayoutAnchor]? {
        guard !placements.isEmpty else { return nil }
        var byIdentity: [String: CGDirectDisplayID] = [:]
        for display in attached {
            // First one wins if two attached displays claim an identity, so the
            // result is stable rather than dependent on dictionary ordering.
            if byIdentity[display.identity] == nil { byIdentity[display.identity] = display.displayID }
        }
        var anchors: [LayoutAnchor] = []
        for placement in placements {
            guard let displayID = byIdentity[placement.identity] else { return nil }
            anchors.append(LayoutAnchor(displayID: displayID, x: placement.x, y: placement.y))
        }
        return anchors
    }
}
