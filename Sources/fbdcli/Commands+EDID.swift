import FBDCLIParser
import FBDCore
import CoreGraphics
import Foundation

// MARK: - EDID (Tier 4)

/// Parse a hex string (whitespace/newlines allowed) into raw bytes. Returns
/// nil when the cleaned string is empty, odd-length, or contains non-hex chars.
func parseHexData(_ string: String) -> Data? {
    EDIDHex.parse(string)
}

/// Classic hex dump: 16 bytes per line, 4-digit offset prefix.
func hexDump(_ data: Data) -> String {
    EDIDHex.dump(data)
}

/// Print a human-readable summary of a parsed EDID block (2-space indented).
func printEDIDSummary(_ parsed: EDIDParser.ParsedEDID) {
    print("  manufacturer: \(parsed.manufacturer.isEmpty ? "(unknown)" : parsed.manufacturer)")
    print("  product code: \(parsed.productCode)")
    print("  serial: \(parsed.serialNumber)")
    print("  manufactured: week \(parsed.weekOfManufacture) of \(parsed.yearOfManufacture)")
    print("  EDID version: \(parsed.edidVersion.major).\(parsed.edidVersion.minor)")
    print("  digital: \(yesno(parsed.isDigital))")
    print(String(format: "  gamma: %.2f", parsed.gamma))
    print("  max size: \(parsed.maxHorizontalSizeCM) x \(parsed.maxVerticalSizeCM) cm")
    if let name = parsed.monitorName {
        print("  monitor name: \(name)")
    }
    if let timing = parsed.preferredTiming {
        print("  preferred timing: \(timing.width)x\(timing.height)")
    }
    print("  checksum: \(parsed.isChecksumValid ? "ok" : "bad")")
}

/// Dispatch `fbdcli edid <subcommand> [args]`.
@MainActor
func cmdEDID(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let sub = args.first else {
        print("fbdcli: edid: expected export, apply, restore, or auto")
        return 1
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "export":
        return cmdEDIDExport(controller, args: rest)
    case "apply":
        return cmdEDIDApply(controller, args: rest)
    case "restore":
        return cmdEDIDRestore(controller, args: rest)
    case "auto":
        return cmdEDIDAuto(args: rest)
    default:
        print("fbdcli: edid: unknown subcommand '\(sub)'")
        return 1
    }
}

/// `fbdcli edid export <id> [file]` — export the display's current EDID.
/// Without a file: 16-bytes-per-line hex dump + parsed summary. With a file:
/// write the raw bytes and print the path.
@MainActor
func cmdEDIDExport(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let display = requireDisplay(args.first, in: controller) else { return 1 }
    let edidController = EDIDController()
    guard let edid = edidController.exportEDID(for: display) else {
        print("fbdcli: edid export: no EDID available for display \(display.id)")
        return 2
    }
    if args.count >= 2 {
        let url = URL(fileURLWithPath: args[1])
        do {
            try edid.write(to: url)
        } catch {
            print("fbdcli: edid export: failed to write \(args[1]): \(error.localizedDescription)")
            return 2
        }
        print("wrote \(edid.count)-byte EDID to \(url.path)")
        return 0
    }
    print("Display \(display.id) EDID (\(edid.count) bytes)")
    print(hexDump(edid))
    if let parsed = EDIDParser.parse(edid) {
        printEDIDSummary(parsed)
    } else {
        print("  (could not parse EDID block)")
    }
    return 0
}

