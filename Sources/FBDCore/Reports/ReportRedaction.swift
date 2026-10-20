import Foundation

/// What a report is allowed to say.
///
/// A report exists to be pasted into a public bug report, so it carries nothing that
/// identifies the person who ran it beyond what diagnosing the display needs. The rules
/// are the same ones the masked settings dump follows (`Settings.debugSummary`): a secret
/// is replaced by `****`, never shortened to something still usable.
///
/// Three rules, and only three:
///
/// 1. **A serial number is masked.** A display's serial identifies the physical unit.
///    Two reports of the same panel are still comparable with the serial masked, because
///    the vendor and product numbers stay.
/// 2. **A path is shortened to its home-relative form.** A path under the user's home
///    directory is replaced with `~`, so the report says "a file in your account" instead
///    of naming the account.
/// 3. **Nothing else is invented.** There is no rule that fills a gap; a field that could
///    not be read is reported as absent, with its reason.
public enum ReportRedaction {
    /// The placeholder that stands in for a masked value.
    public static let masked = "****"

    /// Mask a serial-like number.
    ///
    /// A zero serial means "this display reports no serial", which is a fact rather than
    /// a number, so it is spelled out instead of being masked into a value that looks
    /// like a serial.
    public static func serial(_ value: UInt32) -> String {
        value == 0 ? "not reported" : masked
    }

    /// Mask the serial part of a display identity key.
    ///
    /// The default key is `vendor-model-serial`, so the serial is the last component. A
    /// key built by another identity method is a display name or a lone serial, and is
    /// handled differently:
    ///
    /// - a lone serial is masked entirely;
    /// - a `vendor-model` key has nothing to mask and is left alone;
    /// - a display name is not a serial and is left alone — it is what the user calls the
    ///   panel, and the report needs it.
    ///
    /// A serial of zero means "this display reports no serial", so there is nothing to
    /// mask and the key is left as it is.
    public static func identityKey(_ key: String) -> String {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, parts.allSatisfy({ Int($0) != nil }) {
            guard parts[2] != "0" else { return key }
            return "\(parts[0])-\(parts[1])-\(masked)"
        }
        if parts.count == 1, Int(parts[0]) != nil {
            guard parts[0] != "0" else { return key }
            return masked
        }
        return key
    }

    /// Replace a user's home directory with `~`.
    ///
    /// Paths outside the home directory are left alone: a system path
    /// (`/System/Library/Displays`) identifies no one.
    public static func path(_ path: String) -> String {
        guard !path.isEmpty, path.hasPrefix("/") else { return path }
        let home = NSHomeDirectory()
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        let remainder = String(path.dropFirst(home.count))
        if remainder.isEmpty { return "~" }
        if remainder.hasPrefix("/") { return "~" + remainder }
        return path
    }
}
