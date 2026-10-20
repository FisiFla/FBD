import Foundation
import IOKit

/// Asks the display stack to re-read the display overrides.
///
/// `IOServiceRequestProbe` and `IODisplayCreateInfoDictionary` are **public**
/// IOKit API — they are declared in the SDK's `IOKitLib.h` and
/// `graphics/IOGraphicsLib.h` — so the HiDPI re-enumeration needs no private
/// shim and no runtime symbol lookup. They are wrapped here anyway, so the
/// rest of the code does not deal with IOKit iterators.
public enum IOServiceProbeAPI {
    /// Ask the display matching a vendor and product to re-read its
    /// configuration.
    ///
    /// - Returns: whether the probe was delivered.
    @discardableResult
    public static func requestProbe(vendor: UInt32, product: UInt32) -> Bool {
        guard let matching = IOServiceMatching("IODisplayConnect") else { return false }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard matches(service: service, vendor: vendor, product: product) else { continue }
            return IOServiceRequestProbe(service, 0) == kIOReturnSuccess
        }
        return false
    }

    /// Whether a display service is the one with this vendor and product.
    private static func matches(service: io_service_t, vendor: UInt32, product: UInt32) -> Bool {
        guard let info = IODisplayCreateInfoDictionary(service, UInt32(kIODisplayOnlyPreferredName))?
            .takeRetainedValue() else { return false }
        let dictionary = info as NSDictionary
        guard let vendorNumber = dictionary["DisplayVendorID"] as? NSNumber,
              let productNumber = dictionary["DisplayProductID"] as? NSNumber else { return false }
        return vendorNumber.uint32Value == vendor && productNumber.uint32Value == product
    }
}
