import CoreGraphics
import Foundation

/// Which of a display's properties configuration protection saves and
/// re-applies when the display reconnects.
///
/// Deliberately a plain value type with no hardware dependency, so the two
/// things that need testing — which properties a given display exposes, and
/// how a user-supplied name maps to a flag — are testable without a display.
///
/// BetterDisplay protects nine properties. FBD re-applies eight of them: the six it
/// can observe directly, plus rotation and the colour profile, which it can *apply*
/// but not **read** — so those two are restored from the value FBD itself last
/// applied (`Settings.storedRotation` / `Settings.storedColourProfile`), and one set
/// by another tool is invisible to it. The SDR/HDR *colour mode* pair is still not
/// represented, because FBD has no connection-mode/colour-mode path at all (a private
/// API that was never identified — see `docs/PRIVATE_APIS.md`). Each gap is
/// deliberate and visible rather than silently collapsed into another flag.
public struct ProtectedProperties: OptionSet, Codable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let resolution  = ProtectedProperties(rawValue: 1 << 0)
    public static let refreshRate = ProtectedProperties(rawValue: 1 << 1)
    public static let brightness  = ProtectedProperties(rawValue: 1 << 2)
    public static let preset      = ProtectedProperties(rawValue: 1 << 3)
    public static let hdrMode     = ProtectedProperties(rawValue: 1 << 4)
    public static let mainStatus  = ProtectedProperties(rawValue: 1 << 5)
    public static let rotation    = ProtectedProperties(rawValue: 1 << 6)
    public static let colourProfile = ProtectedProperties(rawValue: 1 << 7)

    public static let all: ProtectedProperties = [
        .resolution, .refreshRate, .brightness, .preset, .hdrMode, .mainStatus,
        .rotation, .colourProfile,
    ]

    /// What protection covered before per-property selection existed (mode,
    /// brightness, active preset). Kept as the default so upgrading to
    /// per-property selection never silently starts re-applying *more* state
    /// than the previous version did — widening is an explicit user choice.
    public static let legacyDefault: ProtectedProperties = [.resolution, .brightness, .preset]

    /// Stable names, in the order properties are re-applied. Also the CLI
    /// vocabulary.
    public static let ordered: [(name: String, property: ProtectedProperties)] = [
        ("resolution", .resolution),
        ("refreshRate", .refreshRate),
        ("preset", .preset),
        ("hdrMode", .hdrMode),
        ("mainStatus", .mainStatus),
        ("rotation", .rotation),
        ("colourProfile", .colourProfile),
        ("brightness", .brightness),
    ]

    /// The property names in this set, in apply order.
    public var names: [String] {
        Self.ordered.filter { contains($0.property) }.map(\.name)
    }

    /// Parses a comma-separated name list (`"resolution,brightness"` or
    /// `"all"`). Returns nil if **any** name is unknown, so a typo is refused
    /// rather than silently dropped.
    public static func parse(_ list: String) -> ProtectedProperties? {
        var result: ProtectedProperties = []
        var sawAny = false
        for raw in list.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            sawAny = true
            if name.lowercased() == "all" {
                result.formUnion(.all)
                continue
            }
            guard let match = ordered.first(where: { $0.name.lowercased() == name.lowercased() }) else {
                return nil
            }
            result.formUnion(match.property)
        }
        return sawAny ? result : nil
    }

    /// Which properties this display can actually be protected on, given what
    /// it exposes. `mainStatus` is always available (`CGDisplayIsMain` works
    /// for any display); everything else depends on the display's state.
    public static func available(for display: Display) -> ProtectedProperties {
        var result: ProtectedProperties = [.mainStatus]
        if display.currentMode != nil {
            result.insert(.resolution)
            result.insert(.refreshRate)
        }
        if display.brightness != nil || display.appleBrightnessAvailable || display.ddcAvailable {
            result.insert(.brightness)
        }
        if display.isXDRCapable, !display.presets.isEmpty {
            result.insert(.preset)
        }
        if display.isHDRModeCapable {
            result.insert(.hdrMode)
        }
        // Rotation and the colour profile are offered for any display FBD can enumerate,
        // because **neither can be probed**: there is no readable rotation and no readable
        // current profile, so there is no capability to test for. Both restore steps are
        // individually guarded, so selecting one on a display that cannot take it logs and
        // does nothing rather than forcing an invalid state.
        if display.currentMode != nil {
            result.insert(.rotation)
            result.insert(.colourProfile)
        }
        return result
    }
}
