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
        let clamped = min(max(value, 0), 1)
        DispatchQueue.main.async {
            display.updateBrightness(clamped)
            NotificationCenter.default.post(name: .fbdDisplayUpdated, object: nil, userInfo: ["displayID": id])
        }
    }
}
