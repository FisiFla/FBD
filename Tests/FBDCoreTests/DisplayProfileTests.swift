import XCTest
@testable import FBDCore

/// Tests for the display profile: the hardware facts a bug report carries.
///
/// The four things that matter here are locked:
///
/// - a display whose link data cannot be read says so, with the reason — it never
///   shows a number that was not measured;
/// - a display whose data *can* be read shows the real numbers;
/// - the masking rules hold (no serial, no home-directory path);
/// - the JSON is stable, so two reports of the same display diff cleanly.
final class DisplayProfileTests: XCTestCase {

    // MARK: - Fixtures

    /// A DPCD dump with known contents: revision 1.4, HBR3, four lanes all trained,
    /// DSC supported.
    private func dpcdDump() -> DPCDBuffer {
        var bytes = [UInt8](repeating: 0, count: 0x210)
        bytes[DPCDRegisters.revision] = 0x14          // 1.4
        bytes[DPCDRegisters.maxLinkRate] = 0x1E      // HBR3
        bytes[DPCDRegisters.maxLaneCount] = 0x84      // 4 lanes, TPS3, enhanced frame
        bytes[DPCDRegisters.dscSupport] = 0x01        // DSC supported
        bytes[DPCDRegisters.lane01Status] = 0xFF      // lanes 0 and 1 trained
        bytes[DPCDRegisters.lane23Status] = 0xFF      // lanes 2 and 3 trained
        return DPCDBuffer(bytes)
    }

    private func edidSummary() -> DisplayEDIDSummary {
        DisplayEDIDSummary(
            byteCount: 256,
            manufacturer: "APP",
            productCode: 0xA0A0,
            serialNumber: ReportRedaction.masked,
            weekOfManufacture: 12,
            yearOfManufacture: 2021,
            versionMajor: 1,
            versionMinor: 4,
            isDigital: true,
            gamma: 2.2,
            horizontalSizeCM: 34,
            verticalSizeCM: 22,
            monitorName: "Color LCD",
            preferredTiming: "3456x2234",
            checksumValid: true
        )
    }

    // MARK: - Unavailable link data

    /// The case the issue is really about: the link data cannot be read, so every
    /// link field is absent **and says why**. A field with a made-up number would be
    /// worse than no field at all.
    func testUnavailableLinkDataIsReportedAsAbsentWithItsReason() {
        let reason = "IOAVVideoInterfaceGetLinkData resolves here but returns a structure "
            + "that no public header describes, so its fields cannot be read safely"
        let profile = DisplayProfile(
            link: DiagnosticGroup(title: "link", fields: [
                DiagnosticField(name: "active bandwidth", unavailableReason: reason),
                DiagnosticField(name: "active link rate", unavailableReason: reason),
                DiagnosticField(name: "tiling", unavailableReason: "no IOKit symbol exposes tiling"),
            ])
        )
        let text = DisplayReport.render(DisplayReport.Snapshot(
            id: 1,
            name: "Panel",
            identityKey: "1552-41040-4251086178",
            profile: profile
        ))
        XCTAssertTrue(text.contains("  link\n"), text)
        XCTAssertTrue(text.contains("    active bandwidth  unavailable — \(reason)\n"), text)
        XCTAssertTrue(text.hasSuffix("""
            tiling            unavailable — no IOKit symbol exposes tiling
        """), text)
        // No invented numbers anywhere in the link section.
        XCTAssertFalse(text.contains("Gbps total"), text)
    }

    /// A group whose every field failed for the same reason prints that reason once,
    /// not once per field.
    func testAGroupThatFailedEntirelyPrintsItsReasonOnce() {
        let group = DiagnosticGroup(
            title: "connection",
            unavailableReason: "the AV video-interface property dictionary is not read by FBD",
            fieldNames: ["_connectionMode", "_hdmiInputCount"]
        )
        XCTAssertEqual(group.sharedUnavailableReason, "the AV video-interface property dictionary is not read by FBD")
        let text = DisplayReport.render(DisplayReport.Snapshot(
            id: 1,
            name: "Panel",
            identityKey: "0-0-0",
            profile: DisplayProfile(connection: group)
        ))
        XCTAssertTrue(text.contains(
            "  connection  unavailable — the AV video-interface property dictionary is not read by FBD"
        ), text)
        XCTAssertFalse(text.contains("_connectionMode"), text)
    }

