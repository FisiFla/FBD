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
/// - `sharpness` — unsharp-mask amount (0 = none), capped at `maxSharpness`.
/// - `unsharpRadius` — unsharp-mask radius in source pixels; only meaningful
///   when `sharpness > 0`.
/// - `zoom` — magnification, 1 = none. Deliberately clamped to ≥ 1: zooming
///   out would drag the clamp-to-edge sampler into view as smeared borders.
/// - `offsetX` / `offsetY` — pan in normalised display units (0 = centred),
///   clamped so the zoomed viewport can never leave the source image.
/// - `lutPath` — path to a `.cube` 3D LUT applied last; `nil` = none.
///
/// The four newer groups are clamped **in the initialiser**, so no caller —
/// CLI, HTTP, UI or App Intent — can hand the shader a value outside its
/// domain. `brightness`/`contrast`/`saturation`/`gamma`/`temperature` are left
/// unclamped because their useful ranges are open (the boost is just
/// `brightness > 1`).
public struct ScreenFilterParams: Equatable, Sendable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var gamma: Double
    public var temperature: Double
    public var invert: Bool
    public var sharpness: Double
    public var unsharpRadius: Double
    public var zoom: Double
    public var offsetX: Double
    public var offsetY: Double
    public var lutPath: String?

    /// Ceiling for `sharpness` (BetterDisplay 5.0.6 raised its own 2 → 10).
    public static let maxSharpness: Double = 10
    /// Ceiling for the unsharp radius, in source pixels (BD: 10 → 25).
    public static let maxUnsharpRadius: Double = 25
    /// Ceiling for `zoom`.
    public static let maxZoom: Double = 8

    public init(
        brightness: Double = 1,
        contrast: Double = 1,
        saturation: Double = 1,
        gamma: Double = 1,
        temperature: Double = 1,
        invert: Bool = false,
        sharpness: Double = 0,
        unsharpRadius: Double = 1,
        zoom: Double = 1,
        offsetX: Double = 0,
        offsetY: Double = 0,
        lutPath: String? = nil
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.gamma = gamma
        self.temperature = temperature
        self.invert = invert
        self.sharpness = min(max(sharpness, 0), Self.maxSharpness)
        self.unsharpRadius = min(max(unsharpRadius, 0), Self.maxUnsharpRadius)
        let clampedZoom = min(max(zoom, 1), Self.maxZoom)
        self.zoom = clampedZoom
        // Half the margin the zoomed viewport leaves around the source.
        let limit = (1 - 1 / clampedZoom) / 2
        self.offsetX = min(max(offsetX, -limit), limit)
        self.offsetY = min(max(offsetY, -limit), limit)
        self.lutPath = lutPath
    }

    /// True when every parameter is neutral (no visible effect).
    public var isNeutral: Bool {
        brightness == 1 && contrast == 1 && saturation == 1
            && gamma == 1 && temperature == 1 && !invert
            && sharpness == 0 && zoom == 1
            && offsetX == 0 && offsetY == 0 && lutPath == nil
    }

    public static let neutral = ScreenFilterParams()
}
