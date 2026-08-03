import Foundation

/// Full-screen software image-adjustment parameters applied by the SCK+Metal
/// overlay (the same pipeline as the XDR software boost).
///
/// Semantics:
/// - `brightness` — multiplier (1 = none; >1 brightens, matching the boost).
/// - `contrast` — around 0.5 (1 = none).
/// - `saturation` — 0 = grayscale, 1 = none, >1 = more vivid.
/// - `gamma` — output gamma (1 = none; <1 brightens shadows, >1 deepens).
/// - `temperature` — white balance: 1 = neutral, <1 warmer (more red),
///   >1 cooler (more blue).
/// - `invert` — invert RGB (negative image).
public struct ScreenFilterParams: Equatable, Sendable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var gamma: Double
    public var temperature: Double
    public var invert: Bool

    public init(
        brightness: Double = 1,
        contrast: Double = 1,
        saturation: Double = 1,
        gamma: Double = 1,
        temperature: Double = 1,
        invert: Bool = false
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.gamma = gamma
        self.temperature = temperature
        self.invert = invert
    }

    /// True when every parameter is neutral (no visible effect).
    public var isNeutral: Bool {
        brightness == 1 && contrast == 1 && saturation == 1
            && gamma == 1 && temperature == 1 && !invert
    }

    public static let neutral = ScreenFilterParams()
}
