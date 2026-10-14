import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake until switched off.
///
/// The assertion is held by **this process**, which is why there is no `fbdcli`
/// command for it: a command-line invocation that acquired one would drop it again
/// on exit, so the toggle belongs to the app and the app is the only thing that can
/// hold it. `Settings.keepAwakeEnabled` records the choice so it survives a
/// restart, and `applyStoredPreference()` re-arms it at launch.
///
/// `kIOPMAssertionTypeNoDisplaySleep` rather than a system-only assertion, because
/// "keep awake" here means the thing the user is watching stays on — a transfer, a
/// slide deck, a render — not merely that the machine stays busy while its screen
/// goes black anyway.
public final class KeepAwakeController {
    public static let shared = KeepAwakeController()

    private var assertionID: IOPMAssertionID = 0

    public init() {}

    /// Whether the assertion is currently held.
    public var isEnabled: Bool { assertionID != 0 }

    /// Take or drop the assertion, recording the choice so it survives a restart.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        Settings.keepAwakeEnabled = enabled
        return enabled ? start() : stop()
    }

    /// Apply the stored preference — the launch path.
    @discardableResult
    public func applyStoredPreference() -> Bool {
        Settings.keepAwakeEnabled ? start() : stop()
    }

    /// Idempotent: calling this twice does not stack two assertions, so a repeat
    /// toggle cannot leave one behind that `stop()` then fails to reach.
    @discardableResult
    public func start() -> Bool {
        guard !isEnabled else { return true }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "FBD is keeping the Mac awake" as CFString,
            &id
        )
        guard status == kIOReturnSuccess else { return false }
        assertionID = id
        return true
    }

    /// Clears the stored id *before* releasing, so a failed release cannot strand a
    /// stale id that a later `start()` would refuse to replace.
    @discardableResult
    public func stop() -> Bool {
        guard isEnabled else { return true }
        let held = assertionID
        assertionID = 0
        return IOPMAssertionRelease(held) == kIOReturnSuccess
    }

    deinit {
        if isEnabled { IOPMAssertionRelease(assertionID) }
    }
}
