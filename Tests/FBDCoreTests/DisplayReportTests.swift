import CoreGraphics
import XCTest
@testable import FBDCore

/// Format locks for the display report.
///
/// These assert the *whole block* rather than sampling lines, because the point of
/// a report is that its shape is stable: it gets pasted into bug reports, and a
/// field that silently moves or disappears makes two reports incomparable. If a
/// change to the report is deliberate, the expected text here changes with it —
/// which is exactly the review surface wanted.
final class DisplayReportTests: XCTestCase {
    private func mode(
        number: Int32 = 54,
        width: Int32 = 1728,
        height: Int32 = 1117,
        pixelsWide: Int32 = 3456,
        pixelsHigh: Int32 = 2234,
        refreshRate: Double = 120,
        flags: Int32 = DisplayMode.hiDPIFlag | DisplayMode.safeFlag,
        encoding: String = "rgb"
    ) -> DisplayMode {
        DisplayMode(
            modeNumber: number,
            flags: flags,
            width: width,
            height: height,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            refreshRate: refreshRate,
            encoding: encoding
        )
    }

    // MARK: - One display

    func testFullyPopulatedDisplayLocksItsWholeBlock() {
        let snapshot = DisplayReport.Snapshot(
            id: 1,
            name: "Built-in Retina Display",
            identityKey: "1552-41040-4251086178",
            isBuiltin: true,
            isOnline: true,
            isActive: true,
            isMain: true,
            bounds: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            currentMode: mode(),
            modeCount: 42,
            refreshRates: [47.95, 60, 120],
            appleBrightnessAvailable: true,
            ddcAvailable: false,
            ddcSummary: nil,
            brightness: 0.46,
            isXDRCapable: true,
            isXDRUpscaled: true,
            xdrUpscaleTargetNits: 1600,
            presetCount: 3,
            activePresetIndex: 1,
            isHDRModeCapable: true,
            isHDRModeEnabled: false
        )
        XCTAssertEqual(DisplayReport.render(snapshot), """
        Display 1: Built-in Retina Display
          identity    1552-41040-4251086178
          kind        built-in, online, active, main
          geometry    0,0 · 1728 × 1117 pt
          mode        3456x2234@120.00 hidpi safe encoding=rgb
          modes       42 (refresh rates: 47.95, 60.00, 120.00)
          control     apple-brightness, no DDC
          brightness  46%
          XDR         capable, upscaled to 1600 nits, 3 presets, active preset 1
          HDR         capable, off
        """)
    }

    /// Absent data must read as absent. A report that omits the line instead
    /// makes "no DDC" indistinguishable from "nobody asked".
    func testEmptyDisplayReportsAbsenceRatherThanOmittingLines() {
        let snapshot = DisplayReport.Snapshot(
            id: 9,
            name: "Unknown",
            identityKey: "0-0-0",
            isOnline: false,
            isActive: false
        )
        XCTAssertEqual(DisplayReport.render(snapshot), """
        Display 9: Unknown
          identity    0-0-0
          kind        external, offline
          geometry    0,0 · 0 × 0 pt
          mode        none reported
          modes       0
          control     no DDC
          brightness  not reported
          XDR         not capable
          HDR         not capable
        """)
    }

    func testAnExternalDDCDisplayReportsItsCapabilities() {
        let snapshot = DisplayReport.Snapshot(
            id: 4,
            name: "Studio Display",
            identityKey: "1-2-3",
            isVirtual: false,
            bounds: CGRect(x: 1728, y: 0, width: 2560, height: 1440),
            modeCount: 12,
            refreshRates: [60],
            ddcAvailable: true,
            ddcSummary: "mccs 2.2, 31 VCP codes",
            brightness: 0.5
        )
        let text = DisplayReport.render(snapshot)
        XCTAssertTrue(text.contains("  kind        external, online, active\n"), text)
        XCTAssertTrue(text.contains("  control     DDC/CI, mccs 2.2, 31 VCP codes\n"), text)
        XCTAssertTrue(text.contains("  XDR         not capable\n"), text)
    }

