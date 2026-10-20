import Foundation

/// The command model for a display's HiDPI override.
///
/// The command is a plain string: a validated shell script that writes the
/// override plist and nothing else. Who runs it is a separate concern — today
/// an AppleScript one-shot that asks macOS for an administrator password,
/// tomorrow a privileged helper that authenticates with Touch ID — so
/// swapping the executor never touches the command, and the command can be
/// checked without running anything.
///
/// Everything that ends up in the script is derived from numbers: the
/// vendor, product and serial of a display, and the Base64 of the plist. No
/// name, no label, no free text from anywhere reaches the shell.
public enum HiDPIOverrideCommand {
    /// Why a command could not be built.
    public enum CommandError: Error, Equatable {
        /// The ladder was empty.
        case emptyLadder
        /// The ladder had more modes than the override format allows.
        case tooManyModes
        /// A mode was not exactly eight bytes long.
        case invalidModeSize
        /// The plist was larger than the override format allows.
        case plistTooLarge
    }

    /// Where the per-display overrides live.
    public static let overrideRoot = "/Library/Displays/Contents/Resources/Default/Overrides"

    /// Where the per-model overrides live.
    ///
    /// A display whose serial number is unknown can only be addressed by its
    /// model, so the ladder goes to the model's folder instead.
    public static let modelOverrideRoot = "/Library/Displays/Contents/Resources/Overrides"

    /// The most modes an override may carry.
    public static let maxModes = 4096

    /// The largest plist an override may be, in bytes.
    public static let maxPlistBytes = 96 * 1024

    /// The folder a display's override lives in.
    ///
    /// A display with a serial number gets its own folder, so two identical
    /// panels keep separate ladders. A display without one gets the model's
    /// folder, which is what the system itself falls back to.
    public static func overrideDirectory(vendor: UInt32, product: UInt32, serial: UInt32) -> String {
        let model = "\(modelOverrideRoot)/DisplayVendorID-\(hex(vendor))/DisplayProductID-\(hex(product))"
        guard serial != 0 else { return model }
        return "\(overrideRoot)/DisplayVendorID-\(hex(vendor))/DisplayProductID-\(hex(product))/DisplaySerialNumber-\(serial)"
    }

    /// The path of a display's override plist.
    public static func overridePath(vendor: UInt32, product: UInt32, serial: UInt32) -> String {
        "\(overrideDirectory(vendor: vendor, product: product, serial: serial))/Contents.json"
    }

    /// The shell script that installs a ladder.
    ///
    /// The script writes the plist through a temporary file in the target
    /// folder and renames it into place, so a reader never sees a half-written
    /// override. The temporary file is removed on every exit path.
    ///
    /// - Throws: `CommandError` when the ladder cannot be expressed.
    public static func install(
        vendor: UInt32,
        product: UInt32,
        serial: UInt32,
        scaledModes: [HiDPIScaledMode]
    ) throws -> String {
        let payload = try plistData(for: scaledModes)
        let encoded = payload.base64EncodedString()
        let directory = overrideDirectory(vendor: vendor, product: product, serial: serial)
        let destination = "\(directory)/Contents.json"
        return """
        set -eu
        /bin/mkdir -p '\(directory)'
        stage=$(/usr/bin/mktemp '\(directory)/.fbd-override.XXXXXXXX')
        trap '/bin/rm -f "$stage"' EXIT
        /usr/bin/printf '%s' '\(encoded)' | /usr/bin/base64 -D > "$stage"
        /usr/bin/plutil -lint -s "$stage"
        /bin/chmod 644 "$stage"
        /bin/mv -f "$stage" '\(destination)'
        """
    }

    /// The shell script that removes a ladder.
    public static func remove(path: String) -> String {
        """
        set -eu
        /bin/rm -f '\(path)'
        """
    }

    /// The override plist for a ladder.
    ///
    /// The plist carries the `scale-resolutions` array the system reads; the
    /// ladder's entries are the backing sizes, as Base64 in XML.
    public static func plistData(for modes: [HiDPIScaledMode]) throws -> Data {
        guard !modes.isEmpty else { throw CommandError.emptyLadder }
        guard modes.count <= maxModes else { throw CommandError.tooManyModes }
        let entries = HiDPILadder.scaleResolutions(modes)
        guard entries.allSatisfy({ $0.count == 8 }) else { throw CommandError.invalidModeSize }

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>scale-resolutions</key>
        \t<array>
        """
        for entry in entries {
            xml += "\t\t<data>\(entry.base64EncodedString())</data>\n"
        }
        xml += """
        \t</array>
        </dict>
        </plist>

        """
        guard xml.utf8.count <= maxPlistBytes else { throw CommandError.plistTooLarge }
        return Data(xml.utf8)
    }

    /// Escape a string for an AppleScript literal.
    ///
    /// A backslash first, then a quote: that order matters — escaping the
    /// quotes first would double the backslashes it just introduced.
    public static func appleScriptLiteral(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        return escaped
    }

    /// Whether an override plist already carries a ladder.
    ///
    /// The comparison is order-independent: the system does not care in which
    /// order the entries are listed, so a plist that lists the same modes in
    /// another order is the same override and must not be rewritten (which
    /// would ask for a password for nothing).
    public static func overridePlistMatches(_ data: Data, scaledModes: [HiDPIScaledMode]) -> Bool {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any],
              let existing = plist["scale-resolutions"] as? [Data] else { return false }
        let wanted = Set(HiDPILadder.scaleResolutions(scaledModes))
        return Set(existing) == wanted
    }

    /// A number as the hexadecimal string the override folders use.
    private static func hex(_ value: UInt32) -> String {
        let text = String(value, radix: 16)
        return text.isEmpty ? "0" : text
    }
}
