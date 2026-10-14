import Foundation

/// How FBD establishes a display's brightness "control value" when it
/// (re)attaches to it — BetterDisplay's three-way "control values on
/// startup" choice, expressed here as a pure, persisted-free model.
///
/// The default is deliberately fail-closed: FBD does not start *writing* to
/// a device merely because it can. Until the user asks otherwise it assumes
/// the last value is still in place and touches nothing.
public enum StartupControlValuePolicy: String, Codable, CaseIterable {
    /// Assume the device already holds the value the user (or the system)
    /// last left there; neither read nor write it on startup. (Default.)
    case assumeLastUsed
    /// Actively write FBD's chosen value to the device on startup.
    case writeToDevice
    /// Read the current value back from the device on startup.
    case readFromDevice
}

/// BetterDisplay-parity brightness model parameters — the *global*
/// (not per-display) knobs that shape FBD's combined-brightness curve.
///
/// Everything here is a plain value: no `UserDefaults`, no `Display`, no
/// private API. Persistence lives in `Settings.brightnessPreferences`; the
/// mapping itself lives in `BrightnessCurve`.
public struct BrightnessPreferences: Equatable, Codable {
    /// Prefer the display's hardware brightness path (Apple / DDC) over a
    /// software overlay wherever a choice exists.
    public var preferHardwareControl: Bool

    /// Lowest luminance the hardware path is asked to reach, in nits.
    public var hardwareMinNits: Double

    /// Highest luminance the hardware path reaches before upscaling begins,
    /// in nits (the display's no-upscaling ceiling).
    public var hardwareMaxNits: Double

    /// Luminance ceiling of the SDR portion of the combined curve, in nits.
    public var hdrPeakSDRNits: Double

    /// Luminance ceiling of the HDR portion of the combined curve, in nits.
    public var hdrPeakHDRNits: Double

    /// The software brightness (as a percent) that the combined slider's 0%
    /// position maps to — the "redefine 0% software brightness" value. 0 lets
    /// the dimming overlay reach black.
    public var softwareZeroPercent: Double

    /// Floor the hardware path is asked not to drop below, as a percent of
    /// the hardware range. 0 disables the floor.
    public var minHardwarePercent: Double

    /// Combined-curve point (percent of the slider) at which software dimming
    /// hands over to XDR/HDR upscaling. Below it the curve is a hardware +
    /// software-dimming ramp; at/above it, upscaling.
    public var dimmingSwitchoverPercent: Double

    /// Maximum XDR/HDR upscaling the combined curve may reach, as a percent of
    /// the hardware ceiling (100 = no upscaling, 320 = 3.2×).
    public var upscaleMaxPercent: Double

    /// Startup control-value policy — see `StartupControlValuePolicy`.
    public var startupControlValuePolicy: StartupControlValuePolicy

    public init(
        preferHardwareControl: Bool = true,
        hardwareMinNits: Double = 4,
        hardwareMaxNits: Double = 500,
        hdrPeakSDRNits: Double = 500,
        hdrPeakHDRNits: Double = 1600,
        softwareZeroPercent: Double = 0,
        minHardwarePercent: Double = 0,
        dimmingSwitchoverPercent: Double = 50,
        upscaleMaxPercent: Double = 320,
        startupControlValuePolicy: StartupControlValuePolicy = .assumeLastUsed
    ) {
        self.preferHardwareControl = preferHardwareControl
        self.hardwareMinNits = hardwareMinNits
        self.hardwareMaxNits = hardwareMaxNits
        self.hdrPeakSDRNits = hdrPeakSDRNits
        self.hdrPeakHDRNits = hdrPeakHDRNits
        self.softwareZeroPercent = softwareZeroPercent
        self.minHardwarePercent = minHardwarePercent
        self.dimmingSwitchoverPercent = dimmingSwitchoverPercent
        self.upscaleMaxPercent = upscaleMaxPercent
        self.startupControlValuePolicy = startupControlValuePolicy
    }

    /// The shipped defaults. `clamped()` of this value equals itself, so it is
    /// the stable identity the wire-up paths compare against.
    public static let standard = BrightnessPreferences()

