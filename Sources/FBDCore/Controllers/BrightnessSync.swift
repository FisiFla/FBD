import Foundation

/// Maps brightness between displays by **luminance** rather than by slider
/// position.
///
/// A raw 0…1 slider value is a fraction of *that display's own* ceiling, so
/// copying it between a 1600-nit XDR panel and a 300-nit monitor leaves the two
/// wildly different in absolute brightness — the divergence this exists to fix.
/// Both are made equally bright by going through nits: the value times the
/// source ceiling is the luminance being asked for, and dividing that by the
/// target ceiling re-expresses it as the target's own fraction.
public enum BrightnessSync {
    /// The value on a display with `targetCeilingNits` that produces the same
    /// luminance as `value` does on one with `sourceCeilingNits`. Clamped to 0…1.
    ///
    /// A ceiling of zero means *unknown*, not *black*: the value is passed
    /// through unchanged rather than divided by zero, and rather than treating a
    /// display whose ceiling we could not read as having no brightness at all.
    public static func equivalentValue(
        _ value: Double,
        sourceCeilingNits: Int,
        targetCeilingNits: Int
    ) -> Double {
        let clamped = min(max(value, 0), 1)
        guard sourceCeilingNits > 0, targetCeilingNits > 0 else { return clamped }
        return min(max(nits(clamped, ceilingNits: sourceCeilingNits) / Double(targetCeilingNits), 0), 1)
    }

    /// The luminance, in nits, that a 0…1 value asks for on a display with this
    /// ceiling.
    public static func nits(_ value: Double, ceilingNits: Int) -> Double {
        guard ceilingNits > 0 else { return 0 }
        return min(max(value, 0), 1) * Double(ceilingNits)
    }
}
