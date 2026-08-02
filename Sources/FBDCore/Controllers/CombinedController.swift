import Foundation
import os

/// Unified brightness surface: hardware (Apple/DDC) below the display's
/// hardware ceiling, native XDR upscaling — or the software boost overlay as
/// a fallback — above it.
///
/// Tier 1 (Settings.combinedBrightnessEnabled off, or no XDR-capable display):
/// exact Apple → DDC routing with no overlay/XDR involvement.
///
/// Plain class (not MainActor); driven from DisplayController on the main
/// thread. OverlayController is @MainActor — CombinedController hops to the
/// main thread for overlay calls.
public final class CombinedController {
    private let apple: AppleController
    private let ddc: DDCController
    private let xdr: XDRNativeController
    private let overlay: OverlayController
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "CombinedController")

    public init(apple: AppleController, ddc: DDCController, xdr: XDRNativeController, overlay: OverlayController) {
        self.apple = apple
        self.ddc = ddc
        self.xdr = xdr
        self.overlay = overlay
    }

    // MARK: - Nits curve

    /// Hardware ceiling in nits: the display's XDR preset slider max
    /// (via display.presets) or 100 fallback.
    public func hardwareMaxNits(for display: Display) -> Int {
        // Exclude FBD upscale slots: their slider ceiling IS the upscale target,
        // so including them would make every drag take the hardware branch and
        // tear down active upscaling.
        display.presets
            .filter { !XDRNativeController.isFBDSlotName($0.name) }
            .map(\.maxSliderBrightness)
            .max() ?? 100
    }

    /// Top of the combined slider: when combined mode + XDR capable →
    /// Settings.xdrUpscaleTargetNits (clamped to the display's HDR ceiling,
    /// exactly like XDRNativeController.setUpscaleTarget clamps), else
    /// hardwareMaxNits.
    public func maxNits(for display: Display) -> Int {
        let hardware = hardwareMaxNits(for: display)
        guard isCombinedCapable(for: display) else { return hardware }
        if let base = display.presets.first(where: { $0.isValid }) {
            return XDRNativeController.clampedTarget(Settings.xdrUpscaleTargetNits, preset: base)
        }
        return max(Settings.xdrUpscaleTargetNits, hardware)
    }

    // MARK: - Brightness

    /// Current brightness 0…1. Tier 1 behavior (Apple → DDC) unless combined
    /// mode is on and the display is XDR-capable, in which case an active
    /// upscale target is reported as a fraction of `maxNits`.
    public func getBrightness(for display: Display) -> Double? {
        if isCombinedCapable(for: display), let target = xdr.upscaleTarget(for: display) {
            let top = maxNits(for: display)
            guard top > 0 else { return nil }
            return min(max(Double(target) / Double(top), 0), 1)
        }
        return hardwareBrightness(for: display)
    }

    /// Set brightness 0…1; the value maps linearly to 0…maxNits nits.
    ///
    /// Below hardwareMaxNits the write goes to hardware (Apple or DDC), and
    /// any active XDR upscaling is removed first so the write lands on the
    /// un-upscaled ceiling (keeping nits = value × maxNits coherent while
    /// descending the slider). Above hardwareMaxNits: native XDR upscaling
    /// via `XDRNativeController.setUpscaleTarget` (clamped) when the display
    /// is capable, falling back to `OverlayController.setSoftwareBoost` when
    /// Settings.softwareUpscalingEnabled.
    ///
    /// When combined mode is off, behavior is exactly Tier 1 (Apple → DDC
    /// routing; no overlay/XDR involvement).
    @discardableResult
    public func setBrightness(_ value: Double, on display: Display) -> Bool {
        let clamped = min(max(value, 0), 1)
        guard isCombinedCapable(for: display) else {
            return setHardwareBrightness(clamped, on: display)
        }

        let top = maxNits(for: display)
        let hardwareMax = hardwareMaxNits(for: display)

        // Shared pure decision logic (also used by the explicit `xdr`
        // command) — see XDRBoostPlanner.
        switch XDRBoostPlanner.plan(
            value: clamped,
            maxNits: top,
            hardwareMaxNits: hardwareMax,
            nativeAvailable: xdr.isAvailable(for: display),
            softwareEnabled: Settings.softwareUpscalingEnabled
        ) {
        case .hardware(let fraction):
            if display.isXDRUpscaled {
                _ = xdr.disableUpscaling(for: display)
            }
            // Stop any software boost overlay: the overlay does not set
            // isXDRUpscaled, so it must be cleared explicitly here.
            withOverlay { $0.setSoftwareBoost(1, displayID: display.id) }
            return setHardwareBrightness(fraction, on: display)
        case .nativeUpscale(let nits):
            return xdr.setUpscaleTarget(nits, for: display)
        case .softwareBoost(let factor):
            log.warning("setBrightness: native XDR upscaling unavailable for \(display.id); using software boost")
            return withOverlay { $0.setSoftwareBoost(factor, displayID: display.id) }
        case .fail:
            return false
        }
    }

    /// Drive the dim-to-black overlay: enabled → fully black (factor 1),
    /// disabled → no dimming (factor 0).
    public func setDimToBlack(_ enabled: Bool, on display: Display) {
        withOverlay { $0.setDimFactor(enabled ? 1 : 0, displayID: display.id) }
    }

    // MARK: - Private

    /// Combined mode requires the setting plus an XDR-capable display
    /// (mirrors the getBrightness contract).
    private func isCombinedCapable(for display: Display) -> Bool {
        guard Settings.combinedBrightnessEnabled, display.isXDRCapable else { return false }
        // Native preset upscaling OR the software overlay fallback (the
        // native path self-tests as unavailable when preset writes are
        // write-protected, e.g. macOS 27 — the overlay must still engage).
        return xdr.isAvailable(for: display) || Settings.softwareUpscalingEnabled
    }

    /// Tier 1 hardware read: Apple path when available, DDC otherwise.
    private func hardwareBrightness(for display: Display) -> Double? {
        if display.appleBrightnessAvailable {
            return apple.getBrightness(for: display)
        }
        return ddc.getFeature(.brightness, for: display)
    }

    /// Tier 1 hardware write: Apple path when available, DDC otherwise.
    private func setHardwareBrightness(_ value: Double, on display: Display) -> Bool {
        let clamped = min(max(value, 0), 1)
        if display.appleBrightnessAvailable {
            apple.setBrightness(clamped, on: display)
            return true
        }
        return ddc.setFeature(.brightness, value: clamped, for: display)
    }

    /// OverlayController is @MainActor; CombinedController is driven from the
    /// main thread (DisplayController). Satisfies the isolation checker on
    /// main and hops defensively when called off main.
    private func withOverlay<T>(_ body: @MainActor (OverlayController) -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body(overlay) }
        }
        log.warning("withOverlay called off the main thread; hopping synchronously")
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body(overlay) } }
    }
}


/// Pure nits→route mapping for the combined brightness curve (unit-tested).
public enum CombinedRoute: Equatable {
    /// Hardware write: 0…1 value against the hardware ceiling.
    case hardware(Double)
    /// Native XDR upscale target in nits (the caller falls back to the
    /// software boost overlay when the XDR route fails or is unavailable).
    case xdr(Int)
}

public enum CombinedRouting {
    /// value 0…1 of the combined slider → concrete control action.
    /// Without XDR headroom (maxNits == hardwareMaxNits) the whole slider
    /// maps to hardware.
    public static func route(
        value: Double,
        hardwareMaxNits: Int,
        maxNits: Int
    ) -> CombinedRoute {
        let clamped = min(max(value, 0), 1)
        let nits = clamped * Double(maxNits)
        let hardware = Double(max(hardwareMaxNits, 1))
        if nits <= hardware || maxNits <= hardwareMaxNits {
            return .hardware(min(max(nits / hardware, 0), 1))
        }
        return .xdr(Int(nits.rounded()))
    }
}
