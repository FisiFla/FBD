import XCTest
@testable import FBDCore

/// Row #28, the transfer half. Per-display state lives in two shapes — key
/// prefixes, and one shared blob with identity keys inside it — so both are
/// covered here. The defaults are an injected suite, so nothing touches the real
/// plist.
final class DisplaySettingsTransferTests: XCTestCase {
    private let suiteName = "test.fbd.transfer"
    private var defaults: UserDefaults!
    private let source = "1552-41040-1"
    private let destination = "1552-41040-2"

    /// Every family the app writes, spelled out. If a new per-display family is
    /// added without joining the transfer, this fails rather than half-migrating.
    private let expectedFamilies: Set<String> = [
        "edidOverride", "cornerRadius", "ddcFeatures",
        "configProtection.v1", "configProtection.properties", "modeFavourites",
    ]

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

    @discardableResult
    private func saveDevice(_ name: String, brand: NetworkDevice.Brand = .yamaha) -> Bool {
        if case .success = NetworkDeviceRegistry.add(
            name: name, brand: brand, host: "device.lan", defaults: defaults
        ) {
            return true
        }
        return false
    }

    private func storeOneOfEveryFamily(_ identity: String, marker: Int) {
        defaults.set(Data([UInt8(marker)]), forKey: "edidOverride.\(identity)")
        defaults.set(Double(marker) + 0.5, forKey: "cornerRadius.\(identity)")
        defaults.set([marker], forKey: "ddcFeatures.\(identity)")
        defaults.set(marker, forKey: "configProtection.properties.\(identity)")
        defaults.set(Data([UInt8(marker)]), forKey: "configProtection.v1.\(identity)")
        defaults.set(Data([UInt8(marker)]), forKey: "modeFavourites.\(identity)")
    }

    // MARK: - The plan

    func testKeyMovesCoverEveryKnownFamily() {
        let families = Set(DisplaySettingsTransfer.keyMoves(from: source, to: destination).map { $0.family })
        XCTAssertEqual(families, expectedFamilies)
    }

    func testKeyMovesPairTheSourceAndDestinationKeys() {
        for move in DisplaySettingsTransfer.keyMoves(from: source, to: destination) {
            XCTAssertEqual(move.source, "\(move.family).\(source)")
            XCTAssertEqual(move.destination, "\(move.family).\(destination)")
        }
    }

    // MARK: - Applying

    func testApplyCopiesEveryFamilyTheSourceHas() {
        storeOneOfEveryFamily(source, marker: 1)

        let outcome = DisplaySettingsTransfer.apply(from: source, to: destination, in: defaults)

        XCTAssertEqual(Set(outcome.moved), expectedFamilies)
        XCTAssertEqual(defaults.data(forKey: "edidOverride.\(destination)"), Data([1]))
        XCTAssertEqual(defaults.double(forKey: "cornerRadius.\(destination)"), 1.5)
        XCTAssertEqual(defaults.array(forKey: "ddcFeatures.\(destination)") as? [Int], [1])
        XCTAssertEqual(defaults.integer(forKey: "configProtection.properties.\(destination)"), 1)
        XCTAssertEqual(defaults.data(forKey: "configProtection.v1.\(destination)"), Data([1]))
        XCTAssertEqual(defaults.data(forKey: "modeFavourites.\(destination)"), Data([1]))
    }

    /// Nothing is deleted from the source, which is what makes the move
    /// reversible: the source keeps working until it is explicitly cleared.
    func testApplyLeavesTheSourceInPlace() {
        storeOneOfEveryFamily(source, marker: 3)
        DisplaySettingsTransfer.apply(from: source, to: destination, in: defaults)
        XCTAssertEqual(defaults.data(forKey: "edidOverride.\(source)"), Data([3]))
    }

    func testApplyRefusesToClobberTheDestinationByDefault() {
        storeOneOfEveryFamily(source, marker: 1)
        defaults.set(Data([2]), forKey: "edidOverride.\(destination)")

        let outcome = DisplaySettingsTransfer.apply(from: source, to: destination, in: defaults)

        XCTAssertFalse(outcome.moved.contains("edidOverride"))
        XCTAssertTrue(outcome.kept.contains("edidOverride"))
        XCTAssertEqual(
            defaults.data(forKey: "edidOverride.\(destination)"), Data([2]),
            "the destination's own settings were overwritten without --overwrite"
        )
        // The families the destination did not have still moved.
        XCTAssertEqual(defaults.double(forKey: "cornerRadius.\(destination)"), 1.5)
    }

