import AppKit
import FBDCore
import os

/// Composition root for the menu-bar app. Owns the controllers the UI drives
/// and wires notification-driven refreshes between FBDCore and the status item.
@MainActor
final class AppCore {
    let displayController = DisplayController.shared
    let statusItemController: StatusItemController

    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "App")
    private var observers: [NSObjectProtocol] = []

    init() {
        statusItemController = StatusItemController()
    }

    func start() {
        // Register first: displayController.start() posts .fbdDisplaysChanged
        // during its initial refresh — the status item must catch it so the
        // first popover shows the populated display list.
        observe(.fbdDisplaysChanged) { [weak self] in
            self?.statusItemController.refreshUI()
        }
        observe(.fbdDisplayUpdated) { [weak self] in
            self?.statusItemController.refreshUI()
        }

        displayController.start()
        statusItemController.install()

        // Tier 3 controllers: virtual screens, soft disconnect, layout protection.
        virtualScreens.start()
        disconnect.start()
        layoutProtection.start()
        // Recreate persisted virtual screens at launch (they are process-lifetime).
        if Settings.reconnectVirtualScreensOnWake {
            virtualScreens.reconnectAuto()
        }

        if IOAVServiceAPI.isAppleSilicon && IOAVServiceAPI.isRunningUnderRosetta && Settings.showRosettaWarning {
            log.warning("Running under Rosetta — DDC control is unavailable")
            NotificationCenter.default.post(name: .fbdRosettaWarningActive, object: nil)
        }
    }

    // Tier 3 controller instances (owned here; UI/CLI create their own for one-shot use).
    let virtualScreens = VirtualScreenController()
    let disconnect = DisconnectController()
    let layoutProtection = LayoutProtectionController()

    // MARK: - URL scheme (fbd://)

    func handle(url: URL) {
        guard url.scheme == "fbd" else {
            log.error("Ignoring non-fbd URL: \(url.absoluteString, privacy: .public)")
            return
        }
        switch url.host {
        case "open":
            openSettingsPanel()
        case "brightness":
            setBrightness(from: url)
        default:
            log.error("Unknown fbd URL: \(url.absoluteString, privacy: .public)")
        }
    }

    private func openSettingsPanel() {
        statusItemController.showPopover()
        NotificationCenter.default.post(name: .fbdOpenSettings, object: nil)
    }

    /// `fbd://brightness/<displayID>/<value 0…1>`
    private func setBrightness(from url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2,
              let id = UInt32(parts[0]),
              let value = Double(parts[1]) else {
            log.error("Malformed fbd://brightness URL: \(url.absoluteString, privacy: .public)")
            return
        }
        guard let display = displayController.display(withID: id) else {
            log.error("fbd://brightness: no display with id \(id)")
            return
        }
        displayController.setBrightness(value, on: display)
        log.info("Set brightness to \(value) for display \(id)")
    }

    // MARK: - Observers

    private func observe(_ name: Notification.Name, handler: @escaping () -> Void) {
        observers.append(
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    handler()
                }
            }
        )
    }
}

// MARK: - App-level notifications

extension Notification.Name {
    /// Posted when the settings panel should be shown (fbd://open).
    static let fbdOpenSettings = Notification.Name("FBDOpenSettings")
    /// Posted once at startup when DDC is unavailable under Rosetta.
    static let fbdRosettaWarningActive = Notification.Name("FBDRosettaWarningActive")
}
