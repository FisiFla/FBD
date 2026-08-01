import CoreGraphics
import CPrivateAPI
import Foundation
import IOKit
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "IOMobileFramebufferAPI")

/// Typed wrappers over the private IOMobileFramebuffer framework (built-in
/// panel control: color remap modes, gamma tables).
///
/// ⚠️ EXPERIMENTAL: on macOS 27 `IOMobileFramebufferOpen` returns
/// kIOReturnNotPrivileged (0xE00002C2) — the user client is entitlement-gated
/// and the framework exports no Close function. Every call here degrades
/// gracefully; the "direct color-table" XDR method therefore reports
/// unavailable on this OS until an entitlement path is found. The wrappers
/// remain useful on macOS versions where the user client is open.
public enum IOMobileFramebufferAPI {
    /// Gamma table layout: 257 entries × 3 channels, 16.16 fixed point.
    public static let gammaTableEntryCount = 257
    public static let gammaTableChannelCount = 3

    /// The IOMobileFramebuffer service for a display (class "IOMobileFramebuffer",
    /// matched by the display's vendor/model/serial on the AppleCLCD2 node).
    private static func service(for displayID: CGDirectDisplayID, vendor: UInt32, model: UInt32, serial: UInt32) -> io_service_t? {
        let services = IOKitSupport.matchingServices(IOServiceMatching("IOMobileFramebuffer"))
        for service in services {
            defer { IOKitSupport.release(service) }
            let props = IOKitSupport.properties(of: service)
            let vendorOK = (props["vendorID"] as? UInt32) == vendor
                || (props["DisplayVendorID"] as? UInt32) == vendor
                || (props["IODisplayVendorID"] as? UInt32) == vendor
            let modelOK = (props["productID"] as? UInt32) == model
                || (props["DisplayProductID"] as? UInt32) == model
                || (props["IODisplayProductID"] as? UInt32) == model
            if vendorOK && modelOK {
                return service
            }
        }
        return nil
    }

    /// Open the display's framebuffer (type 0 = direct connection).
    /// Returns nil when the user client is entitlement-gated or unavailable.
    public static func open(displayID: CGDirectDisplayID, vendor: UInt32, model: UInt32, serial: UInt32) -> IOMobileFramebufferRef? {
        guard let service = service(for: displayID, vendor: vendor, model: model, serial: serial) else {
            log.debug("No IOMobileFramebuffer service for \(displayID)")
            return nil
        }
        var fb: IOMobileFramebufferRef?
        let status = IOMobileFramebufferOpen(service, 0, 0, &fb)
        if status != 0 {
            log.debug("IOMobileFramebufferOpen failed for \(displayID): 0x\(String(status, radix: 16)) (entitlement-gated on macOS 26+)")
            return nil
        }
        return fb
    }

    /// Current color remap mode (0 = normal, 1 = inverted, 2 = grayscale, …).
    public static func colorRemapMode(_ fb: IOMobileFramebufferRef) -> Int? {
        var mode: Int32 = -1
        guard IOMobileFramebufferGetColorRemapMode(fb, &mode) == 0 else { return nil }
        return Int(mode)
    }

    /// Set the color remap mode. NOTE: the documented modes are accessibility
    /// modes (invert/grayscale) — brightness boosting via this path is
    /// unverified on macOS; only call with user consent.
    @discardableResult
    public static func setColorRemapMode(_ mode: Int, on fb: IOMobileFramebufferRef) -> Bool {
        IOMobileFramebufferSetColorRemapMode(fb, Int32(mode)) == 0
    }

    /// Read the current gamma table (771 uint32: 257 entries × 3 channels).
    public static func gammaTable(_ fb: IOMobileFramebufferRef) -> [UInt32]? {
        var table = [UInt32](repeating: 0, count: gammaTableEntryCount * gammaTableChannelCount)
        let status = table.withUnsafeMutableBufferPointer { buffer in
            IOMobileFramebufferGetGammaTable(fb, buffer.baseAddress)
        }
        guard status == 0 else { return nil }
        return table
    }

    /// Write a gamma table. Entries are 16.16 fixed point; values above
    /// 0x10000 request output above the panel's SDR ceiling (the "color table"
    /// XDR method). Restore the original table to disable.
    @discardableResult
    public static func setGammaTable(_ table: [UInt32], on fb: IOMobileFramebufferRef) -> Bool {
        guard table.count == gammaTableEntryCount * gammaTableChannelCount else { return false }
        let status = table.withUnsafeBufferPointer { buffer in
            IOMobileFramebufferSetGammaTable(fb, buffer.baseAddress)
        }
        return status == 0
    }

    /// Identity gamma table (16.16): entry i → i/256 × 0x10000.
    public static func identityGammaTable() -> [UInt32] {
        var table = [UInt32](repeating: 0, count: gammaTableEntryCount * gammaTableChannelCount)
        for i in 0..<gammaTableEntryCount {
            let value = UInt32((Double(i) / Double(gammaTableEntryCount - 1)) * 65536.0)
            for channel in 0..<gammaTableChannelCount {
                table[i * gammaTableChannelCount + channel] = value
            }
        }
        return table
    }

    /// Boosted gamma table: identity scaled by `factor` (1.0 = identity),
    /// clamped to UInt32 max.
    public static func boostedGammaTable(factor: Double) -> [UInt32] {
        identityGammaTable().map { value in
            UInt32(min(Double(value) * factor, Double(UInt32.max)))
        }
    }
}
