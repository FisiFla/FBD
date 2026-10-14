import XCTest
@testable import FBDCore

/// Attaching a saved network device to a display (gap-matrix row #17).
///
/// The registry and the volume mapping are pure, so the whole routing decision is
/// assertable without a device, a network or a display.
final class NetworkDeviceAttachmentTests: XCTestCase {
    private let suiteName = "test.fbd.networkattachments"
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

    /// Save a device so there is something legitimate to attach.
    @discardableResult
    private func saveDevice(_ name: String, brand: NetworkDevice.Brand = .yamaha) -> Bool {
        if case .success = NetworkDeviceRegistry.add(
            name: name, brand: brand, host: "device.lan", defaults: defaults
        ) {
            return true
        }
        return false
    }

    // MARK: - Attaching

    /// An attachment to a device that does not exist is a reference the user cannot
    /// see, so it is refused rather than stored.
    func testAttachRefusesADeviceThatIsNotSaved() {
        XCTAssertFalse(
            NetworkDeviceAttachment.attach(deviceNamed: "Ghost", toDisplay: "1-2-3", defaults: defaults)
        )
        XCTAssertTrue(NetworkDeviceAttachment.attachments(defaults: defaults).isEmpty)
    }

    func testAttachRefusesAnEmptyDisplayIdentity() {
        saveDevice("Amp")
        XCTAssertFalse(
            NetworkDeviceAttachment.attach(deviceNamed: "Amp", toDisplay: "", defaults: defaults),
            "an empty identity is 'any display' everywhere else in FBD — it must not become an attachment key"
        )
    }

    func testAttachAndDetachRoundTripThroughTheInjectedSuite() {
        saveDevice("Amp")
        XCTAssertTrue(
            NetworkDeviceAttachment.attach(deviceNamed: "Amp", toDisplay: "1552-41040-1", defaults: defaults)
        )
        XCTAssertEqual(
            NetworkDeviceAttachment.attachments(defaults: defaults),
            ["1552-41040-1": "Amp"]
        )
        XCTAssertNotNil(defaults.data(forKey: Settings.networkDeviceAttachmentsKey))
        XCTAssertNil(
            UserDefaults.standard.data(forKey: Settings.networkDeviceAttachmentsKey),
            "must not write to UserDefaults.standard"
        )

        XCTAssertTrue(NetworkDeviceAttachment.detach(displayIdentityKey: "1552-41040-1", defaults: defaults))
        XCTAssertTrue(NetworkDeviceAttachment.attachments(defaults: defaults).isEmpty)
    }

    func testDetachReportsWhetherAnythingWasAttached() {
        saveDevice("Amp")
        XCTAssertFalse(
            NetworkDeviceAttachment.detach(displayIdentityKey: "nothing-here", defaults: defaults)
        )
    }

    /// One device per display: re-attaching replaces rather than accumulating, so
    /// there is never a question of which device a volume change goes to.
    func testReattachingReplacesTheEarlierDevice() {
        saveDevice("Amp")
        saveDevice("TV")
        _ = NetworkDeviceAttachment.attach(deviceNamed: "Amp", toDisplay: "1-2-3", defaults: defaults)
        _ = NetworkDeviceAttachment.attach(deviceNamed: "TV", toDisplay: "1-2-3", defaults: defaults)
        XCTAssertEqual(NetworkDeviceAttachment.attachments(defaults: defaults).count, 1)
        XCTAssertEqual(
            NetworkDeviceAttachment.device(forDisplay: "1-2-3", defaults: defaults)?.name,
            "TV"
        )
    }

    // MARK: - Routing by specifier

    func testTheAttachedDeviceResolvesForItsDisplayOnly() {
        saveDevice("Amp")
        _ = NetworkDeviceAttachment.attach(deviceNamed: "Amp", toDisplay: "1-2-3", defaults: defaults)

        let resolved = NetworkDeviceAttachment.device(forDisplay: "1-2-3", defaults: defaults)
        XCTAssertEqual(resolved?.name, "Amp")
        XCTAssertEqual(resolved?.brand, .yamaha)
        XCTAssertEqual(resolved?.host, "device.lan")
        XCTAssertNil(
            NetworkDeviceAttachment.device(forDisplay: "9-9-9", defaults: defaults),
            "a display with no attachment must resolve to nothing, not to someone else's device"
        )
    }

    /// Deleting a device must not leave a half-built one behind — and the name is
    /// still reported, because silence would read as a bug.
    func testRemovingTheDeviceLeavesAReportedDanglingName() {
        saveDevice("Amp")
        _ = NetworkDeviceAttachment.attach(deviceNamed: "Amp", toDisplay: "1-2-3", defaults: defaults)
        XCTAssertTrue(NetworkDeviceAttachment.danglingNames(defaults: defaults).isEmpty)

        XCTAssertTrue(NetworkDeviceRegistry.remove(named: "Amp", defaults: defaults))
        XCTAssertNil(NetworkDeviceAttachment.device(forDisplay: "1-2-3", defaults: defaults))
        XCTAssertEqual(NetworkDeviceAttachment.danglingNames(defaults: defaults), ["Amp"])
    }

    func testNoAttachmentsByDefaultAndCorruptDataDegrades() {
        XCTAssertTrue(NetworkDeviceAttachment.attachments(defaults: defaults).isEmpty)
        XCTAssertTrue(NetworkDeviceAttachment.danglingNames(defaults: defaults).isEmpty)

        defaults.set(Data("not-json".utf8), forKey: Settings.networkDeviceAttachmentsKey)
        XCTAssertTrue(
            NetworkDeviceAttachment.attachments(defaults: defaults).isEmpty,
            "a corrupt blob must degrade to no attachments, not crash"
        )
    }

    // MARK: - Volume mapping

    func testVolumePercentMapsAndClamps() {
        XCTAssertEqual(NetworkDeviceVolume.percent(fromDisplayVolume: 0), 0)
        XCTAssertEqual(NetworkDeviceVolume.percent(fromDisplayVolume: 0.5), 50)
        XCTAssertEqual(NetworkDeviceVolume.percent(fromDisplayVolume: 1), 100)
        // Devices take 0…100, so a caller cannot hand them something they refuse.
        XCTAssertEqual(NetworkDeviceVolume.percent(fromDisplayVolume: 1.4), 100)
        XCTAssertEqual(NetworkDeviceVolume.percent(fromDisplayVolume: -0.2), 0)
        // Rounded, not truncated: 46.6% is nearer 47 than 46.
        XCTAssertEqual(NetworkDeviceVolume.percent(fromDisplayVolume: 0.466), 47)
    }
}