    /// A default mode is called out, because "why did it come back at a different
    /// refresh rate" is a question this report exists to answer.
    func testADefaultModeIsMarked() {
        let snapshot = DisplayReport.Snapshot(
            id: 2,
            name: "Panel",
            identityKey: "1-1-1",
            currentMode: mode(
                number: 7,
                refreshRate: 60,
                flags: DisplayMode.safeFlag | DisplayMode.defaultFlag,
                encoding: ""
            )
        )
        XCTAssertTrue(
            DisplayReport.render(snapshot).contains("  mode        3456x2234@60.00 lodpi safe default\n")
        )
    }

    // MARK: - Many displays

    func testTheCollectionCarriesAHeaderAndEndsOnContent() {
        let text = DisplayReport.render(
            [
                DisplayReport.Snapshot(id: 1, name: "A", identityKey: "1-1-1"),
                DisplayReport.Snapshot(id: 2, name: "B", identityKey: "2-2-2", isMain: true),
            ],
            version: "1.6.0",
            platform: "Version 14.5 (Build 23F79)"
        )
        XCTAssertTrue(
            text.hasPrefix(
                "FBD display report\nversion     1.6.0\nmacOS       Version 14.5 (Build 23F79)\ndisplays    2\n\n"
            ),
            text
        )
        XCTAssertTrue(text.contains("Display 1: A"), text)
        XCTAssertTrue(text.contains("Display 2: B"), text)
        XCTAssertFalse(text.hasSuffix("\n"), "a report must not end on a blank line")
    }

    func testAnEmptyCollectionSaysSo() {
        XCTAssertEqual(
            DisplayReport.render([], version: "1.6.0", platform: "Version 14.5 (Build 23F79)"),
            """
            FBD display report
            version     1.6.0
            macOS       Version 14.5 (Build 23F79)
            displays    0

            No displays reported.
            """
        )
    }

    // MARK: - Extraction

    func testSnapshotLiftsTheIdentityAndLeavesUnknownsUnknown() {
        let display = Display(
            id: 3,
            name: "Test Panel",
            isBuiltin: false,
            vendorNumber: 10,
            modelNumber: 20,
            serialNumber: 30,
            bounds: CGRect(x: 1, y: 2, width: 3, height: 4),
            isOnline: true,
            isActive: true
        )
        let snapshot = DisplayReport.Snapshot(display: display, isMain: true)
        XCTAssertEqual(snapshot.id, 3)
        XCTAssertEqual(snapshot.name, "Test Panel")
        XCTAssertEqual(snapshot.identityKey, "10-20-30")
        XCTAssertTrue(snapshot.isMain)
        XCTAssertFalse(snapshot.isBuiltin)
        XCTAssertEqual(snapshot.modeCount, 0)
        // Never read is nil — distinct from "read and found nothing".
        XCTAssertNil(snapshot.ddcSummary)
        XCTAssertNil(snapshot.brightness)
        XCTAssertNil(snapshot.currentMode)
        XCTAssertFalse(snapshot.isXDRCapable)
    }

    /// The de-duplication is a pure function precisely because a test cannot
    /// populate a `Display`'s mode list, so this is the only way to check it.
    func testDistinctRefreshRatesDeduplicateAndSort() {
        let modes = [
            mode(number: 1, refreshRate: 120),
            mode(number: 2, refreshRate: 60),
            mode(number: 3, refreshRate: 120),
            mode(number: 4, refreshRate: 47.95),
            mode(number: 5, refreshRate: 60),
        ]
        XCTAssertEqual(DisplayReport.distinctRefreshRates(of: modes), [47.95, 60, 120])
        XCTAssertEqual(DisplayReport.distinctRefreshRates(of: []), [])
    }
}
