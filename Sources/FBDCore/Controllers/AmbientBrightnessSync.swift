import Foundation

/// Keeps an external display's brightness in step with the built-in display's
/// ambient-sensor brightness.
///
/// An external monitor has no ambient sensor of its own, so the only way for
/// it to follow the room's light is to follow the built-in panel, which does.
/// The mapping goes through **nits**: a 0…1 slider value is a fraction of
/// *that display's own* ceiling, so copying the fraction across two panels
/// with different ceilings leaves them wildly different in absolute
/// brightness. The source's fraction times its ceiling is the luminance being
/// asked for; dividing that by the target's ceiling re-expresses it as the
/// target's own fraction.
public enum AmbientBrightnessSync {
    /// The displays that follow the source.
    ///
    /// The source is never one of them — a display cannot follow itself — and
    /// a display the user did not opt in is never driven, whatever the
    /// sensor says.
    public static func targets(
        source: Display,
        candidates: [Display],
        followers: [String]
    ) -> [Display] {
        candidates.filter { $0.id != source.id && followers.contains($0.identityKey) }
    }

    /// The fraction the target should be at to match the source's luminance.
    ///
    /// Clamped to 0…1: a source brighter than the target's ceiling asks for
    /// more light than the target can give, and the target is asked for all of
    /// it rather than for a value outside its own scale.
    ///
    /// Nil when a ceiling is unknown (nil, or not positive): the mapping is a
    /// division, and a display whose luminance could not be read must not be
    /// driven by a guess.
    public static func targetFraction(
        sourceFraction: Double,
        sourceCeilingNits: Int?,
        targetCeilingNits: Int?
    ) -> Double? {
        guard let sourceCeiling = sourceCeilingNits, sourceCeiling > 0,
              let targetCeiling = targetCeilingNits, targetCeiling > 0 else {
            return nil
        }
        let source = min(max(sourceFraction, 0), 1)
        let nits = source * Double(sourceCeiling)
        return min(max(nits / Double(targetCeiling), 0), 1)
    }

    /// Whether a write is worth the bus transaction.
    ///
    /// The ambient sensor reports small changes; writing every one of them
    /// would keep the display's DDC bus busy for differences nobody can see.
    /// `epsilon` is a fraction of the scale (2 % by default). A target whose
    /// current brightness is unknown is written — a missing reading is not a
    /// reason to skip the request.
    public static func shouldWrite(current: Double?, target: Double, epsilon: Double = 0.02) -> Bool {
        guard let current else { return true }
        return abs(current - target) > max(epsilon, 0)
    }
}
