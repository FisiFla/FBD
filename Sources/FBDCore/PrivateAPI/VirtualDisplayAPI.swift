import CoreGraphics
import CPrivateAPI
import Foundation
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "VirtualDisplayAPI")

/// Typed wrapper over the SLVirtualDisplay ObjC API (macOS 26+, SkyLight).
/// Live-verified on macOS 27: create → applySettings → appears in
/// CGGetActiveDisplayList → destroy → removed.
///
/// The old CGVirtualDisplay API (macOS 13–15, VirtualDisplay.framework) is
/// reached through the CG path in `VirtualScreenController` via dlopen — the
/// framework does not exist on macOS 26+.
public enum VirtualDisplayAPI {
    private static func takeError(_ ptr: UnsafeMutableRawPointer?) -> NSError? {
        guard let ptr else { return nil }
        // Read the framework error WITHOUT taking ownership of it. The SL
        // framework's NSError** lifetime differs per failure path (the second
        // virtual-display create over-released a takeRetainedValue'd error,
        // crashing at the autorelease-pool drain: "-[NSError release] sent to
        // deallocated instance"). Copying the description via CF never
        // retains/releases the framework-owned object.
        let cfError = unsafeBitCast(ptr, to: CFError.self)
        let message = CFErrorCopyDescription(cfError) as String? ?? "unknown error"
        return NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }
    /// P3 chromaticities used for virtual display configs (macOS 26+ path).
    public static let p3Chromaticities = fbd_chromaticities(
        red: fbd_point(x: 0.680, y: 0.320),
        green: fbd_point(x: 0.265, y: 0.690),
        blue: fbd_point(x: 0.150, y: 0.060),
        white: fbd_point(x: 0.3127, y: 0.3290)
    )

    /// True when the SLVirtualDisplay API is available (macOS 26+).
    public static var isAvailable: Bool {
        NSClassFromString("SLVirtualDisplayConfiguration") != nil
            && NSClassFromString("SLVirtualDisplay") != nil
    }

    /// A created virtual display handle. `destroy()` releases it.
    public final class VirtualDisplayHandle {
        let ref: AnyObject
        public let displayID: CGDirectDisplayID

        init?(ref: AnyObject?, displayID: CGDirectDisplayID) {
            guard let ref else { return nil }
            self.ref = ref
            self.displayID = displayID
        }

        public func apply(settings: AnyObject) -> Bool {
            var err: UnsafeMutableRawPointer?
            let result = FBDVDApplySettings(
                Unmanaged.passUnretained(ref).toOpaque(),
                Unmanaged.passUnretained(settings).toOpaque(),
                &err
            ) != 0
            if let error = VirtualDisplayAPI.takeError(err) {
                log.warning("applySettings failed: \(error.localizedDescription)")
            }
            return result
        }

        public func destroy() {
            FBDVDDestroy(Unmanaged.passUnretained(ref).toOpaque())
        }
    }

    /// Create a virtual display. `sizeMillimeters`, `maxPixels` and `chromaticities`
    /// follow the exact struct layout from the method type encodings.
    public static func create(
        name: String,
        vendorID: UInt64 = 0xFBD0,
        productID: UInt64 = 0x0001,
        serialNumber: UInt64 = 1,
        sizeMillimeters: (width: Float, height: Float) = (200, 112),
        maxPixels: (width: UInt32, height: UInt32) = (4096, 2304),
        chromaticities: fbd_chromaticities = p3Chromaticities
    ) -> VirtualDisplayHandle? {
        guard let configClass = NSClassFromString("SLVirtualDisplayConfiguration"),
              let vdClass = NSClassFromString("SLVirtualDisplay") else {
            log.warning("SLVirtualDisplay unavailable on this macOS")
            return nil
        }
        var err: UnsafeMutableRawPointer?
        let mm = fbd_point(x: sizeMillimeters.width, y: sizeMillimeters.height)
        let maxP = fbd_size_i(w: maxPixels.width, h: maxPixels.height)
        guard let config = FBDVDConfigCreate(
            Unmanaged.passUnretained(configClass as AnyObject).toOpaque(),
            Unmanaged.passUnretained(name as NSString).toOpaque(),
            vendorID, productID, serialNumber, mm, maxP, chromaticities, &err
        ) else {
            log.warning("config create failed: \(takeError(err)?.localizedDescription ?? "unknown")")
            return nil
        }
        var err2: UnsafeMutableRawPointer?
        guard let vd = FBDVDCreate(Unmanaged.passUnretained(vdClass as AnyObject).toOpaque(), config, &err2) else {
            log.warning("virtual display create failed: \(takeError(err2)?.localizedDescription ?? "unknown")")
            return nil
        }
        let displayID = FBDVDDisplayID(vd)
        log.debug("virtual display created: id=\(displayID)")
        return VirtualDisplayHandle(ref: Unmanaged<AnyObject>.fromOpaque(vd).takeUnretainedValue(), displayID: CGDirectDisplayID(displayID))
    }

    /// Build a mode object (macOS 26+). Refresh rate is a Float per the encoding.
    public static func makeMode(
        pixels: (width: UInt32, height: UInt32),
        points: (width: UInt32, height: UInt32),
        refreshRate: Double
    ) -> AnyObject? {
        guard let modeClass = NSClassFromString("SLVirtualDisplayMode") else { return nil }
        var err: UnsafeMutableRawPointer?
        guard let mode = FBDVDModeCreate(
            Unmanaged.passUnretained(modeClass as AnyObject).toOpaque(),
            fbd_size_i(w: pixels.width, h: pixels.height),
            fbd_size_i(w: points.width, h: points.height),
            Float(refreshRate),
            &err
        ) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(mode).takeUnretainedValue()
    }

    /// Build a settings object with a native/preferred mode plus optional modes
    /// and rotations (0 = none). Passed to `apply(settings:)`.
    public static func makeSettings(
        native: AnyObject,
        preferred: AnyObject? = nil,
        optional: [AnyObject] = [],
        rotations: UInt64 = 0
    ) -> AnyObject? {
        guard let settingsClass = NSClassFromString("SLVirtualDisplaySettings") else { return nil }
        var err: UnsafeMutableRawPointer?
        guard let settings = FBDVDSettingsCreate(
            Unmanaged.passUnretained(settingsClass as AnyObject).toOpaque(),
            Unmanaged.passUnretained(native).toOpaque(),
            Unmanaged.passUnretained(preferred ?? native).toOpaque(),
            Unmanaged.passUnretained(optional as NSArray).toOpaque(),
            rotations,
            &err
        ) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(settings).takeUnretainedValue()
    }
}
