import CoreGraphics
import CPrivateAPI
import Foundation
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "DisplayServicesAPI")

// MARK: - Brightness-change notification registry (file scope: the C callback
// must not capture context).

private var brightnessCallbacks: [CGDirectDisplayID: (CGDirectDisplayID, Double) -> Void] = [:]
private let brightnessRegistryLock = NSLock()

private func displayServicesBrightnessCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFString?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    guard let observer else { return }
    let id = CGDirectDisplayID(UInt(bitPattern: observer))
    guard let value = (userInfo as NSDictionary?)?["value"] as? Double else {
        log.debug("brightness notification without value for \(id)")
        return
    }
    brightnessRegistryLock.lock()
    let handler = brightnessCallbacks[id]
    brightnessRegistryLock.unlock()
    handler?(id, value)
}

/// Typed wrappers over DisplayServices.framework (Apple display brightness).
/// Brightness values are 0…1 floats. Status 0 = success.
public enum DisplayServicesAPI {
    public static func canChangeBrightness(_ displayID: CGDirectDisplayID) -> Bool {
        DisplayServicesCanChangeBrightness(displayID)
    }

    public static func getBrightness(_ displayID: CGDirectDisplayID) throws -> Float {
        var value: Float = 0
        let status = DisplayServicesGetBrightness(displayID, &value)
        guard status == 0 else { throw PrivateAPIError.status("DisplayServicesGetBrightness", status) }
        return value
    }

    public static func setBrightness(_ displayID: CGDirectDisplayID, _ value: Float) throws {
        let status = DisplayServicesSetBrightness(displayID, value)
        guard status == 0 else { throw PrivateAPIError.status("DisplayServicesSetBrightness", status) }
    }

    public static func getLinearBrightness(_ displayID: CGDirectDisplayID) throws -> Float {
        var value: Float = 0
        let status = DisplayServicesGetLinearBrightness(displayID, &value)
        guard status == 0 else { throw PrivateAPIError.status("DisplayServicesGetLinearBrightness", status) }
        return value
    }

    public static func setLinearBrightness(_ displayID: CGDirectDisplayID, _ value: Float) throws {
        let status = DisplayServicesSetLinearBrightness(displayID, value)
        guard status == 0 else { throw PrivateAPIError.status("DisplayServicesSetLinearBrightness", status) }
    }

    public static func hasAmbientLightCompensation(_ displayID: CGDirectDisplayID) -> Bool {
        DisplayServicesHasAmbientLightCompensation(displayID) != 0
    }

    public static func isAmbientLightCompensationEnabled(_ displayID: CGDirectDisplayID) throws -> Bool {
        var enabled = false
        let status = DisplayServicesAmbientLightCompensationEnabled(displayID, &enabled)
        guard status == 0 else { throw PrivateAPIError.status("DisplayServicesAmbientLightCompensationEnabled", status) }
        return enabled
    }

    public static func setAmbientLightCompensation(_ displayID: CGDirectDisplayID, enabled: Bool) throws {
        let status = DisplayServicesEnableAmbientLightCompensation(displayID, enabled)
        guard status == 0 else { throw PrivateAPIError.status("DisplayServicesEnableAmbientLightCompensation", status) }
    }

    // MARK: - Brightness-change notifications

    /// Register a callback for hardware brightness changes on a display
    /// (brightness keys, ambient-light adjustments). The private notification
    /// carries the display ID in the observer token and the value in
    /// userInfo["value"] — the same pattern lunar uses.
    @discardableResult
    public static func registerForBrightnessChanges(
        displayID: CGDirectDisplayID,
        callback: @escaping (CGDirectDisplayID, Double) -> Void
    ) -> Bool {
        brightnessRegistryLock.lock()
        brightnessCallbacks[displayID] = callback
        brightnessRegistryLock.unlock()

        let status = DisplayServicesRegisterForBrightnessChangeNotifications(displayID, displayID, displayServicesBrightnessCallback)
        if status != 0 {
            log.warning("DisplayServicesRegisterForBrightnessChangeNotifications failed: \(status)")
            brightnessRegistryLock.lock()
            brightnessCallbacks.removeValue(forKey: displayID)
            brightnessRegistryLock.unlock()
            return false
        }
        return true
    }

    public static func unregisterForBrightnessChanges(displayID: CGDirectDisplayID) {
        DisplayServicesUnregisterForBrightnessChangeNotifications(displayID, displayID)
        brightnessRegistryLock.lock()
        brightnessCallbacks.removeValue(forKey: displayID)
        brightnessRegistryLock.unlock()
    }
}
