import CoreFoundation
import CoreGraphics
import CPrivateAPI
import Foundation
import IOKit
import os

#if canImport(AppKit)
import AppKit
#endif

/// EDID export and override support.
///
/// Apple Silicon: the display's current EDID is read through the private
/// IOAVService API (`IOAVServiceCopyEDID`) and an override is installed as a
/// *virtual* EDID via `IOAVServiceSetVirtualEDIDMode` with
/// `{"IODisplayEDID": data}` — the OS then sees the display's capabilities
/// through the override. The virtual EDID is per-connection and reverts
/// naturally on reconnect/reboot.
///
/// Intel: only export is supported (public IOKit fallback). Overrides would
/// require chunked raw I2C EDID writes to address 0x50 over the IOAVService
/// bus (see betterdisplay-reverse-engineering.md); unsupported on this build
/// and documented as a future extension.
public final class EDIDController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "EDIDController")

    /// True when the AVService path is available (native Apple Silicon).
    public var isAvailable: Bool { IOAVServiceAPI.isAppleSilicon }

    /// True factory EDID per display identity, captured on the first export
    /// so a later restore can return to the true factory state even after an
    /// override was applied. Best-effort: if the first export happens while
    /// an override is already active, that override is captured instead.
    private var factoryEDIDs: [String: Data] = [:]
    private let factoryLock = NSLock()

    private var hasStarted = false
    private var terminationObserver: NSObjectProtocol?

    public init() {}

    // MARK: - Export

    /// Export the display's current EDID: AVService copy (preferred) or the
    /// public `IODisplayCreateInfoDictionary` `kIODisplayEDIDKey` fallback.
    public func exportEDID(for display: Display) -> Data? {
        let key = display.identityKey
        var edid: Data?
        if let service = IOAVServiceAPI.findAVService(
            displayID: display.id,
            vendor: display.vendorNumber,
            model: display.modelNumber,
            serial: display.serialNumber
        ) {
            defer { releaseAVService(service) }
            edid = IOAVServiceAPI.copyEDID(service)
        }
        if edid == nil {
            // CoreDisplay private info dictionary carries IODisplayEDID for
            // some displays (not the built-in panel on macOS 27).
            if let dict = CoreDisplay_DisplayCreateInfoDictionary(display.id)?.takeRetainedValue() as? [String: Any],
               let coreEDID = dict["IODisplayEDID"] as? Data {
                edid = coreEDID
            }
        }
        if edid == nil {
            edid = publicDisplayEDID(for: display)
        }
        guard let edid else {
            log.warning("exportEDID: no EDID available for display \(display.id)")
            return nil
        }
        // First export is assumed to be the factory state; remember it so
        // restoreFactory can return to it even after an override was applied.
        factoryLock.lock()
        if factoryEDIDs[key] == nil { factoryEDIDs[key] = edid }
        factoryLock.unlock()
        log.info("Exported \(edid.count)-byte EDID for display \(display.id)")
        return edid
    }

    /// Public-IOKit fallback: match an IODisplayConnect service by
    /// vendor/model/serial (like IOAVServiceAPI does) and read
    /// "IODisplayEDID" from its info dictionary.
    private func publicDisplayEDID(for display: Display) -> Data? {
        let services = IOKitSupport.matchingServices(IOServiceMatching("IODisplayConnect"))
        for service in services {
            let props = IOKitSupport.properties(of: service)
            if propsMatch(display, props),
               let dict = IODisplayCreateInfoDictionary(service, 0)?.takeRetainedValue() as? [String: Any],
               let edid = dict["IODisplayEDID"] as? Data {
                IOKitSupport.release(service)
                return edid
            }
            IOKitSupport.release(service)
        }
        return nil
    }

    private func propsMatch(_ display: Display, _ props: [String: Any]) -> Bool {
        let vendor = display.vendorNumber
        let model = display.modelNumber
        let serial = display.serialNumber
        let vendorOK = (props["vendorID"] as? UInt32) == vendor
            || (props["DisplayVendorID"] as? UInt32) == vendor
            || (props["IODisplayVendorID"] as? UInt32) == vendor
        let modelOK = (props["productID"] as? UInt32) == model
            || (props["DisplayProductID"] as? UInt32) == model
            || (props["IODisplayProductID"] as? UInt32) == model
        // Serial can be zero on some displays; fall back to vendor+model match.
        let serialOK = serial == 0
            || (props["serialNumber"] as? UInt32) == serial
            || (props["DisplaySerialNumber"] as? UInt32) == serial
            || (props["IODisplaySerialNumber"] as? UInt32) == serial
        return vendorOK && modelOK && serialOK
    }

    // MARK: - Override

    /// Apply a custom EDID (override). Apple Silicon: installs a virtual EDID
    /// via `IOAVServiceSetVirtualEDIDMode` with {"IODisplayEDID": data} and
    /// persists it per display identity. Intel: the chunked I2C EDID write
    /// implementation is a documented future extension — returns false with
    /// a log (best-effort; requires an IOAVService).
    @discardableResult
    public func applyOverride(_ edid: Data, for display: Display) -> Bool {
        guard isAvailable else {
            log.warning("Intel EDID write requires the IOAVService I2C bus — unsupported on this build")
            return false
        }
        guard setVirtualEDID(edid, for: display) else {
            log.error("applyOverride: failed to install virtual EDID for display \(display.id)")
            return false
        }
        Settings.setEDIDOverride(edid, for: display.identityKey)
        NotificationCenter.default.post(name: .fbdDisplayUpdated, object: nil, userInfo: ["displayID": display.id])
        log.info("Applied \(edid.count)-byte EDID override to display \(display.id)")
        return true
    }

    /// Restore the factory EDID. Prefers the in-memory factory capture, then
    /// the caller-provided original EDID, then (best-effort) the display's
    /// current EDID. The persisted override is cleared only when it matches
    /// the restored factory EDID; a distinct user override is left intact for
    /// future sessions (auto-apply on the next connect).
    @discardableResult
    public func restoreFactory(originalEDID: Data?, for display: Display) -> Bool {
        let key = display.identityKey
        var factory: Data?
        factoryLock.lock()
        factory = factoryEDIDs[key] ?? originalEDID
        factoryLock.unlock()
        if factory == nil {
            // Best-effort: no captured factory EDID — re-apply the display's
            // current EDID (which is the override if one was active).
            if let service = IOAVServiceAPI.findAVService(
                displayID: display.id,
                vendor: display.vendorNumber,
                model: display.modelNumber,
                serial: display.serialNumber
            ) {
                defer { releaseAVService(service) }
                factory = IOAVServiceAPI.copyEDID(service)
            }
        }
        guard let factory else {
            log.warning("restoreFactory: no factory EDID available for display \(display.id)")
            return false
        }
        guard isAvailable else {
            log.warning("Intel EDID write requires the IOAVService I2C bus — unsupported on this build")
            return false
        }
        guard setVirtualEDID(factory, for: display) else {
            log.error("restoreFactory: failed to restore EDID for display \(display.id)")
            return false
        }
        if let saved = Settings.edidOverride(for: key), saved == factory {
            Settings.setEDIDOverride(nil, for: key)
        }
        NotificationCenter.default.post(name: .fbdDisplayUpdated, object: nil, userInfo: ["displayID": display.id])
        log.info("Restored factory EDID for display \(display.id)")
        return true
    }

    /// Persist an override per display identity (Settings.setEDIDOverride).
    public func saveOverride(_ edid: Data?, for display: Display) {
        Settings.setEDIDOverride(edid, for: display.identityKey)
    }

    /// Load the persisted override for a display, if any.
    public func savedOverride(for display: Display) -> Data? {
        Settings.edidOverride(for: display.identityKey)
    }

    /// Called on display connect: when Settings.autoApplyEDIDOverride and an
    /// override is saved, apply it. Logs success/failure.
    public func autoApplyIfNeeded(for display: Display) {
        guard Settings.autoApplyEDIDOverride, let saved = savedOverride(for: display) else { return }
        if applyOverride(saved, for: display) {
            log.info("Auto-applied saved EDID override for display \(display.id)")
        } else {
            log.error("Failed to auto-apply saved EDID override for display \(display.id)")
        }
    }

    // MARK: - Lifecycle

    /// Register for app termination to restore the factory EDID when
    /// Settings.restoreFactoryEDIDOnQuit (via NotificationCenter
    /// NSApplication.willTerminateNotification — AppKit).
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        #if canImport(AppKit)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restoreFactoryOnQuit()
        }
        #endif
    }

    private func restoreFactoryOnQuit() {
        guard Settings.restoreFactoryEDIDOnQuit else { return }
        for display in currentDisplays() {
            guard savedOverride(for: display) != nil else { continue }
            var factory: Data?
            factoryLock.lock()
            factory = factoryEDIDs[display.identityKey]
            factoryLock.unlock()
            if restoreFactory(originalEDID: factory, for: display) {
                log.info("Restored factory EDID for display \(display.id) on quit")
            } else {
                log.error("Failed to restore factory EDID for display \(display.id) on quit")
            }
        }
    }

    /// Snapshot of active displays via the public CoreGraphics APIs, so this
    /// controller stays actor-free and does not depend on DisplayController.
    private func currentDisplays() -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard ids.withUnsafeMutableBufferPointer({
            CGGetActiveDisplayList(UInt32($0.count), $0.baseAddress, &count)
        }) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            Display(
                id: id,
                name: "Display \(id)",
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                vendorNumber: CGDisplayVendorNumber(id),
                modelNumber: CGDisplayModelNumber(id),
                serialNumber: CGDisplaySerialNumber(id),
                bounds: CGDisplayBounds(id),
                isOnline: true,
                isActive: true
            )
        }
    }

    // MARK: - Helpers

    private func setVirtualEDID(_ edid: Data, for display: Display) -> Bool {
        guard let service = IOAVServiceAPI.findAVService(
            displayID: display.id,
            vendor: display.vendorNumber,
            model: display.modelNumber,
            serial: display.serialNumber
        ) else {
            log.warning("No AVService available for display \(display.id)")
            return false
        }
        defer { releaseAVService(service) }
        let dict = ["IODisplayEDID": edid as NSData] as CFDictionary
        return IOAVServiceAPI.setVirtualEDIDMode(dict, service: service)
    }

    /// Release an IOAVServiceRef (CF type; mirrors ExternalController's
    /// AVServiceHandle deinit).
    private func releaseAVService(_ service: IOAVServiceRef) {
        Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(service)).release()
    }
}
