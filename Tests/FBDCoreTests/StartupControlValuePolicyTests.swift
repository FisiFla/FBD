import XCTest
@testable import FBDCore

/// Row 9, the startup policy: a picker in Settings that nothing read. The mapping and the
/// store are pure, so both are asserted without a display — and the default case is the
/// one that matters most, because "wiring the behaviour" must not change what a default
/// install does.
final class StartupControlValuePolicyTests: XCTestCase {
    private let suiteName = "test.fbd.startupvalues"
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

    // MARK: - The decision

    /// The no-op case, in both directions: a default install must read and write nothing.
    func testTheDefaultPolicyTouchesNothing() {
        XCTAssertEqual(StartupControlValuePolicy.assumeLastUsed.action(hasStoredValue: true), StartupControlAction.nothing)
        XCTAssertEqual(StartupControlValuePolicy.assumeLastUsed.action(hasStoredValue: false), StartupControlAction.nothing)
    }

    func testWriteToDeviceWritesWhatWasStored() {
        XCTAssertEqual(
            StartupControlValuePolicy.writeToDevice.action(hasStoredValue: true),
            StartupControlAction.writeStored
        )
    }

    /// With nothing stored there is no value to write, so the policy seeds the store by
    /// reading rather than doing nothing for ever on a display FBD has never driven.
    func testWriteToDeviceWithNothingStoredReadsInstead() {
        XCTAssertEqual(
            StartupControlValuePolicy.writeToDevice.action(hasStoredValue: false),
            StartupControlAction.readFromDevice
        )
    }

    func testReadFromDeviceReadsWhateverIsStored() {
        XCTAssertEqual(
            StartupControlValuePolicy.readFromDevice.action(hasStoredValue: true),
            StartupControlAction.readFromDevice
        )
        XCTAssertEqual(
            StartupControlValuePolicy.readFromDevice.action(hasStoredValue: false),
            StartupControlAction.readFromDevice
        )
    }

    /// Every policy is answered for both store states, so adding a case cannot leave a
    /// path unhandled without this failing.
    func testEveryPolicyIsAnsweredForBothStoreStates() {
        XCTAssertEqual(StartupControlValuePolicy.allCases.count, 3)
        for policy in StartupControlValuePolicy.allCases {
            for stored in [true, false] {
                XCTAssertNotNil(policy.action(hasStoredValue: stored))
            }
        }
    }

    // MARK: - The store the policy acts on

    func testRoundTripThroughTheInjectedSuite() {
        XCTAssertNil(Settings.storedBrightness(for: "1-2-3", in: defaults))
        Settings.setStoredBrightness(0.42, for: "1-2-3", in: defaults)
        XCTAssertEqual(Settings.storedBrightness(for: "1-2-3", in: defaults) ?? 0, 0.42, accuracy: 1e-12)
    }

    /// Zero is a legitimate brightness, so it must survive — and "never set" has to stay
    /// distinguishable from it, which is why absence is nil rather than 0.
    func testZeroIsStoredRatherThanReadAsAbsent() {
        Settings.setStoredBrightness(0, for: "1-2-3", in: defaults)
        XCTAssertEqual(Settings.storedBrightness(for: "1-2-3", in: defaults), 0)
    }

    func testClearingRemovesTheValue() {
        Settings.setStoredBrightness(0.7, for: "1-2-3", in: defaults)
        Settings.setStoredBrightness(nil, for: "1-2-3", in: defaults)
        XCTAssertNil(Settings.storedBrightness(for: "1-2-3", in: defaults))
    }

    func testValuesAreKeyedByIdentitySoTwoDisplaysDoNotShareOne() {
        Settings.setStoredBrightness(0.2, for: "a", in: defaults)
        Settings.setStoredBrightness(0.9, for: "b", in: defaults)
        XCTAssertEqual(Settings.storedBrightness(for: "a", in: defaults) ?? 0, 0.2, accuracy: 1e-12)
        XCTAssertEqual(Settings.storedBrightness(for: "b", in: defaults) ?? 0, 0.9, accuracy: 1e-12)
    }
}
