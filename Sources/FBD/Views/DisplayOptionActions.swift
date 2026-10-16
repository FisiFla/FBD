import CoreGraphics
import FBDCore
import Foundation

/// The per-display "options" actions, shared by the popover's display page (`DisplayMoreSection`)
/// and Settings' per-display options menu (`DisplayOptionsMenuView`), so the two surfaces cannot
/// drift. Every refusal is reported through `FBDNotice` rather than discarded.
@MainActor
enum DisplayOptionActions {
    // MARK: HiDPI

    /// The current mode's twin with the other HiDPI flag (same size and rate), if the display has one.
    static func hiDPICounterpart(of display: Display) -> DisplayMode? {
        guard let current = display.currentMode else { return nil }
        return display.modes.first {
            $0.width == current.width && $0.height == current.height
                && $0.refreshRate == current.refreshRate && $0.isHiDPI != current.isHiDPI
        }
    }

    static func setHiDPI(_ wantHiDPI: Bool, on display: Display) {
        guard let current = display.currentMode, current.isHiDPI != wantHiDPI,
              let candidate = hiDPICounterpart(of: display) else { return }
        DisplayController.shared.applyMode(candidate, to: display)
    }

    // MARK: Auto brightness

    /// nil when the display has no ambient-light compensation to drive.
    static func autoBrightness(of display: Display) -> Bool? {
        DisplayController.shared.isAmbientLightCompensationEnabled(on: display)
    }

    static func setAutoBrightness(_ on: Bool, on display: Display) {
        DisplayController.shared.setAmbientLightCompensation(on, on: display)
    }

    // MARK: Mirroring and streaming

    /// Other online displays available as mirror or stream targets.
    static func mirrorTargets(for display: Display) -> [Display] {
        DisplayController.shared.displays.filter { $0.id != display.id && $0.isOnline }
    }

    static func isMirrored(_ display: Display) -> Bool {
        CGDisplayIsInMirrorSet(display.id) != 0
    }

    /// Mirror `display` onto `target` by creating (or reusing) a group containing exactly the two
    /// displays, then mirroring the group.
    static func mirror(_ display: Display, onto target: Display) {
        let groups = DisplayGroupsController()
        let action = "mirror \(display.name) onto \(target.name)"
        if let existing = groups.groups.first(where: {
            $0.displayIDs == [display.id, target.id] || $0.displayIDs == [target.id, display.id]
        }) {
            reportIfRefused(groups.mirror(inGroup: existing.id), action)
            return
        }
        groups.createGroup(name: "Mirror \(display.name) → \(target.name)", displayIDs: [display.id, target.id])
        if let group = groups.groups.last {
            reportIfRefused(groups.mirror(inGroup: group.id), action)
        }
    }

    static func unmirror(_ display: Display) {
        let groups = DisplayGroupsController()
        for group in groups.groups where group.displayIDs.contains(display.id) {
            reportIfRefused(groups.unmirror(inGroup: group.id), "unmirror \(display.name)")
        }
    }

    /// The floating video-filter (PiP) window for this display.
    static func startPictureInPicture(of display: Display) {
        _ = PipStreamController.shared.startPiP(displayID: display.id, filter: .identity)
    }

    /// Redirects this display onto `target`, full-screen.
    static func stream(_ display: Display, to target: Display) {
        _ = PipStreamController.shared.startPiP(
            source: .display(display.id),
            on: target.id,
            presentation: .fullScreen,
            filter: .identity
        )
    }

    // MARK: Resolution favourites

    static func favouriteSummary(_ favourite: ModeFavourite) -> String {
        var text = "\(favourite.width) × \(favourite.height)"
        if favourite.isHiDPI { text += " HiDPI" }
        if favourite.refreshRate > 0 { text += String(format: " @ %.2f Hz", favourite.refreshRate) }
        return text
    }

    /// Records the display's current mode into `slot`, reporting either outcome — the surfaces
    /// that call this (a menu, a transient popover) have no status line of their own.
    @discardableResult
    static func recordFavourite(_ slot: Int, for display: Display, using resolution: ResolutionController) -> Bool {
        guard let mode = resolution.currentMode(for: display) else {
            FBDNotice.shared.report(String(localized: "No current resolution to record."))
            return false
        }
        guard ModeFavourites.save(mode, into: slot, for: display.identityKey) else {
            FBDNotice.shared.report(String(localized: "Resolution favourite \(slot) is out of range."))
            return false
        }
        FBDNotice.shared.report(String(localized: "Recorded resolution favourite \(slot)."))
        return true
    }

    static func applyFavourite(_ slot: Int, to display: Display, using resolution: ResolutionController) {
        let recall = resolution.applyFavourite(slot: slot, for: display.identityKey, to: display)
        if recall.isUnavailable {
            FBDNotice.shared.report(String(localized: "Favourite \(slot) no longer has a matching mode on this display."))
        }
    }

    // MARK: Settings

    /// Opens Settings → Displays scrolled to this display.
    static func showInSettings(_ display: Display) {
        NotificationCenter.default.post(
            name: .fbdOpenSettings,
            object: nil,
            userInfo: [
                "tab": SettingsView.SettingsPage.displays.rawValue,
                "displayID": NSNumber(value: display.id),
            ]
        )
    }

    /// Surface a refused display-groups operation instead of discarding it: a refused mirror
    /// otherwise looks like a dead control.
    private static func reportIfRefused(_ succeeded: Bool, _ action: String) {
        guard !succeeded else { return }
        FBDNotice.shared.report(String(localized: "Could not \(action)."))
    }
}
