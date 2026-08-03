import CoreGraphics
import XCTest
@testable import FBDCore

/// ConfigProtectionController persistence + gating tests. The restore path
/// applies hardware state (ResolutionController/DisplayController) which is
/// not observable in unit tests — the persistence format, key isolation and
/// the settings gate are the testable contract.
@MainActor
final class ConfigProtectionControllerTests: XCTestCase {
    private let suiteName = "test.fbd.configprotection"
    private var originalConfigProtection: Bool!

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        originalConfigProtection = Settings.configProtectionEnabled
    }

    override func tearDown() {
        Settings.configProtectionEnabled = originalConfigProtection
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController() -> ConfigProtectionController {
        let defaults = UserDefaults(suiteName: suiteName)!
        return ConfigProtectionController(defaults: defaults)
    }

    private func makeDisplay(id: CGDirectDisplayID, vendor: UInt32 = 0x10AC, model: UInt32 = 0x1234) -> Display {
        Display(
            id: id,
            name: "Config Test",
            isBuiltin: false,
            vendorNumber: vendor,
            modelNumber: model,
            serialNumber: 0x5678,
            bounds: .zero,
            isOnline: true,
            isActive: true
        )
    }

    func testSaveWritesToInjectedDomainUnderIdentityKey() {
        let controller = makeController()
        let display = makeDisplay(id: 1)
        let resolution = ResolutionController()
        let displayController = DisplayController()

        controller.saveCurrentState(for: display, resolution: resolution, controller: displayController)

        let key = "configProtection.v1.\(display.identityKey)"
        let data = UserDefaults(suiteName: suiteName)?.data(forKey: key)
        XCTAssertNotNil(data, "saved state must land under the identity key in the injected suite")
        XCTAssertNil(UserDefaults.standard.data(forKey: key), "must not write to UserDefaults.standard")
    }

    func testIdentitiesDoNotCollide() {
        let controller = makeController()
        let resolution = ResolutionController()
        let displayController = DisplayController()
        let displayA = makeDisplay(id: 1, vendor: 0x10AC, model: 0x1111)
        let displayB = makeDisplay(id: 2, vendor: 0x10AC, model: 0x2222)

        controller.saveCurrentState(for: displayA, resolution: resolution, controller: displayController)
        controller.saveCurrentState(for: displayB, resolution: resolution, controller: displayController)

        let suite = UserDefaults(suiteName: suiteName)!
        XCTAssertNotNil(suite.data(forKey: "configProtection.v1.\(displayA.identityKey)"))
        XCTAssertNotNil(suite.data(forKey: "configProtection.v1.\(displayB.identityKey)"))
        XCTAssertNotEqual(displayA.identityKey, displayB.identityKey)
    }

    func testRestoreIsNoOpWhenSettingDisabled() {
        Settings.configProtectionEnabled = false
        let controller = makeController()
        let display = makeDisplay(id: 1)
        let resolution = ResolutionController()
        let displayController = DisplayController()

        // No saved state exists; must be a silent no-op (no crash).
        controller.restoreIfNeeded(for: display, resolution: resolution, controller: displayController)
    }

    func testRestoreIsNoOpWithCorruptSavedData() {
        Settings.configProtectionEnabled = true
        let suite = UserDefaults(suiteName: suiteName)!
        suite.set(Data("not-json".utf8), forKey: "configProtection.v1.test-identity")

        let controller = makeController()
        let display = makeDisplay(id: 1)
        controller.restoreIfNeeded(for: display, resolution: ResolutionController(), controller: DisplayController())
        // Reaching this line without a crash is the assertion (corrupt data
        // must decode-fail silently).
    }

    func testSaveRestoreRoundTripDecodesSavedBrightness() {
        let controller = makeController()
        let display = makeDisplay(id: 1)
        // Fabricate a brightness on the display so the saved state carries it.
        display.updateBrightness(0.42)
        controller.saveCurrentState(
            for: display,
            resolution: ResolutionController(),
            controller: DisplayController()
        )

        let suite = UserDefaults(suiteName: suiteName)!
        let data = suite.data(forKey: "configProtection.v1.\(display.identityKey)")
        XCTAssertNotNil(data)
        // The blob must be valid JSON with the expected shape.
        let object = try? JSONSerialization.jsonObject(with: data!) as? [String: Any]
        XCTAssertEqual(object?["brightness"] as? Double, 0.42)
    }
}
