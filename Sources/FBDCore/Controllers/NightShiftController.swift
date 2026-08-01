import CPrivateAPI
import Foundation
import os

/// Night Shift (blue-light reduction) control through the private
/// CoreBrightness `CBBlueLightClient` ObjC class. The class is resolved with
/// `NSClassFromString` after dlopen'ing the private framework and messaged via
/// the C shims in `Sources/CPrivateAPI/fbd_nightshift.c` (never statically
/// linked, never declared in Swift).
///
/// Selectors used (verified against Lunar's CBBlueLightClient.h and its
/// GammaControl.swift usage):
///   - `setStrength:commit:`  (float, BOOL)
///   - `getStrength:`         (float *) — single argument on current macOS
///   - `supportsBlueLightReduction` (class method)
///
/// Strength is a 0…1 fraction (0 = no reduction, 1 = full).
///
/// Plain class (not MainActor): safe to call from any queue. All private-API
/// failures degrade to nil/false with a logged warning — never crash.
public final class NightShiftController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "NightShiftController")

    /// The CBBlueLightClient instance (+1 ownership transferred to ARC), nil
    /// when the class is missing or cannot be instantiated.
    private let client: AnyObject?
    /// The CBBlueLightClient class object (for the class method).
    private let clientClass: AnyClass?

    public init() {
        // CoreBrightness is a private framework the package does not link;
        // load it so NSClassFromString can resolve the class (idempotent).
        _ = FBDLoadCoreBrightness()
        guard let cls = NSClassFromString("CBBlueLightClient") else {
            log.warning("CBBlueLightClient unavailable — Night Shift control disabled")
            client = nil
            clientClass = nil
            return
        }
        guard let raw = FBDNightShiftCreate(Unmanaged.passUnretained(cls as AnyObject).toOpaque()) else {
            log.warning("CBBlueLightClient alloc/init failed")
            client = nil
            clientClass = nil
            return
        }
        client = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
        clientClass = cls
    }

    /// True when Night Shift reduction can be read/written on this Mac.
    public var isAvailable: Bool {
        guard let clientClass else { return false }
        return FBDNightShiftSupportsBlueLightReduction(
            Unmanaged.passUnretained(clientClass as AnyObject).toOpaque()
        )
    }

    /// Current blue-light reduction strength 0…1 (nil when unavailable or the
    /// getter failed).
    public func strength() -> Double? {
        guard let client else { return nil }
        var raw: Float = 0
        guard FBDNightShiftGetStrength(Unmanaged.passUnretained(client).toOpaque(), &raw) else {
            log.warning("getStrength: failed")
            return nil
        }
        return Double(min(max(raw, 0), 1))
    }

    /// Set reduction strength 0…1 (clamped). Returns false when unavailable or
    /// the write failed. Commits immediately.
    @discardableResult
    public func setStrength(_ value: Double) -> Bool {
        guard let client else { return false }
        let clamped = Float(min(max(value, 0), 1))
        guard FBDNightShiftSetStrength(Unmanaged.passUnretained(client).toOpaque(), clamped, true) else {
            log.warning("setStrength: commit failed for \(clamped)")
            return false
        }
        return true
    }
}
