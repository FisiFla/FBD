import Foundation
import IOKit

/// Policy for soft-disconnecting the built-in display (`CGSConfigureDisplayEnabled`).
///
/// On Macs with the **base M3** chip — the M3 MacBook Air and the entry-level
/// M3 MacBook Pro — Apple repurposed the built-in panel's connection to drive
/// two external displays in clamshell mode. The side effect is that a
/// soft-disconnected built-in display may not come back until the lid is
/// closed and reopened, and on some machines not even then, leaving a reboot
/// as the only recovery. The cause is in hardware; there is no fix.
///
/// Earlier and later Macs are unaffected — the clamshell route was introduced
/// with the base M3 and abandoned afterwards. BetterDisplay ships the same
/// guard (waydabber/BetterDisplay#4723, BD 5.0.6).
///
/// The decision is deliberately a pure function of (affected hardware, explicit
/// override) so it is testable without attaching the machines in question.
public enum BuiltInDisconnectGuard {
    /// True when `brandString` names the base M3 chip — and not M3 Pro/Max/Ultra.
    ///
    /// `machdep.cpu.brand_string` reports the chip's marketing name, so
    /// "Apple M3" must not match "Apple M3 Pro". A parenthesised suffix (some
    /// tools append the core count) is ignored.
    public static func isBaseM3Chip(_ brandString: String) -> Bool {
        let name = brandString
            .split(separator: "(", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name == "Apple M3"
    }

    /// Whether a built-in disconnect may proceed: allowed everywhere except on
    /// `affected` hardware that has not been explicitly overridden.
    public static func allowsBuiltInDisconnect(affected: Bool, overrideEnabled: Bool) -> Bool {
        !affected || overrideEnabled
    }

    /// Cached hardware probe: base-M3 chip on a laptop.
    ///
    /// Chip-based rather than a model-identifier list on purpose — a list would
    /// silently miss an unrecognised base-M3 model, and a missed machine means
    /// someone loses their screen until they reboot. A false positive only
    /// costs the user one explicit override.
    public static let isAffectedHardware: Bool = isBaseM3Chip(chipBrandString) && hasBattery

    /// The live decision for this machine, combining the hardware probe with
    /// the user's explicit override.
    public static var builtInDisconnectAllowed: Bool {
        allowsBuiltInDisconnect(
            affected: isAffectedHardware,
            overrideEnabled: Settings.allowBuiltInDisconnectOnAffectedMacs
        )
    }

    // MARK: - Probes

    /// `machdep.cpu.brand_string`, or "" when the sysctl is unavailable.
    private static var chipBrandString: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return ""
        }
        return String(cString: buffer)
    }

    /// A Mac carrying an `AppleSmartBattery` service is a laptop. Desktops are
    /// never affected: whatever display they drive is not a clamshell panel.
    private static var hasBattery: Bool {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return false }
        let services = IOKitSupport.matchingServices(matching)
        defer { services.forEach(IOKitSupport.release) }
        return !services.isEmpty
    }
}
