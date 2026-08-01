import CoreGraphics
import CPrivateAPI
import Darwin
import Foundation
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "CGVirtualDisplayAPI")

/// Legacy CGVirtualDisplay binding (macOS 13–15, VirtualDisplay.framework),
/// loaded at runtime with dlopen + dlsym (the framework does not exist on
/// macOS 26+, so it can never be linked statically).
///
/// NOT live-tested: this machine runs macOS 27 where the framework is absent.
/// Struct layouts and C signatures come from the circulated
/// VirtualDisplay.framework header (see fbd_private_api.h) and must be
/// re-verified on macOS 13–15. All failures degrade to nil/false + os_log.
public enum CGVirtualDisplayAPI {
    // C function types and struct layouts are declared in fbd_private_api.h
    // (fbd_cgvd_* typedefs) so the @convention(c) ABI is exact.

    private typealias CreateWithDescriptorFn = fbd_cgvd_create_fn
    private typealias DestroyFn = fbd_cgvd_destroy_fn
    private typealias CreateModeFn = fbd_cgvd_create_mode_fn
    private typealias SetDisplayModeFn = fbd_cgvd_set_mode_fn
    private typealias ApplySettingsFn = fbd_cgvd_apply_settings_fn
    private typealias ReleaseModeFn = fbd_cgvd_release_mode_fn

    private typealias Descriptor = fbd_cgvd_descriptor
    private typealias Settings = fbd_cgvd_settings

    // MARK: - Symbol resolution

    private struct Symbols {
        let createWithDescriptor: CreateWithDescriptorFn
        let destroy: DestroyFn
        let createMode: CreateModeFn
        let setDisplayMode: SetDisplayModeFn
        let applySettings: ApplySettingsFn
        let releaseMode: ReleaseModeFn?
    }

    private static let frameworkPath = "/System/Library/PrivateFrameworks/VirtualDisplay.framework/VirtualDisplay"

    private static let symbols: Symbols? = {
        guard let handle = dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL) else {
            log.debug("VirtualDisplay.framework unavailable (expected on macOS 26+)")
            return nil
        }
        func resolve<T>(_ name: String) -> T? {
            guard let ptr = dlsym(handle, name) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }
        guard let createWithDescriptor: CreateWithDescriptorFn = resolve("CGVirtualDisplayCreateWithDescriptor"),
              let destroy: DestroyFn = resolve("CGVirtualDisplayDestroy"),
              let createMode: CreateModeFn = resolve("CGVirtualDisplayCreateMode"),
              let setDisplayMode: SetDisplayModeFn = resolve("CGVirtualDisplaySetDisplayMode"),
              let applySettings: ApplySettingsFn = resolve("CGVirtualDisplayApplySettings") else {
            log.warning("VirtualDisplay.framework loaded but required symbols are missing")
            return nil
        }
        let releaseMode: ReleaseModeFn? = resolve("CGVirtualDisplayReleaseMode")
        return Symbols(
            createWithDescriptor: createWithDescriptor,
            destroy: destroy,
            createMode: createMode,
            setDisplayMode: setDisplayMode,
            applySettings: applySettings,
            releaseMode: releaseMode
        )
    }()

    /// True when the framework loaded and every required symbol resolved.
    public static var isAvailable: Bool {
        symbols != nil
    }

    /// A created legacy virtual display.
    public final class Handle {
        /// The display ID we requested in the descriptor. The WindowServer may
        /// assign a different ID — callers re-discover it via CGGetActiveDisplayList.
        public let displayID: CGDirectDisplayID
        private let ref: UnsafeMutableRawPointer
        private var destroyed = false

        fileprivate init?(ref: UnsafeMutableRawPointer?, displayID: CGDirectDisplayID) {
            guard let ref else { return nil }
            self.ref = ref
            self.displayID = displayID
        }

        /// Set the mode and apply settings (hiDPI on).
        func apply(mode: UnsafeMutableRawPointer, width: UInt32, height: UInt32, refreshRate: Double) -> Bool {
            guard let symbols = CGVirtualDisplayAPI.symbols else { return false }
            symbols.setDisplayMode(ref, mode)
            var settings = Settings(hiDPI: 1, width: width, height: height, refreshRate: refreshRate)
            symbols.applySettings(ref, &settings)
            return true
        }

        public func destroy() {
            guard !destroyed else { return }
            destroyed = true
            CGVirtualDisplayAPI.symbols?.destroy(ref)
        }

        deinit {
            destroy()
        }
    }

    /// Create a virtual display (macOS 13–15 path). The WindowServer assigns
    /// the real display ID; callers discover it by diffing the display list.
    public static func create(name: String, width: UInt32, height: UInt32, refreshRate: Double) -> Handle? {
        guard let symbols else {
            log.warning("create: VirtualDisplay.framework unavailable")
            return nil
        }

        let nameRef = name as CFString
        var descriptor = Descriptor(
            displayID: 0xF0F0 + UInt32(ProcessInfo.processInfo.processIdentifier % 0xFF),
            name: Unmanaged.passRetained(nameRef).toOpaque(),
            serialNum: 1,
            productID: 0x0001,
            vendorID: 0xFBD0,
            maxPixelsWide: width,
            maxPixelsHigh: height,
            sizeInMillimeters: CGSize(width: 200, height: 112),
            redPrimary: CGPoint(x: 0.680, y: 0.320),
            greenPrimary: CGPoint(x: 0.265, y: 0.690),
            bluePrimary: CGPoint(x: 0.150, y: 0.060),
            whitePoint: CGPoint(x: 0.3127, y: 0.3290)
        )
        defer {
            // The descriptor's name is ours to release after create.
            Unmanaged<CFString>.fromOpaque(descriptor.name).release()
        }

        guard let display = withUnsafeMutablePointer(to: &descriptor, { ptr in
            symbols.createWithDescriptor(ptr)
        }) else {
            log.warning("create: CGVirtualDisplayCreateWithDescriptor returned nil")
            return nil
        }
        guard let handle = Handle(ref: display, displayID: descriptor.displayID) else {
            symbols.destroy(display)
            return nil
        }

        // Mode object; released after SetDisplayMode (ReleaseMode or CFRelease).
        guard let mode = symbols.createMode(display, width, height, refreshRate) else {
            log.warning("create: CGVirtualDisplayCreateMode returned nil")
            handle.destroy()
            return nil
        }
        if !handle.apply(mode: mode, width: width, height: height, refreshRate: refreshRate) {
            handle.destroy()
            return nil
        }
        if let releaseMode = symbols.releaseMode {
            releaseMode(display, mode)
        } else {
            Unmanaged<CFTypeRef>.fromOpaque(mode).release()
        }
        log.info("legacy virtual display created (requested id \(handle.displayID), \(width)x\(height)@\(refreshRate))")
        return handle
    }
}
