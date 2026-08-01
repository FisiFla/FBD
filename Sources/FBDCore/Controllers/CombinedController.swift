import Foundation

/// Combines the Apple (DisplayServices) and DDC/CI brightness paths into one
/// surface. Apple brightness is preferred when available; DDC is the fallback.
///
/// The full combined curve — hardware brightness + software dimming + XDR
/// upscaling for Pro Display XDR — is a Tier 2 feature. Tier 1 picks a single
/// path per display.
public final class CombinedController {
    private let apple: AppleController
    private let ddc: DDCController

    public init(apple: AppleController, ddc: DDCController) {
        self.apple = apple
        self.ddc = ddc
    }

    /// Current brightness 0…1: Apple path first, DDC otherwise.
    public func getBrightness(for display: Display) -> Double? {
        if apple.isAvailable(for: display) {
            return apple.getBrightness(for: display)
        }
        return ddc.getFeature(.brightness, for: display)
    }

    /// Set brightness 0…1 via the Apple path when available, else DDC.
    public func setBrightness(_ value: Double, on display: Display) {
        if apple.isAvailable(for: display) {
            apple.setBrightness(value, on: display)
        } else {
            ddc.setFeature(.brightness, value: value, for: display)
        }
    }
}
