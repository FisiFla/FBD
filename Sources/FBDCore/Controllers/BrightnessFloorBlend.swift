import Foundation

/// The below-floor brightness blend.
///
/// A monitor's DDC brightness scale rarely reaches black: the panel's own floor
/// sits a good way above zero, so the bottom of the slider is a dead zone —
/// the knob moves, the screen does not.
///
/// The blend splits the slider in two: above the threshold the hardware
/// carries the brightness exactly as before; below it the hardware is pinned
/// at the threshold and the software layer carries the rest as a
/// multiplicative dim. The screen then reaches what the user asked for at the
/// bottom of the slider instead of stopping at the panel's floor.
///
/// Two properties matter, and both are tested:
///
/// - **Continuity.** The effective brightness is the slider value on both
///   sides of the threshold, so dragging through it does not produce a
///   visible band.
/// - **Honest read-back.** While the blend is in force the hardware is
///   pinned, so a hardware read alone reports the floor — "25 %" when the user
///   asked for 0 %. `reconstructSlider(hardwareReadBack:softwareFactor:)`
///   turns the pair back into the logical slider position, and it takes the
///   software factor — the one piece of state that says the blend is in
///   force — as its signal, not the hardware read.
///
/// The whole model is pure: no display, no settings, no overlay. The
/// persistence lives in `Settings`, the wiring in `CombinedBrightness`.
public struct BrightnessFloorBlend: Equatable, Codable, Sendable {
    /// The default threshold: the fraction of the hardware scale at or below
    /// which the software layer carries the brightness.
    public static let defaultThreshold: Double = 0.15

    /// The threshold as a fraction of the hardware brightness scale (0…1).
    ///
    /// This is a fraction of the *hardware* scale (the DDC scale for an
    /// external display), not of the combined slider: the floor is a property
    /// of the panel, and the panel's scale is what runs out.
    public var threshold: Double

    /// Whether the blend is active.
    public var isEnabled: Bool

    /// The lowest effective luminance the hardware reaches, as a fraction of
    /// its scale. 0 = unknown.
    ///
    /// When known, the effective threshold never drops below it: blending
    /// *above* the floor would leave a step in the curve.
    public var hardwareFloor: Double

    public init(
        threshold: Double = BrightnessFloorBlend.defaultThreshold,
        isEnabled: Bool = false,
        hardwareFloor: Double = 0
    ) {
        self.threshold = Self.clamp01(threshold)
        self.isEnabled = isEnabled
        self.hardwareFloor = Self.clamp01(hardwareFloor)
    }

    /// The threshold the curve actually uses.
    public var effectiveThreshold: Double {
        max(Self.clamp01(threshold), Self.clamp01(hardwareFloor))
    }

    /// The result of mapping one slider position onto the two layers.
    public struct Output: Equatable, Sendable {
        /// The value the hardware should be set to, or nil when the hardware
        /// must be left alone entirely (HDR).
        public let hardware: Double?

        /// The multiplicative factor the software layer should apply:
        /// 1 = no software dim.
        public let factor: Double
    }

    /// Map a brightness value onto the hardware write and the software factor.
    ///
    /// - Parameters:
    ///   - value: the requested brightness on the hardware scale (0…1).
    ///   - hdrActive: whether the display is in HDR mode.
    public func evaluate(_ value: Double, hdrActive: Bool = false) -> Output {
        let request = Self.clamp01(value)
        guard isEnabled else {
            // The blend is off: the hardware carries the request on its own,
            // exactly as it did before the blend existed.
            return Output(hardware: request, factor: 1)
        }
        if hdrActive {
            // In HDR the DDC brightness scale does not describe the panel's
            // luminance, so passing the request through to the hardware is
            // wrong: the whole range goes to the software layer and the
            // hardware is left alone.
            return Output(hardware: nil, factor: request)
        }
        let threshold = effectiveThreshold
        guard threshold > 0 else {
            // No band to blend, and dividing by zero is not an option.
            return Output(hardware: request, factor: 1)
        }
        if request >= threshold {
            return Output(hardware: request, factor: 1)
        }
        // Below the threshold: the hardware is pinned at the threshold and the
        // software scales it down. The product is the requested value, so the
        // curve is continuous at the handoff.
        return Output(hardware: threshold, factor: request / threshold)
    }

    /// Turn a read-back into the logical brightness position.
    ///
    /// While the blend is in force the hardware sits at the threshold, so the
    /// hardware read alone reports the floor rather than what the user asked
    /// for. The software factor is what carries the difference, so the logical
    /// position is `threshold × factor`.
    ///
    /// **The factor — not the hardware read — says whether the blend is in
    /// force.** The hardware read cannot: while the blend pins the hardware
    /// the read sits at the threshold, a read that has not caught up with the
    /// write yet still shows the old value, and a monitor that moved on
    /// through its own OSD shows a third value. Asking the hardware "is it at
    /// the threshold?" therefore cannot tell *pinned* from *the hardware moved
    /// on* from *the write has not landed yet* — and it answered "the
    /// hardware is the truth" in exactly the case the blend exists for, so
    /// the read-back reported the floor (or a stale value) instead of the
    /// position the user asked for.
    ///
    /// The caller knows whether the blend is in force: it applied the factor,
    /// and a factor of 1 means it is not in force.
    ///
    /// - Parameters:
    ///   - hardwareReadBack: what the hardware reports, when it could be read.
    ///   - softwareFactor: the factor the software layer is applying now; 1
    ///     means the blend is not in force.
    ///   - hdrActive: whether the display is in HDR mode.
    public func reconstructSlider(
        hardwareReadBack: Double?,
        softwareFactor: Double,
        hdrActive: Bool = false
    ) -> Double {
        let factor = Self.clamp01(softwareFactor)
        let hardware = hardwareReadBack.map(Self.clamp01)
        guard isEnabled else {
            // The blend is not in force: the hardware read is the truth.
            return hardware ?? 0
        }
        if hdrActive {
            // In HDR the software factor *is* the brightness.
            return factor
        }
        guard factor < 1 else {
            // The blend is not in force (the factor is neutral): the hardware
            // read is the truth.
            return hardware ?? 0
        }
        let threshold = effectiveThreshold
        guard threshold > 0 else {
            return hardware ?? 0
        }
        // The blend is in force: the hardware is pinned at the threshold and
        // the software factor carries the rest, so the logical position is
        // `threshold × factor` — the position the user asked for.
        return Self.clamp01(threshold * factor)
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 1)
    }
}
