import XCTest
@testable import FBDCLIParser

final class HTTPRoutingPlanTests: XCTestCase {
    private func plan(_ command: Command, _ args: [String]) -> HTTPRoutingPlan? {
        switch HTTPRoutingPlanBuilder.plan(for: command, args: args) {
        case .success(let plan): return plan
        case .failure: return nil
        }
    }

    private func failureMessage(_ command: Command, _ args: [String]) -> String? {
        switch HTTPRoutingPlanBuilder.plan(for: command, args: args) {
        case .success: return nil
        case .failure(let error): return error.message
        }
    }

    // MARK: - GET mappings

    func testListMapsToGETDisplays() {
        XCTAssertEqual(plan(.list, []), HTTPRoutingPlan(method: "GET", path: "/api/displays", payload: nil))
    }

    func testInfoMapsToGETDisplay() {
        XCTAssertEqual(plan(.info, ["3"]), HTTPRoutingPlan(method: "GET", path: "/api/displays/3", payload: nil))
    }

    func testCapsMapsToGETCaps() {
        XCTAssertEqual(plan(.caps, ["3"]), HTTPRoutingPlan(method: "GET", path: "/api/displays/3/caps", payload: nil))
    }

    func testModesMapsToGETDisplayInfo() {
        XCTAssertEqual(plan(.modes, ["3"]), HTTPRoutingPlan(method: "GET", path: "/api/displays/3", payload: nil))
    }

    func testBrightnessReadMapsToGETDisplay() {
        XCTAssertEqual(plan(.brightness, ["1"]), HTTPRoutingPlan(method: "GET", path: "/api/displays/1", payload: nil))
    }

    func testContrastVolumeReadMapToGETControls() {
        XCTAssertEqual(plan(.contrast, ["1"]), HTTPRoutingPlan(method: "GET", path: "/api/displays/1/controls", payload: nil))
        XCTAssertEqual(plan(.volume, ["1"]), HTTPRoutingPlan(method: "GET", path: "/api/displays/1/controls", payload: nil))
        XCTAssertEqual(plan(.mute, ["1"]), HTTPRoutingPlan(method: "GET", path: "/api/displays/1/controls", payload: nil))
        XCTAssertEqual(plan(.input, ["1"]), HTTPRoutingPlan(method: "GET", path: "/api/displays/1/controls", payload: nil))
    }

    func testXDRReadMapsToGETDisplay() {
        XCTAssertEqual(plan(.xdr, ["1"]), HTTPRoutingPlan(method: "GET", path: "/api/displays/1", payload: nil))
    }

    func testVirtualListMapsToGETVirtual() {
        XCTAssertEqual(plan(.virtual, ["list"]), HTTPRoutingPlan(method: "GET", path: "/api/virtual", payload: nil))
    }

    // MARK: - POST mappings

    func testBrightnessWriteNormalizesPercentToFraction() {
        XCTAssertEqual(
            plan(.brightness, ["1", "60"]),
            HTTPRoutingPlan(method: "POST", path: "/api/displays/1/brightness", payload: ["value": 0.6])
        )
        XCTAssertEqual(
            plan(.brightness, ["1", "0"]),
            HTTPRoutingPlan(method: "POST", path: "/api/displays/1/brightness", payload: ["value": 0.0])
        )
        XCTAssertEqual(
            plan(.brightness, ["1", "100"]),
            HTTPRoutingPlan(method: "POST", path: "/api/displays/1/brightness", payload: ["value": 1.0])
        )
    }

    func testContrastAndVolumeWrites() {
        XCTAssertEqual(
            plan(.contrast, ["2", "50"]),
            HTTPRoutingPlan(method: "POST", path: "/api/displays/2/contrast", payload: ["value": 0.5])
        )
        XCTAssertEqual(
            plan(.volume, ["2", "25"]),
            HTTPRoutingPlan(method: "POST", path: "/api/displays/2/volume", payload: ["value": 0.25])
        )
    }

    func testMuteWriteParsesOnOff() {
        XCTAssertEqual(
            plan(.mute, ["2", "on"]),
            HTTPRoutingPlan(method: "POST", path: "/api/displays/2/mute", payload: ["muted": true])
        )
        XCTAssertEqual(
            plan(.mute, ["2", "off"]),
            HTTPRoutingPlan(method: "POST", path: "/api/displays/2/mute", payload: ["muted": false])
        )
    }

    func testInputWriteParsesSource() {
        XCTAssertEqual(
            plan(.input, ["2", "15"]),
            HTTPRoutingPlan(method: "POST", path: "/api/displays/2/input", payload: ["source": UInt16(15)])
        )
    }

    func testSetModeWithAndWithoutHz() {
        XCTAssertEqual(
            plan(.setMode, ["1", "1920x1080"]),
            HTTPRoutingPlan(method: "POST", path: "/api/displays/1/mode", payload: ["width": 1920, "height": 1080])
        )
        XCTAssertEqual(
            plan(.setMode, ["1", "1920x1080@120"]),
            HTTPRoutingPlan(method: "POST", path: "/api/displays/1/mode", payload: ["width": 1920, "height": 1080, "hz": 120.0])
        )
    }

