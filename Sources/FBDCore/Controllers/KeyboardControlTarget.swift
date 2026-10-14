import CoreGraphics
import Foundation

/// Which screen the hardware keyboard brightness/volume keys act on.
///
/// BetterDisplay offers four choices here; this mirrors them so FBD's media
/// keys can target the same screens. A pure value type — no I/O, no display
/// APIs — so the routing stays unit-testable and the controller seam stays
/// thin.
public enum KeyboardControlTarget: String, Codable, CaseIterable, Sendable {
    /// The screen the mouse pointer is on (BetterDisplay's default).
    case mouseScreen
    /// The screen the focused window is on.
    case focusedScreen
    /// Every screen that supports the requested capability.
    case allSuitableScreens
    /// The screen whose name matches the current audio output device.
    case audioDeviceMatch

    /// BetterDisplay's default: act on the screen under the pointer.
    public static let `default`: KeyboardControlTarget = .mouseScreen
}

/// A pure description of one candidate screen/display.
///
/// Deliberately value-only: the resolver never touches `NSScreen`, the
/// CoreGraphics configuration or DDC — callers translate their live displays
/// into `ScreenCandidate`s and inject them, which keeps the decision total and
/// testable.
public struct ScreenCandidate: Equatable {
    public let displayID: CGDirectDisplayID
    public let name: String
    public let frame: CGRect
    public let supportsBrightness: Bool
    public let supportsVolume: Bool
    public let isMain: Bool
    public let isOnline: Bool

    public init(
        displayID: CGDirectDisplayID,
        name: String,
        frame: CGRect,
        supportsBrightness: Bool,
        supportsVolume: Bool,
        isMain: Bool,
        isOnline: Bool
    ) {
        self.displayID = displayID
        self.name = name
        self.frame = frame
        self.supportsBrightness = supportsBrightness
        self.supportsVolume = supportsVolume
        self.isMain = isMain
        self.isOnline = isOnline
    }
}

/// Resolves a `KeyboardControlTarget` to the display id(s) a media key should
/// act on. Pure, total and deterministic: the same inputs always yield the
/// same ids and no input can trap.
///
/// Rules, in order:
/// - Only **online** candidates are considered at all.
/// - A candidate is *eligible* only when it supports the required capability
///   (volume when `requiresVolume`, otherwise brightness).
/// - `mouseScreen` picks the eligible candidate whose frame contains the mouse
///   location, else the eligible candidate nearest by centre distance, else
///   the main display.
/// - `focusedScreen` uses `focusedDisplayID` when that display is eligible,
///   else follows the same contains → nearest → main chain.
/// - `allSuitableScreens` returns every eligible candidate, main first then by
///   display id ascending.
/// - `audioDeviceMatch` prefers an eligible candidate whose name matches the
///   audio device name (exact first, then a substring in either direction),
///   and otherwise follows the `mouseScreen` chain.
/// - The result is empty only when **nothing** is online. When no candidate is
///   eligible for the capability, the main display is returned so a key press
///   is never silently swallowed.
public enum KeyboardControlResolver {

    /// Case-insensitive exact-or-partial match between an audio device name and
    /// a display name. Partial means either string contains the other. Empty
    /// strings never match.
    public static func matches(audioDeviceName: String, displayName: String) -> Bool {
        let device = audioDeviceName.lowercased()
        let display = displayName.lowercased()
        guard !device.isEmpty, !display.isEmpty else { return false }
        return display == device || display.contains(device) || device.contains(display)
    }

    public static func resolve(
        target: KeyboardControlTarget,
        candidates: [ScreenCandidate],
        mouseLocation: CGPoint,
        focusedDisplayID: CGDirectDisplayID?,
        audioDeviceName: String?,
        requiresVolume: Bool
    ) -> [CGDirectDisplayID] {
        let online = candidates.filter { $0.isOnline }
        guard !online.isEmpty else { return [] }

        let eligible = online.filter { requiresVolume ? $0.supportsVolume : $0.supportsBrightness }
        let main = online.first { $0.isMain } ?? online.min { $0.displayID < $1.displayID }

        switch target {
        case .mouseScreen:
            return mouseChain(eligible, mouseLocation: mouseLocation, main: main)

        case .focusedScreen:
            if let focusedDisplayID, let focused = eligible.first(where: { $0.displayID == focusedDisplayID }) {
                return [focused.displayID]
            }
            return mouseChain(eligible, mouseLocation: mouseLocation, main: main)

        case .allSuitableScreens:
            guard !eligible.isEmpty else { return main.map { [$0.displayID] } ?? [] }
            return eligible.sorted(by: isOrderedBefore).map { $0.displayID }

        case .audioDeviceMatch:
            if let audioDeviceName, !audioDeviceName.isEmpty {
                let exact = eligible.filter { $0.name.lowercased() == audioDeviceName.lowercased() }
                if let hit = exact.sorted(by: isOrderedBefore).first { return [hit.displayID] }
                let partial = eligible.filter { matches(audioDeviceName: audioDeviceName, displayName: $0.name) }
                if let hit = partial.sorted(by: isOrderedBefore).first { return [hit.displayID] }
            }
            return mouseChain(eligible, mouseLocation: mouseLocation, main: main)
        }
    }

    // MARK: - The contains → nearest → main fallback chain

    private static func mouseChain(
        _ eligible: [ScreenCandidate],
        mouseLocation: CGPoint,
        main: ScreenCandidate?
    ) -> [CGDirectDisplayID] {
        // 1. An eligible screen whose frame contains the pointer.
        var containing: ScreenCandidate?
        for candidate in eligible where candidate.frame.contains(mouseLocation) {
            if let current = containing {
                if isOrderedBefore(candidate, current) { containing = candidate }
            } else {
                containing = candidate
            }
        }
        if let containing { return [containing.displayID] }

        // 2. The eligible screen nearest by centre distance.
        var nearest: ScreenCandidate?
        for candidate in eligible {
            guard let current = nearest else {
                nearest = candidate
                continue
            }
            let candidateDistance = centreDistanceSquared(candidate, to: mouseLocation)
            let currentDistance = centreDistanceSquared(current, to: mouseLocation)
            if candidateDistance < currentDistance
                || (candidateDistance == currentDistance && isOrderedBefore(candidate, current)) {
                nearest = candidate
            }
        }
        if let nearest { return [nearest.displayID] }

        // 3. The main display, so the key is never silently swallowed.
        return main.map { [$0.displayID] } ?? []
    }

    /// Stable ordering: main display first, then display id ascending.
    private static func isOrderedBefore(_ a: ScreenCandidate, _ b: ScreenCandidate) -> Bool {
        if a.isMain != b.isMain { return a.isMain }
        return a.displayID < b.displayID
    }

    private static func centreDistanceSquared(_ candidate: ScreenCandidate, to point: CGPoint) -> CGFloat {
        let dx = candidate.frame.midX - point.x
        let dy = candidate.frame.midY - point.y
        return dx * dx + dy * dy
    }
}
