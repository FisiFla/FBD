import Foundation
import XCTest
@testable import FBDCore

/// The saved network-device registry: host validation, add/list/remove,
/// deduplication, the size bound and persistence. All pure — the registry never
/// talks to a device, which is what makes it testable.
final class NetworkDeviceRegistryTests: XCTestCase {
    private let suiteName = "test.fbd.networkdevices"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Host validation

    func testValidHostAcceptsHostnamesAndAddresses() {
        XCTAssertEqual(NetworkDeviceRegistry.validatedHost("living-room-tv.local"), "living-room-tv.local")
        XCTAssertEqual(NetworkDeviceRegistry.validatedHost("192.168.0.42"), "192.168.0.42")
        XCTAssertEqual(NetworkDeviceRegistry.validatedHost("  tv.lan  "), "tv.lan")
        XCTAssertEqual(NetworkDeviceRegistry.validatedHost("tv_1"), "tv_1")
    }

    /// The host is interpolated into a request URL by the controllers, so
    /// anything that could redirect the request is refused.
    func testValidHostRefusesSchemePathCredentialsAndQuery() {
        XCTAssertNil(NetworkDeviceRegistry.validatedHost("http://tv.lan"))
        XCTAssertNil(NetworkDeviceRegistry.validatedHost("tv.lan/api"))
        XCTAssertNil(NetworkDeviceRegistry.validatedHost("user@tv.lan"))
        XCTAssertNil(NetworkDeviceRegistry.validatedHost("tv.lan?x=1"))
        XCTAssertNil(NetworkDeviceRegistry.validatedHost("tv.lan#frag"))
        XCTAssertNil(NetworkDeviceRegistry.validatedHost("tv lan"))
        XCTAssertNil(NetworkDeviceRegistry.validatedHost("tv\\lan"))
    }

    func testValidHostRefusesEmptyAndMalformed() {
        XCTAssertNil(NetworkDeviceRegistry.validatedHost(""))
        XCTAssertNil(NetworkDeviceRegistry.validatedHost("   "))
        XCTAssertNil(NetworkDeviceRegistry.validatedHost(".tv.lan"))
        XCTAssertNil(NetworkDeviceRegistry.validatedHost("-tv.lan"))
        XCTAssertNil(NetworkDeviceRegistry.validatedHost("tv.lan."))
        XCTAssertNil(NetworkDeviceRegistry.validatedHost(String(repeating: "a", count: 254)))
    }

    /// A port belongs to the caller's parameter, not the host, so a `:port`
    /// suffix is refused rather than silently producing a malformed URL.
    func testValidHostRefusesPortSuffix() {
        XCTAssertNil(NetworkDeviceRegistry.validatedHost("tv.lan:3000"))
        XCTAssertNil(NetworkDeviceRegistry.validatedHost("192.168.0.42:8080"))
        XCTAssertNil(NetworkDeviceRegistry.validatedHost("[fe80::1]:3000"))
    }

    /// A bare IPv6 literal contains colons but is not a port suffix.
    func testValidHostAcceptsIPv6Literal() {
        XCTAssertEqual(NetworkDeviceRegistry.validatedHost("fe80::1"), "fe80::1")
        XCTAssertEqual(NetworkDeviceRegistry.validatedHost("[fe80::1]"), "[fe80::1]")
    }

    // MARK: - Add

    func testAddStoresADevice() {
        let result = NetworkDeviceRegistry.add(
            name: "Living room TV", brand: .lg, host: "tv.lan", defaults: defaults
        )
        guard case .success(let device) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(device.name, "Living room TV")
        XCTAssertEqual(device.brand, .lg)
        XCTAssertEqual(device.host, "tv.lan")
        XCTAssertEqual(device.id, "living-room-tv")
        XCTAssertNil(device.zone)
        XCTAssertEqual(NetworkDeviceRegistry.list(defaults: defaults).count, 1)
    }

    func testAddKeepsAZone() {
        let result = NetworkDeviceRegistry.add(
            name: "Amp", brand: .yamaha, host: "amp.lan", zone: "2", defaults: defaults
        )
        guard case .success(let device) = result else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(device.zone, "2")
    }

    func testAddTreatsBlankZoneAsAbsent() {
        let result = NetworkDeviceRegistry.add(
            name: "Amp", brand: .yamaha, host: "amp.lan", zone: "   ", defaults: defaults
        )
        guard case .success(let device) = result else {
            return XCTFail("expected success")
        }
        XCTAssertNil(device.zone, "a blank zone must not be stored as a zone")
    }

    func testAddRefusesEmptyName() {
        XCTAssertEqual(
            NetworkDeviceRegistry.add(name: "  ", brand: .lg, host: "tv.lan", defaults: defaults),
            .failure(.emptyName)
        )
    }

