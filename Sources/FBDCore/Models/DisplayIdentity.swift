import Foundation

/// How a display is matched to its stored settings.
///
/// Changing this re-keys every per-display setting, so the default reproduces the
/// historical key byte-for-byte and an existing install keeps all of its state.
/// Moving a display that already has settings onto a different method is what
/// `DisplaySettingsTransfer` exists for.
public enum DisplayIdentityMethod: String, Codable, CaseIterable, Sendable {
    /// Vendor, model and serial — the historical key, and the most precise.
    case vendorModelSerial
    /// Vendor and model only. For adapters and hubs that report a different
    /// serial on every connection, where a serial-keyed setting can never match
    /// the next time the display appears.
    case vendorModel
    /// Serial only, for a rig where several identical panels share a model number
    /// and only the serial tells them apart.
    case serial
    /// The display's name. The loosest match: two identical monitors report the
    /// same name, so they would share one set of settings.
    case displayName

    public static let `default`: DisplayIdentityMethod = .vendorModelSerial

    public var label: String {
        switch self {
        case .vendorModelSerial: return "Vendor, model and serial"
        case .vendorModel: return "Vendor and model"
        case .serial: return "Serial only"
        case .displayName: return "Display name"
        }
    }

    /// What choosing this costs, so the trade-off is visible where it is picked
    /// rather than discovered as orphaned settings later.
    public var caveat: String {
        switch self {
        case .vendorModelSerial:
            return "Default. Most precise; a display whose serial changes on reconnect will not match."
        case .vendorModel:
            return "Right for adapters and hubs that report a new serial each time."
        case .serial:
            return "For identical panels that share a model number."
        case .displayName:
            return "Loosest. Two identical monitors share one set of settings."
        }
    }
}

/// Builds the key a display's persisted settings are filed under.
public enum DisplayIdentity {
    /// The identity key for a display under `method`.
    ///
    /// `.vendorModelSerial` reproduces the historical `"vendor-model-serial"`
    /// string exactly, which is why it is the default: nothing that is already
    /// stored moves.
    public static func key(
        vendor: UInt32,
        model: UInt32,
        serial: UInt32,
        name: String,
        method: DisplayIdentityMethod
    ) -> String {
        switch method {
        case .vendorModelSerial:
            return "\(vendor)-\(model)-\(serial)"
        case .vendorModel:
            return "\(vendor)-\(model)"
        case .serial:
            return "\(serial)"
        case .displayName:
            let normalized = normalizedName(name)
            // A nameless display would otherwise share one empty key with every
            // other nameless display, so fall back to the precise key instead.
            return normalized.isEmpty
                ? key(vendor: vendor, model: model, serial: serial, name: name, method: .vendorModelSerial)
                : normalized
        }
    }

    /// Names are compared trimmed, case-folded and with whitespace runs collapsed,
    /// so re-capitalising or re-spacing a display's name does not orphan its
    /// settings.
    static func normalizedName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
