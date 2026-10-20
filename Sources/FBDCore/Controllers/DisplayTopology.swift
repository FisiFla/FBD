import AppKit
import CoreGraphics
import Foundation

/// The display topology the disconnect policies act on.
///
/// Everything a policy needs to know about the attached displays in one place:
/// which are online, which are active, which one is the built-in panel, and
/// what identity each online display's settings are filed under.
///
/// It is injected so a policy can be exercised with a topology the test
/// machine cannot produce — an external display attached, a built-in panel
/// that is off, a display that comes back.
///
/// The disconnect policies work on display *ids* (that is what the CGS call
/// takes), but what is remembered is keyed by *identity*: a display id
/// changes on every replug and every reboot, an identity does not.
public protocol DisplayTopology: AnyObject {
    /// The online displays (connected, possibly inactive): id → identity key.
    func onlineDisplays() -> [CGDirectDisplayID: String]
    /// The active display ids.
    func activeDisplayIDs() -> [CGDirectDisplayID]
    /// The built-in panel's id, when one is attached.
    func builtinDisplayID() -> CGDirectDisplayID?
    /// Whether the display is the built-in panel.
    func isBuiltin(_ displayID: CGDirectDisplayID) -> Bool
}

/// The live topology: the CoreGraphics display lists.
///
/// The identity key is built the way `Display.identityKey` builds it, from
/// the same CoreGraphics identity and the same name source — AppKit's
/// `NSScreen.localizedName`, with the same "Display <id>" fallback
/// `DisplayController` uses. The two therefore agree, so a display that was
/// remembered under one path is found under the other.
///
/// AppKit wants the main thread, and the policies run there; a caller that
/// does not gets the fallback name, which is the precise vendor/model/serial
/// key in every identity method that needs one.
public final class CoreGraphicsDisplayTopology: DisplayTopology {
    public init() {}

    public func onlineDisplays() -> [CGDirectDisplayID: String] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [:] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard ids.withUnsafeMutableBufferPointer({
            CGGetOnlineDisplayList(UInt32($0.count), $0.baseAddress, &count)
        }) == .success else { return [:] }
        var result: [CGDirectDisplayID: String] = [:]
        for id in ids.prefix(Int(count)) {
            result[id] = Self.identityKey(for: id)
        }
        return result
    }

    public func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard ids.withUnsafeMutableBufferPointer({
            CGGetActiveDisplayList(UInt32($0.count), $0.baseAddress, &count)
        }) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    public func builtinDisplayID() -> CGDirectDisplayID? {
        onlineDisplays().keys.first(where: { isBuiltin($0) })
    }

    public func isBuiltin(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }

    /// The identity key of a display id: the same key `Display.identityKey`
    /// returns, built from the same CoreGraphics identity and the same name.
    public static func identityKey(for displayID: CGDirectDisplayID) -> String {
        DisplayIdentity.key(
            vendor: CGDisplayVendorNumber(displayID),
            model: CGDisplayModelNumber(displayID),
            serial: CGDisplaySerialNumber(displayID),
            name: displayName(for: displayID),
            method: Settings.displayIdentityMethod
        )
    }

    /// The display's user-visible name, or the same "Display <id>" fallback
    /// `DisplayController` uses when the OS has no screen for it.
    private static func displayName(for displayID: CGDirectDisplayID) -> String {
        guard Thread.isMainThread else { return "Display \(displayID)" }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else {
            return "Display \(displayID)"
        }
        return screen.localizedName
    }
}
