import CoreGraphics
import Foundation

/// A detailed, paste-ready report of a display's state.
///
/// Split into a value-type `Snapshot` and a pure formatter, which is what makes
/// the output lockable in tests: `Display`'s collections are `private(set)`, so a
/// test cannot populate one directly, and a report whose format nobody can pin
/// down is a report that drifts the first time someone edits it.
///
/// The value is diagnostic. When a display misbehaves, what matters is the mode,
/// which control paths exist, and what the XDR/HDR state actually is — so those
/// are reported, and absent data is reported as absent rather than omitted.
///
/// A report is also something a user pastes into a **public** bug report, so it
/// carries nothing that identifies them: serials are masked and home-directory
/// paths are shortened (see `ReportRedaction`). The facts a maintainer needs —
/// vendor, product, mode, link state — survive that.
public enum DisplayReport {
    /// The facts a report needs, lifted off `Display`.
    public struct Snapshot: Equatable {
        public let id: CGDirectDisplayID
        public let name: String
        public let identityKey: String
        public let isBuiltin: Bool
        public let isVirtual: Bool
        public let isOnline: Bool
        public let isActive: Bool
        public let isMain: Bool
        public let bounds: CGRect
        public let currentMode: DisplayMode?
        public let modeCount: Int
        /// Distinct refresh rates the display offers, ascending.
        public let refreshRates: [Double]
        public let appleBrightnessAvailable: Bool
        public let ddcAvailable: Bool
        /// `nil` when capabilities have not been read — different from "none".
        public let ddcSummary: String?
        public let brightness: Double?
        public let isXDRCapable: Bool
        public let isXDRUpscaled: Bool
        public let xdrUpscaleTargetNits: Int?
        public let presetCount: Int
        public let activePresetIndex: Int?
        public let isHDRModeCapable: Bool
        public let isHDRModeEnabled: Bool
        /// The hardware facts (EDID, DPCD, link, connection), when they were collected.
        public let profile: DisplayProfile?

        public init(display: Display, isMain: Bool, profile: DisplayProfile? = nil) {
            self.id = display.id
            self.name = display.name
            self.identityKey = display.identityKey
            self.isBuiltin = display.isBuiltin
            self.isVirtual = display.isVirtual
            self.isOnline = display.isOnline
            self.isActive = display.isActive
            self.isMain = isMain
            self.bounds = display.bounds
            self.currentMode = display.currentMode
            self.modeCount = display.modes.count
            self.refreshRates = DisplayReport.distinctRefreshRates(of: display.modes)
            self.appleBrightnessAvailable = display.appleBrightnessAvailable
            self.ddcAvailable = display.ddcAvailable
            if let caps = display.ddcCapabilities {
                self.ddcSummary = "mccs \(caps.mccsVersion), \(caps.vcpCodes.count) VCP codes"
            } else {
                self.ddcSummary = nil
            }
            self.brightness = display.brightness
            self.isXDRCapable = display.isXDRCapable
            self.isXDRUpscaled = display.isXDRUpscaled
            self.xdrUpscaleTargetNits = display.xdrUpscaleTargetNits
            self.presetCount = display.presets.count
            self.activePresetIndex = display.activePresetIndex
            self.isHDRModeCapable = display.isHDRModeCapable
            self.isHDRModeEnabled = display.isHDRModeEnabled
            self.profile = profile
        }

