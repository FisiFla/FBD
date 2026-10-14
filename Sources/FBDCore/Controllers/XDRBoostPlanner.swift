import CoreGraphics
import Foundation

/// Pure decision logic for XDR-capable brightness requests, shared by the
/// combined slider path and the explicit `xdr` command. Encodes the macOS 27
/// fallback chain: native preset upscaling first, software boost overlay as
/// the fallback, and the rule that any hardware (below-ceiling) outcome
/// stops an active overlay boost (the overlay does not set `isXDRUpscaled`,
/// so without this the screen could stay brightened after dragging below
/// the ceiling).
public enum XDRBoostPlanner {
    public enum Plan: Equatable {
        /// Hardware brightness fraction; the overlay is ALWAYS stopped
        /// (idempotent) — this is what keeps below-ceiling drags from
        /// leaving a stale boost active.
        case hardware(fraction: Double)
        /// Native preset upscaling to a nits target.
        case nativeUpscale(nits: Int)
        /// Software boost overlay at a brightness multiplier.
        case softwareBoost(factor: Double)
        /// Native unavailable, software disabled (or no headroom).
        case fail
    }

    /// Plan the route for a 0…1 slider value (or a direct nits target) on a
    /// display with the given ceilings and capability flags.
    ///
    /// The optional `preferences` input is additive and behaviour-preserving:
    /// when it is `nil` or a non-standard profile is not supplied, the plan is
    /// computed from the caller-supplied ceilings exactly as before. When a
    /// non-standard profile is passed, its `hdrPeakHDRNits` and
    /// `hardwareMaxNits` cap the top and hardware ceilings — a preference can
    /// only *tighten* the model, never raise it above the display's real
    /// limits.
    public static func plan(
        value: Double,
        maxNits: Int,
        hardwareMaxNits: Int,
        nativeAvailable: Bool,
        softwareEnabled: Bool,
        preferences: BrightnessPreferences? = nil
    ) -> Plan {
        let clamped = min(max(value, 0), 1)

        var top = Double(max(maxNits, 0))
        var hardware = Double(max(hardwareMaxNits, 1))
        if let profile = preferences?.clamped(), profile != BrightnessPreferences.standard {
            top = Double(max(min(maxNits, Int(profile.hdrPeakHDRNits.rounded())), 0))
            hardware = Double(max(min(hardwareMaxNits, Int(profile.hardwareMaxNits.rounded())), 1))
        }

        guard top > 0, hardware > 0 else { return .fail }
        let nits = clamped * top

        // Below the hardware ceiling: hardware, and stop any overlay boost.
        if nits <= hardware || top <= hardware {
            return .hardware(fraction: min(max(nits / hardware, 0), 1))
        }

        let target = Int(nits.rounded())
        if nativeAvailable {
            return .nativeUpscale(nits: target)
        }
        guard softwareEnabled else { return .fail }
        let factor = nits / hardware
        guard factor > 1 else { return .fail }
        return .softwareBoost(factor: factor)
    }

    /// Plan for an explicit nits target (the `xdr <id> <nits>` command):
    /// native first, software fallback, both gated on availability.
    ///
    /// As with the slider overload, the optional `preferences` input is
    /// additive: `nil` reproduces the legacy plan, while a non-standard
    /// profile caps the target at its `hdrPeakHDRNits` and the hardware
    /// ceiling at its `hardwareMaxNits`.
    public static func plan(
        nits: Int,
        hardwareMaxNits: Int,
        nativeAvailable: Bool,
        softwareEnabled: Bool,
        preferences: BrightnessPreferences? = nil
    ) -> Plan {
        guard nits > 0 else { return .fail }

        var hardware = Double(max(hardwareMaxNits, 1))
        var target = nits
        if let profile = preferences?.clamped(), profile != BrightnessPreferences.standard {
            hardware = Double(max(min(hardwareMaxNits, Int(profile.hardwareMaxNits.rounded())), 1))
            target = min(nits, Int(profile.hdrPeakHDRNits.rounded()))
        }

        guard target > 0 else { return .fail }
        guard hardware > 0 else { return .fail }
        if nativeAvailable {
            return .nativeUpscale(nits: target)
        }
        guard softwareEnabled else { return .fail }
        let factor = Double(target) / hardware
        guard factor > 1 else { return .fail }
        return .softwareBoost(factor: factor)
    }
}
