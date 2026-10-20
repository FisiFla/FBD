import CoreGraphics
import XCTest
@testable import FBDCore

/// A topology a test machine cannot produce.
///
/// The disconnect policies act on what is attached: an external display that
/// comes back, a built-in panel that is on or off, a base-M3 guard refusal.
/// None of that can be arranged with the displays this machine has, so the
/// topology is a test double.
final class FakeDisplayTopology: DisplayTopology {
    /// The online displays: id → identity key.
    var online: [CGDirectDisplayID: String] = [:]
    /// The active display ids.
    var active: [CGDirectDisplayID] = []
    /// The built-in panel's id, when one is attached.
    var builtin: CGDirectDisplayID?

    func onlineDisplays() -> [CGDirectDisplayID: String] { online }
    func activeDisplayIDs() -> [CGDirectDisplayID] { active }
    func builtinDisplayID() -> CGDirectDisplayID? { builtin }
    func isBuiltin(_ displayID: CGDirectDisplayID) -> Bool { displayID == builtin }
}

/// Records the enable/disable calls a policy makes, instead of performing
/// them: a real call would go to the WindowServer with a display id that does
/// not exist.
final class RecordingDisplayEnabler: DisplayEnabling {
    /// The calls, in order.
    private(set) var calls: [(enabled: Bool, displayID: CGDirectDisplayID)] = []

    /// Whether the calls are reported as accepted.
    var succeeds = true

    func setEnabled(_ enabled: Bool, displayID: CGDirectDisplayID) -> Bool {
        calls.append((enabled, displayID))
        return succeeds
    }
}
