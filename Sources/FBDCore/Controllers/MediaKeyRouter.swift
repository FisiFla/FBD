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
/// - Volume/mute keys (NX_KEYTYPE_SOUND_* = 0/1, MUTE = 7) are consumed only
///   when the target has DDC (Apple displays have no DDC volume).
public enum MediaKeyRouter {
    /// One brightness step (~6.25%), matching macOS's standard step.
    public static let step = 0.0625

    public static func route(
        keyCode: Int32,
        interceptEnabled: Bool,
        targetHasControlPath: Bool,
        targetHasDDC: Bool
    ) -> MediaKeyAction {
        guard interceptEnabled, targetHasControlPath else { return .none }
        switch keyCode {
        case 2: // NX_KEYTYPE_BRIGHTNESS_UP
            return .brightnessUp
        case 3: // NX_KEYTYPE_BRIGHTNESS_DOWN
            return .brightnessDown
        case 0: // NX_KEYTYPE_SOUND_UP
            return targetHasDDC ? .volumeUp : .none
        case 1: // NX_KEYTYPE_SOUND_DOWN
            return targetHasDDC ? .volumeDown : .none
        case 7: // NX_KEYTYPE_MUTE
            return targetHasDDC ? .toggleMute : .none
        default:
            return .none
        }
    }
}