/// `fbdcli edid apply <id> <file-or-hex>` — read the override from a file or
/// parse it from a hex string, then install it as a virtual EDID.
@MainActor
func cmdEDIDApply(_ controller: DisplayController, args: [String]) -> Int32 {
    guard requireArgCount(args, 2, usage: "fbdcli: edid apply: expected <id> <file-or-hex>") else { return 1 }
    guard let display = requireDisplay(args[0], in: controller) else { return 1 }
    let edidController = EDIDController()
    if !edidController.isAvailable {
        print("warning: EDID overrides unsupported on this hardware (Intel/unsupported) — export only")
    }
    let source = args[1]
    let data: Data?
    if FileManager.default.fileExists(atPath: source) {
        data = try? Data(contentsOf: URL(fileURLWithPath: source))
    } else {
        data = parseHexData(source)
    }
    guard let data = data, !data.isEmpty else {
        print("fbdcli: edid apply: cannot read '\(source)' (no such file or invalid hex)")
        return 1
    }
    if let reason = EDIDValidation.validate(data) {
        print("fbdcli: edid apply: invalid EDID: \(reason)")
        return 1
    }
    guard edidController.applyOverride(data, for: display) else {
        print("fbdcli: edid apply: failed to apply override to display \(display.id)")
        return 2
    }
    print("applied \(data.count)-byte EDID override to display \(display.id)")
    return 0
}

/// `fbdcli edid restore <id>` — restore the factory EDID, using the current
/// export as the original reference (export also captures the factory state).
@MainActor
func cmdEDIDRestore(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let display = requireDisplay(args.first, in: controller) else { return 1 }
    let edidController = EDIDController()
    let original = edidController.exportEDID(for: display)
    guard edidController.restoreFactory(originalEDID: original, for: display) else {
        print("fbdcli: edid restore: failed to restore factory EDID for display \(display.id)")
        return 2
    }
    print("restored factory EDID for display \(display.id)")
    return 0
}

/// `fbdcli edid auto [on|off]` — get or set auto-apply of saved EDID overrides.
@MainActor
func cmdEDIDAuto(args: [String]) -> Int32 {
    if let arg = args.first {
        let enabled: Bool
        switch arg {
        case "on": enabled = true
        case "off": enabled = false
        default:
            print("fbdcli: edid auto: expected on or off (got '\(arg)')")
            return 1
        }
        Settings.autoApplyEDIDOverride = enabled
    }
    print("auto-apply EDID override: \(Settings.autoApplyEDIDOverride ? "on" : "off")")
    return 0
}

// MARK: - Color profiles (Tier 4)

/// Dispatch `fbdcli profile <subcommand> [args]`.
@MainActor
func cmdProfile(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let sub = args.first else {
        print("fbdcli: profile: expected list, apply, or restore")
        return 1
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "list":
        return cmdProfileList(controller, args: rest)
    case "apply":
        return cmdProfileApply(controller, args: rest)
    case "restore":
        return cmdProfileRestore(controller, args: rest)
    default:
        print("fbdcli: profile: unknown subcommand '\(sub)'")
        return 1
    }
}

/// `fbdcli profile list <id>` — one line per profile "index  name  url",
/// plus the default profile.
@MainActor
func cmdProfileList(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let display = requireDisplay(args.first, in: controller) else { return 1 }
    let profileController = ColorProfileController()
    let profiles = profileController.profiles(for: display)
    if profiles.isEmpty {
        print("no color profiles found for display \(display.id)")
    } else {
        for (index, profile) in profiles.enumerated() {
            print("\(index)  \(profile.name)  \(profile.url.path)")
        }
    }
    if let defaultURL = profileController.defaultProfile(for: display) {
        print("default: \(defaultURL.path)")
    } else {
        print("default: (none)")
    }
    return 0
}

/// `fbdcli profile apply <id> <index-or-url>` — apply a profile by list index
/// (from `profile list`) or by URL/name substring.
@MainActor
func cmdProfileApply(_ controller: DisplayController, args: [String]) -> Int32 {
    guard requireArgCount(args, 2, usage: "fbdcli: profile apply: expected <id> <index-or-url>") else { return 1 }
    guard let display = requireDisplay(args[0], in: controller) else { return 1 }
    let profileController = ColorProfileController()
    let profiles = profileController.profiles(for: display)
    let target = args[1]
    var profile: ColorProfile?
    if let index = Int(target), profiles.indices.contains(index) {
        profile = profiles[index]
    } else if let match = profiles.first(where: {
        $0.url.path.localizedCaseInsensitiveContains(target)
            || $0.name.localizedCaseInsensitiveContains(target)
    }) {
        profile = match
    }
    guard let profile = profile else {
        print("no profile matches '\(target)' (use 'fbdcli profile list \(display.id)')")
        return 1
    }
    guard profileController.applyProfile(profile.url, for: display) else {
        print("fbdcli: profile apply: failed to apply profile '\(profile.name)' to display \(display.id)")
        return 2
    }
    print("applied profile '\(profile.name)' to display \(display.id)")
    return 0
}