        /// Direct initialiser, so a format-lock test needs no `Display` at all.
        public init(
            id: CGDirectDisplayID,
            name: String,
            identityKey: String,
            isBuiltin: Bool = false,
            isVirtual: Bool = false,
            isOnline: Bool = true,
            isActive: Bool = true,
            isMain: Bool = false,
            bounds: CGRect = .zero,
            currentMode: DisplayMode? = nil,
            modeCount: Int = 0,
            refreshRates: [Double] = [],
            appleBrightnessAvailable: Bool = false,
            ddcAvailable: Bool = false,
            ddcSummary: String? = nil,
            brightness: Double? = nil,
            isXDRCapable: Bool = false,
            isXDRUpscaled: Bool = false,
            xdrUpscaleTargetNits: Int? = nil,
            presetCount: Int = 0,
            activePresetIndex: Int? = nil,
            isHDRModeCapable: Bool = false,
            isHDRModeEnabled: Bool = false,
            profile: DisplayProfile? = nil
        ) {
            self.id = id
            self.name = name
            self.identityKey = identityKey
            self.isBuiltin = isBuiltin
            self.isVirtual = isVirtual
            self.isOnline = isOnline
            self.isActive = isActive
            self.isMain = isMain
            self.bounds = bounds
            self.currentMode = currentMode
            self.modeCount = modeCount
            self.refreshRates = refreshRates
            self.appleBrightnessAvailable = appleBrightnessAvailable
            self.ddcAvailable = ddcAvailable
            self.ddcSummary = ddcSummary
            self.brightness = brightness
            self.isXDRCapable = isXDRCapable
            self.isXDRUpscaled = isXDRUpscaled
            self.xdrUpscaleTargetNits = xdrUpscaleTargetNits
            self.presetCount = presetCount
            self.activePresetIndex = activePresetIndex
            self.isHDRModeCapable = isHDRModeCapable
            self.isHDRModeEnabled = isHDRModeEnabled
            self.profile = profile
        }
    }

    /// Distinct refresh rates a mode list offers, ascending. Pure, and separate
    /// from `Snapshot`, because a test cannot populate a `Display`'s mode list —
    /// so a de-duplication that lived inline in the snapshot initialiser would be
    /// the one part of this report nobody could check.
    public static func distinctRefreshRates(of modes: [DisplayMode]) -> [Double] {
        Array(Set(modes.map(\.refreshRate))).sorted()
    }

    /// Render one display. Pure — the same snapshot always gives the same text.
    public static func render(_ snapshot: Snapshot) -> String {
        var lines: [String] = []
        lines.append("Display \(snapshot.id): \(snapshot.name)")
        lines.append("  identity    \(ReportRedaction.identityKey(snapshot.identityKey))")
        lines.append("  kind        \(kind(snapshot))")
        lines.append("  geometry    \(geometry(snapshot.bounds))")

        if let mode = snapshot.currentMode {
            var parts = [mode.key, mode.isHiDPI ? "hidpi" : "lodpi", mode.isSafe ? "safe" : "unsafe"]
            if mode.isDefault { parts.append("default") }
            // The raw CGS encoding descriptor is the colour-depth evidence (for
            // example 10 bits per channel), which is exactly what a display
            // problem report needs — so it is kept, but labelled, because
            // unlabelled it reads as noise.
            if !mode.encoding.isEmpty { parts.append("encoding=\(mode.encoding)") }
            lines.append("  mode        \(parts.joined(separator: " "))")
        } else {
            lines.append("  mode        none reported")
        }

        lines.append("  modes       \(snapshot.modeCount)\(refreshList(snapshot.refreshRates))")
        lines.append("  control     \(control(snapshot))")
        lines.append("  brightness  \(brightness(snapshot.brightness))")
        lines.append("  XDR         \(xdr(snapshot))")
        lines.append("  HDR         \(hdr(snapshot))")
        lines.append(contentsOf: profileLines(snapshot.profile))
        return lines.joined(separator: "\n")
    }

