import ColorSync
import CoreGraphics
import Foundation

/// ColorSync dictionary keys (the kColorSync* constants import as Unmanaged<CFString>?).
private enum CSKey {
    static let factory = kColorSyncFactoryProfiles!.takeUnretainedValue() as String
    static let custom = kColorSyncCustomProfiles!.takeUnretainedValue() as String
    static let profileURL = kColorSyncDeviceProfileURL!.takeUnretainedValue() as String
    static let modeDescription = kColorSyncDeviceModeDescription!.takeUnretainedValue() as String
    static let defaultProfileID = kColorSyncDeviceDefaultProfileID!.takeUnretainedValue() as String
}
import os

/// A display color profile (name + file URL), as reported by ColorSync.
public struct ColorProfile: Identifiable, Equatable, Sendable {
    public let url: URL
    public let name: String
    public var id: URL { url }

    public init(url: URL, name: String) {
        self.url = url
        self.name = name
    }
}

/// Per-display color profile management through the public ColorSync device
/// APIs. Displays are registered with ColorSync under
/// `kColorSyncDisplayDeviceClass` using the CFUUID produced by
/// `CGDisplayCreateUUIDFromDisplayID` (declared in the public
/// ColorSyncDevice.h header).
///
/// Plain class; all methods are user-initiated (no observers, no automatic
/// application of profiles).
public final class ColorProfileController {
    private let log = Logger(subsystem: "dev.fisifla.fbd", category: "ColorProfileController")

    public init() {}

    // MARK: - Query

    /// All color profiles known for a display (factory + custom, custom
    /// overriding factory by profile URL), sorted by name. Returns [] when the
    /// display is not registered with ColorSync or the device info cannot be
    /// read — never throws.
    public func profiles(for display: Display) -> [ColorProfile] {
        guard let deviceInfo = deviceInfo(for: display) else { return [] }

        var byURL: [URL: ColorProfile] = [:]

        let factory = deviceInfo[CSKey.factory] as? [String: Any] ?? [:]
        for (_, raw) in factory {
            guard let info = raw as? [String: Any],
                  let url = info[CSKey.profileURL] as? URL else {
                // Entries may carry kCFNull in lieu of a URL (no factory profile).
                continue
            }
            byURL[url] = ColorProfile(
                url: url,
                name: profileName(for: url, modeDescription: info[CSKey.modeDescription] as? String)
            )
        }

        // Custom profiles override factory entries with the same URL.
        let custom = deviceInfo[CSKey.custom] as? [String: Any] ?? [:]
        for (key, value) in custom where key != (CSKey.defaultProfileID) {
            guard let url = value as? URL else { continue } // kCFNull = custom profile unset
            byURL[url] = ColorProfile(url: url, name: profileName(for: url, modeDescription: nil))
        }

        if byURL.isEmpty {
            log.debug("profiles(for:): no profiles registered for display \(display.id)")
        }
        return byURL.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// The default (factory) profile URL for a display. Prefers the active
    /// custom default when one is set, then `kColorSyncDeviceDefaultProfileID`
    /// from the factory profiles; falls back to the sole factory profile.
    public func defaultProfile(for display: Display) -> URL? {
        guard let deviceInfo = deviceInfo(for: display) else { return nil }

        // A custom default (kColorSyncDeviceDefaultProfileID inside the custom
        // profiles dictionary) is the currently active profile.
        if let custom = deviceInfo[CSKey.custom] as? [String: Any],
           let url = custom[CSKey.defaultProfileID] as? URL {
            return url
        }

        guard let factory = deviceInfo[CSKey.factory] as? [String: Any] else {
            return nil
        }
        if let defaultID = factory[CSKey.defaultProfileID] as? String,
           let info = factory[defaultID] as? [String: Any],
           let url = info[CSKey.profileURL] as? URL {
            return url
        }
        // No explicit default ID: a single factory profile is the default.
        let urls = factory.values.compactMap { ($0 as? [String: Any])?[CSKey.profileURL] as? URL }
        return urls.count == 1 ? urls.first : nil
    }

    // MARK: - Apply

    /// Apply a profile by URL as the display's custom default profile
    /// (`ColorSyncDeviceSetCustomProfiles` with `kColorSyncCustomProfiles`
    /// keyed by `kColorSyncDeviceDefaultProfileID`). Returns false on failure.
    @discardableResult
    public func applyProfile(_ url: URL, for display: Display) -> Bool {
        let uuid = CGDisplayCreateUUIDFromDisplayID(display.id)
        let custom: [String: Any] = [CSKey.defaultProfileID: url]
        let profileInfo: [String: Any] = [CSKey.custom: custom]
        let ok = ColorSyncDeviceSetCustomProfiles(
            kColorSyncDisplayDeviceClass!.takeUnretainedValue(),
            uuid!.takeUnretainedValue(),
            profileInfo as CFDictionary
        )
        if !ok {
            log.warning("applyProfile failed for display \(display.id): \(url.path)")
        }
        return ok
    }

    /// Restore the factory default profile by clearing the custom profiles.
    /// First tries an empty custom-profiles dictionary, then the documented
    /// unset (kCFNull in lieu of the profile URL). Returns false on failure.
    @discardableResult
    public func restoreDefault(for display: Display) -> Bool {
        let uuid = CGDisplayCreateUUIDFromDisplayID(display.id)
        let empty: [String: Any] = [CSKey.custom: [String: Any]()]
        if ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass!.takeUnretainedValue(), uuid!.takeUnretainedValue(), empty as CFDictionary) {
            return true
        }
        // Documented reset: pass kCFNull in lieu of the profile URL.
        let unset: [String: Any] = [
            CSKey.custom: [CSKey.defaultProfileID: NSNull()],
        ]
        let ok = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass!.takeUnretainedValue(), uuid!.takeUnretainedValue(), unset as CFDictionary)
        if !ok {
            log.warning("restoreDefault failed for display \(display.id)")
        }
        return ok
    }

    // MARK: - Helpers

    /// The display's ColorSync device info dictionary (factory + custom
    /// profiles resolved for the current host/user). nil when the display is
    /// not registered with ColorSync.
    private func deviceInfo(for display: Display) -> [String: Any]? {
        let uuid = CGDisplayCreateUUIDFromDisplayID(display.id)
        guard let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass!.takeUnretainedValue(), uuid!.takeUnretainedValue()) else {
            log.warning("ColorSyncDeviceCopyDeviceInfo failed for display \(display.id)")
            return nil
        }
        return info as? [String: Any]
    }

    /// Best available profile name: the profile's own description from its ICC
    /// header (what ColorSync Utility shows), then the device's localized mode
    /// description, then the file name.
    private func profileName(for url: URL, modeDescription: String?) -> String {
        if let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil) {
            let profileRef = profile.takeRetainedValue()
            if let description = ColorSyncProfileCopyDescriptionString(profileRef)?.takeRetainedValue() as String?,
               !description.isEmpty {
                return description
            }
        }
        if let modeDescription, !modeDescription.isEmpty {
            return modeDescription
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        return fileName.isEmpty ? "Profile" : fileName
    }
}