/// `fbdcli profile restore <id>` — restore the display's default profile.
@MainActor
func cmdProfileRestore(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let display = requireDisplay(args.first, in: controller) else { return 1 }
    guard ColorProfileController().restoreDefault(for: display) else {
        print("fbdcli: profile restore: failed to restore default profile for display \(display.id)")
        return 2
    }
    print("restored default color profile for display \(display.id)")
    return 0
}

// MARK: - Underscan (Tier 4)

/// `fbdcli underscan <id> [on|off]` — set underscan (TVs only). No getter
/// exists on UnderscanController, so the bare form explains the set-only API.
/// `args` includes the display id at index 0 (mirrors the brightness pattern).
@MainActor
func cmdUnderscan(display: Display, args: [String]) -> Int32 {
    if args.count >= 2 {
        let enabled: Bool
        switch args[1] {
        case "on": enabled = true
        case "off": enabled = false
        default:
            print("fbdcli: underscan: expected on or off (got '\(args[1])')")
            return 1
        }
        guard UnderscanController().setUnderscan(enabled, for: display) else {
            print("fbdcli: underscan: failed for display \(display.id) (no underscan support?)")
            return 2
        }
        print("underscan \(display.id) = \(enabled ? "on" : "off")")
        return 0
    }
    print("underscan control (set only): pass on or off, e.g. 'fbdcli underscan \(display.id) on'")
    return 0
}

// MARK: - Config protection (Tier 4)

/// Dispatch `fbdcli protect <subcommand> [args]`.
@MainActor
func cmdProtect(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let sub = args.first else {
        print("fbdcli: protect: expected config, save, or restore")
        return 1
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "config":
        return cmdProtectConfig(args: rest)
    case "save":
        return cmdProtectSave(controller, args: rest)
    case "restore":
        return cmdProtectRestore(controller, args: rest)
    default:
        print("fbdcli: protect: unknown subcommand '\(sub)'")
        return 1
    }
}

/// `fbdcli protect config [on|off]` — get or set config protection.
@MainActor
func cmdProtectConfig(args: [String]) -> Int32 {
    if let arg = args.first {
        let enabled: Bool
        switch arg {
        case "on": enabled = true
        case "off": enabled = false
        default:
            print("fbdcli: protect config: expected on or off (got '\(arg)')")
            return 1
        }
        Settings.configProtectionEnabled = enabled
    }
    print("config protection: \(Settings.configProtectionEnabled ? "on" : "off")")
    return 0
}

/// `fbdcli protect save <id>` — snapshot the display's current
/// resolution/preset/brightness for later restore.
@MainActor
func cmdProtectSave(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let display = requireDisplay(args.first, in: controller) else { return 1 }
    ConfigProtectionController().saveCurrentState(
        for: display,
        resolution: ResolutionController(),
        controller: controller
    )
    print("saved config state for display \(display.id)")
    return 0
}

/// `fbdcli protect restore <id>` — re-apply saved config if any (no-op unless
/// config protection is enabled and state was saved).
@MainActor
func cmdProtectRestore(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let display = requireDisplay(args.first, in: controller) else { return 1 }
    guard Settings.configProtectionEnabled else {
        print("config protection is off — nothing restored (enable with 'fbdcli protect config on')")
        return 0
    }
    ConfigProtectionController().restoreIfNeeded(
        for: display,
        resolution: ResolutionController(),
        controller: controller
    )
    print("config restore requested for display \(display.id)")
    return 0
}
