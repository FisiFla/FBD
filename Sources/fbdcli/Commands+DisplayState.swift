import FBDCLIParser
import FBDCore
import CoreGraphics
import Foundation

// MARK: - hidpi (the smooth-scaling ladder)

/// `fbdcli hidpi <id> install|remove|status [--preview]` — the display's
/// smooth-scaling (HiDPI) ladder.
///
/// Installing writes an override under /Library, so macOS asks for an
/// administrator password. The CLI says so *before* the prompt appears, and
/// it never claims the display shows the new modes: the override is a file,
/// and the display usually picks it up on the next wake.
///
/// `--preview` prints the ladder — the logical sizes and the backing sizes
/// behind them — and installs nothing.
@MainActor
func cmdHiDPI(_ controller: DisplayController, args: [String]) -> Int32 {
    let parsed: HiDPIArgs
    switch HiDPIArgs.parse(args) {
    case .failure(let failure):
        print("fbdcli: hidpi: \(failure.message)")
        return 1
    case .success(let value):
        parsed = value
    }
    guard let display = requireDisplay(String(parsed.displayID), in: controller) else { return 1 }
    let service = HiDPIOverrideService.shared

    if parsed.preview {
        printHiDIPreview(display, service: service, operation: parsed.operation)
        return 0
    }

    switch parsed.operation {
    case .status:
        let state = service.state(for: display)
        print("hidpi \(display.id): \(hiDPIStatus(state).summary)")
        print("  override: \(state.path)")
        return 0

    case .install:
        let state = service.state(for: display)
        // The service's own answer to "can this display take a ladder?" is
        // the one the install path uses: a built-in panel and a virtual
        // screen have none, and macOS drives the built-in's scaled modes
        // itself.
        guard service.isSupported(for: display) else {
            print("fbdcli: hidpi \(display.id): this display takes no smooth-scaling override "
                + "(a built-in panel and a virtual screen have none)")
            return 2
        }
        if state.isInstalled {
            print("hidpi \(display.id): the smooth-scaling ladder is already installed")
            return 0
        }
        print("hidpi \(display.id): installing the smooth-scaling ladder — macOS will ask for an administrator password")
        switch service.installSmoothScaling(for: display) {
        case .success:
            print("hidpi \(display.id): the smooth-scaling override was written (\(state.modeCount) scaled modes)")
            print("  override: \(state.path)")
            print("  note: the display usually picks the ladder up on the next wake")
            return 0
        case .failure(let error):
            return reportWriteFailure(
                outcome: .failed(reason: hiDPIFailureReason(error)),
                command: "hidpi \(display.id) install",
                readBack: readBackCommand(.hidpi, String(display.id))
            )
        }

    case .remove:
        let state = service.state(for: display)
        guard state.isInstalled else {
            print("hidpi \(display.id): no smooth-scaling override is installed")
            return 0
        }
        print("hidpi \(display.id): removing the smooth-scaling override — macOS will ask for an administrator password")
        switch service.removeSmoothScaling(for: display) {
        case .success:
            print("hidpi \(display.id): the smooth-scaling override was removed")
            return 0
        case .failure(let error):
            return reportWriteFailure(
                outcome: .failed(reason: hiDPIFailureReason(error)),
                command: "hidpi \(display.id) remove",
                readBack: readBackCommand(.hidpi, String(display.id))
            )
        }
    }
}

/// The override's state, as the CLI reports it.
func hiDPIStatus(_ state: HiDPIOverrideState) -> HiDPIOverrideStatus {
    HiDPIOverrideStatus(
        isSupported: state.isSupported,
        isInstalled: state.isInstalled,
        modeCount: state.modeCount,
        wouldPrompt: state.wouldPrompt,
        path: state.path
    )
}

/// Why an install or a remove did not happen, in the user's words.
///
/// The privilege dialog being dismissed is not a failure of the write — it
/// is the user saying no — so it gets its own words.
func hiDPIFailureReason(_ error: HiDPIOverrideError) -> String {
    switch error {
    case .privilegeDeclined:
        return "the administrator dialog was dismissed — nothing was changed"
    case .executionFailed(let message):
        return "the privileged command failed (\(message)) — nothing was changed"
    case .unsupportedDisplay:
        return "this display takes no smooth-scaling override"
    }
}

/// Print the ladder a display would carry and change nothing.
///
/// The sizes are the honest ones: the logical size the user sees, and the
/// backing size it is drawn into.
@MainActor
func printHiDIPreview(_ display: Display, service: HiDPIOverrideService, operation: HiDPIArgs.Operation) {
    guard service.isSupported(for: display), let modes = service.ladder(for: display) else {
        print("hidpi \(display.id): this display takes no smooth-scaling override "
            + "(a built-in panel and a virtual screen have none)")
        return
    }
    print("hidpi \(display.id): the ladder carries \(modes.count) scaled mode(s):")
    for mode in modes {
        let preview = ScaledModePreview(
            logicalWidth: mode.logicalWidth,
            logicalHeight: mode.logicalHeight,
            backingWidth: mode.backingWidth,
            backingHeight: mode.backingHeight
        )
        print("  \(preview.line)")
    }
    switch operation {
    case .install:
        print("  (preview only — nothing was installed)")
    case .remove:
        print("  (preview only — nothing was removed)")
    case .status:
        print("  (preview only — nothing was changed)")
    }
}

// MARK: - gamma-floor (the below-floor brightness blend)

