import XCTest
@testable import FBDCore

// MARK: - Fake (the second adapter at the DisplayControlling seam)

@MainActor
private final class FakeDisplayController: DisplayControlling {
    var displays: [Display] = []
    var brightnessResult: Double? = nil
    var brightnessAccepts = true
    var contrastAccepts = true
    var volumeAccepts = true
    var mutedAccepts = true
    var inputAccepts = true
    var modeAccepts = true
    var xdrAccepts = true
    var xdrDisableAccepts = true
    var rotationResult: Int? = 0
    var filterAccepts = true
    var caps: DDC.DDCCapabilities? = nil
    var boostIDs: [UInt32] = []
    var lastFilter: ScreenFilterParams? = nil
    var filterStopped = false
    var modeSwitchCalls = 0
    var virtualScreens: [VirtualScreenInstance] = []
    var virtualConfigs: [VirtualScreenConfig] = []
    var virtualAvailable = false
    var createdConfigs: [VirtualScreenConfig] = []
    var destroyedIDs: [String] = []

    @discardableResult
    func createVirtual(_ config: VirtualScreenConfig) -> Bool {
        createdConfigs.append(config)
        return virtualAvailable
    }
    @discardableResult
    func destroyVirtual(id: String) -> Bool {
        destroyedIDs.append(id)
        return virtualConfigs.contains { $0.id == id }
    }
    func virtualDisplayID(for id: String) -> CGDirectDisplayID? { 42 }

    func display(withID id: CGDirectDisplayID) -> Display? {
        displays.first { $0.id == id }
    }
    func getBrightness(for display: Display) -> Double? { brightnessResult }
    @discardableResult
    func setBrightness(_ value: Double, on display: Display) -> Bool { brightnessAccepts }
    func readDDCControls(for display: Display) -> DisplayController.DDCControls {
        .init(contrast: 0.5, volume: 0.5, muted: false, inputSource: nil)
    }
    func readDDCCapabilities(for display: Display) -> DDC.DDCCapabilities? { caps }
    @discardableResult
    func setContrast(_ value: Double, on display: Display) -> Bool { contrastAccepts }
    @discardableResult
    func setVolume(_ value: Double, on display: Display) -> Bool { volumeAccepts }
    @discardableResult
    func setMuted(_ muted: Bool, on display: Display) -> Bool { mutedAccepts }
    @discardableResult
    func setInputSource(_ source: UInt16, on display: Display) -> Bool { inputAccepts }
    @discardableResult
    func applyMode(_ mode: DisplayMode, to display: Display) -> Bool {
        modeSwitchCalls += 1
        return modeAccepts
    }
    @discardableResult
    func setXDRUpscaleTarget(_ nits: Int, on display: Display) -> Bool { xdrAccepts }
    @discardableResult
    func disableXDRUpscaling(on display: Display) -> Bool { xdrDisableAccepts }
    func setRotation(_ degrees: Int, on display: Display) -> Int? { rotationResult }
    @discardableResult
    func setScreenFilter(_ params: ScreenFilterParams, on display: Display) -> Bool {
        lastFilter = params
        return filterAccepts
    }
    func stopScreenFilter(on display: Display) { filterStopped = true }
    func activeBoostDisplayIDs() -> [UInt32] { boostIDs }
}

// MARK: - Tests

@MainActor
final class HTTPExecutorTests: XCTestCase {
    private var fake: FakeDisplayController!
    private var display: Display!

    override func setUp() {
        super.setUp()
        fake = FakeDisplayController()
        display = Display(
            id: 7,
            name: "Test",
            isBuiltin: false,
            vendorNumber: 0x10AC,
            modelNumber: 0x1234,
            serialNumber: 0x5678,
            bounds: .zero,
            isOnline: true,
            isActive: true
        )
        display.updateModes([
            DisplayMode(
                modeNumber: 1, flags: DisplayMode.safeFlag, width: 1920, height: 1080,
                pixelsWide: 1920, pixelsHigh: 1080, refreshRate: 60, encoding: "test"
            ),
        ], current: nil)
        fake.displays = [display]
    }

    private func run(_ route: HTTPRoute) -> (Int, String) {
        HTTPExecutor.execute(route, controller: fake, version: "9.9.9")
    }

    // MARK: - Health / list / info

