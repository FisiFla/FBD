import CoreFoundation
import CoreGraphics
import CPrivateAPI
import Foundation
import IOKit
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "IOAVServiceAPI")

/// Typed wrappers over the private IOKit IOAVService APIs (DDC/EDID over I2C,
/// Apple Silicon only). This is the same transport BetterDisplay and lunar use
/// for external displays. No-op (returns nil / throws) on Intel and under Rosetta.
public enum IOAVServiceAPI {
    /// Find the AVService for a display by walking the IORegistry from the
    /// display's IODisplayPrefsKey-matched node down to a DCPAVServiceProxy /
    /// IOAVService child.
    ///
    /// - Parameters:
    ///   - displayID: CG display ID (used for logging only).
    ///   - vendor/model/serial: display identity used to match the registry node.
    public static func findAVService(displayID: CGDirectDisplayID, vendor: UInt32, model: UInt32, serial: UInt32) -> IOAVServiceRef? {
        guard isAppleSilicon else { return nil }

        guard let displayService = displayService(vendor: vendor, model: model, serial: serial) else {
            log.debug("No display service found for \(displayID)")
            return nil
        }
        defer { IOKitSupport.release(displayService) }
        // On Apple Silicon the AVService lives under DCPAVServiceProxy (or directly as IOAVService).
        guard let proxy = IOKitSupport.firstChild(named: "DCPAVServiceProxy", of: displayService)
            ?? IOKitSupport.firstChild(named: "IOAVService", of: displayService) else {
            log.debug("No DCPAVServiceProxy/IOAVService under display service for \(displayID)")
            return nil
        }
        defer { IOKitSupport.release(proxy) }
        guard let service = IOAVServiceCreateWithService(proxy) else {
            log.debug("IOAVServiceCreateWithService failed for \(displayID)")
            return nil
        }
        return service
    }

    /// The IORegistry node for a display, matched by vendor/model/serial of its
    /// AppleCLCD2 / IODisplayConnect / IOMobileFramebufferShim node properties.
    /// Returns a +1 ref owned by the caller — release with `IOKitSupport.release`.
    private static func displayService(vendor: UInt32, model: UInt32, serial: UInt32) -> io_service_t? {
        let candidates = ["AppleCLCD2", "IODisplayConnect", "IOMobileFramebufferShim"]
        for className in candidates {
            let services = IOKitSupport.matchingServices(IOServiceMatching(className))
            for service in services {
                let props = IOKitSupport.properties(of: service)
                if propsMatchDisplay(props, vendor: vendor, model: model, serial: serial) {
                    return service // +1 ref transfers to the caller
                }
                IOKitSupport.release(service)
            }
        }
        return nil
    }

    private static func propsMatchDisplay(_ props: [String: Any], vendor: UInt32, model: UInt32, serial: UInt32) -> Bool {
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

    /// Read raw bytes from an I2C address (e.g. 0x37 DDC, 0x50 EDID).
    public static func readI2C(_ service: IOAVServiceRef, address: UInt8, length: Int) -> Data? {
        guard length > 0, length <= 256 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let status = buffer.withUnsafeMutableBytes { raw -> kern_return_t in
            IOAVServiceReadI2C(service, UInt32(address), raw.bindMemory(to: UInt8.self).baseAddress, UInt32(length))
        }
        guard status == KERN_SUCCESS else {
            log.debug("IOAVServiceReadI2C failed: \(status)")
            return nil
        }
        return Data(buffer)
    }

    /// Write raw bytes to an I2C address (e.g. 0x37 DDC).
    @discardableResult
    public static func writeI2C(_ service: IOAVServiceRef, address: UInt8, data: Data) -> Bool {
        let count = data.count
        var bytes = [UInt8](data)
        let status = bytes.withUnsafeMutableBytes { raw -> kern_return_t in
            IOAVServiceWriteI2C(service, UInt32(address), raw.bindMemory(to: UInt8.self).baseAddress, UInt32(count))
        }
        if status != KERN_SUCCESS {
            log.debug("IOAVServiceWriteI2C failed: \(status)")
        }
        return status == KERN_SUCCESS
    }

    /// Current EDID of the display as a raw data blob (flattened DisplayIODictionary).
    public static func copyEDID(_ service: IOAVServiceRef) -> Data? {
        guard let dict = IOAVServiceCopyEDID(service)?.takeRetainedValue() else { return nil }
        // EDID bytes live under the "IODisplayEDID" key (CFData) in the returned dictionary.
        if let edidData = (dict as? [String: Any])?["IODisplayEDID"] as? Data {
            return edidData
        }
        return nil
    }

    /// Install a virtual EDID on the display (Apple Silicon; the OS then sees
    /// the display's capabilities through this EDID). Pass the original EDID
    /// dictionary to restore factory behavior.
    @discardableResult
    public static func setVirtualEDIDMode(_ edid: CFDictionary, service: IOAVServiceRef) -> Bool {
        let status = IOAVServiceSetVirtualEDIDMode(service, edid)
        if status != KERN_SUCCESS {
            log.debug("IOAVServiceSetVirtualEDIDMode failed: \(status)")
        }
        return status == KERN_SUCCESS
    }

    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return ProcessInfo.processInfo.isAppleSilicon && !ProcessInfo.processInfo.isRosettaTranslated
        #else
        return false
        #endif
    }

    /// True when the current process runs under Rosetta 2 (DDC is unavailable then).
    public static var isRunningUnderRosetta: Bool {
        #if arch(arm64)
        return ProcessInfo.processInfo.isRosettaTranslated
        #else
        return false
        #endif
    }
}

extension ProcessInfo {
    /// sysctl.proc_translated == 1 means we run under Rosetta 2.
    var isRosettaTranslated: Bool {
        var ret = Int32(0)
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("sysctl.proc_translated", &ret, &size, nil, 0)
        return result == 0 && ret == 1
    }

    var isAppleSilicon: Bool {
        var ret = UInt32(0)
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("hw.optional.arm64", &ret, &size, nil, 0) == 0 else { return false }
        return ret == 1
    }
}