    func testXDRWriteOnAndOff() {
        XCTAssertEqual(
            plan(.xdr, ["1", "800"]),
            HTTPRoutingPlan(method: "POST", path: "/api/displays/1/xdr", payload: ["nits": 800])
        )
        XCTAssertEqual(
            plan(.xdr, ["1", "off"]),
            HTTPRoutingPlan(method: "POST", path: "/api/displays/1/xdr", payload: ["enabled": false])
        )
    }

    func testVirtualCreateWithHDRFlag() {
        XCTAssertEqual(
            plan(.virtual, ["create", "Loop", "1920x1080"]),
            HTTPRoutingPlan(method: "POST", path: "/api/virtual/create", payload: ["name": "Loop", "width": UInt32(1920), "height": UInt32(1080), "hz": 60.0])
        )
        XCTAssertEqual(
            plan(.virtual, ["create", "Loop", "1920x1080@120", "--hdr"]),
            HTTPRoutingPlan(method: "POST", path: "/api/virtual/create", payload: ["name": "Loop", "width": UInt32(1920), "height": UInt32(1080), "hz": 120.0, "isHDR": true])
        )
    }

    func testVirtualDestroyMapsID() {
        XCTAssertEqual(
            plan(.virtual, ["destroy", "abc-123"]),
            HTTPRoutingPlan(method: "POST", path: "/api/virtual/destroy", payload: ["id": "abc-123"])
        )
    }

    // MARK: - Validation failures (exact CLI messages)

    func testMissingIDMessages() {
        XCTAssertEqual(failureMessage(.brightness, []), "fbdcli: brightness: display id required")
        XCTAssertEqual(failureMessage(.contrast, []), "fbdcli: contrast: display id required")
        XCTAssertEqual(failureMessage(.volume, []), "fbdcli: volume: display id required")
        XCTAssertEqual(failureMessage(.mute, []), "fbdcli: mute: display id required")
        XCTAssertEqual(failureMessage(.input, []), "fbdcli: input: display id required")
        XCTAssertEqual(failureMessage(.caps, []), "fbdcli: caps: display id required")
        XCTAssertEqual(failureMessage(.modes, []), "fbdcli: modes: display id required")
        XCTAssertEqual(failureMessage(.info, []), "fbdcli: info: display id required")
        XCTAssertEqual(failureMessage(.xdr, []), "fbdcli: xdr: display id required")
    }

    func testOutOfRangeValuesRejected() {
        XCTAssertEqual(failureMessage(.brightness, ["1", "101"]), "fbdcli: brightness: expected 0-100")
        XCTAssertEqual(failureMessage(.brightness, ["1", "-1"]), "fbdcli: brightness: expected 0-100")
        XCTAssertEqual(failureMessage(.brightness, ["1", "abc"]), "fbdcli: brightness: expected 0-100")
        XCTAssertEqual(failureMessage(.volume, ["1", "200"]), "fbdcli: volume: expected 0-100")
    }

    func testMuteAndInputValidation() {
        XCTAssertEqual(failureMessage(.mute, ["1", "yes"]), "fbdcli: mute: expected on or off (got 'yes')")
        XCTAssertEqual(failureMessage(.input, ["1", "hdmi"]), "fbdcli: input: source must be a number (got 'hdmi')")
    }

    func testSetModeValidation() {
        XCTAssertEqual(failureMessage(.setMode, ["1"]), "fbdcli: set-mode: expected <id> <W>x<H>[@<hz>]")
        XCTAssertEqual(failureMessage(.setMode, ["1", "wide"]), "fbdcli: set-mode: expected <W>x<H>[@<hz>] (got 'wide')")
    }

    func testXDRValidation() {
        XCTAssertEqual(failureMessage(.xdr, ["1", "zero"]), "fbdcli: xdr: expected a nits value or 'off' (got 'zero')")
        XCTAssertEqual(failureMessage(.xdr, ["1", "0"]), "fbdcli: xdr: expected a nits value or 'off' (got '0')")
    }

    func testVirtualValidation() {
        XCTAssertEqual(failureMessage(.virtual, []), "fbdcli: virtual: action required (list|create|destroy)")
        XCTAssertEqual(failureMessage(.virtual, ["create", "Name"]), "fbdcli: virtual create: expected <name> <W>x<H>[@<hz>]")
        XCTAssertEqual(failureMessage(.virtual, ["create", "Name", "nonsense"]), "fbdcli: virtual create: expected <W>x<H>[@<hz>] (got 'nonsense')")
        XCTAssertEqual(failureMessage(.virtual, ["destroy"]), "fbdcli: virtual destroy: expected <id-or-name>")
        XCTAssertEqual(failureMessage(.virtual, ["frobnicate"]), "fbdcli: virtual: unknown action 'frobnicate' (list|create|destroy)")
    }

    func testNonRoutableCommandRejected() {
        XCTAssertEqual(failureMessage(.layout, []), "fbdcli: layout: not routable")
    }
}
