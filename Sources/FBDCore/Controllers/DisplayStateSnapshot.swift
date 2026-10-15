import CoreGraphics
import Foundation
import os

/// Everything FBD can record about one display at a moment in time, and the one
/// implementation that re-applies it.
///
/// Two features work from this same shape: config protection, which re-applies
/// it when a display reconnects, and named display presets, which re-apply it on
/// demand. Sharing the type means a field added here is captured and restored
/// everywhere at once, and the two features cannot drift apart.
///
/// All fields are optional so a blob written by an older FBD (which only had
/// mode/brightness/preset) still decodes.
public struct DisplayStateSnapshot: Codable, Equatable {
    /// CGS mode number of the current mode (nil when none could be read).
    public var modeNumber: Int32?
    /// The saved mode's refresh rate in Hz (used when only `.refreshRate` is
    /// protected, so the exact mode need not still exist).
    public var refreshRate: Double?
    /// Last known brightness, 0…1 (nil when the display has no control path).
    public var brightness: Double?
    /// Active XDR preset index (nil = factory default / non-XDR display).
    public var activePresetIndex: Int?
    /// HDR framebuffer mode state (nil when the display cannot report it).
    public var isHDRModeEnabled: Bool?
    /// Whether the display was the main display.
    public var isMain: Bool?
    /// Rotation FBD last applied, in degrees (nil when it never applied one).
    ///
    /// Taken from `Settings.storedRotation` because rotation cannot be read
    /// back, so what FBD applied is the only value there is to protect.
    public var rotationDegrees: Int?
    /// The colour profile FBD last applied, by path (nil when it never applied
    /// one). Same reasoning as `rotationDegrees`.
    public var colourProfilePath: String?

    public init(
        modeNumber: Int32? = nil,
        refreshRate: Double? = nil,
        brightness: Double? = nil,
        activePresetIndex: Int? = nil,
        isHDRModeEnabled: Bool? = nil,
        isMain: Bool? = nil,
        rotationDegrees: Int? = nil,
        colourProfilePath: String? = nil
    ) {
        self.modeNumber = modeNumber
        self.refreshRate = refreshRate
        self.brightness = brightness
        self.activePresetIndex = activePresetIndex
        self.isHDRModeEnabled = isHDRModeEnabled
        self.isMain = isMain
        self.rotationDegrees = rotationDegrees
        self.colourProfilePath = colourProfilePath
    }

    private static let log = Logger(subsystem: "dev.fisifla.fbd", category: "DisplayStateSnapshot")

    // MARK: - Capture

    /// Read everything observable about `display`: its current mode + refresh
    /// rate + brightness + active preset + HDR state + main status, plus what
    /// FBD itself last applied (rotation, colour profile — neither can be read
    /// back from the display).
    ///
    /// MainActor because it reads `DisplayController`'s brightness.
    @MainActor
    public static func capture(
        for display: Display,
        resolution: ResolutionController,
        controller: any DisplayControlling
    ) -> DisplayStateSnapshot {
        let mode = resolution.currentMode(for: display)
        return DisplayStateSnapshot(
            modeNumber: mode?.modeNumber,
            refreshRate: mode?.refreshRate,
            brightness: display.brightness ?? controller.getBrightness(for: display),
            activePresetIndex: display.activePresetIndex,
            isHDRModeEnabled: display.isHDRModeCapable ? display.isHDRModeEnabled : nil,
            isMain: CGDisplayIsMain(display.id) != 0,
            rotationDegrees: Settings.storedRotation(for: display.identityKey),
            colourProfilePath: Settings.storedColourProfile(for: display.identityKey)
        )
    }

    // MARK: - Apply

    /// Re-apply `properties` to `display`, skipping any the display no longer
    /// exposes: mode first (via `ResolutionController.applyMode`), then the
    /// preset, HDR mode and main status, then rotation and the colour profile,
    /// then brightness last.
    ///
    /// Every step is individually guarded, so a display that lost a capability
    /// cannot be driven into an invalid state — the caller passes the
    /// already-narrowed selection (`ProtectedProperties.available(for:)`).
    ///
    /// - Parameter brightnessDelay: how long to wait before setting brightness,
    ///   so a mode switch can settle first. 0 sets it immediately, which is
    ///   what an on-demand preset apply wants; a reconnect passes a small delay.
    @MainActor
    public func apply(
        to display: Display,
        properties: ProtectedProperties,
        resolution: ResolutionController,
        controller: any DisplayControlling,
        brightnessDelay: TimeInterval = 0
    ) {
        if properties.contains(.resolution) {
            if let modeNumber = modeNumber,
               let mode = resolution.modes(for: display).first(where: { $0.modeNumber == modeNumber }) {
                resolution.applyMode(mode, to: display)
                Self.log.info("applied mode \(modeNumber) for \(display.identityKey)")
            }
        } else if properties.contains(.refreshRate), let hz = refreshRate, hz > 0 {
            // Only the refresh rate is applied: prefer the saved rate rather
            // than a specific mode, which need not still be offered.
            resolution.setRefreshRate(hz, for: display)
            Self.log.info("applied refresh rate \(hz) for \(display.identityKey)")
        }

        if properties.contains(.preset),
           let index = activePresetIndex,
           display.isXDRCapable,
           display.presets.indices.contains(index) {
            if !controller.selectPreset(index, on: display) {
                Self.log.warning("apply: preset \(index) refused for \(display.identityKey)")
            }
        }

        if properties.contains(.hdrMode), let enabled = isHDRModeEnabled, display.isHDRModeCapable {
            _ = controller.setHDRMode(enabled, on: display)
        }

        if properties.contains(.mainStatus), isMain == true, CGDisplayIsMain(display.id) == 0 {
            _ = controller.setAsMainDisplay(display)
        }

        if properties.contains(.rotation), let degrees = rotationDegrees {
            if controller.setRotation(degrees, on: display) == nil {
                Self.log.warning("apply: rotation \(degrees) refused for \(display.identityKey)")
            }
        }

        if properties.contains(.colourProfile),
           let path = colourProfilePath,
           !path.isEmpty {
            if !ColorProfileController().applyProfile(URL(fileURLWithPath: path), for: display) {
                Self.log.warning("apply: colour profile \(path) refused for \(display.identityKey)")
            }
        }

        if properties.contains(.brightness), let brightness {
            applyBrightness(brightness, to: display, controller: controller, delay: brightnessDelay)
        }
    }

    /// Set brightness, optionally after `delay` so a mode switch settles. With
    /// no delay the write happens synchronously on the MainActor; with one it is
    /// deferred and the display is re-resolved by id, since the caller's
    /// `Display` may be gone by then.
    @MainActor
    private func applyBrightness(
        _ brightness: Double,
        to display: Display,
        controller: any DisplayControlling,
        delay: TimeInterval
    ) {
        guard delay > 0 else {
            _ = controller.setBrightness(brightness, on: display)
            return
        }
        let displayID = display.id
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in
                guard let display = controller.display(withID: displayID) else { return }
                _ = controller.setBrightness(brightness, on: display)
            }
        }
    }
}
