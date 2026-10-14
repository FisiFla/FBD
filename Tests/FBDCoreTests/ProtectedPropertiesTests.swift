import XCTest
@testable import FBDCore

/// Row 1: per-property configuration protection. What is asserted here is the option set and
/// the stored values the two *unreadable* properties are protected from — the restore path
/// itself needs a live display, and `SavedState` is private to its controller.
final class ProtectedPropertiesTests: XCTestCase {
    private let suiteName = "test.fbd.protectedproperties"
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

    // MARK: - The option set

    func testRotationAndColourProfileAreSelectableByName() {
        let selection = ProtectedProperties.parse("rotation,colourProfile")
        XCTAssertEqual(selection, [.rotation, .colourProfile])
        XCTAssertEqual(selection?.names, ["rotation", "colourProfile"])
    }

    func testAllCoversBothNewProperties() {
        XCTAssertTrue(ProtectedProperties.all.contains(.rotation))
        XCTAssertTrue(ProtectedProperties.all.contains(.colourProfile))
        XCTAssertEqual(ProtectedProperties.parse("all")?.contains(.rotation), true)
    }

    /// Widening what protection covers must stay an explicit user choice: the legacy default
    /// is what every existing install has, so it must not have grown two properties.
    func testTheLegacyDefaultDidNotWiden() {
        XCTAssertEqual(ProtectedProperties.legacyDefault, [.resolution, .brightness, .preset])
        XCTAssertFalse(ProtectedProperties.legacyDefault.contains(.rotation))
        XCTAssertFalse(ProtectedProperties.legacyDefault.contains(.colourProfile))
    }

    /// The apply order is both the CLI vocabulary and the restore sequence, and brightness
    /// stays last because it is applied after a settling delay.
    func testApplyOrderPutsBrightnessLast() {
        XCTAssertEqual(ProtectedProperties.ordered.last?.name, "brightness")
        XCTAssertEqual(
            ProtectedProperties.all.names,
            [
                "resolution", "refreshRate", "preset", "hdrMode", "mainStatus",
                "rotation", "colourProfile", "brightness",
            ]
        )
    }

    func testAnUnknownNameIsStillRefusedRatherThanDropped() {
        XCTAssertNil(ProtectedProperties.parse("rotation,nonsense"))
    }

    /// Neither new property can be probed — there is no readable rotation and no readable
    /// current profile — so both hang off the same condition the mode-based ones do: a display
    /// FBD can enumerate. With no mode there is nothing to offer.
    func testTheUnprobeablePropertiesFollowTheEnumeratedDisplayCondition() {
        let idle = Display(
            id: 7,
            name: "No modes",
            isBuiltin: false,
            vendorNumber: 1,
            modelNumber: 2,
            serialNumber: 3,
            bounds: .zero,
            isOnline: true,
            isActive: true
        )

        let available = ProtectedProperties.available(for: idle)

        XCTAssertTrue(available.contains(.mainStatus), "main status works for any display")
        XCTAssertFalse(available.contains(.rotation))
        XCTAssertFalse(available.contains(.colourProfile))
    }

    // MARK: - The values the two unreadable properties are protected from

    func testRotationRoundTripsThroughTheInjectedSuite() {
        XCTAssertNil(Settings.storedRotation(for: "a", in: defaults))
        Settings.setStoredRotation(90, for: "a", in: defaults)
        XCTAssertEqual(Settings.storedRotation(for: "a", in: defaults), 90)
        Settings.setStoredRotation(nil, for: "a", in: defaults)
        XCTAssertNil(Settings.storedRotation(for: "a", in: defaults))
    }

    /// Zero degrees is a real rotation (landscape), so it has to survive — which is why the
    /// setter takes an optional instead of treating 0 as "unset".
    func testZeroDegreesIsStoredRatherThanReadAsAbsent() {
        Settings.setStoredRotation(0, for: "a", in: defaults)
        XCTAssertEqual(Settings.storedRotation(for: "a", in: defaults), 0)
    }

    func testColourProfileRoundTripsThroughTheInjectedSuite() {
        XCTAssertNil(Settings.storedColourProfile(for: "a", in: defaults))
        Settings.setStoredColourProfile("/Library/ColorSync/Profiles/test.icc", for: "a", in: defaults)
        XCTAssertEqual(
            Settings.storedColourProfile(for: "a", in: defaults),
            "/Library/ColorSync/Profiles/test.icc"
        )
        Settings.setStoredColourProfile(nil, for: "a", in: defaults)
        XCTAssertNil(Settings.storedColourProfile(for: "a", in: defaults))
    }

    func testTheTwoStoredValuesAreKeyedByIdentitySoDisplaysDoNotShare() {
        Settings.setStoredRotation(90, for: "a", in: defaults)
        Settings.setStoredRotation(270, for: "b", in: defaults)
        Settings.setStoredColourProfile("/x/a.icc", for: "a", in: defaults)
        XCTAssertEqual(Settings.storedRotation(for: "a", in: defaults), 90)
        XCTAssertEqual(Settings.storedRotation(for: "b", in: defaults), 270)
        XCTAssertNil(Settings.storedColourProfile(for: "b", in: defaults))
    }
}
