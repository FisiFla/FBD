import CoreGraphics
import CPrivateAPI
import Foundation
import os

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "SkyLightAPI")

/// Typed wrappers over SkyLight (WindowServer client) — minimal Tier 1 surface.
/// Tier 2 adds the XDR preset rewrite APIs (SLSDisplaySetPresetData etc.).
public enum SkyLightAPI {
    /// The process's WindowServer connection ID.
    public static var mainConnectionID: Int {
        Int(SLSMainConnectionID())
    }

    /// Ask the WindowServer to re-detect connected displays. Used after
    /// configuration changes (mode apply, virtual display add/remove).
    public static func detectDisplays() {
        let status = SLSDetectDisplays(Int32(mainConnectionID))
        if status != .success {
            log.warning("SLSDetectDisplays failed: \(status.rawValue)")
        }
    }
}
