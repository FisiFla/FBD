import XCTest
import FBDCore

/// Tests for the authoritative virtual-display ID registry and its
/// integration with Display.isVirtual.
final class VirtualDisplayRegistryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Isolate from other tests: prune everything not online (nothing is
        // online in the test process, so the registry empties).
        VirtualDisplayRegistry.shared.prune(keeping: [])
    }

    private func makeDisplay(id: CGDirectDisplayID) -> Display {
        Display(
            id: id,
            name: "Display \(id)",
            isBuiltin: false,
            vendorNumber: 0x1111,
            modelNumber: 0x2222,
            serialNumber: 0x3333,
            bounds: .zero,
            isOnline: true,
            isActive: true
        )
    }

    // MARK: - Registry

    func testRegisterContainsUnregister() {
        let registry = VirtualDisplayRegistry()
        let id: CGDirectDisplayID = 0x4242_4242

        XCTAssertFalse(registry.contains(id))
        registry.register(id)
        XCTAssertTrue(registry.contains(id))
        registry.unregister(id)
        XCTAssertFalse(registry.contains(id))
    }

    func testPruneDropsVanishedIDs() {
        let registry = VirtualDisplayRegistry()
        registry.register(0x1111_1111)
        registry.register(0x2222_2222)

        registry.prune(keeping: [0x1111_1111])

        XCTAssertTrue(registry.contains(0x1111_1111))
        XCTAssertFalse(registry.contains(0x2222_2222))
    }

    // MARK: - Persistence (cross-process visibility)

    func testRegisteredIDsSurviveNewRegistryInstance() {
        let id: CGDirectDisplayID = 0x4242_4243
        defer {
            VirtualDisplayRegistry.shared.unregister(id)
        }

        let registry = VirtualDisplayRegistry()
        registry.register(id)

        // A fresh instance (another process / app relaunch) must still see it.
        let fresh = VirtualDisplayRegistry()
        XCTAssertTrue(fresh.contains(id), "registered IDs must persist to Settings")

        fresh.unregister(id)
        XCTAssertFalse(VirtualDisplayRegistry().contains(id), "unregister must persist too")
    }

    // MARK: - Display.isVirtual integration

    func testRegisteredDisplayIsVirtual() {
        let display = makeDisplay(id: 0x4242_4242)
        XCTAssertFalse(display.isVirtual, "not registered yet")

        VirtualDisplayRegistry.shared.register(display.id)
        XCTAssertTrue(display.isVirtual, "registry must be the primary signal")

        VirtualDisplayRegistry.shared.unregister(display.id)
        XCTAssertFalse(display.isVirtual, "unregistered display must not be virtual")
    }

    func testLegacyFingerprintsStillRecognized() {
        // Displays FBD did not create still match the magic-ID fallbacks.
        let f0f0 = makeDisplay(id: 0xF0F0)
        XCTAssertTrue(f0f0.isVirtual)

        let sidecar = makeDisplay(id: 0x896)
        XCTAssertTrue(sidecar.isVirtual)

        let vendorFingerprint = Display(
            id: 0xCAFE_0001,
            name: "Unknown",
            isBuiltin: false,
            vendorNumber: 0x0100,
            modelNumber: 0x0000,
            serialNumber: 0,
            bounds: .zero,
            isOnline: true,
            isActive: true
        )
        XCTAssertTrue(vendorFingerprint.isVirtual)
    }

    func testOrdinaryExternalDisplayIsNotVirtual() {
        XCTAssertFalse(makeDisplay(id: 0x1234_5678).isVirtual)
    }
}