    /// A normalised copy: every field is clamped into its allowed span,
    /// non-finite inputs fall back to the `standard` value, and inverted bound
    /// pairs (`hardwareMinNits > hardwareMaxNits`, `hdrPeakSDRNits >
    /// hdrPeakHDRNits`) are swapped so a user can never produce a negative or
    /// empty range. Idempotent: `x.clamped().clamped() == x.clamped()`.
    public func clamped() -> BrightnessPreferences {
        let defaults = BrightnessPreferences.standard
        var result = self

        // Nits fields: finite, non-negative, and the min/max pair reordered.
        var minNits = Self.clamp(hardwareMinNits, 0, Self.maxNits, defaults.hardwareMinNits)
        var maxNits = Self.clamp(hardwareMaxNits, 0, Self.maxNits, defaults.hardwareMaxNits)
        if minNits > maxNits { swap(&minNits, &maxNits) }
        result.hardwareMinNits = minNits
        result.hardwareMaxNits = maxNits

        // SDR/HDR peaks: finite, non-negative, SDR never above HDR.
        var sdr = Self.clamp(hdrPeakSDRNits, 0, Self.maxNits, defaults.hdrPeakSDRNits)
        var hdr = Self.clamp(hdrPeakHDRNits, 0, Self.maxNits, defaults.hdrPeakHDRNits)
        if sdr > hdr { swap(&sdr, &hdr) }
        result.hdrPeakSDRNits = sdr
        result.hdrPeakHDRNits = hdr

        // Percent fields: 0…100.
        result.softwareZeroPercent = Self.clamp(softwareZeroPercent, 0, 100, defaults.softwareZeroPercent)
        result.minHardwarePercent = Self.clamp(minHardwarePercent, 0, 100, defaults.minHardwarePercent)
        result.dimmingSwitchoverPercent = Self.clamp(dimmingSwitchoverPercent, 0, 100, defaults.dimmingSwitchoverPercent)

        // Upscaling is a percent of the hardware ceiling: never below 100
        // (which is a factor of 1 — no upscaling) nor above a sane 1000 (10×).
        result.upscaleMaxPercent = Self.clamp(upscaleMaxPercent, 100, 1000, defaults.upscaleMaxPercent)

        return result
    }

    /// Upper bound for the nits-denominated fields (40 000 nits is well past
    /// any shipping panel; it exists only to bound a hand-edited blob).
    private static let maxNits = 40_000.0

    /// Finite-clamp helper: a non-finite input falls back to `fallback`.
    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double, _ fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, lower), upper)
    }
}

/// The pure mapping behind BetterDisplay's tunable "combined brightness":
/// one 0…1 slider position drives the hardware brightness write, a software
/// dimming overlay, and XDR/HDR upscaling at once.
///
/// The curve has two zones, split at `dimmingSwitchoverPercent`:
///
/// - **Dimming zone** (input below the switchover): the hardware value ramps
///   linearly from `minHardwarePercent` up to full scale, and the software
///   dimming overlay blends in from `softwareZeroPercent` up to full. A
///   slider at 0 therefore lands on a real, configured minimum instead of
///   snapping to black or being pinned by the panel's hardware floor.
/// - **Upscaling zone** (input at/above the switchover): the hardware value is
///   saturated at 1.0 — it reached full scale *at* the switchover, before
///   upscaling begins — and the upscaling factor ramps from 1.0 up to
///   `upscaleMaxPercent`.
///
/// Every output is clamped into range, is monotonic non-decreasing in the
/// input, and can never be negative or NaN.
public struct BrightnessCurve {
    /// The three normalised outputs at one slider position, plus the nits the
    /// hardware write corresponds to.
    public struct Output: Equatable {
        /// Fraction to write on the hardware path (0…1).
        public let hardware: Double
        /// Software dimming overlay level (0…1; 1 = no dimming).
        public let softwareDim: Double
        /// XDR/HDR upscaling factor (>= 1).
        public let upscaleFactor: Double
        /// Luminance the hardware write reaches, in nits.
        public let hardwareNits: Double
    }

