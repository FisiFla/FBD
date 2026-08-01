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
    /// unbundled or no SUFeedURL is configured in Info.plist (Sparkle 2.9+
    /// reads the feed URL from the bundle; it is not settable at runtime).
    public func start() {
        #if canImport(Sparkle)
        guard Bundle.main.bundleIdentifier == "dev.fisifla.fbd",
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feed.isEmpty else {
            log.info("updater disabled (unbundled or no SUFeedURL in Info.plist)")
            return
        }
        updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        log.info("Sparkle updater active (feed: \(feed, privacy: .public))")
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
