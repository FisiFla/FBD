import XCTest
@testable import FBDCLIParser

/// The parsers of the per-display state commands (issue #28): the
/// smooth-scaling ladder (`hidpi`), the below-floor brightness blend
/// (`gamma-floor`) and the display's connection (`display`).
final class DisplayCommandArgsTests: XCTestCase {

    // MARK: - hidpi

    func testHiDPIInstall() {
        XCTAssertEqual(
            HiDPIArgs.parse(["2", "install"]),
            .success(HiDPIArgs(displayID: 2, operation: .install))
        )
    }

    func testHiDPIRemoveAndStatus() {
        XCTAssertEqual(
            HiDPIArgs.parse(["3", "remove"]),
            .success(HiDPIArgs(displayID: 3, operation: .remove))
        )
        XCTAssertEqual(
            HiDPIArgs.parse(["3", "status"]),
            .success(HiDPIArgs(displayID: 3, operation: .status))
        )
    }

    func testHiDPIPreviewIsAFlag() {
        XCTAssertEqual(
            HiDPIArgs.parse(["2", "install", "--preview"]),
            .success(HiDPIArgs(displayID: 2, operation: .install, preview: true))
        )
    }

    func testHiDPIRejectsAnUnknownOperation() {
        XCTAssertEqual(
            failure(HiDPIArgs.parse(["2", "uninstall"])),
            "unknown operation 'uninstall' (expected install, remove or status)"
        )
    }

    func testHiDPIRejectsAnUnknownOption() {
        XCTAssertEqual(
            failure(HiDPIArgs.parse(["2", "install", "--force"])),
            "unknown option '--force' (expected --preview)"
        )
    }

    func testHiDPIRejectsAMissingIDOrOperation() {
        XCTAssertEqual(failure(HiDPIArgs.parse([])), "expected <id> install|remove|status")
        XCTAssertEqual(failure(HiDPIArgs.parse(["2"])), "expected install, remove or status")
        XCTAssertEqual(failure(HiDPIArgs.parse(["screen", "install"])), "display id must be a number (got 'screen')")
    }

    // MARK: - gamma-floor

    func testGammaFloorOnAndOff() {
        XCTAssertEqual(
            GammaFloorArgs.parse(["1", "on"]),
            .success(GammaFloorArgs(displayID: 1, action: .set(enabled: true, thresholdPercent: nil)))
        )
        XCTAssertEqual(
            GammaFloorArgs.parse(["1", "off"]),
            .success(GammaFloorArgs(displayID: 1, action: .set(enabled: false, thresholdPercent: nil)))
        )
    }

    func testGammaFloorKeepsTheThresholdWhenNoneIsGiven() {
        XCTAssertEqual(
            GammaFloorArgs.parse(["1", "on"]),
            .success(GammaFloorArgs(displayID: 1, action: .set(enabled: true, thresholdPercent: nil)))
        )
    }

    func testGammaFloorTakesAThresholdInPercent() {
        XCTAssertEqual(
            GammaFloorArgs.parse(["1", "on", "20"]),
            .success(GammaFloorArgs(displayID: 1, action: .set(enabled: true, thresholdPercent: 20)))
        )
        XCTAssertEqual(
            GammaFloorArgs.parse(["1", "off", "0"]),
            .success(GammaFloorArgs(displayID: 1, action: .set(enabled: false, thresholdPercent: 0)))
        )
        XCTAssertEqual(
            GammaFloorArgs.parse(["1", "off", "100"]),
            .success(GammaFloorArgs(displayID: 1, action: .set(enabled: false, thresholdPercent: 100)))
        )
    }

    func testGammaFloorBareFormReportsTheState() {
        XCTAssertEqual(
            GammaFloorArgs.parse(["1"]),
            .success(GammaFloorArgs(displayID: 1, action: .report))
        )
    }

    func testGammaFloorRejectsAnOutOfRangeThreshold() {
        XCTAssertEqual(
            failure(GammaFloorArgs.parse(["1", "on", "101"])),
            "threshold must be a number between 0 and 100 (got '101')"
        )
        XCTAssertEqual(
            failure(GammaFloorArgs.parse(["1", "on", "-1"])),
            "threshold must be a number between 0 and 100 (got '-1')"
        )
    }

    func testGammaFloorRejectsAnUnknownWord() {
        XCTAssertEqual(
            failure(GammaFloorArgs.parse(["1", "maybe"])),
            "expected on or off (got 'maybe')"
        )
    }

    // MARK: - display

    func testDisplayDisconnectAndReconnect() {
        XCTAssertEqual(
            DisplayArgs.parse(["2", "disconnect"]),
            .success(DisplayArgs(displayID: 2, action: .disconnect(remember: false)))
        )
        XCTAssertEqual(
            DisplayArgs.parse(["2", "reconnect"]),
            .success(DisplayArgs(displayID: 2, action: .reconnect))
        )
    }

    func testDisplayDisconnectWithRemember() {
        XCTAssertEqual(
            DisplayArgs.parse(["2", "disconnect", "--remember"]),
            .success(DisplayArgs(displayID: 2, action: .disconnect(remember: true)))
        )
    }

    func testDisplayListRemembered() {
        XCTAssertEqual(
            DisplayArgs.parse(["--list-remembered"]),
            .success(DisplayArgs(displayID: nil, action: .listRemembered))
        )
    }

    func testDisplayListRememberedTakesNoDisplayID() {
        XCTAssertEqual(
            failure(DisplayArgs.parse(["2", "--list-remembered"])),
            "'--list-remembered' takes no display id"
        )
    }

    func testDisplayRejectsAnUnknownAction() {
        XCTAssertEqual(
            failure(DisplayArgs.parse(["2", "off"])),
            "unknown action 'off' (expected disconnect or reconnect)"
        )
        XCTAssertEqual(
            failure(DisplayArgs.parse(["2"])),
            "expected disconnect or reconnect"
        )
        XCTAssertEqual(
            failure(DisplayArgs.parse([])),
            "expected <id> disconnect|reconnect or --list-remembered"
        )
    }

    func testDisplayRejectsAnUnknownOption() {
        XCTAssertEqual(
            failure(DisplayArgs.parse(["2", "disconnect", "--forever"])),
            "unknown option '--forever' (expected --remember)"
        )
    }

    // MARK: - The wording the CLI prints

    func testTheHiDPIStatusSummary() {
        let status = HiDPIOverrideStatus(
            isSupported: true,
            isInstalled: false,
            modeCount: 12,
            wouldPrompt: true,
            path: "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-123"
        )
        XCTAssertEqual(
            status.summary,
            "supported=yes installed=no modes=12 adminPrompt=yes"
        )
    }

    func testTheScaledModePreviewLine() {
        let mode = ScaledModePreview(
            logicalWidth: 1920,
            logicalHeight: 1080,
            backingWidth: 3840,
            backingHeight: 2160
        )
        XCTAssertEqual(mode.line, "1920x1080 points  ->  3840x2160 pixels")
    }

    func testTheFloorBlendSummary() {
        XCTAssertEqual(
            FloorBlendStatus(isEnabled: true, threshold: 0.15).summary,
            "on (threshold 15%)"
        )
        XCTAssertEqual(
            FloorBlendStatus(isEnabled: false, threshold: 0.2).summary,
            "off (threshold 20%)"
        )
    }

    // MARK: - Helpers

    /// The message of a parse failure, or nil when the parse succeeded.
    private func failure<T>(_ result: Result<T, TVCommandValidation.Failure>) -> String? {
        switch result {
        case .failure(let failure): return failure.message
        case .success: return nil
        }
    }
}
