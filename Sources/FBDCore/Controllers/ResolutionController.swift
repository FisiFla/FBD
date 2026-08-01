import CoreGraphics
import CPrivateAPI
import Foundation
import os

/// Resolution control via the CGS display mode APIs (same family displayplacer
/// uses). Modes are fetched per display, applied through a display
/// configuration transaction, and broadcast via `fbdDisplayUpdated`.
public final class ResolutionController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "ResolutionController")

    public init() {}

    /// All modes for a display, junk modes (width == 0) dropped, sorted by
    /// physical pixel count descending.
    public func modes(for display: Display) -> [DisplayMode] {
        let descriptions: [CGSDisplayModeDescription]
        do {
            descriptions = try CGSAPI.modeDescriptions(for: display.id)
        } catch {
            log.warning("modes(for:) failed for \(display.id): \(error.localizedDescription)")
            return []
        }
        return descriptions
            .map { DisplayMode.from(cgsDescription: $0) }
            .filter { $0.width != 0 }
            .sorted { $0.pixelsWide * $0.pixelsHigh > $1.pixelsWide * $1.pixelsHigh }
    }

    /// The display's current mode, matched by CGS mode number.
    public func currentMode(for display: Display) -> DisplayMode? {
        let modeNumber: Int32
        do {
            modeNumber = try CGSAPI.currentModeNumber(for: display.id)
        } catch {
            log.warning("currentMode(for:) failed for \(display.id): \(error.localizedDescription)")
            return nil
        }
        return modes(for: display).first { $0.modeNumber == modeNumber }
    }

    /// Unique refresh rates (Hz) across all modes, ascending.
    public func refreshRates(for display: Display) -> [Double] {
        var seen = Set<Double>()
        return modes(for: display)
            .map { $0.refreshRate }
            .filter { $0 > 0 }
            .filter { seen.insert($0).inserted }
            .sorted()
    }

    /// Apply a mode: configure via CGS, ask the WindowServer to re-detect
    /// displays, refresh the display's mode list, and broadcast the change.
    public func applyMode(_ mode: DisplayMode, to display: Display) {
        do {
            try CGSAPI.configureMode(mode.modeNumber, on: display.id)
        } catch {
            log.error("applyMode \(mode.modeNumber) failed for \(display.id): \(error.localizedDescription)")
            return
        }
        SkyLightAPI.detectDisplays()
        display.updateModes(modes(for: display), current: currentMode(for: display))
        NotificationCenter.default.post(
            name: .fbdDisplayUpdated,
            object: nil,
            userInfo: ["displayID": display.id]
        )
    }

    /// Switch refresh rate while keeping the current physical resolution:
    /// picks the mode with the same pixelsWide/pixelsHigh and the refresh rate
    /// nearest to `hz`, preferring HiDPI on ties.
    public func setRefreshRate(_ hz: Double, for display: Display) {
        guard let current = currentMode(for: display) else {
            log.warning("setRefreshRate: no current mode for \(display.id)")
            return
        }
        let sameSize = modes(for: display).filter {
            $0.pixelsWide == current.pixelsWide && $0.pixelsHigh == current.pixelsHigh
        }
        guard let best = sameSize.sorted(by: { a, b in
            let distanceA = abs(a.refreshRate - hz)
            let distanceB = abs(b.refreshRate - hz)
            if distanceA != distanceB { return distanceA < distanceB }
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            return a.refreshRate > b.refreshRate
        }).first else {
            log.warning("setRefreshRate: no same-size mode for \(display.id)")
            return
        }
        if abs(best.refreshRate - hz) > 0.5 {
            log.debug("Closest refresh rate to \(hz) Hz for \(display.id) is \(best.refreshRate) Hz")
        }
        applyMode(best, to: display)
    }
}
