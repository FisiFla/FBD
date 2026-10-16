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

/// The full-screen overlay surface (software brightness boost and dim). @MainActor —
/// callers must hop to the main thread (see `withOverlay`).
@MainActor
public protocol OverlayControlling: AnyObject {
    @discardableResult func setSoftwareBoost(_ factor: Double, displayID: CGDirectDisplayID) -> Bool

    /// Set the software *brightness* dim: `factor` 1 is undimmed, 0 is fully dimmed. Returns
    /// whether the request could be carried out at all — false only when the display has no
    /// usable geometry, which is the caller's signal to keep the hardware route.
    @discardableResult func setSoftwareDim(_ factor: Double, displayID: CGDirectDisplayID) -> Bool

    /// Whether a dim set through this surface is still in force afterwards.
    ///
    /// The dim is a window owned by this process, so it lives exactly as long as the process
    /// does. The app's overlay persists and can hold a brightness level; a one-shot `fbdcli`
    /// invocation would dim the screen for a tenth of a second and then vanish, which from the
    /// user's side is the command silently failing. A surface that says no here keeps the
    /// caller on the hardware route it has always used rather than accepting a write that will
    /// not last.
    var softwareDimPersists: Bool { get }
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
    /// Optional injected brightness-model profile. `nil` (the default) means
    /// "use the stored global preferences" — see `effectivePreferences`.
    private let injectedPreferences: BrightnessPreferences?
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "CombinedBrightness")

    /// The brightness-model profile the route decision runs under: the
    /// injected profile when one was supplied, otherwise the stored global
    /// preferences (`Settings.brightnessPreferences`, itself `.standard` when
    /// unset). Passing `.standard` (or nothing) reproduces the legacy route.
    public var effectivePreferences: BrightnessPreferences {
        injectedPreferences ?? Settings.brightnessPreferences
    }

    public init(
        apple: AppleControlling,
        ddc: DDCControlling,
        xdr: XDRUpscaling,
        overlay: OverlayControlling,
        preferences: BrightnessPreferences? = nil
    ) {
        self.apple = apple
        self.ddc = ddc
        self.xdr = xdr
        self.overlay = overlay
        self.injectedPreferences = preferences
    }

    // MARK: - Interface

    /// Current brightness 0…1 on the combined curve. When an upscale is
    /// active (native or software boost) the upscale target is reported as a
    /// fraction of `maxNits`; otherwise the hardware brightness.
    /// Current brightness 0…1 on the combined curve — what the **screen** shows, not just what
    /// the backlight is doing. When an upscale is active (native or software boost) the upscale
    /// target is reported as a fraction of `maxNits`; otherwise the hardware brightness. Either
    /// way the software dim in force multiplies in, because a read that disagrees with the
    /// screen is the bug this class documents having fixed once already.
    ///
    /// Nil still means "no control path", exactly as before.
    public func get(for display: Display) -> Double? {
        let dim = min(max(display.softwareDim, 0), 1)
        if isCombinedCapable(for: display), display.isXDRUpscaled,
           let target = display.xdrUpscaleTargetNits ?? xdr.upscaleTarget(for: display) {
            let top = maxNits(for: display)
            guard top > 0 else { return nil }
            return min(max(Double(target) / Double(top), 0), 1) * dim
        }
        guard let hardware = hardwareBrightness(for: display) else { return nil }
        return min(max(hardware * dim, 0), 1)
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
            softwareEnabled: Settings.softwareUpscalingEnabled,
            preferences: effectivePreferences
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

            if let route = dimRoute(value: clamped, on: display) {
                applySoftwareDim(route.dim, on: display)
                guard let hardware = route.hardware else { return true }
                return setHardwareBrightness(hardware, on: display)
            }
            // No dim in play: release any a previous route applied, so the screen cannot stay
            // dimmed after whatever dimmed it has gone.
            applySoftwareDim(1, on: display)
            return setHardwareBrightness(fraction, on: display)
        case .nativeUpscale(let nits):
            // XDRNativeController updates the display state on success. The curve's ceiling
            // applies here as well as to the software boost: `upscaleMaxPercent` says how far
            // past the hardware ceiling an upscale may reach, and the native path is usually
            // the one doing it. A preference may only tighten the model.
            //
            // Above the ceiling the curve keeps dimming off, and a boost and a dim would fight
            // each other, so any dim the dimming zone applied is released here.
            applySoftwareDim(1, on: display)
            let target = cappedUpscaleNits(nits, ceiling: Double(hardwareMax))
            if xdr.setUpscaleTarget(target, for: display) {
                return true
            }
            // Native preset write failed (write-protected slots on macOS 27): drive the same
            // request through the software boost so slider drags above the ceiling still work.
            guard Settings.softwareUpscalingEnabled, hardwareMax > 0, target > hardwareMax else {
                return false
            }
            log.warning("set: native XDR write failed for \(display.id); using software boost")
            let factor = boostFactor(from: Double(target) / Double(hardwareMax), value: clamped, ceiling: Double(hardwareMax))
            let ok = withOverlay { $0.setSoftwareBoost(factor, displayID: display.id) }
            if ok {
                display.updateSoftwareBoost(true, targetNits: target)
            }
            return ok
        case .softwareBoost(let factor):
            log.warning("set: native XDR upscaling unavailable for \(display.id); using software boost")
            // A boost brightens and a dim darkens: they would fight, so the dim goes.
            applySoftwareDim(1, on: display)
            let boost = boostFactor(from: factor, value: clamped, ceiling: Double(hardwareMax))
            let ok = withOverlay { $0.setSoftwareBoost(boost, displayID: display.id) }
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
            softwareEnabled: Settings.softwareUpscalingEnabled,
            preferences: effectivePreferences
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
    /// The display's native brightness ceiling in nits — its hardware maximum,
    /// with no upscaling. Public so group sync can map brightness by luminance
    /// rather than by raw slider position.
    public func hardwareCeilingNits(for display: Display) -> Int {
        hardwareMaxNits(for: display)
    }

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
    /// Apply the software dim the route asks for, recording it so a read agrees with the screen.
    /// A factor of 1 releases it.
    @discardableResult
    private func applySoftwareDim(_ factor: Double, on display: Display) -> Bool {
        let carried = withOverlay { $0.setSoftwareDim(factor, displayID: display.id) }
        display.updateSoftwareDim(carried ? factor : 1)
        return carried
    }

    /// Whether a dim is worth routing to here: it has to be a surface that outlives the call.
    /// Outside the app the overlay is transient, so the route keeps to hardware rather than
    /// accepting a write that would vanish.
    private func softwareDimIsUsable(on display: Display) -> Bool {
        withOverlay { $0.softwareDimPersists }
    }

    /// The `(hardware, dim)` pair a request maps to when a dim is in play, or nil to use the
    /// planner's hardware fraction unchanged.
    ///
    /// Two cases put a dim in play, and both are opt-in:
    ///
    /// - the curve's **dimming zone**, when the profile carries one of its knobs — there the
    ///   model ramps the hardware *and* dims the rest, so both halves are applied;
    /// - **prefer software brightness**, where the dim does the work so the slider is not on the
    ///   hardware write path. A dim can only *lower* what the screen shows, so a request above
    ///   the current backlight still needs the hardware, and returning nil says so.
    ///
    /// With the shipped profile and no preference set, this returns nil — which is what keeps
    /// the default route byte-for-byte what it was.
    private func dimRoute(
        value: Double,
        on display: Display
    ) -> (hardware: Double?, dim: Double)? {
        guard softwareDimIsUsable(on: display) else { return nil }
        let profile = effectivePreferences.clamped()
        let standard = BrightnessPreferences.standard

        let curveKnobMoved = profile.minHardwarePercent != standard.minHardwarePercent
            || profile.softwareZeroPercent != standard.softwareZeroPercent
            || profile.dimmingSwitchoverPercent != standard.dimmingSwitchoverPercent
        let ceiling = Double(hardwareMaxNits(for: display))
        if curveKnobMoved, ceiling > 0 {
            let curve = BrightnessCurve.evaluate(value, preferences: profile, hardwareCeiling: ceiling)
            // `< 1` is exactly the dimming zone: the upscaling zone keeps dimming off.
            guard curve.softwareDim < 1 else { return nil }
            return (hardware: curve.hardware, dim: curve.softwareDim)
        }

        guard !profile.preferHardwareControl else { return nil }
        let current = hardwareBrightness(for: display) ?? 1
        guard current > 0 else { return nil }
        let dim = min(max(value / current, 0), 1)
        // Asked for more than the backlight gives: only the hardware can deliver that.
        guard dim < 1 else { return nil }
        return (hardware: nil, dim: dim)
    }

    /// The curve's `upscaleMaxPercent` applied to a nits target, or the target unchanged
    /// when the profile carries no curve knob.
    ///
    /// `upscaleMaxPercent` is a multiple of the *hardware* ceiling — 320 means "up to 3.2×
    /// the ceiling" — so the cap is that multiple of the ceiling, never above the target
    /// already asked for.
    private func cappedUpscaleNits(_ nits: Int, ceiling: Double) -> Int {
        let profile = effectivePreferences.clamped()
        guard profile.upscaleMaxPercent != BrightnessPreferences.standard.upscaleMaxPercent,
              ceiling > 0 else {
            return nits
        }
        let cap = ceiling * profile.upscaleMaxPercent / 100
        guard cap.isFinite, cap > 0 else { return nits }
        return min(nits, Int(cap.rounded()))
    }

    /// The software-boost factor for a slider value.
    ///
    /// Normally the planner's own factor. When the profile carries a knob the linear model
    /// has no notion of — `upscaleMaxPercent` or `dimmingSwitchoverPercent` — the boost
    /// follows `BrightnessCurve`'s upscaling ramp instead, which is where those two live.
    /// That is the call site the curve was written for and never had: four labelled sliders
    /// in Settings shaped nothing at all before this.
    ///
    /// Only the boost path takes it. The curve's *dimming* zone wants a software dim (a
    /// hardware ramp plus an overlay dim), and this process does not track software
    /// brightness — `get` would then report a value the screen is not showing, which is the
    /// read-back disagreement this class exists to fix. See the gap-matrix row.
    private func boostFactor(from plannerFactor: Double, value: Double, ceiling: Double) -> Double {
        let profile = effectivePreferences.clamped()
        let standard = BrightnessPreferences.standard
        guard profile.upscaleMaxPercent != standard.upscaleMaxPercent
            || profile.dimmingSwitchoverPercent != standard.dimmingSwitchoverPercent else {
            return plannerFactor
        }
        let curve = BrightnessCurve.evaluate(value, preferences: profile, hardwareCeiling: ceiling)
        return max(curve.upscaleFactor, 1)
    }

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
    /// Marked discardable: several callers invoke it purely for the side effect.
    @discardableResult
    private func withOverlay<T>(_ body: @MainActor (OverlayControlling) -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body(overlay) }
        }
        log.warning("withOverlay called off the main thread; hopping synchronously")
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body(overlay) } }
    }
}
