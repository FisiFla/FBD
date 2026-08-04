import CoreGraphics
import Foundation
import os

/// Apple display brightness control via DisplayServices.framework
/// (built-in and some external displays driven by the WindowServer).
///
/// Plain class (not MainActor): called from DisplayController and CombinedBrightness.
/// All private-API failures degrade to nil/false with a logged warning.
public final class AppleController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "AppleController")

    public init() {}

    /// Whether DisplayServices can change brightness for this display.
    public func isAvailable(for display: Display) -> Bool {
        DisplayServicesAPI.canChangeBrightness(display.id)
    }

    /// Current brightness as a 0…1 fraction (clamped), or nil if unavailable.
    public func getBrightness(for display: Display) -> Double? {
        do {
            let value = try DisplayServicesAPI.getBrightness(display.id)
            return clamp(Double(value))
        } catch {
            log.warning("getBrightness failed for \(display.id): \(error.localizedDescription)")
            return nil
        }
    }

    /// Set brightness; `value` is clamped to 0…1.
    public func setBrightness(_ value: Double, on display: Display) {
        do {
            try DisplayServicesAPI.setBrightness(display.id, Float(clamp(value)))
        } catch {
            log.warning("setBrightness failed for \(display.id): \(error.localizedDescription)")
        }
    }

    /// Linear (physical) brightness 0…1, or nil if unavailable.
    public func getLinearBrightness(for display: Display) -> Double? {
        do {
            let value = try DisplayServicesAPI.getLinearBrightness(display.id)
            return clamp(Double(value))
        } catch {
            log.warning("getLinearBrightness failed for \(display.id): \(error.localizedDescription)")
            return nil
        }
    }

    /// Set linear (physical) brightness; `value` is clamped to 0…1.
    public func setLinearBrightness(_ value: Double, on display: Display) {
        do {
            try DisplayServicesAPI.setLinearBrightness(display.id, Float(clamp(value)))
        } catch {
            log.warning("setLinearBrightness failed for \(display.id): \(error.localizedDescription)")
        }
    }

    /// Whether ambient light compensation is currently enabled, or nil if
    /// the display does not support it / the API failed.
    public func isAmbientLightCompensationEnabled(for display: Display) -> Bool? {
        do {
            return try DisplayServicesAPI.isAmbientLightCompensationEnabled(display.id)
        } catch {
            log.warning("isAmbientLightCompensationEnabled failed for \(display.id): \(error.localizedDescription)")
            return nil
        }
    }

    /// Enable or disable ambient light compensation (no-op on failure).
    public func setAmbientLightCompensation(_ enabled: Bool, for display: Display) {
        do {
            try DisplayServicesAPI.setAmbientLightCompensation(display.id, enabled: enabled)
        } catch {
            log.warning("setAmbientLightCompensation failed for \(display.id): \(error.localizedDescription)")
        }
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