    func testAddRefusesInvalidHost() {
        XCTAssertEqual(
            NetworkDeviceRegistry.add(name: "TV", brand: .lg, host: "http://tv.lan", defaults: defaults),
            .failure(.invalidHost("http://tv.lan"))
        )
        XCTAssertTrue(NetworkDeviceRegistry.list(defaults: defaults).isEmpty, "a refused add must store nothing")
    }

    func testAddRefusesDuplicateNameCaseInsensitively() {
        _ = NetworkDeviceRegistry.add(name: "TV", brand: .lg, host: "tv.lan", defaults: defaults)
        XCTAssertEqual(
            NetworkDeviceRegistry.add(name: "tv", brand: .samsung, host: "other.lan", defaults: defaults),
            .failure(.duplicateName("tv"))
        )
        XCTAssertEqual(NetworkDeviceRegistry.list(defaults: defaults).count, 1)
    }

    func testAddRefusesBeyondTheLimit() {
        for index in 0..<NetworkDeviceRegistry.limit {
            let result = NetworkDeviceRegistry.add(
                name: "device-\(index)", brand: .lg, host: "host-\(index).lan", defaults: defaults
            )
            guard case .success = result else { return XCTFail("add \(index) failed") }
        }
        XCTAssertEqual(
            NetworkDeviceRegistry.add(name: "too-many", brand: .lg, host: "x.lan", defaults: defaults),
            .failure(.tooMany(NetworkDeviceRegistry.limit))
        )
    }

    // MARK: - Lookup and list

    func testLookupIsCaseInsensitive() {
        _ = NetworkDeviceRegistry.add(name: "Living Room", brand: .lg, host: "tv.lan", defaults: defaults)
        XCTAssertNotNil(NetworkDeviceRegistry.device(named: "living room", defaults: defaults))
        XCTAssertNotNil(NetworkDeviceRegistry.device(named: "  LIVING ROOM ", defaults: defaults))
        XCTAssertNil(NetworkDeviceRegistry.device(named: "kitchen", defaults: defaults))
    }

    func testListIsSortedByName() {
        _ = NetworkDeviceRegistry.add(name: "Zeta", brand: .lg, host: "z.lan", defaults: defaults)
        _ = NetworkDeviceRegistry.add(name: "alpha", brand: .lg, host: "a.lan", defaults: defaults)
        _ = NetworkDeviceRegistry.add(name: "Beta", brand: .lg, host: "b.lan", defaults: defaults)
        XCTAssertEqual(NetworkDeviceRegistry.list(defaults: defaults).map(\.name), ["alpha", "Beta", "Zeta"])
    }

    // MARK: - Remove

    func testRemoveByName() {
        _ = NetworkDeviceRegistry.add(name: "TV", brand: .lg, host: "tv.lan", defaults: defaults)
        XCTAssertTrue(NetworkDeviceRegistry.remove(named: "tv", defaults: defaults))
        XCTAssertTrue(NetworkDeviceRegistry.list(defaults: defaults).isEmpty)
    }

    func testRemoveUnknownReportsFalse() {
        XCTAssertFalse(NetworkDeviceRegistry.remove(named: "nope", defaults: defaults))
    }

    // MARK: - Persistence

    func testPersistsThroughTheInjectedSuiteOnly() {
        _ = NetworkDeviceRegistry.add(name: "TV", brand: .lg, host: "tv.lan", defaults: defaults)
        XCTAssertNotNil(defaults.data(forKey: Settings.networkDevicesKey))
        XCTAssertNil(
            UserDefaults.standard.data(forKey: Settings.networkDevicesKey),
            "must not write to UserDefaults.standard"
        )
    }

    func testListIsEmptyWithNoStoredBlob() {
        XCTAssertTrue(NetworkDeviceRegistry.list(defaults: defaults).isEmpty)
    }

    func testListSurvivesCorruptData() {
        defaults.set(Data("not-json".utf8), forKey: Settings.networkDevicesKey)
        XCTAssertTrue(
            NetworkDeviceRegistry.list(defaults: defaults).isEmpty,
            "a corrupt blob must degrade to an empty list, not crash"
        )
    }

    func testIdentifierIsStableAndSlugged() {
        XCTAssertEqual(NetworkDeviceRegistry.identifier(for: "Living room TV"), "living-room-tv")
        XCTAssertEqual(NetworkDeviceRegistry.identifier(for: "  Amp 2  "), "amp-2")
        XCTAssertEqual(NetworkDeviceRegistry.identifier(for: "TV!!"), "tv")
        XCTAssertEqual(NetworkDeviceRegistry.identifier(for: "!!!"), "device")
    }
}
