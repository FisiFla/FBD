import Foundation
import os

/// Collects the hardware facts a display report carries.
///
/// Everything here is a **read**: the CoreDisplay info dictionary, the panel's EDID, and —
/// when the caller asks for it — the sink's DPCD over AUX. Nothing writes to a display,
/// and nothing caches what it read: a report describes the display as it is now.
///
/// The controller exists because those reads live in three different layers (a private-API
/// wrapper, the EDID controller and the IODP wrapper) and a report needs them together.
/// Gathering them here keeps the report code — which the CLI drives — a pure consumer of
/// public FBDCore API.
public final class DisplayProfileController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "DisplayProfileController")
    private let edidController = EDIDController()

    public init() {}

    /// The profile for a display.
    ///
    /// - Parameter readDPCD: when false, no AUX read is attempted and the DPCD section
    ///   says so. A report covering every display stays free of bus traffic; a report for
    ///   one display asks for the whole story.
    public func profile(for display: Display, readDPCD: Bool) -> DisplayProfile {
        var profile = DisplayProfile()

        profile.panel = panelGroup(for: display)
        collectEDID(for: display, into: &profile)
        profile.dpcd = dpcdGroup(for: display, readDPCD: readDPCD)
        profile.link = linkGroup()
        profile.connection = connectionGroup()

        return profile
    }

    // MARK: - EDID

    private func collectEDID(for display: Display, into profile: inout DisplayProfile) {
        guard let data = edidController.exportEDID(for: display) else {
            profile.edidUnavailableReason = "no EDID could be read for this display"
            return
        }
        guard let parsed = EDIDParser.parse(data) else {
            profile.edidUnavailableReason =
                "an EDID was read (\(data.count) bytes) but it is not a parsable EDID block"
            return
        }
        profile.edid = DisplayEDIDSummary(
            byteCount: data.count,
            manufacturer: parsed.manufacturer,
            productCode: parsed.productCode,
            // Masked here, not at render time: the raw serial must never reach the report.
            serialNumber: ReportRedaction.serial(parsed.serialNumber),
            weekOfManufacture: Int(parsed.weekOfManufacture),
            yearOfManufacture: parsed.yearOfManufacture,
            versionMajor: Int(parsed.edidVersion.major),
            versionMinor: Int(parsed.edidVersion.minor),
            isDigital: parsed.isDigital,
            gamma: parsed.gamma,
            horizontalSizeCM: Int(parsed.maxHorizontalSizeCM),
            verticalSizeCM: Int(parsed.maxVerticalSizeCM),
            monitorName: parsed.monitorName.map { ReportRedaction.path($0) },
            preferredTiming: parsed.preferredTiming.map { "\($0.width)x\($0.height)" },
            checksumValid: parsed.isChecksumValid
        )
    }

    // MARK: - CoreDisplay panel facts

    private func panelGroup(for display: Display) -> DiagnosticGroup {
        guard let info = CoreDisplayInfoAPI.infoDictionary(for: display.id) else {
            return DiagnosticGroup(
                title: "panel",
                unavailableReason: "the CoreDisplay info dictionary could not be read",
                fieldNames: DisplayProfileController.panelFieldNames
            )
        }
        var fields: [DiagnosticField] = []
        fields.append(field("transport type", info, "kDisplayTransportType"))
        fields.append(field("technology type", info, "DisplayTechnologyType"))
        fields.append(field("digital", info, "IODisplayIsDigital"))
        fields.append(field("underscan", info, "DisplaySupportsUnderscan"))
        fields.append(field("rotation", info, "kCGDisplaySupportsRotation"))
        fields.append(field("virtual device", info, "kCGDisplayIsVirtualDevice"))
        fields.append(field("AirPlay", info, "kCGDisplayIsAirPlay"))
        fields.append(field("dynamic refresh rate", info, "kCGDisplayIsDFR"))
        if let location = info["IODisplayLocation"] as? String {
            fields.append(DiagnosticField(name: "registry location", value: ReportRedaction.path(location)))
        }
        if let name = productName(from: info) {
            fields.append(DiagnosticField(name: "product name", value: name))
        }
        if let size = panelSize(from: info) {
            fields.append(DiagnosticField(name: "panel size", value: size))
        }
        if let week = info["DisplayWeekManufacture"] as? NSNumber,
           let year = info["DisplayYearManufacture"] as? NSNumber {
            // A zero week and a zero year are how a panel says it has no manufacture
            // date; printing "0 week 0" would read like a measurement.
            let text = (year.intValue == 0 && week.intValue == 0)
                ? "not reported"
                : "\(year.intValue) week \(week.intValue)"
            fields.append(DiagnosticField(name: "manufactured", value: text))
        }
        if let gamma = info["DisplayWhiteGamma"] as? NSNumber {
            fields.append(DiagnosticField(name: "white gamma", value: String(format: "%.2f", gamma.doubleValue)))
        }
        return DiagnosticGroup(title: "panel", fields: fields)
    }

    static let panelFieldNames = [
        "transport type", "technology type", "digital", "underscan", "rotation",
        "virtual device", "AirPlay", "dynamic refresh rate", "registry location",
        "product name", "panel size", "manufactured", "white gamma",
    ]

    /// One dictionary entry as a report field: a measured value, or the reason it is
    /// missing. An absent key is a fact about the dictionary, not about the panel.
    private func field(_ name: String, _ info: [String: Any], _ key: String) -> DiagnosticField {
        guard let raw = info[key] else {
            return DiagnosticField(name: name, unavailableReason: "the info dictionary has no '\(key)' entry")
        }
        if let number = raw as? NSNumber {
            // A boolean arrives as an NSNumber too; report it as a flag rather than 0/1.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return DiagnosticField(name: name, value: number.boolValue ? "yes" : "no")
            }
            return DiagnosticField(name: name, value: "\(number.intValue)")
        }
        return DiagnosticField(name: name, value: String(describing: raw))
    }

    /// The English product name out of CoreDisplay's localized name dictionary.
    private func productName(from info: [String: Any]) -> String? {
        guard let names = info["DisplayProductName"] as? [String: Any] else { return nil }
        if let english = names["en"] as? String, !english.isEmpty { return english }
        if let english = names["en_US"] as? String, !english.isEmpty { return english }
        guard let first = names.values.compactMap({ $0 as? String }).sorted().first else { return nil }
        return first.isEmpty ? nil : first
    }

    /// The panel's physical size in millimetres, when the dictionary carries both halves.
    private func panelSize(from info: [String: Any]) -> String? {
        guard let width = info["DisplayHorizontalImageSize"] as? NSNumber,
              let height = info["DisplayVerticalImageSize"] as? NSNumber else { return nil }
        return "\(width.intValue) × \(height.intValue) mm"
    }

    // MARK: - DPCD

    /// The decoded DPCD registers, or the reason there are none.
    private func dpcdGroup(for display: Display, readDPCD: Bool) -> DiagnosticGroup {
        guard readDPCD else {
            return DiagnosticGroup(
                title: "DPCD",
                unavailableReason: "not read (a DPCD read is an AUX transaction, and this "
                    + "report did not ask for one)",
                fieldNames: DisplayProfileController.dpcdFieldNames
            )
        }
        guard let request = DPCDRequest(address: 0, length: DisplayProfileController.dpcdReadLength) else {
            return DiagnosticGroup(
                title: "DPCD",
                unavailableReason: "the DPCD read length is out of range",
                fieldNames: DisplayProfileController.dpcdFieldNames
            )
        }
        switch IODPAPI.read(request, for: display) {
        case .success(let bytes):
            return dpcdGroup(from: DPCDReport.decode(DPCDBuffer(bytes)))
        case .failure(let failure):
            log.debug("DPCD read failed for display \(display.id): \(failure.description)")
            return DiagnosticGroup(
                title: "DPCD",
                unavailableReason: failure.description,
                fieldNames: DisplayProfileController.dpcdFieldNames
            )
        }
    }

    static let dpcdFieldNames = [
        "revision", "max link rate", "max lane count", "capability bandwidth",
        "lanes trained", "DSC", "HDCP",
    ]

    /// How much DPCD a report reads: the capability block (0x000), the DSC block
    /// (0x060) and the lane status block (0x202) all fall inside it.
    static let dpcdReadLength = 0x210

    /// The decoded DPCD registers as report fields.
    ///
    /// Internal rather than private so a test can lock the shape against a synthetic
    /// dump: the real read needs a DisplayPort sink, and this repository's machine has
    /// none attached.
    func dpcdGroup(from report: DPCDReport) -> DiagnosticGroup {
        var fields: [DiagnosticField] = []

        if let revision = report.sink.revision {
            fields.append(DiagnosticField(name: "revision", value: revision.description))
        } else {
            fields.append(DiagnosticField(
                name: "revision",
                unavailableReason: "the DPCD dump did not carry the revision register"
            ))
        }

        if let rate = report.sink.maxLinkRate {
            fields.append(DiagnosticField(
                name: "max link rate",
                value: "\(rate.name) (\(rate.gigabitsPerLane) Gbps/lane)"
            ))
        } else if let raw = report.sink.maxLinkRateRaw {
            fields.append(DiagnosticField(
                name: "max link rate",
                value: "unknown code \(String(format: "0x%02x", raw))"
            ))
        } else {
            fields.append(DiagnosticField(
                name: "max link rate",
                unavailableReason: "the DPCD dump did not carry the link rate"
            ))
        }

        if let lanes = report.sink.maxLaneCount {
            fields.append(DiagnosticField(name: "max lane count", value: "\(lanes)"))
        } else {
            fields.append(DiagnosticField(
                name: "max lane count",
                unavailableReason: "the DPCD dump did not carry the lane count"
            ))
        }

        if let total = report.sink.totalGigabitsPerSecond {
            fields.append(DiagnosticField(name: "capability bandwidth", value: "\(total) Gbps total"))
        } else {
            fields.append(DiagnosticField(
                name: "capability bandwidth",
                unavailableReason: "the DPCD dump did not carry a link rate and lane count"
            ))
        }

        if let laneStatus = report.laneStatus {
            let trained = laneStatus.trainedLanes
            let trainedText = trained.isEmpty ? "none" : trained.map(String.init).joined(separator: ", ")
            fields.append(DiagnosticField(
                name: "lanes trained",
                value: "\(trainedText) of \(laneStatus.laneCount)"
            ))
        } else {
            fields.append(DiagnosticField(
                name: "lanes trained",
                unavailableReason: "the DPCD dump did not cover the lane status registers"
            ))
        }

        if let dsc = report.dsc {
            fields.append(DiagnosticField(
                name: "DSC",
                value: dsc.supported ? "supported" : "not supported"
            ))
        } else {
            fields.append(DiagnosticField(
                name: "DSC",
                unavailableReason: "the DPCD dump did not cover the DSC block"
            ))
        }

        if let hdcp = report.hdcp {
            fields.append(DiagnosticField(
                name: "HDCP",
                value: hdcp.linkIntegrityFailure ? "link integrity failure" : "ok"
            ))
        } else {
            fields.append(DiagnosticField(
                name: "HDCP",
                unavailableReason: "the DPCD dump did not cover the HDCP status register"
            ))
        }

        return DiagnosticGroup(title: "DPCD", fields: fields)
    }

    // MARK: - Link and connection

    /// The DisplayPort **link** facets — what the link is doing right now, as opposed to
    /// what the sink in the DPCD dump can do.
    ///
    /// All four are unavailable, and each says why. The active bandwidth and the active
    /// link rate live in the structure `IOAVVideoInterfaceGetLinkData` returns, which no
    /// public header describes, so they cannot be decoded safely; the DPCD dump describes
    /// what the sink supports, not the mode in force; and no IOKit symbol exposes tiling.
    private func linkGroup() -> DiagnosticGroup {
        let linkReason = VideoLinkDataAPI.unavailableReason
        return DiagnosticGroup(title: "link", fields: [
            DiagnosticField(name: "active bandwidth", unavailableReason: linkReason),
            DiagnosticField(name: "active link rate", unavailableReason: linkReason),
            DiagnosticField(name: "DSC in use", unavailableReason:
                "the DPCD dump reports what the sink supports, not what the current mode uses"),
            DiagnosticField(name: "tiling", unavailableReason:
                "no IOKit symbol exposes tiling, and FBD does not decode the DPCD tiling registers"),
        ])
    }

    /// The connection facts BetterDisplay reads from the AV video-interface properties.
    ///
    /// They live in a dictionary FBD does not read: the entry point that would produce it
    /// is only probed, never called (see `VideoLinkDataAPI`). The names are kept exactly
    /// as the reverse engineering found them, so a report can be compared with the
    /// finding field for field.
    private func connectionGroup() -> DiagnosticGroup {
        DiagnosticGroup(
            title: "connection",
            unavailableReason: "the connection facts live in the AV video-interface property "
                + "dictionary, which FBD only probes and never reads",
            fieldNames: DisplayProfileController.connectionFieldNames
        )
    }

    static let connectionFieldNames = [
        "_connectionMode",
        "_connectionTypeDescription",
        "_connectionStatusActiveProbe",
        "_tunnelControlDescription",
        "_lastCECReport",
        "_hdmiInputCount",
        "_macInputNumber",
    ]
}
