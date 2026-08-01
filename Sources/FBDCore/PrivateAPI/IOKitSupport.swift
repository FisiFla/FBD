import Foundation
import IOKit

/// Thin typed helpers over the public IOKit registry APIs used to locate
/// display services (and, on Apple Silicon, the AVService for DDC/EDID).
public enum IOKitSupport {
    /// Iterate all services matching an IOServiceMatching dictionary.
    /// Each returned service is a +1 ref owned by the caller — release with
    /// `IOObjectRelease` (see `release`).
    public static func matchingServices(_ matching: CFDictionary) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            result.append(service)
        }
        return result
    }

    /// Release a +1 io_service_t ref obtained from IOIteratorNext /
    /// IOServiceGetMatchingService.
    public static func release(_ service: io_service_t) {
        if service != 0 {
            IOObjectRelease(service)
        }
    }

    /// All IORegistry property keys + values of a service as a Swift dictionary.
    public static func properties(of service: io_service_t) -> [String: Any] {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return [:]
        }
        return dict
    }

    /// Recursively search the IORegistry children of `service` for a child whose
    /// IORegistryEntryGetName matches `name` (e.g. "DCPAVServiceProxy", "IOAVService").
    /// Returns a +1 ref owned by the caller — release with `IOKitSupport.release`.
    public static func firstChild(named name: String, of service: io_service_t, depth: Int = 0) -> io_service_t? {
        guard depth < 16 else { return nil }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane, 0, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            var buffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(child, &buffer)
            let childName = String(cString: buffer)
            if childName == name {
                return child
            }
            if let found = firstChild(named: name, of: child, depth: depth + 1) {
                // Release the intermediate child we kept a +1 ref on during the walk.
                if found != child {
                    release(child)
                }
                return found
            }
            release(child)
        }
        return nil
    }

    /// IORegistry entry name of a service.
    public static func name(of service: io_service_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(service, &buffer)
        return String(cString: buffer)
    }
}
