import CPrivateAPI
import CoreGraphics
import Foundation
import os

/// The CoreDisplay info dictionary for a display.
///
/// `CoreDisplay_DisplayCreateInfoDictionary` is the window server's own record of a
/// display: its identity, its transport, its flags, its panel geometry and its luminance
/// data. It is read-only, it returns a dictionary, and it is live-verified on macOS 27 — so
/// it is the one source that answers "what does macOS think this display is" without any
/// bus traffic.
///
/// It is read on demand rather than cached: a report asks for it, and nothing else does.
public enum CoreDisplayInfoAPI {
    private static let log = Logger(subsystem: "dev.fisifla.fbd", category: "CoreDisplayInfoAPI")

    /// The info dictionary for a display, or nil when it could not be read.
    public static func infoDictionary(for displayID: CGDirectDisplayID) -> [String: Any]? {
        guard let created = CoreDisplay_DisplayCreateInfoDictionary(displayID) else {
            log.debug("CoreDisplay_DisplayCreateInfoDictionary returned nothing for display \(displayID)")
            return nil
        }
        let dictionary = created.takeRetainedValue()
        guard let info = dictionary as? [String: Any] else {
            log.debug("CoreDisplay_DisplayCreateInfoDictionary returned a non-dictionary for display \(displayID)")
            return nil
        }
        return info
    }
}
