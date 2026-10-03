import Foundation

/// What (if anything) to do with a hardware media-key event.
public enum MediaKeyAction: Equatable {
    /// Pass the event through to the system (no interception).
    case none
    case brightnessUp
    case brightnessDown
    case volumeUp
    case volumeDown
    case toggleMute
}

/// Where a volume key should act.
public enum VolumeTarget: Equatable {
    /// The display's own speakers, over DDC.
    case display
    /// The Mac's own output device, over CoreAudio (#20).
    case system
}

/// Pure decision logic for hardware media-key interception.
///
/// `HotkeyController` feeds the current display/control-path state; this
/// type decides whether a key is consumed and what it should do. Extracted
/// from the controller so the routing matrix is unit-testable.
///
/// Semantics preserved from the controller's original implementation:
/// - Interception only happens when `interceptEnabled`.
/// - The target display must have *some* control path (Apple brightness or
///   DDC) or every key passes through.
/// - Brightness keys (NX_KEYTYPE_BRIGHTNESS_UP/DOWN = 2/3) are consumed when
///   any control path exists (DDC brightness is a valid route too).
/// - Volume/mute keys (NX_KEYTYPE_SOUND_* = 0/1, MUTE = 7) go to the display
///   over DDC when it has DDC, and otherwise to the Mac's own output device
///   when that has a volume control. A display with no DDC used to mean the
///   key passed through to macOS; it now means the Mac's own volume moves,
///   which is what a user pressing the key on a DDC-less setup expects.
public enum MediaKeyRouter {
    /// One brightness step (~6.25%), matching macOS's standard step.
    public static let step = 0.0625

    /// A routed press: what to do, and for a volume key, where.
    public struct Decision: Equatable {
        public let action: MediaKeyAction
        /// nil for brightness and pass-through, which have no volume target.
        public let volumeTarget: VolumeTarget?

        public init(action: MediaKeyAction, volumeTarget: VolumeTarget? = nil) {
            self.action = action
            self.volumeTarget = volumeTarget
        }
    }

    /// The full decision, including which volume path to use.
    public static func decide(
        keyCode: Int32,
        interceptEnabled: Bool,
        targetHasControlPath: Bool,
        targetHasDDC: Bool,
        systemVolumeAvailable: Bool
    ) -> Decision {
        guard interceptEnabled, targetHasControlPath else { return Decision(action: .none) }

        /// DDC is preferred when the display has it: the key is about the
        /// display the user is looking at.
        let volumeTarget: VolumeTarget? = targetHasDDC
            ? .display
            : (systemVolumeAvailable ? .system : nil)

        switch keyCode {
        case 2: // NX_KEYTYPE_BRIGHTNESS_UP
            return Decision(action: .brightnessUp)
        case 3: // NX_KEYTYPE_BRIGHTNESS_DOWN
            return Decision(action: .brightnessDown)
        case 0: // NX_KEYTYPE_SOUND_UP
            guard let volumeTarget else { return Decision(action: .none) }
            return Decision(action: .volumeUp, volumeTarget: volumeTarget)
        case 1: // NX_KEYTYPE_SOUND_DOWN
            guard let volumeTarget else { return Decision(action: .none) }
            return Decision(action: .volumeDown, volumeTarget: volumeTarget)
        case 7: // NX_KEYTYPE_MUTE
            guard let volumeTarget else { return Decision(action: .none) }
            return Decision(action: .toggleMute, volumeTarget: volumeTarget)
        default:
            return Decision(action: .none)
        }
    }

    /// Action-only view of the same decision, with no system volume path
    /// available — the behaviour before #20 added one.
    public static func route(
        keyCode: Int32,
        interceptEnabled: Bool,
        targetHasControlPath: Bool,
        targetHasDDC: Bool
    ) -> MediaKeyAction {
        decide(
            keyCode: keyCode,
            interceptEnabled: interceptEnabled,
            targetHasControlPath: targetHasControlPath,
            targetHasDDC: targetHasDDC,
            systemVolumeAvailable: false
        ).action
    }
}
