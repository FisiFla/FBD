import CoreGraphics
import Foundation
import os

// MARK: - Control seams (protocols + conformances)

/// The Apple brightness-control surface (hardware slider / ambient path).
public protocol AppleControlling: AnyObject {
    func getBrightness(for display: Display) -> Double?
    func setBrightness(_ value: Double, on display: Display)
}

extension AppleController: AppleControlling {}

/// The DDC/CI feature surface (brightness, contrast, volume, …).
public protocol DDCControlling: AnyObject {
    func getFeature(_ feature: DDCFeature, for display: Display) -> Double?
    @discardableResult func setFeature(_ feature: DDCFeature, value: Double, for display: Display) -> Bool
}

extension DDCController: DDCControlling {}

/// The native XDR preset-upscaling surface (SkyLight preset writes).
public protocol XDRUpscaling: AnyObject {
    func isAvailable(for display: Display) -> Bool
    @discardableResult func setUpscaleTarget(_ nits: Int, for display: Display) -> Bool
    @discardableResult func disableUpscaling(for display: Display) -> Bool
    func upscaleTarget(for display: Display) -> Int?
}

extension XDRNativeController: XDRUpscaling {}

/// The full-screen overlay surface (software brightness boost). @MainActor —
/// callers must hop to the main thread (see `withOverlay`).
@MainActor
public protocol OverlayControlling: AnyObject {
    @discardableResult func setSoftwareBoost(_ factor: Double, displayID: CGDirectDisplayID) -> Bool
}

extension OverlayController: OverlayControlling {}

// MARK: - The deepened module

