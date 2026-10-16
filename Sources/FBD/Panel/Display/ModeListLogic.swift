import FBDCore
import Foundation

/// What the display page lists for resolution and refresh rate. Pure, so the rules are tested
/// without a display.
enum ModeListLogic {
    /// The short resolution list: one row per logical size at the current aspect ratio, HiDPI
    /// preferred, the mode in effect always present. The rule itself lives in FBDCore's
    /// `CuratedModes` (pinned by `CuratedModesTests`); this is the app's single entry to it.
    static func curated(modes: [DisplayMode], current: DisplayMode?) -> [DisplayMode] {
        CuratedModes.curated(from: modes, current: current)
    }

    /// The refresh rates the current size offers (same logical size, same HiDPI-ness),
    /// deduplicated, highest first. Rates of other sizes are left out: picking one would find no
    /// matching mode and do nothing. A 0 Hz rate (a display that does not report one) is not a
    /// choice either.
    static func refreshRates(modes: [DisplayMode], current: DisplayMode?) -> [Double] {
        guard let current else { return [] }
        let rates = modes
            .filter { sameSize($0, current) && $0.refreshRate > 0 }
            .map(\.refreshRate)
        return Set(rates).sorted(by: >)
    }

    /// The mode to apply for a refresh-rate pick: the current size and HiDPI-ness at `hz` —
    /// the candidate search the options menu's Refresh Rate submenu used.
    static func mode(refreshRate hz: Double, modes: [DisplayMode], current: DisplayMode?) -> DisplayMode? {
        guard let current else { return nil }
        return modes.first { sameSize($0, current) && $0.refreshRate == hz }
    }

    /// "60 Hz", or "59.94 Hz" for a fractional rate, so 59.94 and 60 are not two "60 Hz" rows.
    static func rateLabel(_ hz: Double) -> String {
        hz == hz.rounded()
            ? String(localized: "\(Int(hz)) Hz")
            : String(format: "%.2f Hz", hz)
    }

    private static func sameSize(_ mode: DisplayMode, _ current: DisplayMode) -> Bool {
        mode.width == current.width && mode.height == current.height && mode.isHiDPI == current.isHiDPI
    }
}