    func testHealth() {
        fake.boostIDs = [1]
        let (status, body) = run(.health)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("\"version\":\"9.9.9\""))
        XCTAssertTrue(body.contains("\"boostActive\":[1]"))
    }

    func testListDisplays() {
        let (status, body) = run(.listDisplays)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("\"displays\""))
    }

    func testDisplayInfoFoundAndNotFound() {
        let (status, body) = run(.displayInfo(id: 7))
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("\"modes\""))
        XCTAssertEqual(run(.displayInfo(id: 99)).0, 404)
    }

    // MARK: - Controls

    func testControlsAndCaps() {
        XCTAssertEqual(run(.displayControls(id: 7, what: "controls")).0, 200)
        fake.caps = DDC.DDCCapabilities(mccsVersion: "3.0", vcpCodes: [0x10], raw: "test")
        XCTAssertEqual(run(.displayControls(id: 7, what: "caps")).0, 200)
        fake.caps = nil
        XCTAssertEqual(run(.displayControls(id: 7, what: "caps")).0, 404)
        XCTAssertEqual(run(.displayControls(id: 99, what: "controls")).0, 404)
    }

    // MARK: - Actions

    func testBrightnessAction() {
        fake.brightnessAccepts = false
        XCTAssertEqual(run(.displayAction(id: 7, action: .brightness(0.5))).0, 500)
        fake.brightnessAccepts = true
        XCTAssertEqual(run(.displayAction(id: 7, action: .brightness(0.5))).0, 200)
    }

    func testActionFailuresMapTo500() {
        fake.contrastAccepts = false
        XCTAssertEqual(run(.displayAction(id: 7, action: .contrast(0.5))).0, 500)
        fake.volumeAccepts = false
        XCTAssertEqual(run(.displayAction(id: 7, action: .volume(0.3))).0, 500)
        fake.mutedAccepts = false
        XCTAssertEqual(run(.displayAction(id: 7, action: .mute(true))).0, 500)
        fake.inputAccepts = false
        XCTAssertEqual(run(.displayAction(id: 7, action: .input(3))).0, 500)
        fake.rotationResult = nil
        XCTAssertEqual(run(.displayAction(id: 7, action: .rotate(90))).0, 500)
    }

    func testModeAction() {
        // No matching mode -> 404.
        XCTAssertEqual(run(.displayAction(id: 7, action: .mode(width: 800, height: 600, hz: nil))).0, 404)
        // Matching mode -> 200 + applyMode called.
        let (status, body) = run(.displayAction(id: 7, action: .mode(width: 1920, height: 1080, hz: 60)))
        XCTAssertEqual(status, 200)
        XCTAssertEqual(fake.modeSwitchCalls, 1)
        XCTAssertTrue(body.contains("1920x1080"))
        fake.modeAccepts = false
        XCTAssertEqual(run(.displayAction(id: 7, action: .mode(width: 1920, height: 1080, hz: 60))).0, 500)
    }

    func testXRDActions() {
        XCTAssertEqual(run(.displayAction(id: 7, action: .xdr(nits: 800))).0, 200)
        XCTAssertEqual(run(.displayAction(id: 7, action: .xdrDisable)).0, 200)
        fake.xdrAccepts = false
        XCTAssertEqual(run(.displayAction(id: 7, action: .xdr(nits: 800))).0, 500)
        fake.xdrDisableAccepts = false
        XCTAssertEqual(run(.displayAction(id: 7, action: .xdrDisable)).0, 500)
    }

    func testFilterActions() {
        let params = ScreenFilterParams(brightness: 1, contrast: 1, saturation: 0, gamma: 1, temperature: 1, invert: false)
        XCTAssertEqual(run(.displayAction(id: 7, action: .filter(params))).0, 200)
        XCTAssertEqual(fake.lastFilter?.saturation, 0)
        XCTAssertEqual(run(.displayAction(id: 7, action: .filterOff)).0, 200)
        XCTAssertTrue(fake.filterStopped)
        fake.filterAccepts = false
        XCTAssertEqual(run(.displayAction(id: 7, action: .filter(params))).0, 500)
    }

    func testActionOnMissingDisplayIs404() {
        XCTAssertEqual(run(.displayAction(id: 99, action: .brightness(0.5))).0, 404)
    }

    // MARK: - Virtual (through the seam — no hardware)

    func testVirtualList() {
        let config = VirtualScreenConfig(name: "V", width: 1920, height: 1080)
        fake.virtualConfigs = [config]
        fake.virtualScreens = [VirtualScreenInstance(id: config.id, displayID: 42, config: config)]
        let (status, body) = run(.virtualList)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("\"id\":\"\(config.id)\""))
    }

    func testVirtualCreateSuccessAndUnavailable() {
        fake.virtualAvailable = true
        let request = VirtualCreateRequest(name: "V", width: 1920, height: 1080, hz: 60, isHDR: false)
        let (status, body) = run(.virtualCreate(request))
        XCTAssertEqual(status, 201)
        XCTAssertEqual(fake.createdConfigs.count, 1)
        XCTAssertEqual(fake.createdConfigs[0].name, "V")
        XCTAssertTrue(body.contains("\"displayID\":42"))

        fake.virtualAvailable = false
        XCTAssertEqual(run(.virtualCreate(request)).0, 500)
        XCTAssertEqual(fake.createdConfigs.count, 1, "unavailable must not attempt creation")
    }

    func testVirtualDestroy() {
        let config = VirtualScreenConfig(name: "V", width: 1920, height: 1080)
        fake.virtualConfigs = [config]
        XCTAssertEqual(run(.virtualDestroy(id: config.id)).0, 200)
        XCTAssertEqual(fake.destroyedIDs, [config.id])
        XCTAssertEqual(run(.virtualDestroy(id: "nonexistent")).0, 404)
    }
}