/// Combined brightness — the whole "where does this brightness request go?"
/// decision, its execution, and its state sync behind a tiny surface.
///
/// Owns, in one place:
/// - the nits ceiling math (`hardwareMaxNits` / `maxNits`), previously
///   duplicated across `CombinedController` and the hand-written fallback in
///   `DisplayController.setXDRUpscaleTarget`;
/// - the route decision via `XDRBoostPlanner` (the tested pure planner);
/// - the write + fallback chain: native XDR upscaling first, the software
///   boost overlay when native is unavailable *or* the preset write fails
///   (write-protected slots on macOS 27);
/// - the **upscale-state invariant**: after every call returns,
///   `display.isXDRUpscaled` / `xdrUpscaleTargetNits` mirror what is on
///   screen. The pre-deepening combined path never updated the flag on the
///   software-boost or hardware-stop branches, so brightness read-back
///   disagreed with the screen; here every branch syncs after the write
///   succeeds.
public final class CombinedBrightness {
    private let apple: AppleControlling
    private let ddc: DDCControlling
    private let xdr: XDRUpscaling
    private let overlay: OverlayControlling
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "CombinedBrightness")

    public init(
        apple: AppleControlling,
        ddc: DDCControlling,
        xdr: XDRUpscaling,
        overlay: OverlayControlling
    ) {
        self.apple = apple
        self.ddc = ddc
        self.xdr = xdr
        self.overlay = overlay
    }

    // MARK: - Interface

    /// Current brightness 0…1 on the combined curve. When an upscale is
    /// active (native or software boost) the upscale target is reported as a
    /// fraction of `maxNits`; otherwise the hardware brightness.
    public func get(for display: Display) -> Double? {
        if isCombinedCapable(for: display), display.isXDRUpscaled,
           let target = display.xdrUpscaleTargetNits ?? xdr.upscaleTarget(for: display) {
            let top = maxNits(for: display)
            guard top > 0 else { return nil }
            return min(max(Double(target) / Double(top), 0), 1)
        }
        return hardwareBrightness(for: display)
    }

    /// Set brightness 0…1. Below the hardware ceiling the write goes to
    /// hardware (Apple or DDC) and any active upscaling is torn down; above
    /// it, native XDR upscaling — or the software boost overlay as a
    /// fallback. Returns whether a control path engaged; state is synced on
    /// every branch.
    @discardableResult
    public func set(_ value: Double, on display: Display) -> Bool {
        let clamped = min(max(value, 0), 1)
        guard isCombinedCapable(for: display) else {
            return setHardwareBrightness(clamped, on: display)
        }

        let top = maxNits(for: display)
        let hardwareMax = hardwareMaxNits(for: display)

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
            // Stop any software boost overlay (the overlay does not clear
            // the flag, so it must be done here) — below the ceiling,
            // upscaling is off, full stop.
            withOverlay { $0.setSoftwareBoost(1, displayID: display.id) }
            display.updateSoftwareBoost(false, targetNits: nil)
            return setHardwareBrightness(fraction, on: display)
        case .nativeUpscale(let nits):
            // XDRNativeController updates the display state on success.
            return xdr.setUpscaleTarget(nits, for: display)
        case .softwareBoost(let factor):
            log.warning("set: native XDR upscaling unavailable for \(display.id); using software boost")
            let ok = withOverlay { $0.setSoftwareBoost(factor, displayID: display.id) }
            if ok {
                display.updateSoftwareBoost(true, targetNits: Int((Double(top) * clamped).rounded()))
            }
            return ok
        case .fail:
            return false
        }
    }

    /// Explicit upscale target in nits (the `xdr <id> <nits>` command);
    /// `nil` disables upscaling (native teardown + overlay stop + state
    /// off). Native-first with the software overlay fallback on preset-write
    /// failure.
    @discardableResult
    public func setTarget(_ nits: Int?, on display: Display) -> Bool {
        guard let nits else {
            let native = xdr.disableUpscaling(for: display)
            withOverlay { $0.setSoftwareBoost(1, displayID: display.id) }
            display.updateSoftwareBoost(false, targetNits: nil)
            return native
        }

        let hardwareMax = hardwareMaxNits(for: display)
        switch XDRBoostPlanner.plan(
            nits: nits,
            hardwareMaxNits: hardwareMax,
            nativeAvailable: xdr.isAvailable(for: display),
            softwareEnabled: Settings.softwareUpscalingEnabled
        ) {
        case .nativeUpscale(let target):
            if xdr.setUpscaleTarget(target, for: display) {
                return true
            }
            // Native preset write failed (e.g. write-protected preset slots
            // on macOS 27). Fall back to the software boost overlay when it
            // is enabled and the target has headroom above the hardware
            // ceiling — otherwise the explicit `xdr <id> <nits>` command is
            // dead on write-protected systems.
            guard Settings.softwareUpscalingEnabled, hardwareMax > 0, target > hardwareMax else {
                return false
            }
            let ok = withOverlay { $0.setSoftwareBoost(Double(target) / Double(hardwareMax), displayID: display.id) }
            if ok {
                display.updateSoftwareBoost(true, targetNits: target)
            }
            return ok
        case .softwareBoost(let factor):
            // Requires Screen Recording permission (logged by the overlay).
            let ok = withOverlay { $0.setSoftwareBoost(factor, displayID: display.id) }
            if ok {
                display.updateSoftwareBoost(true, targetNits: nits)
            }
            return ok
        case .hardware, .fail:
            return false
        }
    }

    // MARK: - Ceiling math (one copy — `CombinedRouting` deleted)

    /// Hardware ceiling in nits: the display's XDR preset slider max
    /// (via display.presets) or 100 fallback.
    private func hardwareMaxNits(for display: Display) -> Int {
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
    private func maxNits(for display: Display) -> Int {
        let hardware = hardwareMaxNits(for: display)
        guard isCombinedCapable(for: display) else { return hardware }
        if let base = display.presets.first(where: { $0.isValid }) {
            return XDRNativeController.clampedTarget(Settings.xdrUpscaleTargetNits, preset: base)
        }
        return max(Settings.xdrUpscaleTargetNits, hardware)
    }

    // MARK: - Private helpers

    /// Combined mode requires the setting plus an XDR-capable display.
    private func isCombinedCapable(for display: Display) -> Bool {
        guard Settings.combinedBrightnessEnabled, display.isXDRCapable else { return false }
        // Native preset upscaling OR the software overlay fallback (the
        // native path self-tests as unavailable when preset writes are
        // write-protected, e.g. macOS 27 — the overlay must still engage).
        return xdr.isAvailable(for: display) || Settings.softwareUpscalingEnabled
    }

    /// Hardware brightness read: Apple path when available, DDC otherwise.
    private func hardwareBrightness(for display: Display) -> Double? {
        if display.appleBrightnessAvailable {
            return apple.getBrightness(for: display)
        }
        return ddc.getFeature(.brightness, for: display)
    }

    /// Hardware brightness write: Apple path when available, DDC otherwise.
    private func setHardwareBrightness(_ value: Double, on display: Display) -> Bool {
        let clamped = min(max(value, 0), 1)
        if display.appleBrightnessAvailable {
            apple.setBrightness(clamped, on: display)
            return true
        }
        return ddc.setFeature(.brightness, value: clamped, for: display)
    }

    /// OverlayController is @MainActor; CombinedBrightness is driven from the
    /// main thread (DisplayController). Satisfies the isolation checker on
    /// main and hops defensively when called off main.
    private func withOverlay<T>(_ body: @MainActor (OverlayControlling) -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body(overlay) }
        }
        log.warning("withOverlay called off the main thread; hopping synchronously")
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body(overlay) } }
    }
}
