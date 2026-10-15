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

    /// Per-display selection key. Lives in the same injected suite and under
    /// the same `configProtection.` prefix as the saved blob, so the app and
    /// the CLI (which share the suite) agree on it.
    private func selectionKey(for identity: String) -> String { "configProtection.properties.\(identity)" }

    // MARK: - Property selection

    /// Which properties protection re-applies for this display. Defaults to
    /// `ProtectedProperties.legacyDefault` so an existing install behaves
    /// exactly as before until the user widens the selection.
    public func protectedProperties(for display: Display) -> ProtectedProperties {
        let key = selectionKey(for: display.identityKey)
        guard defaults.object(forKey: key) != nil else { return .legacyDefault }
        return ProtectedProperties(rawValue: defaults.integer(forKey: key))
    }

    public func setProtectedProperties(_ properties: ProtectedProperties, for display: Display) {
        defaults.set(properties.rawValue, forKey: selectionKey(for: display.identityKey))
    }

    /// The properties that will actually be re-applied: the saved selection
    /// intersected with what this display currently exposes. This is the
    /// single derived value both restore and the UI/CLI report, so "what will
    /// happen" cannot drift between them.
    public func applicableProperties(for display: Display) -> ProtectedProperties {
        protectedProperties(for: display).intersection(ProtectedProperties.available(for: display))
    }

    // MARK: - Save / restore

    /// Save the display's current mode + refresh rate + brightness + active
    /// preset + HDR state + main status, keyed by identityKey. Everything
    /// observable is recorded; which parts are *re-applied* is decided at
    /// restore time by the per-display `ProtectedProperties` selection, so
    /// changing the selection never requires re-saving.
    public func saveCurrentState(for display: Display, resolution: ResolutionController, controller: DisplayController) {
        let state = DisplayStateSnapshot.capture(for: display, resolution: resolution, controller: controller)
        guard let data = try? JSONEncoder().encode(state) else {
            log.warning("saveCurrentState: encode failed for \(display.identityKey)")
            return
        }
        defaults.set(data, forKey: key(for: display.identityKey))
        log.debug("saved config state for \(display.identityKey)")
    }

    /// Re-apply the *selected* properties that this display exposes, for a
    /// display that just (re)appeared: mode first (via
    /// ResolutionController.applyMode), then the preset, HDR mode and main
    /// status, then brightness with a small delay so the mode switch settles.
    /// No-op unless Settings.configProtectionEnabled and saved state exists.
    ///
    /// A property the user selected but the display no longer exposes is
    /// skipped rather than forced — every step is individually guarded, so a
    /// display that lost a capability cannot be driven into an invalid state.
    /// Re-apply the *selected* properties that this display exposes, for a
    /// display that just (re)appeared. The apply itself lives on
    /// `DisplayStateSnapshot` — the same code a named preset runs — with a small
    /// delay before brightness so the mode switch settles.
    /// No-op unless Settings.configProtectionEnabled and saved state exists.
    public func restoreIfNeeded(for display: Display, resolution: ResolutionController, controller: DisplayController) {
        guard Settings.configProtectionEnabled,
              let data = defaults.data(forKey: key(for: display.identityKey)),
              let state = try? JSONDecoder().decode(DisplayStateSnapshot.self, from: data) else {
            return
        }

        state.apply(
            to: display,
            properties: applicableProperties(for: display),
            resolution: resolution,
            controller: controller,
            brightnessDelay: 0.5
        )
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
