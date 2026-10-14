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

        public init(display: Display, isMain: Bool) {
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
            isHDRModeEnabled: Bool = false
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
        lines.append("  identity    \(snapshot.identityKey)")
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
}