    /// Render every display under a small header, for a bug report.
    ///
    /// Both header values are passed in rather than read here, which keeps this
    /// pure and testable. The platform string earns its place: FBD's display
    /// capabilities differ per macOS release, so a report without it cannot be
    /// compared against another.
    public static func render(_ snapshots: [Snapshot], version: String, platform: String) -> String {
        var lines = [
            "FBD display report",
            "version     \(version)",
            "macOS       \(platform)",
            "displays    \(snapshots.count)",
            "",
        ]
        if snapshots.isEmpty {
            lines.append("No displays reported.")
        }
        for snapshot in snapshots {
            lines.append(render(snapshot))
            lines.append("")
        }
        // Trim the trailing blank so the file ends on content.
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON

    /// The report as JSON. Same facts as the text, machine-readable.
    ///
    /// The key order is stable (`HTTPJSON.encode` sorts keys), so two reports of
    /// the same display diff cleanly — which is the point of exporting one.
    public static func renderJSON(_ snapshots: [Snapshot], version: String, platform: String) -> String {
        HTTPJSON.encode(jsonObject(snapshots, version: version, platform: platform))
    }

    /// The JSON object behind `renderJSON`, for callers that want to embed it.
    public static func jsonObject(_ snapshots: [Snapshot], version: String, platform: String) -> [String: Any] {
        [
            "version": version,
            "macOS": platform,
            "displays": snapshots.map { jsonObject($0) },
        ]
    }

    /// One display as a JSON object.
    public static func jsonObject(_ snapshot: Snapshot) -> [String: Any] {
        var info: [String: Any] = [
            "id": snapshot.id,
            "name": snapshot.name,
            "identity": ReportRedaction.identityKey(snapshot.identityKey),
            "kind": kind(snapshot),
            "geometry": geometry(snapshot.bounds),
            "modeCount": snapshot.modeCount,
            "refreshRates": snapshot.refreshRates,
            "control": control(snapshot),
            "brightness": nullable(snapshot.brightness),
            "xdr": xdrJSON(snapshot),
            "hdr": hdrJSON(snapshot),
        ]
        if let mode = snapshot.currentMode {
            info["mode"] = [
                "key": mode.key,
                "hidpi": mode.isHiDPI,
                "safe": mode.isSafe,
                "default": mode.isDefault,
                "encoding": mode.encoding,
            ] as [String: Any]
        } else {
            info["mode"] = NSNull()
        }
        info["profile"] = profileJSON(snapshot.profile)
        return info
    }

    // MARK: - Field rendering

    private static func kind(_ snapshot: Snapshot) -> String {
        var parts: [String] = []
        if snapshot.isBuiltin { parts.append("built-in") }
        if snapshot.isVirtual { parts.append("virtual") }
        if parts.isEmpty { parts.append("external") }
        parts.append(snapshot.isOnline ? "online" : "offline")
        if snapshot.isActive { parts.append("active") }
        if snapshot.isMain { parts.append("main") }
        return parts.joined(separator: ", ")
    }

    private static func geometry(_ bounds: CGRect) -> String {
        let origin = "\(Int(bounds.origin.x)),\(Int(bounds.origin.y))"
        let size = "\(Int(bounds.width)) × \(Int(bounds.height)) pt"
        return "\(origin) · \(size)"
    }

    private static func refreshList(_ rates: [Double]) -> String {
        guard !rates.isEmpty else { return "" }
        let rendered = rates.map { String(format: "%.2f", $0) }.joined(separator: ", ")
        return " (refresh rates: \(rendered))"
    }

    private static func control(_ snapshot: Snapshot) -> String {
        var parts: [String] = []
        if snapshot.appleBrightnessAvailable { parts.append("apple-brightness") }
        if snapshot.ddcAvailable {
            parts.append("DDC/CI")
        } else {
            parts.append("no DDC")
        }
        if let summary = snapshot.ddcSummary { parts.append(summary) }
        return parts.joined(separator: ", ")
    }

    private static func brightness(_ value: Double?) -> String {
        guard let value else { return "not reported" }
        return "\(Int((value * 100).rounded()))%"
    }

    private static func xdr(_ snapshot: Snapshot) -> String {
        guard snapshot.isXDRCapable else { return "not capable" }
        var parts: [String] = ["capable"]
        if snapshot.isXDRUpscaled {
            let nits = snapshot.xdrUpscaleTargetNits.map { " to \($0) nits" } ?? ""
            parts.append("upscaled\(nits)")
        } else {
            parts.append("not upscaled")
        }
        parts.append("\(snapshot.presetCount) presets")
        if let index = snapshot.activePresetIndex { parts.append("active preset \(index)") }
        return parts.joined(separator: ", ")
    }

    private static func hdr(_ snapshot: Snapshot) -> String {
        guard snapshot.isHDRModeCapable else { return "not capable" }
        return snapshot.isHDRModeEnabled ? "capable, on" : "capable, off"
    }

    // MARK: - Profile rendering

    /// The profile as one line per group, for `fbdcli info`.
    ///
    /// The same facts as the report, flattened: a group that could not be read is
    /// "unavailable" with its reason, and a group that could is its fields with their
    /// values.
    public static func profileSummary(_ profile: DisplayProfile?) -> [(label: String, value: String)] {
        guard let profile else { return [] }
        var summary: [(label: String, value: String)] = []
        if let edid = profile.edid {
            summary.append(("EDID", edidLine(edid)))
        } else {
            summary.append(("EDID", "unavailable — \(profile.edidUnavailableReason ?? "not read")"))
        }
        for group in [profile.panel, profile.dpcd, profile.link, profile.connection] {
            guard let group else { continue }
            summary.append((group.title, groupSummary(group)))
        }
        return summary
    }

    private static func groupSummary(_ group: DiagnosticGroup) -> String {
        if let reason = group.sharedUnavailableReason {
            return "unavailable — \(reason)"
        }
        return group.fields.map { field in
            if let value = field.value { return "\(field.name): \(value)" }
            return "\(field.name): unavailable — \(field.unavailableReason ?? "not read")"
        }.joined(separator: ", ")
    }

    /// The profile summary as an ordered list of `label`/`value` pairs.
    ///
    /// A JSON object has no order, so a client that receives the profile over HTTP
    /// gets the summary as an array — the groups and their fields then come out in the
    /// order they were built in, which is the order the text report prints them.
    public static func profileSummaryJSON(_ profile: DisplayProfile?) -> [[String: Any]] {
        profileSummary(profile).map { entry in
            ["label": entry.label, "value": entry.value] as [String: Any]
        }
    }

    /// The hardware section: EDID, panel facts, DPCD, link and connection.
    ///
    /// Each group is either a list of measured fields or one honest "unavailable"
    /// line. A group whose fields all failed for the same reason prints that reason
    /// once rather than repeating it per field.
    private static func profileLines(_ profile: DisplayProfile?) -> [String] {
        guard let profile else { return [] }
        var lines: [String] = []
        if let edid = profile.edid {
            lines.append("  EDID        \(edidLine(edid))")
        } else {
            lines.append("  EDID        unavailable — \(profile.edidUnavailableReason ?? "not read")")
        }
        for group in [profile.panel, profile.dpcd, profile.link, profile.connection] {
            guard let group else { continue }
            if let reason = group.sharedUnavailableReason {
                lines.append("  \(pad(group.title, 12))unavailable — \(reason)")
                continue
            }
            lines.append("  \(group.title)")
            let width = group.fields.map(\.name.count).max() ?? 0
            for field in group.fields {
                let text = field.value ?? "unavailable — \(field.unavailableReason ?? "not read")"
                lines.append("    \(pad(field.name, width))  \(text)")
            }
        }
        return lines
    }

    private static func edidLine(_ edid: DisplayEDIDSummary) -> String {
        var parts = ["\(edid.byteCount) bytes"]
        if !edid.manufacturer.isEmpty { parts.append(edid.manufacturer) }
        parts.append(String(format: "product 0x%04X", edid.productCode))
        parts.append("serial \(edid.serialNumber)")
        parts.append("\(edid.yearOfManufacture) week \(edid.weekOfManufacture)")
        parts.append("v\(edid.versionMajor).\(edid.versionMinor)")
        parts.append(edid.isDigital ? "digital" : "analog")
        if let name = edid.monitorName { parts.append("name \(name)") }
        if let timing = edid.preferredTiming { parts.append("preferred \(timing)") }
        parts.append(edid.checksumValid ? "checksum ok" : "checksum bad")
        return parts.joined(separator: ", ")
    }

    // MARK: - JSON helpers

    /// The profile as a JSON object, for callers that want it on its own.
    ///
    /// Every absent fact is `null` plus a reason string — never a missing key and
    /// never a made-up value.
    public static func profileJSON(_ profile: DisplayProfile?) -> [String: Any] {
        guard let profile else {
            return [
                "edid": NSNull(),
                "edidUnavailableReason": NSNull(),
                "panel": NSNull(),
                "dpcd": NSNull(),
                "link": NSNull(),
                "connection": NSNull(),
            ]
        }
        return [
            "edid": edidJSON(profile.edid),
            "edidUnavailableReason": nullable(profile.edidUnavailableReason),
            "panel": groupJSON(profile.panel),
            "dpcd": groupJSON(profile.dpcd),
            "link": groupJSON(profile.link),
            "connection": groupJSON(profile.connection),
        ]
    }
    private static func edidJSON(_ edid: DisplayEDIDSummary?) -> Any {
        guard let edid else { return NSNull() }
        return [
            "byteCount": edid.byteCount,
            "manufacturer": edid.manufacturer,
            "productCode": edid.productCode,
            "serialNumber": edid.serialNumber,
            "weekOfManufacture": edid.weekOfManufacture,
            "yearOfManufacture": edid.yearOfManufacture,
            "version": "\(edid.versionMajor).\(edid.versionMinor)",
            "digital": edid.isDigital,
            // The gamma is a hundredths value, and a double's binary tail ("2.2000000000000002")
            // is noise in a report; two decimals as a string is both honest and stable.
            "gamma": String(format: "%.2f", edid.gamma),
            "sizeCM": "\(edid.horizontalSizeCM)x\(edid.verticalSizeCM)",
            "monitorName": nullable(edid.monitorName),
            "preferredTiming": nullable(edid.preferredTiming),
            "checksumValid": edid.checksumValid,
        ] as [String: Any]
    }

    /// A group as a JSON object.
    ///
    /// Every field gets its value key **and** its reason key, so the shape does not
    /// change with the data: an absent field is `null` plus a reason string, never a
    /// missing key and never a made-up value.
    private static func groupJSON(_ group: DiagnosticGroup?) -> Any {
        guard let group else { return NSNull() }
        var info: [String: Any] = [:]
        for field in group.fields {
            info[field.name] = nullable(field.value)
            info[field.name + "UnavailableReason"] = nullable(field.unavailableReason)
        }
        return info
    }

    private static func xdrJSON(_ snapshot: Snapshot) -> [String: Any] {
        [
            "capable": snapshot.isXDRCapable,
            "upscaled": snapshot.isXDRUpscaled,
            "targetNits": nullable(snapshot.xdrUpscaleTargetNits),
            "presetCount": snapshot.presetCount,
            "activePresetIndex": nullable(snapshot.activePresetIndex),
        ]
    }

    private static func hdrJSON(_ snapshot: Snapshot) -> [String: Any] {
        [
            "capable": snapshot.isHDRModeCapable,
            "enabled": snapshot.isHDRModeEnabled,
        ]
    }

    private static func nullable(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private static func nullable(_ value: Int?) -> Any {
        if let value { return value }
        return NSNull()
    }

    private static func nullable(_ value: Double?) -> Any {
        if let value { return value }
        return NSNull()
    }

    /// Left-pad to `width` columns (never truncates).
    private static func pad(_ string: String, _ width: Int) -> String {
        string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
    }
}
