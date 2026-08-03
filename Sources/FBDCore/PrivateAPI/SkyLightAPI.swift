import CoreGraphics
import CPrivateAPI
import Foundation
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "SkyLightAPI")

/// A display preset as exposed by SkyLight (Apple displays only).
/// Built-in XDR displays ship ~11 valid factory presets plus 5 blank writable
/// slots (verified on macOS 27: indices 0–10 valid, 11–15 blank).
public struct XDRPreset: Identifiable {
    public let index: Int
    public let name: String
    public let isValid: Bool
    public let isWritable: Bool
    /// PresetMaxSDRLuminance (nits).
    public let maxSDRLuminance: Int
    /// PresetMaxHDRLuminance (nits).
    public let maxHDRLuminance: Int
    /// PresetHostMaxSliderBrightness (nits) — the top of the brightness slider.
    public let maxSliderBrightness: Int
    /// PresetHostMinSliderBrightness (nits).
    public let minSliderBrightness: Int
    /// PresetHostMaxPotentialEDRHeadroom (×100 — e.g. 16 = 1.6×?).
    public let edrHeadroom: Int
    /// PresetUniqueID (16-byte UUID blob).
    public let uniqueID: Data?
    /// Full raw preset dictionary (used when writing modified presets).
    public let raw: [String: Any]

    public var id: Int { index }

    public init(
        index: Int,
        name: String,
        isValid: Bool,
        isWritable: Bool,
        maxSDRLuminance: Int,
        maxHDRLuminance: Int,
        maxSliderBrightness: Int,
        minSliderBrightness: Int,
        edrHeadroom: Int,
        uniqueID: Data?,
        raw: [String: Any]
    ) {
        self.index = index
        self.name = name
        self.isValid = isValid
        self.isWritable = isWritable
        self.maxSDRLuminance = maxSDRLuminance
        self.maxHDRLuminance = maxHDRLuminance
        self.maxSliderBrightness = maxSliderBrightness
        self.minSliderBrightness = minSliderBrightness
        self.edrHeadroom = edrHeadroom
        self.uniqueID = uniqueID
        self.raw = raw
    }
}

/// Typed wrappers over SkyLight (WindowServer client).
/// Tier 1: connection + display re-detection. Tier 2: display presets + HDR mode.
public enum SkyLightAPI {
    /// The process's WindowServer connection ID.
    public static var mainConnectionID: Int {
        Int(SLSMainConnectionID())
    }

    /// Ask the WindowServer to re-detect connected displays. Used after
    /// configuration changes (mode apply, virtual display add/remove).
    /// Rotate a display: degrees must be a multiple of 90; mapped to the
    /// SLS 0-3 rotation steps (0 = normal, 1 = 90° clockwise, 2 = 180°, 3 = 270°).
    /// Returns the current rotation in degrees (0/90/180/270) on success.
    public static func setRotation(_ degrees: Int, for displayID: CGDirectDisplayID) -> Int? {
        let steps = ((degrees % 360) + 360) % 360 / 90
        guard SLSMainConnectionID() != 0 else { return nil }
        let error = SLSSetDisplayRotation(SLSMainConnectionID(), Int32(displayID), Int32(steps))
        guard error == .success else { return nil }
        return Int(SLDisplayRotation(SLSMainConnectionID(), Int32(displayID))) * 90
    }

    public static func detectDisplays() {
        let status = SLSDetectDisplays(Int32(mainConnectionID))
        if status != .success {
            log.warning("SLSDetectDisplays failed: \(status.rawValue)")
        }
    }

    // MARK: - Presets

    /// Enumerate display presets (cap at 32 slots; blank slots return invalid).
    public static func presets(for displayID: CGDirectDisplayID) -> [XDRPreset] {
        var result: [XDRPreset] = []
        for index in 0..<32 {
            guard let data = SLSDisplayCopyPresetData(Int32(displayID), Int32(index))?.takeRetainedValue() as? [String: Any] else {
                // Stop at the first truly empty slot beyond the valid range.
                if index > 16 { break }
                continue
            }
            result.append(makePreset(index: index, displayID: displayID, data: data))
        }
        return result
    }

    /// The factory default preset index (0 on the built-in XDR display).
    public static func factoryDefaultPresetIndex(for displayID: CGDirectDisplayID) -> Int {
        let index = SLSDisplayGetFactoryDefaultPresetIndex(Int32(displayID))
        return Int(index)
    }

