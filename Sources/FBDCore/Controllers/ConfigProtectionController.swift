import CoreGraphics
import Foundation
import os

/// Config protection: save a display's resolution + brightness + active preset
/// and re-apply them when the display reconnects (offline→online).
///
/// Saved per display identity as JSON in UserDefaults under
/// `"configProtection.v1.<identityKey>"`. Restores only run while
/// `Settings.configProtectionEnabled` is on and only for displays that
/// transitioned offline→online (tracked via `.fbdDisplaysChanged`).
///
/// MainActor, like DisplayController: it mediates MainActor-isolated
/// DisplayController state (brightness, presets). The `.fbdDisplaysChanged`
/// observer runs on the main queue.
@MainActor
public final class ConfigProtectionController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "ConfigProtectionController")
    nonisolated private static let suite = "dev.fisifla.fbd"

    private let resolution = ResolutionController()

    /// Persistence domain. Defaults to the shared FBD suite (app + CLI see
    /// the same state); injectable so tests use a scratch suite.
    private let defaults: UserDefaults

    private var hasRegistered = false
    private var observer: NSObjectProtocol?
    /// Display IDs that were online at the last `.fbdDisplaysChanged` tick.
    private var knownOnlineIDs: Set<CGDirectDisplayID> = []

    public init(defaults: UserDefaults = ConfigProtectionController.defaults) {
        self.defaults = defaults
    }

    // MARK: - Persistence

    private struct SavedState: Codable {
        /// CGS mode number of the current mode (nil when none could be read).
        var modeNumber: Int32?
        /// Last known brightness, 0…1 (nil when the display has no control path).
        var brightness: Double?
        /// Active XDR preset index (nil = factory default / non-XDR display).
        var activePresetIndex: Int?
    }

    /// Same suite selection as Settings: the app bundle's standard domain IS
    /// dev.fisifla.fbd; CLI/tests target the suite explicitly so both read the
    /// same plist.
    nonisolated public static var defaults: UserDefaults {
        if Bundle.main.bundleIdentifier == "dev.fisifla.fbd" {
            return .standard
        }
        return UserDefaults(suiteName: suite) ?? .standard
    }

    private func key(for identity: String) -> String { "configProtection.v1.\(identity)" }

    // MARK: - Save / restore

    /// Save the display's current mode (via ResolutionController.currentMode)
    /// + brightness + active preset index, keyed by identityKey.
    public func saveCurrentState(for display: Display, resolution: ResolutionController, controller: DisplayController) {
        let state = SavedState(
            modeNumber: resolution.currentMode(for: display)?.modeNumber,
            brightness: display.brightness ?? controller.getBrightness(for: display),
            activePresetIndex: display.activePresetIndex
        )
        guard let data = try? JSONEncoder().encode(state) else {
            log.warning("saveCurrentState: encode failed for \(display.identityKey)")
            return
        }
        defaults.set(data, forKey: key(for: display.identityKey))
        log.debug("saved config state for \(display.identityKey)")
    }

    /// Re-apply saved state for a display that just (re)appeared: mode first
    /// (via ResolutionController.applyMode), then the active preset, then
    /// brightness with a small delay so the mode switch settles first.
    /// No-op unless Settings.configProtectionEnabled and saved state exists.
    public func restoreIfNeeded(for display: Display, resolution: ResolutionController, controller: DisplayController) {
        guard Settings.configProtectionEnabled,
              let data = defaults.data(forKey: key(for: display.identityKey)),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else {
            return
        }

        if let modeNumber = state.modeNumber,
           let mode = resolution.modes(for: display).first(where: { $0.modeNumber == modeNumber }) {
            resolution.applyMode(mode, to: display)
            log.info("restored mode \(modeNumber) for \(display.identityKey)")
        }

        if let index = state.activePresetIndex, display.isXDRCapable, display.presets.indices.contains(index) {
            controller.selectPreset(index, on: display)
        }

        if let brightness = state.brightness {
            let displayID = display.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Task { @MainActor in
                    guard let display = controller.display(withID: displayID) else { return }
                    _ = controller.setBrightness(brightness, on: display)
                }
            }
        }
    }

    // MARK: - Observation

    /// Observe .fbdDisplaysChanged; for each display that transitioned
    /// offline→online and has saved state + setting enabled → restore (mode,
    /// then brightness with a small delay).
    public func start(controller: DisplayController) {
        guard !hasRegistered else { return }
        hasRegistered = true
        // Seed with the currently online displays so the first notification
        // (posted by the initial refresh) does not count as a reconnect.
        knownOnlineIDs = Set(controller.displays.filter { $0.isOnline }.map { $0.id })
        observer = NotificationCenter.default.addObserver(
            forName: .fbdDisplaysChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleDisplaysChanged(controller: controller)
            }
        }
    }

    private func handleDisplaysChanged(controller: DisplayController) {
        let online = Set(controller.displays.filter { $0.isOnline }.map { $0.id })
        let appeared = online.subtracting(knownOnlineIDs)
        knownOnlineIDs = online
        guard Settings.configProtectionEnabled else { return }

        for id in appeared {
            guard let display = controller.display(withID: id),
                  defaults.data(forKey: key(for: display.identityKey)) != nil else {
                continue
            }
            log.info("display \(id) reappeared — restoring saved config")
            restoreIfNeeded(for: display, resolution: resolution, controller: controller)
        }
    }
}
