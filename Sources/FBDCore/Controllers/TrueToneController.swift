import CPrivateAPI
import Foundation
import os

/// True Tone control through the private CoreBrightness `CBTrueToneClient`
/// ObjC class. The class is resolved with `NSClassFromString` after dlopen'ing
/// the private framework and messaged via the C shims in
/// `Sources/CPrivateAPI/fbd_nightshift.c` (never statically linked).
///
/// Selectors used (verified against Lunar's CBTrueToneClient.h):
///   - `available`   (BOOL)
///   - `enabled`     (BOOL)
///   - `setEnabled:` (BOOL)
///
/// NOTE: as of macOS 26.3+ True Tone is no longer controllable from third
/// parties (`available` returns false) — every method degrades gracefully.
///
/// Plain class (not MainActor): safe to call from any queue. All private-API
/// failures degrade to nil/false with a logged warning — never crash.
public final class TrueToneController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "TrueToneController")

    /// The CBTrueToneClient instance (+1 ownership transferred to ARC), nil
    /// when the class is missing or cannot be instantiated.
    private let client: AnyObject?

    public init() {
        // CoreBrightness is a private framework the package does not link;
        // load it so NSClassFromString can resolve the class (idempotent).
        _ = FBDLoadCoreBrightness()
        guard let cls = NSClassFromString("CBTrueToneClient") else {
            log.warning("CBTrueToneClient unavailable — True Tone control disabled")
            client = nil
            return
        }
        guard let raw = FBDTrueToneCreate(Unmanaged.passUnretained(cls as AnyObject).toOpaque()) else {
            log.warning("CBTrueToneClient alloc/init failed")
            client = nil
            return
        }
        client = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
    }

    /// True when True Tone can be queried/controlled on this Mac.
    public var isAvailable: Bool {
        guard let client else { return false }
        return FBDTrueToneIsAvailable(Unmanaged.passUnretained(client).toOpaque())
    }

    /// Current True Tone state, or nil when unavailable.
    public func isEnabled() -> Bool? {
        guard isAvailable, let client else { return nil }
        return FBDTrueToneIsEnabled(Unmanaged.passUnretained(client).toOpaque())
    }

    /// Enable or disable True Tone. Returns false when unavailable or the
    /// write failed.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        guard let client else { return false }
        guard FBDTrueToneSetEnabled(Unmanaged.passUnretained(client).toOpaque(), enabled) else {
            log.warning("setEnabled: failed for \(enabled)")
            return false
        }
        return true
    }
}