    /// A group where only some fields are missing has no single reason, so it is
    /// printed in full.
    func testAPartlyAvailableGroupHasNoSharedReason() {
        let group = DiagnosticGroup(title: "link", fields: [
            DiagnosticField(name: "max lane count", value: "4"),
            DiagnosticField(name: "tiling", unavailableReason: "no symbol"),
        ])
        XCTAssertNil(group.sharedUnavailableReason)
    }

    // MARK: - A display with values

    /// The other case: the data can be read, and the report shows the real numbers.
    func testADecodedDPCDReportsItsRealValues() {
        let report = DPCDReport.decode(dpcdDump())
        let group = DisplayProfileController().dpcdGroup(from: report)
        let text = DisplayReport.render(DisplayReport.Snapshot(
            id: 4,
            name: "Studio Display",
            identityKey: "1-2-3",
            profile: DisplayProfile(dpcd: group)
        ))
        XCTAssertTrue(text.contains("  DPCD\n"), text)
        XCTAssertTrue(text.hasSuffix("""
            revision              1.4
            max link rate         HBR3 (8.1 Gbps/lane)
            max lane count        4
            capability bandwidth  32.4 Gbps total
            lanes trained         0, 1, 2, 3 of 4
            DSC                   supported
            HDCP                  unavailable — the DPCD dump did not cover the HDCP status register
        """), text)
    }

    /// The EDID summary is one line, with the serial already masked.
    func testTheEDIDLineCarriesTheParsedFacts() {
        let text = DisplayReport.render(DisplayReport.Snapshot(
            id: 1,
            name: "Panel",
            identityKey: "1552-41040-4251086178",
            profile: DisplayProfile(edid: edidSummary())
        ))
        XCTAssertTrue(text.hasSuffix("""
          EDID        256 bytes, APP, product 0xA0A0, serial ****, 2021 week 12, v1.4, digital, name Color LCD, preferred 3456x2234, checksum ok
        """), text)
    }

    func testAMissingEDIDSaysWhy() {
        let text = DisplayReport.render(DisplayReport.Snapshot(
            id: 1,
            name: "Panel",
            identityKey: "0-0-0",
            profile: DisplayProfile(edidUnavailableReason: "no EDID could be read for this display")
        ))
        XCTAssertTrue(text.hasSuffix("""
          EDID        unavailable — no EDID could be read for this display
        """), text)
    }

    // MARK: - Masking

    func testASerialIsMasked() {
        XCTAssertEqual(ReportRedaction.serial(4251086178), "****")
        // Zero means "this display reports no serial", which is a fact, not a number.
        XCTAssertEqual(ReportRedaction.serial(0), "not reported")
    }

    func testTheIdentityKeyKeepsTheVendorAndProductButNotTheSerial() {
        XCTAssertEqual(ReportRedaction.identityKey("1552-41040-4251086178"), "1552-41040-****")
        // A display with no serial has nothing to mask.
        XCTAssertEqual(ReportRedaction.identityKey("1552-41040-0"), "1552-41040-0")
        // The other identity methods: a lone serial is masked, a name is not.
        XCTAssertEqual(ReportRedaction.identityKey("4251086178"), "****")
        XCTAssertEqual(ReportRedaction.identityKey("studio display"), "studio display")
        XCTAssertEqual(ReportRedaction.identityKey("1552-41040"), "1552-41040")
    }

    func testAHomeDirectoryPathIsShortened() {
        let home = NSHomeDirectory()
        XCTAssertEqual(ReportRedaction.path("\(home)/Library/Displays/x.edid"), "~/Library/Displays/x.edid")
        XCTAssertEqual(ReportRedaction.path(home), "~")
        // A system path identifies nobody and is left alone.
        XCTAssertEqual(ReportRedaction.path("/System/Library/Displays"), "/System/Library/Displays")
        XCTAssertEqual(ReportRedaction.path("not a path"), "not a path")
    }