    func testOverwriteReplacesTheDestination() {
        storeOneOfEveryFamily(source, marker: 1)
        defaults.set(Data([2]), forKey: "edidOverride.\(destination)")

        let outcome = DisplaySettingsTransfer.apply(from: source, to: destination, in: defaults, overwrite: true)

        XCTAssertTrue(outcome.moved.contains("edidOverride"))
        XCTAssertEqual(defaults.data(forKey: "edidOverride.\(destination)"), Data([1]))
    }

    func testApplyIsANoOpForAnEmptyOrIdenticalIdentity() {
        storeOneOfEveryFamily(source, marker: 1)
        XCTAssertTrue(DisplaySettingsTransfer.apply(from: source, to: source, in: defaults).isEmpty)
        XCTAssertTrue(DisplaySettingsTransfer.apply(from: "", to: destination, in: defaults).isEmpty)
        XCTAssertTrue(DisplaySettingsTransfer.apply(from: source, to: "", in: defaults).isEmpty)
        XCTAssertNil(defaults.data(forKey: "edidOverride."), "an empty identity got settings written")
    }

    func testApplyWithNothingStoredReportsNothingMoved() {
        XCTAssertTrue(DisplaySettingsTransfer.apply(from: source, to: destination, in: defaults).isEmpty)
    }

    // MARK: - The shared blob, which a key-prefix walk would miss

    func testTheDeviceAttachmentMovesEvenThoughItIsNotItsOwnKey() {
        saveDevice("Amp")
        XCTAssertTrue(NetworkDeviceAttachment.attach(deviceNamed: "Amp", toDisplay: source, defaults: defaults))

        let outcome = DisplaySettingsTransfer.apply(from: source, to: destination, in: defaults)

        XCTAssertTrue(outcome.movedDeviceAttachment)
        XCTAssertEqual(
            NetworkDeviceAttachment.attachments(defaults: defaults)[destination], "Amp",
            "the attachment lives inside one shared blob and was left behind"
        )
        XCTAssertEqual(NetworkDeviceAttachment.attachments(defaults: defaults)[source], "Amp")
    }

    func testTheAttachmentCountsAsAPresentFamily() {
        saveDevice("Amp")
        NetworkDeviceAttachment.attach(deviceNamed: "Amp", toDisplay: source, defaults: defaults)
        XCTAssertTrue(
            DisplaySettingsTransfer.familiesPresent(for: source, in: defaults)
                .contains(DisplaySettingsTransfer.sharedBlobFamily)
        )
    }

    func testTheAttachmentIsKeptWhenTheDestinationAlreadyHasOne() {
        saveDevice("Amp")
        saveDevice("TV", brand: .lg)
        NetworkDeviceAttachment.attach(deviceNamed: "Amp", toDisplay: source, defaults: defaults)
        NetworkDeviceAttachment.attach(deviceNamed: "TV", toDisplay: destination, defaults: defaults)

        let outcome = DisplaySettingsTransfer.apply(from: source, to: destination, in: defaults)

        XCTAssertFalse(outcome.movedDeviceAttachment)
        XCTAssertTrue(outcome.kept.contains(DisplaySettingsTransfer.sharedBlobFamily))
        XCTAssertEqual(NetworkDeviceAttachment.attachments(defaults: defaults)[destination], "TV")
    }

    // MARK: - Removing, the undo path

    func testRemoveClearsEverythingATransferWouldHaveMoved() {
        saveDevice("Amp")
        storeOneOfEveryFamily(source, marker: 5)
        NetworkDeviceAttachment.attach(deviceNamed: "Amp", toDisplay: source, defaults: defaults)
        let before = DisplaySettingsTransfer.familiesPresent(for: source, in: defaults)
        XCTAssertEqual(before.count, expectedFamilies.count + 1)

        let removed = DisplaySettingsTransfer.remove(for: source, in: defaults)

        XCTAssertEqual(removed, before.count)
        XCTAssertTrue(DisplaySettingsTransfer.familiesPresent(for: source, in: defaults).isEmpty)
    }

    func testRemoveLeavesTheDestinationAloneAfterATransfer() {
        storeOneOfEveryFamily(source, marker: 6)
        DisplaySettingsTransfer.apply(from: source, to: destination, in: defaults)

        DisplaySettingsTransfer.remove(for: source, in: defaults)

        XCTAssertNil(defaults.data(forKey: "edidOverride.\(source)"))
        XCTAssertEqual(
            defaults.data(forKey: "edidOverride.\(destination)"), Data([6]),
            "clearing the source also cleared the copy"
        )
    }

    func testRemoveOnAnUnknownIdentityChangesNothing() {
        XCTAssertEqual(DisplaySettingsTransfer.remove(for: "9-9-9", in: defaults), 0)
        XCTAssertEqual(DisplaySettingsTransfer.remove(for: "", in: defaults), 0)
    }
}