    /// Evaluate the curve for a 0…1 slider position.
    ///
    /// - Parameters:
    ///   - input: the combined slider position; clamped to 0…1.
    ///   - preferences: the model parameters; clamped on entry.
    ///   - hardwareCeiling: the display's hardware maximum in nits, used to
    ///     report `hardwareNits`. A non-positive (unknown) value falls back to
    ///     `preferences.hardwareMaxNits`.
    public static func evaluate(
        _ input: Double,
        preferences: BrightnessPreferences = .standard,
        hardwareCeiling: Double = 0
    ) -> Output {
        let prefs = preferences.clamped()
        let s = clamp01(input)

        let switchover = clamp01(prefs.dimmingSwitchoverPercent / 100)
        let hardwareFloor = clamp01(prefs.minHardwarePercent / 100)
        let softwareFloor = clamp01(prefs.softwareZeroPercent / 100)
        let upscaleMax = Swift.max(prefs.upscaleMaxPercent / 100, 1)

        let hardware: Double
        let softwareDim: Double
        let upscaleFactor: Double

        if switchover <= 0 {
            // Degenerate: no dimming zone, the whole slider is upscaling.
            let u = clamp01(s)
            hardware = 1
            softwareDim = 1
            upscaleFactor = 1 + (upscaleMax - 1) * u
        } else if s <= switchover {
            // Dimming zone: t runs 0→1 across the zone.
            let t = clamp01(s / switchover)
            hardware = hardwareFloor + (1 - hardwareFloor) * t
            softwareDim = softwareFloor + (1 - softwareFloor) * t
            upscaleFactor = 1
        } else {
            // Upscaling zone: hardware saturated, dimming off.
            let span = 1 - switchover
            let u = span > 0 ? clamp01((s - switchover) / span) : 1
            hardware = 1
            softwareDim = 1
            upscaleFactor = 1 + (upscaleMax - 1) * u
        }

        // The luminance the hardware write reaches, using the display's
        // ceiling when known and the preference ceiling otherwise.
        let ceiling = (hardwareCeiling.isFinite && hardwareCeiling > 0)
            ? hardwareCeiling
            : prefs.hardwareMaxNits
        let lowNits = Swift.min(prefs.hardwareMinNits, ceiling)
        let highNits = Swift.max(prefs.hardwareMinNits, ceiling)
        let nits = lowNits + (highNits - lowNits) * hardware

        return Output(
            hardware: clamp01(hardware),
            softwareDim: clamp01(softwareDim),
            upscaleFactor: Swift.max(upscaleFactor, 1),
            hardwareNits: nits.isFinite ? Swift.max(nits, 0) : Swift.max(lowNits, 0)
        )
    }

    // MARK: - Nits conversion

    /// Map a 0…1 scale value onto the SDR range
    /// (`hardwareMinNits` … `hdrPeakSDRNits`).
    public static func sdrNits(fromScale value: Double, preferences: BrightnessPreferences = .standard) -> Double {
        let prefs = preferences.clamped()
        return nits(fromScale: value, lower: prefs.hardwareMinNits, upper: prefs.hdrPeakSDRNits)
    }

    /// Map a 0…1 scale value onto the HDR range
    /// (`hardwareMinNits` … `hdrPeakHDRNits`).
    public static func hdrNits(fromScale value: Double, preferences: BrightnessPreferences = .standard) -> Double {
        let prefs = preferences.clamped()
        return nits(fromScale: value, lower: prefs.hardwareMinNits, upper: prefs.hdrPeakHDRNits)
    }

    /// Map a 0…1 scale value onto the hardware range
    /// (`hardwareMinNits` … `hardwareMaxNits`).
    public static func hardwareNits(fromScale value: Double, preferences: BrightnessPreferences = .standard) -> Double {
        let prefs = preferences.clamped()
        return nits(fromScale: value, lower: prefs.hardwareMinNits, upper: prefs.hardwareMaxNits)
    }

    /// Inverse of `sdrNits`.
    public static func sdrScale(fromNits nits: Double, preferences: BrightnessPreferences = .standard) -> Double {
        let prefs = preferences.clamped()
        return scale(fromNits: nits, lower: prefs.hardwareMinNits, upper: prefs.hdrPeakSDRNits)
    }

    /// Inverse of `hdrNits`.
    public static func hdrScale(fromNits nits: Double, preferences: BrightnessPreferences = .standard) -> Double {
        let prefs = preferences.clamped()
        return scale(fromNits: nits, lower: prefs.hardwareMinNits, upper: prefs.hdrPeakHDRNits)
    }

    /// Inverse of `hardwareNits`.
    public static func hardwareScale(fromNits nits: Double, preferences: BrightnessPreferences = .standard) -> Double {
        let prefs = preferences.clamped()
        return scale(fromNits: nits, lower: prefs.hardwareMinNits, upper: prefs.hardwareMaxNits)
    }

    // MARK: - Internals

    private static func nits(fromScale value: Double, lower: Double, upper: Double) -> Double {
        let lo = lower.isFinite ? lower : 0
        let hi = upper.isFinite ? upper : lo
        guard hi > lo else { return Swift.max(lo, 0) }
        return lo + (hi - lo) * clamp01(value)
    }

    private static func scale(fromNits nits: Double, lower: Double, upper: Double) -> Double {
        let lo = lower.isFinite ? lower : 0
        let hi = upper.isFinite ? upper : lo
        guard hi > lo, nits.isFinite else { return 0 }
        return clamp01((nits - lo) / (hi - lo))
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 1)
    }
}