    /// The end-to-end promise: nothing that identifies the unit reaches the report.
    func testTheReportCarriesNoRawSerial() {
        let text = DisplayReport.render(DisplayReport.Snapshot(
            id: 1,
            name: "Built-in Retina Display",
            identityKey: "1552-41040-4251086178",
            profile: DisplayProfile(edid: edidSummary())
        ))
        XCTAssertFalse(text.contains("4251086178"), text)
        let json = DisplayReport.renderJSON(
            [DisplayReport.Snapshot(
                id: 1,
                name: "Built-in Retina Display",
                identityKey: "1552-41040-4251086178",
                profile: DisplayProfile(edid: edidSummary())
            )],
            version: "1.6.0",
            platform: "Version 27.0.1 (Build 26A434)"
        )
        XCTAssertFalse(json.contains("4251086178"), json)
        XCTAssertTrue(json.contains("1552-41040-****"), json)
    }

    // MARK: - JSON

    /// An absent fact is `null` plus a reason string — never a missing key and never a
    /// made-up value.
    func testJSONReportsAbsentFactsAsNullWithAReason() throws {
        let reason = "no IOAVService node for this display"
        let profile = DisplayProfile(
            dpcd: DiagnosticGroup(title: "DPCD", unavailableReason: reason, fieldNames: ["revision"])
        )
        let json = HTTPJSON.encode(DisplayReport.profileJSON(profile))
        let object = try XCTUnwrap(HTTPJSON.parse(json))
        let dpcd = try XCTUnwrap(object["dpcd"] as? [String: Any])
        XCTAssertTrue(dpcd["revision"] is NSNull)
        XCTAssertEqual(dpcd["revisionUnavailableReason"] as? String, reason)
    }

    /// The JSON is byte-stable: same facts, same bytes, so two reports diff cleanly.
    func testJSONSerialisationIsStable() {
        let profile = DisplayProfile(
            edid: edidSummary(),
            link: DiagnosticGroup(title: "link", fields: [
                DiagnosticField(name: "active bandwidth", unavailableReason: "not readable"),
            ])
        )
        let snapshot = DisplayReport.Snapshot(
            id: 1,
            name: "Built-in Retina Display",
            identityKey: "1552-41040-4251086178",
            profile: profile
        )
        let first = DisplayReport.renderJSON(
            [snapshot],
            version: "1.6.0",
            platform: "Version 27.0.1 (Build 26A434)"
        )
        let second = DisplayReport.renderJSON(
            [snapshot],
            version: "1.6.0",
            platform: "Version 27.0.1 (Build 26A434)"
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, """
        {"displays":[{"brightness":null,"control":"no DDC","geometry":"0,0 · 0 × 0 pt","hdr":{"capable":false,\
        "enabled":false},"id":1,"identity":"1552-41040-****","kind":"external, online, active","mode":null,\
        "modeCount":0,"name":"Built-in Retina Display","profile":{"connection":null,"dpcd":null,\
        "edid":{"byteCount":256,"checksumValid":true,"digital":true,"gamma":"2.20","manufacturer":"APP",\
        "monitorName":"Color LCD","preferredTiming":"3456x2234","productCode":41120,"serialNumber":"****",\
        "sizeCM":"34x22","version":"1.4","weekOfManufacture":12,"yearOfManufacture":2021},\
        "edidUnavailableReason":null,"link":{"active bandwidth":null,\
        "active bandwidthUnavailableReason":"not readable"},"panel":null},"refreshRates":[],\
        "xdr":{"activePresetIndex":null,"capable":false,"presetCount":0,"targetNits":null,"upscaled":false}}],\
        "macOS":"Version 27.0.1 (Build 26A434)","version":"1.6.0"}
        """)
    }
}
