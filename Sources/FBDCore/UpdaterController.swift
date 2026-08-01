import Foundation
import os
#if canImport(Sparkle)
import Sparkle
#endif

private let log = Logger(subsystem: "dev.fisifla.fbd", category: "Updater")

/// Sparkle auto-update integration (optional). Only active when:
/// - the app runs from a signed .app bundle, and
/// - Settings.updateFeedURL is non-empty (a release appcast must exist).
public final class UpdaterController {
    public static let shared = UpdaterController()

    #if canImport(Sparkle)
    private var updater: SPUStandardUpdaterController?
    #endif

    public init() {}

    /// Start checking for updates (once per launch, delayed). No-op when
    /// unbundled or no feed URL is configured.
    public func start() {
        #if canImport(Sparkle)
        guard Bundle.main.bundleIdentifier == "dev.fisifla.fbd",
              !Settings.updateFeedURL.isEmpty else {
            log.info("updater disabled (unbundled or no feed URL)")
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.feedURL = URL(string: Settings.updateFeedURL)
        updater = controller
        log.info("Sparkle updater active (feed: \(Settings.updateFeedURL, privacy: .public))")
        #else
        log.info("updater unavailable (Sparkle not linked)")
        #endif
    }

    /// Check for updates now (menu item).
    public func checkForUpdates() {
        #if canImport(Sparkle)
        updater?.checkForUpdates(nil)
        #endif
    }
}
