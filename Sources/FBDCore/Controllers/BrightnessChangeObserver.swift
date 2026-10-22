import CoreGraphics
import Foundation
import os

/// Mirrors hardware brightness changes (DisplayServices notifications) onto
/// the Display model and `.fbdDisplayUpdated`, so UI bound to
/// `display.brightness` follows keyboard/ambient-light adjustments.
public final class BrightnessChangeObserver {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "BrightnessChangeObserver")
    private let lock = NSLock()
    private var observed: [CGDirectDisplayID: Display] = [:]

    /// Called when a display's hardware brightness changed, with the display
    /// and its new value (0…1).
    ///
    /// This is the seam the ambient-light sync hangs on: the built-in
    /// panel's ambient sensor drives its backlight, and this is where that
    /// shows up. Called on the **main queue**, right after the display model
    /// has been updated.
    public var onChange: ((Display, Double) -> Void)?

    public init() {}

    /// Register for hardware brightness-change notifications on `display`.
    /// On change, `display.brightness` is updated on the main thread and
    /// `Notification.Name.fbdDisplayUpdated` is posted with
    /// ["displayID": CGDirectDisplayID]. Idempotent per Display instance.
    public func observe(display: Display) {
        lock.lock()
        let existing = observed[display.id]
        lock.unlock()
        if existing === display { return }

        if existing != nil {
            // Same id, different Display instance: swap the registration.
            DisplayServicesAPI.unregisterForBrightnessChanges(displayID: display.id)
        }
        let registered = DisplayServicesAPI.registerForBrightnessChanges(displayID: display.id) { [weak self] id, value in
            self?.handleChange(id: id, value: value)
        }
        guard registered else {
            log.warning("observe: registerForBrightnessChanges failed for \(display.id)")
            return
        }
        lock.lock()
        observed[display.id] = display
        lock.unlock()
    }

    /// Stop observing a display (unregisters only when we were observing).
    public func unobserve(displayID: CGDirectDisplayID) {
        lock.lock()
        let wasObserved = observed.removeValue(forKey: displayID) != nil
        lock.unlock()
        guard wasObserved else { return }
        DisplayServicesAPI.unregisterForBrightnessChanges(displayID: displayID)
    }

    /// Stop observing every display.
    public func unobserveAll() {
        lock.lock()
        let ids = Array(observed.keys)
        observed.removeAll()
        lock.unlock()
        for id in ids {
            DisplayServicesAPI.unregisterForBrightnessChanges(displayID: id)
        }
    }

    /// Notification callbacks arrive on an arbitrary thread; hop to main.
    private func handleChange(id: CGDirectDisplayID, value: Double) {
        lock.lock()
        let display = observed[id]
        lock.unlock()
        guard let display else { return }
        DispatchQueue.main.async {
            Self.applyHardwareChange(displayID: id, brightness: value, to: display)
            // The ambient-light sync hangs on this: the built-in panel's
            // ambient sensor drives its backlight, and this is where that
            // change arrives.
            self.onChange?(display, min(max(value, 0), 1))
        }
    }

    /// Apply a brightness change the **hardware** made and announce it as such.
    ///
    /// The hardware changed the display, not the user: the brightness keys,
    /// the ambient-light sensor, another application. The origin is what tells
    /// the HUD not to announce a change nobody asked for — the update is still
    /// posted, so everything bound to the display keeps refreshing.
    ///
    /// Split out of the notification callback so the origin contract can be
    /// checked without a display attached.
    internal static func applyHardwareChange(displayID: CGDirectDisplayID, brightness: Double, to display: Display) {
        let clamped = min(max(brightness, 0), 1)
        display.updateBrightness(clamped)
        NotificationCenter.default.post(
            name: .fbdDisplayUpdated,
            object: nil,
            userInfo: [
                "displayID": displayID,
                DisplayUpdateOrigin.userInfoKey: DisplayUpdateOrigin.hardware.rawValue
            ]
        )
    }
}