    /// Current active preset index. Returns nil when the factory default is active.
    /// NOTE: SLSDisplayGetActivePresetIndex always returns -1 on macOS 27 even
    /// after a successful SetActivePresetIndex (verified by probe) — the active
    /// preset is therefore derived from SLSDisplayCopyActivePreset instead.
    public static func activePresetIndex(for displayID: CGDirectDisplayID) -> Int? {
        guard let active = SLSDisplayCopyActivePreset(Int32(displayID))?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        let activeUID = active["PresetUniqueID"] as? Data
        let activeName = active["PresetName"] as? String
        let candidates = presets(for: displayID)
        // Name match first: FBD upscale slots inherit the base preset's unique
        // ID, so UID matching could resolve to the wrong (factory) preset.
        if let activeName, let hit = candidates.first(where: { $0.name == activeName }) {
            return hit.index
        }
        if let activeUID {
            // Never resolve an FBD-named slot by UID — the factory preset
            // sharing that UID would win.
            if let hit = candidates.first(where: { $0.uniqueID == activeUID && !XDRNativeController.isFBDSlotName($0.name) }) {
                return hit.index
            }
            if let hit = candidates.first(where: { $0.uniqueID == activeUID }) {
                return hit.index
            }
        }
        return nil
    }

    /// Activate a preset by index. Returns false on failure.
    @discardableResult
    public static func setActivePreset(_ index: Int, for displayID: CGDirectDisplayID) -> Bool {
        let status = SLSDisplaySetActivePresetIndex(Int32(displayID), Int32(index))
        if status != 0 {
            log.warning("SLSDisplaySetActivePresetIndex(\(index)) failed: \(status)")
        }
        return status == 0
    }

    /// Write a preset's data dictionary back to the display.
    @discardableResult
    public static func setPresetData(_ data: [String: Any], index: Int, for displayID: CGDirectDisplayID) -> Bool {
        SLSDisplaySetPresetData(Int32(displayID), Int32(index), data as CFDictionary)
        return true
    }

    /// Build an upscaled preset from a base preset's raw dictionary (pure — unit-tested).
    /// Raises the SDR luminance and slider ceiling to `targetNits` (clamped to
    /// the preset's HDR maximum), keeps every other key, marks the preset valid.
    public static func upscaledPresetData(from raw: [String: Any], targetNits: Int) -> [String: Any] {
        var data = raw
        let originalMaxHDR = (raw["PresetMaxHDRLuminance"] as? Int) ?? targetNits
        let maxHDR = max(originalMaxHDR, targetNits)
        data["PresetMaxSDRLuminance"] = targetNits
        data["PresetHostMaxSliderBrightness"] = targetNits
        data["PresetMaxHDRLuminance"] = maxHDR
        data["PresetValid"] = 1
        data["PresetOrigin"] = 0
        data["PresetName"] = "FBD XDR (\(targetNits) nits)"
        data["PresetDescription"] = "SDR brightness upscaled to \(targetNits) nits by FBD."
        return data
    }

    /// Restore the original data of a preset (used when disabling upscaling).
    public static func restorePresetData(_ original: [String: Any], index: Int, for displayID: CGDirectDisplayID) {
        SLSDisplaySetPresetData(Int32(displayID), Int32(index), original as CFDictionary)
    }

    // MARK: - HDR mode

    /// Whether the display supports the HDR framebuffer mode (external HDR
    /// displays report true; the built-in XDR reports false on macOS 27).
    public static func supportsHDRMode(_ displayID: CGDirectDisplayID) -> Bool {
        SLSDisplaySupportsHDRMode(Int32(displayID)) != 0
    }

    public static func isHDRModeEnabled(_ displayID: CGDirectDisplayID) -> Bool {
        SLSDisplayIsHDRModeEnabled(Int32(displayID)) != 0
    }

    /// Force the HDR framebuffer mode (16-bpc extended luminance range).
    @discardableResult
    public static func setHDRModeEnabled(_ enabled: Bool, displayID: CGDirectDisplayID) -> Bool {
        let status = SLSDisplaySetHDRModeEnabled(Int32(displayID), enabled)
        if status != 0 {
            log.warning("SLSDisplaySetHDRModeEnabled(\(enabled)) failed: \(status)")
        }
        return status == 0
    }

    // MARK: - Helpers

    private static func makePreset(index: Int, displayID: CGDirectDisplayID, data: [String: Any]) -> XDRPreset {
        XDRPreset(
            index: index,
            name: (data["PresetName"] as? String) ?? "Preset \(index)",
            isValid: (data["PresetValid"] as? Int) == 1,
            isWritable: SLSDisplayIsPresetWritable(Int32(displayID), Int32(index)) != 0,
            maxSDRLuminance: (data["PresetMaxSDRLuminance"] as? Int) ?? 0,
            maxHDRLuminance: (data["PresetMaxHDRLuminance"] as? Int) ?? 0,
            maxSliderBrightness: (data["PresetHostMaxSliderBrightness"] as? Int) ?? 0,
            minSliderBrightness: (data["PresetHostMinSliderBrightness"] as? Int) ?? 0,
            edrHeadroom: (data["PresetHostMaxPotentialEDRHeadroom"] as? Int) ?? 0,
            uniqueID: data["PresetUniqueID"] as? Data,
            raw: data
        )
    }
}
