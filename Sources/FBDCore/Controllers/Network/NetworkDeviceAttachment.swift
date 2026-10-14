import Foundation

/// How a display's volume maps onto a network device's.
public enum NetworkDeviceVolume {
    /// A display reports volume as 0…1; every `Network/` controller takes 0…100.
    /// Clamped, so a caller cannot send a device something it would refuse.
    public static func percent(fromDisplayVolume value: Double) -> Int {
        Int((min(max(value, 0), 1) * 100).rounded())
    }
}

/// Attaches a saved network device to a display, so the display's own volume
/// control also reaches the device.
///
/// BetterDisplay grafts its smart-device controllers onto a display. FBD's devices
/// have no `CGDirectDisplayID`, so this is a mapping rather than a graft — and it is
/// keyed by the display's **identity** (`vendor-model-serial`), not its id, so a
/// reconnect that renumbers the display keeps the attachment.
///
/// Persisted as one JSON object through `Settings.defaults`, the single write path
/// the app and the CLI share.
public enum NetworkDeviceAttachment {
    /// `displayIdentity` → device name.
    public static func attachments(defaults: UserDefaults = Settings.defaults) -> [String: String] {
        guard let data = defaults.data(forKey: Settings.networkDeviceAttachmentsKey),
              let attachments = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return attachments
    }

    /// Attach a device to a display.
    ///
    /// Refuses a device that is not in the registry. An attachment to nothing is a
    /// dangling reference the user cannot see, and storing one would make the
    /// Settings list claim a device that is not there.
    @discardableResult
    public static func attach(
        deviceNamed name: String,
        toDisplay displayIdentityKey: String,
        defaults: UserDefaults = Settings.defaults
    ) -> Bool {
        guard !displayIdentityKey.isEmpty else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, NetworkDeviceRegistry.device(named: trimmed, defaults: defaults) != nil else {
            return false
        }
        var current = attachments(defaults: defaults)
        current[displayIdentityKey] = trimmed
        save(current, defaults: defaults)
        return true
    }

    /// Remove a display's attachment. Returns false when it had none.
    @discardableResult
    public static func detach(
        displayIdentityKey: String,
        defaults: UserDefaults = Settings.defaults
    ) -> Bool {
        var current = attachments(defaults: defaults)
        guard current.removeValue(forKey: displayIdentityKey) != nil else { return false }
        save(current, defaults: defaults)
        return true
    }

    /// The device attached to a display, or nil.
    ///
    /// A name whose device has since been deleted resolves to nil rather than to a
    /// half-built device — see `danglingNames` for how that is surfaced.
    public static func device(
        forDisplay displayIdentityKey: String,
        defaults: UserDefaults = Settings.defaults
    ) -> NetworkDevice? {
        guard let name = attachments(defaults: defaults)[displayIdentityKey] else { return nil }
        return NetworkDeviceRegistry.device(named: name, defaults: defaults)
    }

    /// Attached names whose device no longer exists, so a caller can say so instead
    /// of showing nothing where the user expected a device.
    public static func danglingNames(defaults: UserDefaults = Settings.defaults) -> [String] {
        let attached = attachments(defaults: defaults)
        guard !attached.isEmpty else { return [] }
        return attached.values
            .filter { NetworkDeviceRegistry.device(named: $0, defaults: defaults) == nil }
            .sorted()
    }

    private static func save(_ attachments: [String: String], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(attachments) else { return }
        defaults.set(data, forKey: Settings.networkDeviceAttachmentsKey)
    }
}
