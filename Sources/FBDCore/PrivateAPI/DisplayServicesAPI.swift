import CoreGraphics
import CPrivateAPI
import Foundation
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "DisplayServicesAPI")

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
}

// Note: DisplayServicesRegisterForBrightnessChangeNotifications (C decl in
// fbd_private_api.h) is not wrapped yet — the CFNotificationCallback gets no
// context pointer, so the handler would need a global registry. Brightness sync
// (Tier 2) will own that; Tier 1 refreshes on display-reconfiguration events.
