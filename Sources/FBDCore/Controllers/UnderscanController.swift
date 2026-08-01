import CoreGraphics
import CPrivateAPI
import Foundation
import os

/// Underscan (overscan compensation) control for TVs.
///
/// Underscan is a TV-only feature; the WindowServer itself rejects the request
/// for displays without underscan support, so the SLS call's status is the
/// support probe. `SLSDisplaySetUnderscan` is a private SkyLight API with an
/// unverified signature — it is therefore only ever called on explicit user
/// request, never automatically.
///
/// Plain class; no observers, no automatic invocation.
public final class UnderscanController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "UnderscanController")

    public init() {}

    /// Toggle underscan (TVs; SLSDisplaySetUnderscan — unverified signature,
    /// user-initiated only). Returns false when the display has no underscan
    /// support (all non-TV displays log + return false).
    @discardableResult
    public func setUnderscan(_ enabled: Bool, for display: Display) -> Bool {
        guard !display.isVirtual else {
            log.warning("setUnderscan: virtual display \(display.id) has no underscan support")
            return false
        }
        let status = SLSDisplaySetUnderscan(Int32(display.id), enabled)
        guard status == 0 else {
            log.warning("SLSDisplaySetUnderscan(\(enabled)) failed for display \(display.id): no underscan support (status \(status))")
            return false
        }
        log.info("Underscan \(enabled ? "enabled" : "disabled") for display \(display.id)")
        return true
    }
}
