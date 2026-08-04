import CoreGraphics
import Foundation
import os

/// Native XDR upscaling via SkyLight display presets (Tier 2 feature).
///
/// Mechanism (verified on macOS 27, built-in XDR panel): factory presets
/// 0–10 are valid ("Apple XDR Display (P3-1600 nits)" …), indices 11–15 are
/// blank writable slots. Upscaling copies the factory default preset's raw
/// dict, raises the SDR luminance + slider ceiling to the requested nits
/// (`SkyLightAPI.upscaledPresetData`), writes it into a blank slot and
/// activates that slot. Disabling restores the slot's original dict and the
/// pre-upscale active preset.
///
/// Persistence: the target is stored under `Settings.defaults` (the
/// suite-aware accessor) so the app and the CLI read the same plist —
/// `xdrUpscaleTarget.<identityKey>` while upscaling is active. The slot's
/// ORIGINAL dict is kept in memory only (`slotStates`) — after a restart the
/// original blank dict is unknown, so `disableUpscaling` restores whatever the
/// slot currently holds. `refresh` re-applies a persisted target after an app
/// restart when the FBD slot (or a blank slot) survived, and clears the
/// persisted target when a tracked slot was overwritten by the user.
///
/// Plain class; call on the main thread from DisplayController.
public final class XDRNativeController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "XDRNativeController")

    /// Per-display bookkeeping for the slot we rewrote, keyed by `identityKey`.
    private var slotStates: [String: SlotState] = [:]

    private struct SlotState {
        let index: Int
        /// The slot's dict before FBD overwrote it (blank for factory slots).
        let originalData: [String: Any]
        /// Active preset index before upscaling (nil = factory default active).
        let previousActiveIndex: Int?
    }

    public init() {}

    // MARK: - Public API

    /// Populate XDR state on `display` and re-apply a persisted upscale target
    /// after an app restart. Does not post `.fbdDisplayUpdated` (the mutation
    /// methods post it; DisplayController posts `.fbdDisplaysChanged` after
    /// enumeration).
    public func refresh(for display: Display) {
        let presets = SkyLightAPI.presets(for: display.id)
        detectOverwrittenSlot(display, presets: presets)

        let isCapable = presets.contains { $0.isValid }
        let activeIndex = SkyLightAPI.activePresetIndex(for: display.id)
        let activePreset = activeIndex.flatMap { index in presets.first { $0.index == index } }
        let isUpscaled = activePreset.map { Self.isFBDSlotName($0.name) } ?? false
        var targetNits = activePreset.flatMap { Self.upscaleNits(fromPresetName: $0.name) }
            ?? persistedTarget(for: display)

        // Restart case: a target was persisted but no FBD preset is active and
        // this session has not tracked a slot (fresh process). Re-apply when a
        // slot (FBD or blank) is available.
        if slotStates[display.identityKey] == nil,
           let persisted = persistedTarget(for: display), !isUpscaled {
            let hasSlot = presets.contains { Self.isFBDSlotName($0.name) || !$0.isValid }
            if hasSlot {
                if setUpscaleTarget(persisted, for: display) {
                    log.debug("Re-applied persisted XDR upscale target \(persisted) nits on display \(display.id)")
                    return // setUpscaleTarget already updated state and posted
                }
                log.warning("Re-applying persisted XDR upscale target \(persisted) nits failed on display \(display.id)")
            } else {
                log.warning("Persisted XDR upscale target \(persisted) nits but display \(display.id) has no writable slot; clearing")
                clearPersistedTarget(for: display)
                targetNits = nil
            }
        }

        display.updateXDRState(
            presets: presets,
            isXDRCapable: isCapable,
            activePresetIndex: activeIndex,
            isXDRUpscaled: isUpscaled,
            xdrUpscaleTargetNits: targetNits,
            isHDRModeCapable: SkyLightAPI.supportsHDRMode(display.id),
            isHDRModeEnabled: SkyLightAPI.isHDRModeEnabled(display.id)
        )
    }

    /// True when the display has valid Apple presets.
    public func isAvailable(for display: Display) -> Bool {
        display.isXDRCapable || SkyLightAPI.presets(for: display.id).contains { $0.isValid }
    }

    /// Apply native XDR upscaling so the brightness slider ceiling becomes
    /// `nits`. Returns false (and logs) on any SkyLight failure.
    @discardableResult
    public func setUpscaleTarget(_ nits: Int, for display: Display) -> Bool {
        let presets = SkyLightAPI.presets(for: display.id)
        guard let base = basePreset(for: display, presets: presets) else {
            log.warning("setUpscaleTarget: no valid base preset for display \(display.id)")
            return false
        }
        let target = Self.clampedTarget(nits, preset: base)

        // Reuse the existing FBD slot; otherwise take the first blank writable slot.
        let existingFBD = presets.first { Self.isFBDSlotName($0.name) }
        let blank = presets.first { !$0.isValid && $0.isWritable } ?? presets.first { !$0.isValid }
        guard let slot = existingFBD ?? blank else {
            log.warning("setUpscaleTarget: no writable preset slot on display \(display.id)")
            return false
        }

        let key = display.identityKey
        let stateToSave = slotStates[key] ?? SlotState(
            index: slot.index,
            originalData: slot.raw,
            previousActiveIndex: SkyLightAPI.activePresetIndex(for: display.id)
        )

        guard SkyLightAPI.setPresetData(
            SkyLightAPI.upscaledPresetData(from: base.raw, targetNits: target),
            index: slot.index,
            for: display.id
        ) else {
            log.warning("setUpscaleTarget: writing preset slot \(slot.index) failed for display \(display.id)")
            return false
        }

        // Self-test: on macOS 26+ SLSDisplaySetPresetData can silently reject
        // writes (verified empirically on macOS 27 — readback stays unchanged
        // for both valid and blank slots). Detect it so callers can fall back
        // to the software upscaling method instead of reporting success.
        if let written = SkyLightAPI.presets(for: display.id).first(where: { $0.index == slot.index }),
           Self.upscaleNits(fromPresetName: written.name) != target {
            // Name prefix alone is not enough when re-targeting an existing FBD
            // slot: a rejected write would leave the OLD name (still prefixed).
            log.warning("setUpscaleTarget: preset slot \(slot.index) write was rejected (preset writes are write-protected on this macOS version) — native XDR upscaling unavailable, use the software method")
            return false
        }
        guard SkyLightAPI.setActivePreset(slot.index, for: display.id) else {
            log.warning("setUpscaleTarget: activating preset slot \(slot.index) failed for display \(display.id)")
            return false
        }

        slotStates[key] = stateToSave
        Settings.defaults.set(target, forKey: targetKey(for: display))
        // NOTE: state is recorded BEFORE activation on purpose — if activation
        // fails, a later disableUpscaling must restore the slot's original data
        // rather than the FBD dict we just wrote.

        let updatedPresets = SkyLightAPI.presets(for: display.id)
        display.updateXDRState(
            presets: updatedPresets,
            isXDRCapable: updatedPresets.contains { $0.isValid },
            activePresetIndex: SkyLightAPI.activePresetIndex(for: display.id),
            isXDRUpscaled: true,
            xdrUpscaleTargetNits: target,
            isHDRModeCapable: SkyLightAPI.supportsHDRMode(display.id),
            isHDRModeEnabled: SkyLightAPI.isHDRModeEnabled(display.id)
        )
        NotificationCenter.default.post(name: .fbdDisplayUpdated, object: nil, userInfo: ["displayID": display.id])
        log.debug("XDR upscaling enabled at \(target) nits (slot \(slot.index)) on display \(display.id)")
        return true
    }

    /// Remove upscaling: restore the slot's saved dict and the pre-upscale
    /// active preset, then clear the persisted target. Idempotent.
    @discardableResult
    public func disableUpscaling(for display: Display) -> Bool {
        let key = display.identityKey
        var success = true

        if let state = slotStates[key] {
            SkyLightAPI.restorePresetData(state.originalData, index: state.index, for: display.id)
            let previous = state.previousActiveIndex ?? SkyLightAPI.factoryDefaultPresetIndex(for: display.id)
            if !SkyLightAPI.setActivePreset(previous, for: display.id) {
                log.warning("disableUpscaling: restoring active preset \(previous) failed for display \(display.id)")
                success = false
            }
            slotStates[key] = nil
        } else if let activeIndex = SkyLightAPI.activePresetIndex(for: display.id),
                  let active = SkyLightAPI.presets(for: display.id).first(where: { $0.index == activeIndex }),
                  Self.isFBDSlotName(active.name) {
            // Untracked FBD preset (previous session): leave its data, revert to factory.
            _ = SkyLightAPI.setActivePreset(SkyLightAPI.factoryDefaultPresetIndex(for: display.id), for: display.id)
        }

        clearPersistedTarget(for: display)

        let presets = SkyLightAPI.presets(for: display.id)
        let activeIndex = SkyLightAPI.activePresetIndex(for: display.id)
        let activePreset = activeIndex.flatMap { index in presets.first { $0.index == index } }
        display.updateXDRState(
            presets: presets,
            isXDRCapable: presets.contains { $0.isValid },
            activePresetIndex: activeIndex,
            isXDRUpscaled: activePreset.map { Self.isFBDSlotName($0.name) } ?? false,
            xdrUpscaleTargetNits: nil,
            isHDRModeCapable: SkyLightAPI.supportsHDRMode(display.id),
            isHDRModeEnabled: SkyLightAPI.isHDRModeEnabled(display.id)
        )
        NotificationCenter.default.post(name: .fbdDisplayUpdated, object: nil, userInfo: ["displayID": display.id])
        return success
    }

    /// Activate a factory preset by index; leaving the FBD slot disables
    /// upscaling (slot restored, persisted target cleared).
    @discardableResult
    public func selectPreset(_ index: Int, for display: Display) -> Bool {
        let presets = SkyLightAPI.presets(for: display.id)
        let selectingFBD = presets.first { $0.index == index }
            .map { Self.isFBDSlotName($0.name) } ?? false

        if !selectingFBD, slotStates[display.identityKey] != nil || display.isXDRUpscaled {
            _ = disableUpscaling(for: display)
        }

        guard SkyLightAPI.setActivePreset(index, for: display.id) else {
            log.warning("selectPreset: activating preset \(index) failed for display \(display.id)")
            refresh(for: display)
            NotificationCenter.default.post(name: .fbdDisplayUpdated, object: nil, userInfo: ["displayID": display.id])
            return false
        }

        refresh(for: display)
        NotificationCenter.default.post(name: .fbdDisplayUpdated, object: nil, userInfo: ["displayID": display.id])
        return true
    }

    /// Force the HDR framebuffer mode (external HDR displays only).
    @discardableResult
    public func setHDRMode(_ enabled: Bool, for display: Display) -> Bool {
        guard SkyLightAPI.supportsHDRMode(display.id) else {
            log.warning("setHDRMode: display \(display.id) does not support HDR mode")
            return false
        }
        guard SkyLightAPI.setHDRModeEnabled(enabled, displayID: display.id) else {
            log.warning("setHDRMode(\(enabled)) failed for display \(display.id)")
            return false
        }
        display.updateXDRState(
            presets: display.presets,
            isXDRCapable: display.isXDRCapable,
            activePresetIndex: display.activePresetIndex,
            isXDRUpscaled: display.isXDRUpscaled,
            xdrUpscaleTargetNits: display.xdrUpscaleTargetNits,
            isHDRModeCapable: true,
            isHDRModeEnabled: enabled
        )
        NotificationCenter.default.post(name: .fbdDisplayUpdated, object: nil, userInfo: ["displayID": display.id])
        return true
    }

    /// The nits target of the active FBD upscale, if any.
    public func upscaleTarget(for display: Display) -> Int? {
        display.isXDRUpscaled ? display.xdrUpscaleTargetNits : nil
    }

    // MARK: - Pure helpers (unit-tested, no SkyLight)

    /// Clamp an upscale target to the preset's slider range.
    public static func clampedTarget(_ nits: Int, preset: XDRPreset) -> Int {
        min(max(nits, preset.minSliderBrightness), preset.maxHDRLuminance)
    }

    /// Whether a preset name marks an FBD upscale slot.
    public static func isFBDSlotName(_ name: String) -> Bool {
        name.hasPrefix("FBD XDR")
    }

    /// Parse the target from an FBD preset name, e.g. "FBD XDR (1600 nits)" → 1600.
    public static func upscaleNits(fromPresetName name: String) -> Int? {
        guard let open = name.lastIndex(of: "("),
              let close = name.lastIndex(of: ")"),
              open < close else { return nil }
        let inner = name[name.index(after: open)..<close]
        let parts = inner.split(separator: " ")
        guard parts.count == 2, parts[1] == "nits", let nits = Int(parts[0]) else { return nil }
        return nits
    }

    // MARK: - Private

    /// The base preset for upscaling: the factory default preset, falling back
    /// to the first valid preset.
    private func basePreset(for display: Display, presets: [XDRPreset]) -> XDRPreset? {
        let factoryIndex = SkyLightAPI.factoryDefaultPresetIndex(for: display.id)
        if let factory = presets.first(where: { $0.index == factoryIndex }), factory.isValid {
            return factory
        }
        return presets.first { $0.isValid }
    }

    private func persistedTarget(for display: Display) -> Int? {
        Settings.defaults.object(forKey: targetKey(for: display)) as? Int
    }

    private func clearPersistedTarget(for display: Display) {
        Settings.defaults.removeObject(forKey: targetKey(for: display))
    }

    private func targetKey(for display: Display) -> String {
        "xdrUpscaleTarget.\(display.identityKey)"
    }

    /// Drop tracking + persisted target when a slot we wrote was replaced by
    /// the user (its name is no longer FBD) or the slot vanished.
    private func detectOverwrittenSlot(_ display: Display, presets: [XDRPreset]) {
        guard let state = slotStates[display.identityKey] else { return }
        guard let slotPreset = presets.first(where: { $0.index == state.index }) else {
            slotStates[display.identityKey] = nil
            clearPersistedTarget(for: display)
            return
        }
        if !Self.isFBDSlotName(slotPreset.name) {
            log.warning("XDR preset slot \(state.index) on display \(display.identityKey) was overwritten; clearing persisted target")
            slotStates[display.identityKey] = nil
            clearPersistedTarget(for: display)
        }
    }
}
