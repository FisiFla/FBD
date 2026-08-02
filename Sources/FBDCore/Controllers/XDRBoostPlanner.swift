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
    public static func plan(
        value: Double,
        maxNits: Int,
        hardwareMaxNits: Int,
        nativeAvailable: Bool,
        softwareEnabled: Bool
    ) -> Plan {
        let clamped = min(max(value, 0), 1)
        let top = Double(max(maxNits, 0))
        let hardware = Double(max(hardwareMaxNits, 1))
        guard top > 0, hardware > 0 else { return .fail }
        let nits = clamped * top

        // Below the hardware ceiling: hardware, and stop any overlay boost.
        if nits <= hardware || maxNits <= hardwareMaxNits {
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
    public static func plan(
        nits: Int,
        hardwareMaxNits: Int,
        nativeAvailable: Bool,
        softwareEnabled: Bool
    ) -> Plan {
        guard nits > 0 else { return .fail }
        let hardware = Double(max(hardwareMaxNits, 1))
        guard hardware > 0 else { return .fail }
        if nativeAvailable {
            return .nativeUpscale(nits: nits)
        }
        guard softwareEnabled else { return .fail }
        let factor = Double(nits) / hardware
        guard factor > 1 else { return .fail }
        return .softwareBoost(factor: factor)
    }
}