/// `fbdcli gamma-floor <id> [on|off] [value]` — the below-floor brightness
/// blend of a display.
///
/// The bare form reports the state. `on`/`off` turns the blend on or off and
/// the optional value is the threshold in percent; without a value the
/// threshold that is configured is kept.
///
/// The blend reaches past the panel's own floor in software, so it only
/// does something on a display that has one — and it needs the Screen
/// Recording permission, without which the software layer cannot dim.
@MainActor
func cmdGammaFloor(_ controller: DisplayController, args: [String]) -> Int32 {
    let parsed: GammaFloorArgs
    switch GammaFloorArgs.parse(args) {
    case .failure(let failure):
        print("fbdcli: gamma-floor: \(failure.message)")
        return 1
    case .success(let value):
        parsed = value
    }
    guard let display = requireDisplay(String(parsed.displayID), in: controller) else { return 1 }

    switch parsed.action {
    case .report:
        print("gamma-floor \(display.id): \(floorBlendStatus(for: display).summary)")
        return 0

    case .set(let enabled, let thresholdPercent):
        // The threshold is a percentage on the command line and a fraction of
        // the hardware scale in the blend itself.
        let threshold = thresholdPercent.map { $0 / 100.0 }
        guard controller.setFloorBlend(enabled, threshold: threshold, for: display) else {
            return reportWriteFailure(
                outcome: .failed(reason: "the brightness blend was not changed"),
                command: "gamma-floor \(display.id)",
                readBack: readBackCommand(.gammaFloor, String(display.id))
            )
        }
        print("gamma-floor \(display.id): \(floorBlendStatus(for: display).summary)")
        return 0
    }
}

/// The blend's state for a display, as the CLI reports it.
func floorBlendStatus(for display: Display) -> FloorBlendStatus {
    let blend = Settings.floorBlend(for: display.identityKey)
    return FloorBlendStatus(isEnabled: blend.isEnabled, threshold: blend.threshold)
}

// MARK: - display (connect / disconnect)

/// `fbdcli display <id> disconnect [--remember]`, `fbdcli display <id>
/// reconnect` and `fbdcli display --list-remembered`.
///
/// The disconnect memory is a setting, not an event: `--remember` keeps the
/// display off when it is plugged back in, and a reconnect forgets that note.
@MainActor
func cmdDisplay(_ controller: DisplayController, args: [String]) -> Int32 {
    let parsed: DisplayArgs
    switch DisplayArgs.parse(args) {
    case .failure(let failure):
        print("fbdcli: display: \(failure.message)")
        return 1
    case .success(let value):
        parsed = value
    }

    switch parsed.action {
    case .listRemembered:
        return cmdListRemembered()
    case .disconnect(let remember):
        guard let displayID = parsed.displayID else { return 1 }
        return cmdDisplayDisconnect(controller, displayID: displayID, remember: remember)
    case .reconnect:
        guard let displayID = parsed.displayID else { return 1 }
        return cmdDisplayReconnect(controller, displayID: displayID)
    }
}

/// `fbdcli display <id> disconnect [--remember]` — put a display's screen to
/// black.
///
/// The built-in panel's guard runs before anything is touched: on the Macs
/// where it may not come back without a reboot, the disconnect is refused
/// instead of attempted.
@MainActor
func cmdDisplayDisconnect(_ controller: DisplayController, displayID: UInt32, remember: Bool) -> Int32 {
    guard let display = requireDisplay(String(displayID), in: controller) else { return 1 }
    if CGDisplayIsBuiltin(display.id) != 0, !BuiltInDisconnectGuard.builtInDisconnectAllowed {
        print("fbdcli: refusing to disconnect the built-in display — on this Mac (base M3) it may")
        print("        not reconnect without a reboot. Set \"Allow built-in display disconnect\"")
        print("        in FBD's Settings if you accept that risk, then re-run.")
        return 2
    }
    let disconnect = DisconnectController()
    guard disconnect.setEnabled(false, displayID: display.id) else {
        return reportWriteFailure(
            outcome: .failed(reason: "the display configuration was not changed"),
            command: "display \(display.id) disconnect",
            readBack: readBackCommand(.display, String(display.id))
        )
    }
    if remember {
        disconnect.rememberDisconnect(for: display)
        print("display \(display.id) disconnected (remembered as off: it stays off when it is plugged back in)")
        print("  verify the memory with: fbdcli display --list-remembered")
    } else {
        print("display \(display.id) disconnected")
    }
    return 0
}

/// `fbdcli display <id> reconnect` — bring a display back.
///
/// A display that is off is not in the list any more, so it is re-enabled by
/// id — the way `fbdcli enable` does it. When the display *is* known, the
/// "keep it off" note is cleared: the user asked for it back, so the note
/// would only contradict them.
@MainActor
func cmdDisplayReconnect(_ controller: DisplayController, displayID: UInt32) -> Int32 {
    let disconnect = DisconnectController()
    let display = controller.display(withID: displayID)
    guard disconnect.setEnabled(true, displayID: displayID) else {
        return reportWriteFailure(
            outcome: .failed(reason: "the display configuration was not changed"),
            command: "display \(displayID) reconnect",
            readBack: readBackCommand(.display, String(displayID))
        )
    }
    if let display {
        disconnect.forgetDisconnect(for: display)
    }
    print("display \(displayID) reconnected")
    return 0
}

/// `fbdcli display --list-remembered` — the displays FBD is remembering as
/// off.
///
/// The memory is keyed by the display's *identity* (vendor, model and serial
/// by default), not by its id: an id changes on every replug, an identity
/// does not.
@MainActor
func cmdListRemembered() -> Int32 {
    let remembered = DisconnectController().rememberedDisplays()
    guard !remembered.isEmpty else {
        print("no display is remembered as off")
        return 0
    }
    print("remembered as off:")
    for identity in remembered {
        print("  \(identity)")
    }
    return 0
}
