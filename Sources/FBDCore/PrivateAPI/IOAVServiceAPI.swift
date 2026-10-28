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
        guard let service = findDPService(displayID: displayID, vendor: vendor, model: model, serial: serial) else {
            return nil
        }
        defer { IOKitSupport.release(service) }
        guard let avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service) else {
            log.debug("IOAVServiceCreateWithService failed for \(displayID)")
            return nil
        }
        return avService
    }

    /// The `DCPAVServiceProxy` / `IOAVService` node for a display, or nil. A **+1 ref the caller
    /// owns** — release with `IOKitSupport.release`.
    ///
    /// This is the IOService `findAVService` wraps in an IOAVService, and also the one
    /// `IODPDeviceCreateWithService` wants for the DPCD read path, so it is exposed rather than
    /// buried inside `findAVService` and duplicated.
    public static func findDPService(
        displayID: CGDirectDisplayID,
        vendor: UInt32,
        model: UInt32,
        serial: UInt32
    ) -> io_service_t? {
        guard isAppleSilicon else { return nil }

        // On Apple Silicon an external display's DCPAVServiceProxy is not a child of its
        // AppleCLCD2: the framebuffer sits under `dispextN` and the proxy under the following
        // `dcpextN` sibling. Walk the service plane in order and pair the two (as MonitorControl
        // and m1ddc do). Older layouts put the AVService under the display node, so fall back.
        if let proxy = pairedExternalProxy(vendor: vendor, model: model, serial: serial) {
            return proxy // +1 ref transfers to the caller
        }
        guard let displayService = displayService(vendor: vendor, model: model, serial: serial) else {
            log.debug("No display service found for \(displayID)")
            return nil
        }
        defer { IOKitSupport.release(displayService) }
        guard let proxy = IOKitSupport.firstChild(named: "DCPAVServiceProxy", of: displayService)
            ?? IOKitSupport.firstChild(named: "IOAVService", of: displayService) else {
            log.debug("No DCPAVServiceProxy/IOAVService for \(displayID)")
            return nil
        }
        return proxy // +1 ref transfers to the caller
    }

    /// One node of an in-order IOService-plane walk, reduced to what pairing needs.
    struct RegistryNode {
        let className: String
        let props: [String: Any]
    }

    static let framebufferClasses: Set<String> = ["AppleCLCD2", "IOMobileFramebufferShim"]

    /// Index of the `DCPAVServiceProxy` belonging to the display: the first External proxy
    /// after a matching framebuffer and before the next framebuffer.
    static func proxyIndex(in nodes: [RegistryNode], vendor: UInt32, model: UInt32, serial: UInt32) -> Int? {
        var framebufferMatched = false
        for (index, node) in nodes.enumerated() {
            if framebufferClasses.contains(node.className) {
                framebufferMatched = framebufferMatches(node.props, vendor: vendor, model: model, serial: serial)
            } else if node.className == "DCPAVServiceProxy", framebufferMatched,
                      (node.props["Location"] as? String) == "External" {
                return index
            }
        }
        return nil
    }

    /// The paired external proxy, as a +1 ref the caller owns.
    private static func pairedExternalProxy(vendor: UInt32, model: UInt32, serial: UInt32) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var nodes: [RegistryNode] = []
        var services: [io_service_t] = []
        defer { services.forEach(IOKitSupport.release) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            var buffer = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &buffer)
            let className = String(cString: buffer)
            guard framebufferClasses.contains(className) || className == "DCPAVServiceProxy" else {
                IOKitSupport.release(entry)
                continue
            }
            nodes.append(RegistryNode(className: className, props: IOKitSupport.properties(of: entry)))
            services.append(entry)
        }
        guard let index = proxyIndex(in: nodes, vendor: vendor, model: model, serial: serial) else { return nil }
        IOObjectRetain(services[index])
        return services[index]
    }

    /// The IORegistry node for a display, matched by vendor/model/serial of its
    /// AppleCLCD2 / IODisplayConnect / IOMobileFramebufferShim node properties.
    /// Returns a +1 ref owned by the caller — release with `IOKitSupport.release`.
    private static func displayService(vendor: UInt32, model: UInt32, serial: UInt32) -> io_service_t? {
        let candidates = ["AppleCLCD2", "IODisplayConnect", "IOMobileFramebufferShim"]
        for className in candidates {
            let services = IOKitSupport.matchingServices(IOServiceMatching(className))
            var match: io_service_t?
            for service in services {
                // Release every non-matching node, and the rest of the iterator after a hit.
                if match == nil,
                   framebufferMatches(IOKitSupport.properties(of: service), vendor: vendor, model: model, serial: serial) {
                    match = service // +1 ref transfers to the caller
                } else {
                    IOKitSupport.release(service)
                }
            }
            if let match { return match }
        }
        return nil
    }

    /// The IORegistry node for the display itself — the `AppleCLCD2` / `IODisplayConnect` /
    /// `IOMobileFramebufferShim` node that `findDPService` walks *from*. A **+1 ref the caller owns**.
    ///
    /// Exposed because `IODPDeviceCreateWithService` accepts a display's own IOService as well as the
    /// AVService child, and a built-in panel has no `DCPAVServiceProxy` to walk to — measured: the
    /// DPCD read found no service until this was tried.
    public static func findDisplayService(
        displayID: CGDirectDisplayID,
        vendor: UInt32,
        model: UInt32,
        serial: UInt32
    ) -> io_service_t? {
        guard isAppleSilicon else { return nil }
        guard let service = displayService(vendor: vendor, model: model, serial: serial) else {
            log.debug("No display service for \(displayID)")
            return nil
        }
        return service // +1 ref transfers to the caller
    }

    static func framebufferMatches(_ props: [String: Any], vendor: UInt32, model: UInt32, serial: UInt32) -> Bool {
        // Apple Silicon framebuffers expose identity only through their EDID UUID.
        if let uuid = props["EDID UUID"] as? String, edidUUID(uuid, matchesVendor: vendor, model: model) {
            return true
        }
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

    /// An `EDID UUID` begins with the EDID manufacturer ID (big-endian, as CG reports it)
    /// followed by the product code (little-endian, as stored in the EDID).
    static func edidUUID(_ uuid: String, matchesVendor vendor: UInt32, model: UInt32) -> Bool {
        let hex = uuid.replacingOccurrences(of: "-", with: "").uppercased()
        guard hex.count >= 8 else { return false }
        let expected = String(format: "%04X%02X%02X", vendor & 0xFFFF, model & 0xFF, (model >> 8) & 0xFF)
        return hex.hasPrefix(expected)
    }

    /// Read raw bytes from an I2C chip address (e.g. 0x37 DDC, 0x50 EDID); `offset` is the
    /// data address sent first (0x51 for DDC/CI, per m1ddc).
    public static func readI2C(_ service: IOAVServiceRef, address: UInt8, offset: UInt8 = 0, length: Int) -> Data? {
        guard length > 0, length <= 256 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let status = buffer.withUnsafeMutableBytes { raw -> kern_return_t in
            IOAVServiceReadI2C(service, UInt32(address), UInt32(offset), raw.baseAddress, UInt32(length))
        }
        guard status == KERN_SUCCESS else {
            log.debug("IOAVServiceReadI2C failed: \(status)")
            return nil
        }
        return Data(buffer)
    }

    /// Write raw bytes to an I2C chip address (e.g. 0x37 DDC); `dataAddress` is sent first
    /// (0x51 for DDC/CI, per m1ddc).
    @discardableResult
    public static func writeI2C(_ service: IOAVServiceRef, address: UInt8, dataAddress: UInt8 = 0, data: Data) -> Bool {
        let count = data.count
        var bytes = [UInt8](data)
        let status = bytes.withUnsafeMutableBytes { raw -> kern_return_t in
            IOAVServiceWriteI2C(service, UInt32(address), UInt32(dataAddress), raw.baseAddress, UInt32(count))
        }
        if status != KERN_SUCCESS {
            log.debug("IOAVServiceWriteI2C failed: \(status)")
        }
        return status == KERN_SUCCESS
    }

    /// Current EDID of the display as raw bytes.
    public static func copyEDID(_ service: IOAVServiceRef) -> Data? {
        var edid: Unmanaged<CFData>?
        let status = IOAVServiceCopyEDID(service, &edid)
        guard status == KERN_SUCCESS, let data = edid?.takeRetainedValue() else {
            log.debug("IOAVServiceCopyEDID failed: \(status)")
            return nil
        }
        return data as Data
    }

    /// Install a virtual EDID on the display. Disabled: `IOAVServiceSetVirtualEDIDMode` takes a
    /// mode whose values are undocumented and unmeasured, and a wrong guess can blank the
    /// display. Fails closed until a mode is measured on hardware — reading a monitor's
    /// EDID is verified (2026-10-28), installing a virtual one is not.
    public static func setVirtualEDID(_ edid: Data, service: IOAVServiceRef) -> Bool {
        log.error("Virtual EDID install is disabled: IOAVServiceSetVirtualEDIDMode mode values are unverified")
        return false
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
