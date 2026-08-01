import FBDCore
import CoreGraphics
import Foundation

// MARK: - list

/// `fbdcli list` — one line per display: id, name, type, current mode, HiDPI,
/// DDC availability, Apple-brightness availability.
@MainActor
func cmdList(_ controller: DisplayController) -> Int32 {
    for display in controller.displays {
        let type = display.isBuiltin ? "builtin" : (display.isVirtual ? "virtual" : "external")
        let mode: String
        let hidpi: String
        if let current = display.currentMode {
            mode = current.key
            hidpi = current.isHiDPI ? "hidpi" : "sdr"
        } else {
            mode = "-"
            hidpi = "-"
        }
        print(
            "\(pad(String(display.id), 4))"
            + " \(pad(display.name, 24))"
            + " \(pad(type, 8))"
            + " \(pad(mode, 16))"
            + " \(pad(hidpi, 6))"
            + " ddc:\(display.ddcAvailable ? "yes" : "no")"
            + "  apple:\(display.appleBrightnessAvailable ? "yes" : "no")"
        )
    }
    return 0
}

// MARK: - info

/// `fbdcli info <id>` — full detail for one display.
@MainActor
func cmdInfo(_ display: Display) -> Int32 {
    let modeLine: String
    if let current = display.currentMode {
        var parts = [current.key]
        parts.append(current.isHiDPI ? "hidpi" : "sdr")
        parts.append(current.isSafe ? "safe" : "unsafe")
        modeLine = parts.joined(separator: " ")
    } else {
        modeLine = "none"
    }
    let capabilities: String
    if let caps = display.ddcCapabilities {
        capabilities = "mccs \(caps.mccsVersion), \(caps.vcpCodes.count) VCP codes"
    } else {
        capabilities = "not read"
    }
    let bounds = display.bounds
    print("Display \(display.id)")
    print("  name: \(display.name)")
    print("  builtin: \(yesno(display.isBuiltin))")
    print("  virtual: \(yesno(display.isVirtual))")
    print(String(format: "  vendor: 0x%04X (%d)", display.vendorNumber, display.vendorNumber))
    print(String(format: "  model: 0x%04X (%d)", display.modelNumber, display.modelNumber))
    print("  serial: \(display.serialNumber)")
    print("  bounds: \(Int(bounds.origin.x)),\(Int(bounds.origin.y)) \(Int(bounds.width))x\(Int(bounds.height))")
    print("  online: \(yesno(display.isOnline))")
    print("  active: \(yesno(display.isActive))")
    print("  current mode: \(modeLine)")
    print("  mode count: \(display.modes.count)")
    print("  ddcAvailable: \(yesno(display.ddcAvailable))")
    print("  appleBrightnessAvailable: \(yesno(display.appleBrightnessAvailable))")
    print("  capabilities: \(capabilities)")
    return 0
}

// MARK: - brightness

/// `fbdcli brightness <id> [0-100]` — print current brightness (0-100, one
/// decimal) or set it (decimals accepted). Writes are debounced by
/// DisplayController, so the main run loop is pumped until the write lands
/// (verified by read-back).
@MainActor
func cmdBrightness(_ controller: DisplayController, display: Display, args: [String]) -> Int32 {
    if args.count >= 2 {
        guard let value = parsePercent(args[1], command: "brightness") else { return 1 }
        let target = value / 100.0
        guard controller.setBrightness(target, on: display) else {
            print("fbdcli: brightness \(display.id): no control path (DDC unavailable or non-Apple display)")
            return 2
        }

        // setBrightness schedules the write via DispatchQueue.main.asyncAfter;
        // pump the main run loop until the value lands or a deadline passes.
        // The deadline accounts for the DDC write cooldown between transactions.
        let debounce = Double(Settings.brightnessDebounceMilliseconds) / 1000.0
        let deadline = Date().addingTimeInterval(debounce + 2.5)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if let readBack = controller.getBrightness(for: display), abs(readBack - target) < 0.02 {
                break
            }
        }
        if let readBack = controller.getBrightness(for: display) {
            print("brightness \(display.id) = \(String(format: "%.1f", readBack * 100))")
        } else {
            print("brightness \(display.id) set to \(String(format: "%.1f", value)) (no read-back available)")
        }
        return 0
    }

    guard let value = controller.getBrightness(for: display) else {
        print("brightness unavailable for display \(display.id) (no Apple or DDC path)")
        return 2
    }
    print(String(format: "%.1f", value * 100))
    return 0
}

// MARK: - contrast / volume

/// `fbdcli contrast <id> [0-100]` — get or set contrast via DDC.
@MainActor
func cmdContrast(_ controller: DisplayController, display: Display, args: [String]) -> Int32 {
    if args.count >= 2 {
        guard let value = parsePercent(args[1], command: "contrast") else { return 1 }
        guard !ddcUnusable(display) else { return 2 }
        guard controller.setContrast(value / 100.0, on: display) else {
            print("fbdcli: contrast \(display.id): write not accepted (DDC unavailable?)")
            return 2
        }
        print("contrast \(display.id) set to \(String(format: "%.1f", value))")
        return 0
    }
    guard !ddcUnusable(display) else { return 2 }
    guard let value = ddcProbe.getFeature(.contrast, for: display) else {
        log.warning("contrast read failed for \(display.id)")
        print("contrast read failed for display \(display.id)")
        return 2
    }
    print(String(format: "%.1f", value * 100))
    return 0
}

/// `fbdcli volume <id> [0-100]` — get or set speaker volume via DDC.
@MainActor
func cmdVolume(_ controller: DisplayController, display: Display, args: [String]) -> Int32 {
    if args.count >= 2 {
        guard let value = parsePercent(args[1], command: "volume") else { return 1 }
        guard !ddcUnusable(display) else { return 2 }
        guard controller.setVolume(value / 100.0, on: display) else {
            print("fbdcli: volume \(display.id): write not accepted (DDC unavailable?)")
            return 2
        }
        print("volume \(display.id) set to \(String(format: "%.1f", value))")
        return 0
    }
    guard !ddcUnusable(display) else { return 2 }
    guard let value = ddcProbe.getFeature(.volume, for: display) else {
        log.warning("volume read failed for \(display.id)")
        print("volume read failed for display \(display.id)")
        return 2
    }
    print(String(format: "%.1f", value * 100))
    return 0
}

// MARK: - mute

/// `fbdcli mute <id> [on|off]` — get or set the mute state via DDC
/// (MCCS VCP 0x8D: 1 = muted, 2 = unmuted; the controller maps on/off).
@MainActor
func cmdMute(_ controller: DisplayController, display: Display, args: [String]) -> Int32 {
    if args.count >= 2 {
        let state: Bool
        switch args[1].lowercased() {
        case "on": state = true
        case "off": state = false
        default:
            print("fbdcli: mute: expected on or off (got '\(args[1])')")
            return 1
        }
        guard !ddcUnusable(display) else { return 2 }
        guard controller.setMuted(state, on: display) else {
            print("fbdcli: mute \(display.id): write not accepted (DDC unavailable?)")
            return 2
        }
        print("mute \(display.id) = \(state ? "on" : "off")")
        return 0
    }
    guard !ddcUnusable(display) else { return 2 }
    guard let value = ddcProbe.getFeature(.mute, for: display) else {
        log.warning("mute read failed for \(display.id)")
        print("mute read failed for display \(display.id)")
        return 2
    }
    // MCCS: 1 = muted, 2 = unmuted (0 reported by some displays = unmuted).
    print(value == 1 ? "on" : "off")
    return 0
}

// MARK: - input

/// `fbdcli input <id> [source]` — get the current input source or switch it
/// via DDC (MCCS VCP 0x60). Bare form prints the current value and a hint
/// table of common MCCS input source numbers.
@MainActor
func cmdInput(_ controller: DisplayController, display: Display, args: [String]) -> Int32 {
    if args.count >= 2 {
        guard let source = UInt16(args[1]) else {
            print("fbdcli: input: source must be a number (got '\(args[1])')")
            return 1
        }
        guard !ddcUnusable(display) else { return 2 }
        guard controller.setInputSource(source, on: display) else {
            print("fbdcli: input \(display.id): write not accepted (DDC unavailable?)")
            return 2
        }
        if let label = inputSourceLabel(source) {
            print("input \(display.id) set to \(source) (\(label))")
        } else {
            print("input \(display.id) set to \(source) (unknown source)")
        }
        return 0
    }
    guard !ddcUnusable(display) else { return 2 }
    var status: Int32 = 0
    if let value = ddcProbe.getFeature(.inputSource, for: display) {
        let source = UInt16(value)
        if let label = inputSourceLabel(source) {
            print("current input: \(source) (\(label))")
        } else {
            print("current input: \(source) (unknown source)")
        }
    } else {
        log.warning("input read failed for \(display.id)")
        print("input read failed for display \(display.id)")
        status = 2
    }
    print(inputSourceHintTable)
    return status
}

/// MCCS 2.2a VCP 0x60 input source labels (decimal values).
func inputSourceLabel(_ value: UInt16) -> String? {
    switch value {
    case 1: return "VGA-1"
    case 2: return "VGA-2"
    case 3: return "DVI-1"
    case 4: return "DVI-2"
    case 5: return "Composite-1"
    case 6: return "Composite-2"
    case 7: return "S-Video-1"
    case 8: return "S-Video-2"
    case 9: return "Tuner-1"
    case 10: return "Tuner-2"
    case 11: return "Tuner-3"
    case 12: return "Component-1"
    case 13: return "Component-2"
    case 14: return "DisplayPort-1"
    case 15: return "DisplayPort-2"
    case 16: return "HDMI-1"
    case 17: return "HDMI-2"
    case 18: return "DVI"
    case 19: return "TV"
    case 20: return "SDI"
    case 21: return "HDMI-3"
    case 22: return "HDMI-4"
    case 23: return "DisplayPort-3"
    case 24: return "DisplayPort-4"
    case 25: return "USB-C (Thunderbolt)"
    default: return nil
    }
}

/// Hint table printed by bare `fbdcli input <id>`.
let inputSourceHintTable: String = {
    let entries: [(Int, String)] = [
        (1, "VGA-1"), (2, "VGA-2"), (3, "DVI-1"), (4, "DVI-2"),
        (5, "Composite-1"), (6, "Composite-2"), (7, "S-Video-1"), (8, "S-Video-2"),
        (9, "Tuner-1"), (10, "Tuner-2"), (11, "Tuner-3"),
        (12, "Component-1"), (13, "Component-2"),
        (14, "DisplayPort-1"), (15, "DisplayPort-2"), (16, "HDMI-1"), (17, "HDMI-2"),
        (18, "DVI"), (19, "TV"), (20, "SDI"),
        (21, "HDMI-3"), (22, "HDMI-4"), (23, "DisplayPort-3"), (24, "DisplayPort-4"),
        (25, "USB-C (Thunderbolt)"),
    ]
    var lines = ["MCCS input source values (VCP 0x60):"]
    for chunkStart in stride(from: 0, to: entries.count, by: 3) {
        let slice = entries[chunkStart..<min(chunkStart + 3, entries.count)]
        let row = slice.map { "\(pad(String($0.0), 3))  \(pad($0.1, 15))" }.joined()
        lines.append(row.trimmingCharacters(in: .whitespaces))
    }
    return lines.joined(separator: "\n")
}()

// MARK: - caps

/// `fbdcli caps <id>` — read the display's DDC capabilities and print the raw
/// capabilities text, parsed VCP codes, and MCCS version.
@MainActor
func cmdCaps(_ display: Display) -> Int32 {
    guard !ddcUnusable(display) else { return 2 }
    guard let caps = ddcProbe.readCapabilities(for: display) else {
        log.warning("capabilities read failed for \(display.id)")
        print("capabilities read failed for display \(display.id)")
        return 2
    }
    print("Display \(display.id) capabilities")
    print("  mccs version: \(caps.mccsVersion.isEmpty ? "unknown" : caps.mccsVersion)")
    let codes = caps.vcpCodes.sorted().map { String(format: "0x%02X", $0) }
    print("  vcp codes (\(codes.count)): \(codes.joined(separator: " "))")
    print("  raw:")
    print(caps.raw)
    return 0
}

// MARK: - modes

/// `fbdcli modes <id>` — one line per mode: resolution@hz, HiDPI, safe, current.
@MainActor
func cmdModes(_ display: Display) -> Int32 {
    guard !display.modes.isEmpty else {
        print("no modes reported for display \(display.id)")
        return 2
    }
    let currentNumber = display.currentMode?.modeNumber
    for mode in display.modes {
        let hidpi = mode.isHiDPI ? "hidpi" : "sdr"
        let safe = mode.isSafe ? "safe" : "unsafe"
        let current = mode.modeNumber == currentNumber ? "  current" : ""
        print("\(mode.key)  \(hidpi)  \(safe)\(current)")
    }
    return 0
}

// MARK: - set-mode

/// `fbdcli set-mode <id> <W>x<H>[@<hz>]` — find the best matching mode (same
/// physical pixels, nearest refresh rate, HiDPI preferred) and apply it.
@MainActor
func cmdSetMode(_ controller: DisplayController, display: Display, args: [String]) -> Int32 {
    guard args.count >= 2 else {
        print("fbdcli: set-mode: expected <id> <W>x<H>[@<hz>]")
        return 1
    }
    guard let (width, height, hz) = parseModeSpec(args[1]) else {
        print("fbdcli: set-mode: invalid mode spec '\(args[1])' (expected WxH[@hz], e.g. 1920x1080@60)")
        return 1
    }
    let candidates = display.modes.filter { $0.pixelsWide == width && $0.pixelsHigh == height }
    guard !candidates.isEmpty else {
        print("no mode matches \(width)x\(height) on display \(display.id)")
        return 2
    }

    let best: DisplayMode
    if let hz {
        // Same pixels, nearest refresh rate, HiDPI preferred, then safe.
        best = candidates.sorted { a, b in
            let distanceA = abs(a.refreshRate - hz)
            let distanceB = abs(b.refreshRate - hz)
            if distanceA != distanceB { return distanceA < distanceB }
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
            return a.isSafe && !b.isSafe
        }.first!
    } else if let current = display.currentMode,
              let sameRate = candidates.first(where: { $0.refreshRate == current.refreshRate }) {
        // No hz requested: keep the current refresh rate when available.
        best = sameRate
    } else {
        // Otherwise prefer HiDPI, then the highest refresh rate, then safe.
        best = candidates.sorted { a, b in
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            if a.refreshRate != b.refreshRate { return a.refreshRate > b.refreshRate }
            return a.isSafe && !b.isSafe
        }.first!
    }

    controller.applyMode(best, to: display)
    print("applied \(best.key) (\(best.isHiDPI ? "hidpi" : "sdr"), \(best.isSafe ? "safe" : "unsafe"))")
    return 0
}

// MARK: - ddc-test

/// `fbdcli ddc-test <id>` — DDC diagnostics: arch + Rosetta status, Apple
/// Silicon, AVService presence, then live readCapabilities and readVCP
/// (brightness). Exit 0 when both DDC reads work, 2 otherwise.
@MainActor
func cmdDdcTest(_ display: Display) -> Int32 {
    #if arch(arm64)
    let arch = "arm64"
    #else
    let arch = "x86_64"
    #endif

    print("ddc-test for display \(display.id) (\(display.name))")
    print("  arch: \(arch)")
    print("  appleSilicon: \(yesno(IOAVServiceAPI.isAppleSilicon))")
    print("  rosetta: \(yesno(IOAVServiceAPI.isRunningUnderRosetta))")
    if let message = ddcUnavailableMessage() {
        print("  \(message)")
    }

    let external = ExternalController()
    let avService = external.avService(for: display) != nil
    print("  avService: \(avService ? "found" : "not found")")

    var ok = true

    // Step 1: capabilities read.
    if let reason = ddcFailureReason(for: display) {
        print("  step readCapabilities: failed — \(reason)")
        ok = false
    } else if let caps = ddcProbe.readCapabilities(for: display) {
        print("  step readCapabilities: ok — mccs \(caps.mccsVersion), \(caps.vcpCodes.count) VCP codes")
    } else {
        log.warning("ddc-test readCapabilities failed for \(display.id)")
        print("  step readCapabilities: failed — I2C transaction failed (no reply)")
        ok = false
    }

    // Step 2: VCP brightness read.
    if let reason = ddcFailureReason(for: display) {
        print("  step readVCP(brightness): failed — \(reason)")
        ok = false
    } else if let value = ddcProbe.readVCP(DDC.VCPCode.brightness.rawValue, for: display) {
        print("  step readVCP(brightness): ok — \(String(format: "%.1f", value.normalized * 100))%")
    } else {
        log.warning("ddc-test readVCP(brightness) failed for \(display.id)")
        print("  step readVCP(brightness): failed — I2C transaction failed (no reply)")
        ok = false
    }

    if display.appleBrightnessAvailable {
        print("  note: brightness also available via the Apple path (DisplayServices)")
    }

    print("  result: \(ok ? "DDC working" : "DDC unavailable") (exit \(ok ? 0 : 2))")
    return ok ? 0 : 2
}

// MARK: - XDR / HDR commands

/// `fbdcli xdr <id>` — show XDR state. `fbdcli xdr <id> <nits>` — enable upscaling.
/// `fbdcli xdr <id> off` — disable upscaling.
@MainActor
func cmdXDR(_ controller: DisplayController, display: Display, args: [String]) -> Int32 {
    if args.count >= 2 {
        if args[1] == "off" {
            guard controller.disableXDRUpscaling(on: display) else {
                print("fbdcli: xdr \(display.id): failed to disable upscaling")
                return 2
            }
            print("xdr \(display.id): upscaling disabled")
            return 0
        }
        guard let nits = Int(args[1]), nits > 0 else {
            print("fbdcli: xdr: expected a nits value or 'off' (got '\(args[1])')")
            return 1
        }
        guard controller.setXDRUpscaleTarget(nits, on: display) else {
            print("fbdcli: xdr \(display.id): failed to enable upscaling to \(nits) nits (no blank preset slot?)")
            return 2
        }
        print("xdr \(display.id): upscaling enabled to \(nits) nits")
        return 0
    }
    guard display.isXDRCapable else {
        print("xdr \(display.id): display has no Apple preset support")
        return 0
    }
    print("xdr \(display.id): capable=yes presets=\(display.presets.filter { $0.isValid }.count) active=\(display.activePresetIndex.map(String.init) ?? "factory") upscaled=\(display.isXDRUpscaled ? "yes (\(display.xdrUpscaleTargetNits ?? 0) nits)" : "no")")
    return 0
}

/// `fbdcli preset <id>` — list presets. `fbdcli preset <id> <index>` — activate.
@MainActor
func cmdPreset(_ controller: DisplayController, display: Display, args: [String]) -> Int32 {
    if args.count >= 2 {
        guard let index = Int(args[1]) else {
            print("fbdcli: preset: expected an index (got '\(args[1])')")
            return 1
        }
        guard display.presets.contains(where: { $0.index == index && $0.isValid }) else {
            print("fbdcli: preset \(index): not a valid preset for display \(display.id)")
            return 2
        }
        guard controller.selectPreset(index, on: display) else {
            print("fbdcli: preset \(index): activation failed")
            return 2
        }
        print("preset \(display.id): activated \(index)")
        return 0
    }
    for preset in display.presets {
        let marker = preset.index == display.activePresetIndex ? " *" : ""
        let valid = preset.isValid ? "valid" : "blank"
        print("  \(preset.index)  \(preset.name)  \(valid)  SDR=\(preset.maxSDRLuminance) HDR=\(preset.maxHDRLuminance)\(marker)")
    }
    return 0
}

/// `fbdcli hdr <id>` — show HDR mode. `fbdcli hdr <id> on|off` — set (external HDR displays).
@MainActor
func cmdHDR(_ controller: DisplayController, display: Display, args: [String]) -> Int32 {
    if args.count >= 2 {
        let enabled: Bool
        switch args[1] {
        case "on": enabled = true
        case "off": enabled = false
        default:
            print("fbdcli: hdr: expected on or off (got '\(args[1])')")
            return 1
        }
        guard controller.setHDRMode(enabled, on: display) else {
            print("fbdcli: hdr \(display.id): display does not support the HDR framebuffer mode")
            return 2
        }
        print("hdr \(display.id): \(enabled ? "on" : "off")")
        return 0
    }
    print("hdr \(display.id): capable=\(display.isHDRModeCapable ? "yes" : "no") enabled=\(display.isHDRModeEnabled ? "yes" : "no")")
    return 0
}

// MARK: - Virtual screens

/// Dispatch `fbdcli virtual <subcommand> [args]`.
@MainActor
func cmdVirtual(args: [String]) -> Int32 {
    guard let sub = args.first else {
        print("fbdcli: virtual: expected list, create, destroy, reconnect, or disconnect-all")
        return 1
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "list":
        return cmdVirtualList()
    case "create":
        return cmdVirtualCreate(args: rest)
    case "destroy":
        return cmdVirtualDestroy(args: rest)
    case "reconnect":
        return cmdVirtualReconnect(args: rest)
    case "disconnect-all":
        return cmdVirtualDisconnectAll()
    default:
        print("fbdcli: virtual: unknown subcommand '\(sub)'")
        return 1
    }
}

/// "WxH@Hz" spec for a virtual screen config (e.g. "1920x1080@60").
func virtualSpec(_ config: VirtualScreenConfig) -> String {
    String(format: "%ux%u@%g", config.width, config.height, config.refreshRate)
}

/// Resolve a persisted virtual screen config by id or name.
func resolveVirtualConfig(_ controller: VirtualScreenController, _ idOrName: String) -> VirtualScreenConfig? {
    controller.configs.first { $0.id == idOrName || $0.name == idOrName }
}

/// `fbdcli virtual list` — table of persisted configs (id, name, spec, hdr,
/// auto, state) plus the currently active screens.
@MainActor
func cmdVirtualList() -> Int32 {
    let controller = VirtualScreenController.shared
    print("\(pad("ID", 36)) \(pad("NAME", 24)) \(pad("SPEC", 16)) \(pad("HDR", 4)) \(pad("AUTO", 5)) STATE")
    for config in controller.configs {
        let state: String
        if let displayID = controller.displayID(for: config.id) {
            state = String(displayID)
        } else {
            state = "—"
        }
        let idCol = pad(config.id, 36)
        let nameCol = pad(config.name, 24)
        let specCol = pad(virtualSpec(config), 16)
        let hdrCol = pad(config.isHDR ? "yes" : "no", 4)
        let autoCol = pad(config.autoConnect ? "yes" : "no", 5)
        print("\(idCol) \(nameCol) \(specCol) \(hdrCol) \(autoCol) \(state)")
    }
    if controller.screens.isEmpty {
        print("no active screens")
    } else {
        print("active screens:")
        for screen in controller.screens {
            print("  \(screen.id)  display \(screen.displayID)  \(screen.config.name)")
        }
    }
    return 0
}

/// `fbdcli virtual create <name> <W>x<H>[@<hz>] [--hdr] [--no-auto]` — create
/// and connect a virtual screen (default refresh rate 60 Hz, auto-connect on).
@MainActor
func cmdVirtualCreate(args: [String]) -> Int32 {
    guard args.count >= 2 else {
        print("fbdcli: virtual create: expected <name> <W>x<H>[@<hz>] [--hdr] [--no-auto]")
        return 1
    }
    let name = args[0]
    guard let (width, height, hz) = parseModeSpec(args[1]) else {
        print("fbdcli: virtual create: invalid spec '\(args[1])' (expected WxH[@hz], e.g. 1920x1080@60)")
        return 1
    }
    var isHDR = false
    var autoConnect = true
    for flag in args.dropFirst(2) {
        switch flag {
        case "--hdr": isHDR = true
        case "--no-auto": autoConnect = false
        default:
            print("fbdcli: virtual create: unknown flag '\(flag)' (expected --hdr or --no-auto)")
            return 1
        }
    }
    let controller = VirtualScreenController.shared
    guard controller.isAvailable else {
        print("virtual displays unavailable on this macOS")
        return 2
    }
    let config = VirtualScreenConfig(
        name: name,
        width: UInt32(width),
        height: UInt32(height),
        refreshRate: hz ?? 60,
        isHDR: isHDR,
        autoConnect: autoConnect
    )
    guard controller.create(config), let displayID = controller.displayID(for: config.id) else {
        print("fbdcli: virtual create: failed to create '\(name)'")
        return 2
    }
    print("virtual display created: \(displayID) (\(name) \(virtualSpec(config)))")
    return 0
}

/// `fbdcli virtual destroy <id-or-name>` — disconnect and forget a persisted config.
@MainActor
func cmdVirtualDestroy(args: [String]) -> Int32 {
    guard let idOrName = args.first, !idOrName.isEmpty else {
        print("fbdcli: virtual destroy: expected <id-or-name>")
        return 1
    }
    let controller = VirtualScreenController.shared
    guard let config = resolveVirtualConfig(controller, idOrName) else {
        print("no virtual screen '\(idOrName)'")
        return 1
    }
    guard controller.destroy(id: config.id) else {
        print("fbdcli: virtual destroy: failed to destroy '\(config.name)'")
        return 2
    }
    print("virtual screen '\(config.name)' destroyed")
    return 0
}

/// `fbdcli virtual reconnect <id-or-name>` — reconnect a persisted config.
@MainActor
func cmdVirtualReconnect(args: [String]) -> Int32 {
    guard let idOrName = args.first, !idOrName.isEmpty else {
        print("fbdcli: virtual reconnect: expected <id-or-name>")
        return 1
    }
    let controller = VirtualScreenController.shared
    guard let config = resolveVirtualConfig(controller, idOrName) else {
        print("no virtual screen '\(idOrName)'")
        return 1
    }
    guard controller.reconnect(id: config.id) else {
        print("fbdcli: virtual reconnect: failed to reconnect '\(config.name)' (already active or creation failed)")
        return 2
    }
    print("virtual screen '\(config.name)' reconnected (display \(controller.displayID(for: config.id) ?? 0))")
    return 0
}

/// `fbdcli virtual disconnect-all` — disconnect all active screens (keeps configs).
@MainActor
func cmdVirtualDisconnectAll() -> Int32 {
    let controller = VirtualScreenController.shared
    let count = controller.screens.count
    controller.disconnectAll()
    print("disconnected \(count) virtual screen(s)")
    return 0
}

// MARK: - disable / enable

/// Parse a display id and require it to be online (a soft-disabled display
/// stays online, so `enable` can find it after `disable` removed it from the
/// active list). Prints a message and returns nil on failure (caller exits 1).
func requireOnlineDisplay(_ idString: String?) -> CGDirectDisplayID? {
    guard let idString, !idString.isEmpty else {
        print("fbdcli: missing display id")
        return nil
    }
    guard let id = parseDisplayID(idString) else {
        print("fbdcli: invalid display id '\(idString)'")
        return nil
    }
    guard CGDisplayIsOnline(id) != 0 else {
        print("Display \(id) not found")
        return nil
    }
    return id
}

/// `fbdcli disable <id>` / `fbdcli enable <id>` — soft-disconnect or re-enable
/// a display in the layout (CGSConfigureDisplayEnabled).
@MainActor
func cmdDisableEnable(displayID: CGDirectDisplayID, enabled: Bool) -> Int32 {
    if !enabled, CGDisplayIsBuiltin(displayID) != 0 {
        print("warning: built-in display will go dark until re-enabled")
    }
    guard DisconnectController().setEnabled(enabled, displayID: displayID) else {
        print("fbdcli: \(enabled ? "enable" : "disable") \(displayID): display configuration failed")
        return 2
    }
    print("display \(displayID) \(enabled ? "enabled" : "disabled")")
    return 0
}

// MARK: - Layout protection

/// Dispatch `fbdcli layout <subcommand> [args]`.
@MainActor
func cmdLayout(args: [String]) -> Int32 {
    guard let sub = args.first else {
        print("fbdcli: layout: expected save, restore, or protect [on|off]")
        return 1
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "save":
        return cmdLayoutSave()
    case "restore":
        return cmdLayoutRestore()
    case "protect":
        return cmdLayoutProtect(args: rest)
    default:
        print("fbdcli: layout: unknown subcommand '\(sub)'")
        return 1
    }
}

/// `fbdcli layout save` — snapshot origins of all active displays.
@MainActor
func cmdLayoutSave() -> Int32 {
    let controller = LayoutProtectionController()
    controller.saveCurrentArrangement()
    let count = Settings.loadLayoutAnchors().count
    print("saved arrangement of \(count) display(s)")
    return 0
}

/// `fbdcli layout restore` — re-apply the saved arrangement.
@MainActor
func cmdLayoutRestore() -> Int32 {
    let controller = LayoutProtectionController()
    guard controller.hasSavedArrangement else {
        print("no saved arrangement to restore")
        return 2
    }
    guard controller.restoreArrangement() else {
        print("fbdcli: layout restore: failed to restore arrangement")
        return 2
    }
    print("arrangement restored")
    return 0
}

/// `fbdcli layout protect [on|off]` — get or set layout protection.
@MainActor
func cmdLayoutProtect(args: [String]) -> Int32 {
    if let arg = args.first {
        let enabled: Bool
        switch arg {
        case "on": enabled = true
        case "off": enabled = false
        default:
            print("fbdcli: layout protect: expected on or off (got '\(arg)')")
            return 1
        }
        Settings.layoutProtectionEnabled = enabled
    }
    print("layout protection: \(Settings.layoutProtectionEnabled ? "on" : "off")")
    return 0
}

// MARK: - Display groups

/// Resolve a group by name, printing a message and returning nil on failure
/// (caller exits 1).
func requireGroup(_ name: String?, in controller: DisplayGroupsController) -> DisplayGroup? {
    guard let name, !name.isEmpty else {
        print("fbdcli: missing group name")
        return nil
    }
    guard let group = controller.group(named: name) else {
        print("no group named '\(name)'")
        return nil
    }
    return group
}

/// Dispatch `fbdcli group <subcommand> [args]`.
@MainActor
func cmdGroup(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let sub = args.first else {
        print("fbdcli: group: expected list, create, delete, add, remove, mirror, or unmirror")
        return 1
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "list":
        return cmdGroupList()
    case "create":
        return cmdGroupCreate(controller, args: rest)
    case "delete":
        return cmdGroupDelete(args: rest)
    case "add":
        return cmdGroupAdd(controller, args: rest)
    case "remove":
        return cmdGroupRemove(args: rest)
    case "mirror":
        return cmdGroupMirror(args: rest, mirror: true)
    case "unmirror":
        return cmdGroupMirror(args: rest, mirror: false)
    default:
        print("fbdcli: group: unknown subcommand '\(sub)'")
        return 1
    }
}

/// `fbdcli group list` — one line per group with its member display ids.
@MainActor
func cmdGroupList() -> Int32 {
    let controller = DisplayGroupsController()
    guard !controller.groups.isEmpty else {
        print("no groups")
        return 0
    }
    for group in controller.groups {
        let members = group.displayIDs.sorted().map(String.init).joined(separator: ", ")
        print("\(group.name): \(members.isEmpty ? "(empty)" : members)")
    }
    return 0
}

/// `fbdcli group create <name> [id...]` — create a group; member ids must
/// belong to known (active) displays.
@MainActor
func cmdGroupCreate(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let name = args.first, !name.isEmpty else {
        print("fbdcli: group create: expected <name> [id...]")
        return 1
    }
    var ids: Set<CGDirectDisplayID> = []
    for idString in args.dropFirst() {
        guard let id = parseDisplayID(idString) else {
            print("fbdcli: invalid display id '\(idString)'")
            return 1
        }
        guard controller.display(withID: id) != nil else {
            print("Display \(id) not found")
            return 1
        }
        ids.insert(id)
    }
    let groups = DisplayGroupsController()
    groups.createGroup(name: name, displayIDs: ids)
    print("created group '\(name)' with \(ids.count) display(s)")
    return 0
}

/// `fbdcli group delete <name>`.
@MainActor
func cmdGroupDelete(args: [String]) -> Int32 {
    guard let name = args.first, !name.isEmpty else {
        print("fbdcli: group delete: expected <name>")
        return 1
    }
    let groups = DisplayGroupsController()
    guard let group = requireGroup(name, in: groups) else { return 1 }
    groups.deleteGroup(id: group.id)
    print("deleted group '\(name)'")
    return 0
}

/// `fbdcli group add <name> <id>` — add a known display to a group.
@MainActor
func cmdGroupAdd(_ controller: DisplayController, args: [String]) -> Int32 {
    guard args.count >= 2 else {
        print("fbdcli: group add: expected <name> <id>")
        return 1
    }
    let groups = DisplayGroupsController()
    guard let group = requireGroup(args[0], in: groups) else { return 1 }
    guard let id = parseDisplayID(args[1]) else {
        print("fbdcli: invalid display id '\(args[1])'")
        return 1
    }
    guard controller.display(withID: id) != nil else {
        print("Display \(id) not found")
        return 1
    }
    guard !group.displayIDs.contains(id) else {
        print("display \(id) already in group '\(group.name)'")
        return 0
    }
    groups.addDisplay(id, toGroup: group.id)
    print("added display \(id) to '\(group.name)'")
    return 0
}

/// `fbdcli group remove <name> <id>` — remove a display from a group.
@MainActor
func cmdGroupRemove(args: [String]) -> Int32 {
    guard args.count >= 2 else {
        print("fbdcli: group remove: expected <name> <id>")
        return 1
    }
    let groups = DisplayGroupsController()
    guard let group = requireGroup(args[0], in: groups) else { return 1 }
    guard let id = parseDisplayID(args[1]) else {
        print("fbdcli: invalid display id '\(args[1])'")
        return 1
    }
    guard group.displayIDs.contains(id) else {
        print("display \(id) not in group '\(group.name)'")
        return 0
    }
    groups.removeDisplay(id, fromGroup: group.id)
    print("removed display \(id) from '\(group.name)'")
    return 0
}

/// `fbdcli group mirror <name>` / `fbdcli group unmirror <name>`.
@MainActor
func cmdGroupMirror(args: [String], mirror: Bool) -> Int32 {
    guard let name = args.first, !name.isEmpty else {
        print("fbdcli: group \(mirror ? "mirror" : "unmirror"): expected <name>")
        return 1
    }
    let groups = DisplayGroupsController()
    guard let group = requireGroup(name, in: groups) else { return 1 }
    let action = mirror ? groups.mirror(inGroup: group.id) : groups.unmirror(inGroup: group.id)
    guard action else {
        print("fbdcli: group \(mirror ? "mirror" : "unmirror"): failed for '\(group.name)'")
        return 2
    }
    print("group '\(group.name)' \(mirror ? "mirrored" : "unmirrored")")
    return 0
}

// MARK: - EDID (Tier 4)

/// Parse a hex string (whitespace/newlines allowed) into raw bytes. Returns
/// nil when the cleaned string is empty, odd-length, or contains non-hex chars.
func parseHexData(_ string: String) -> Data? {
    let cleaned = string.filter { !$0.isWhitespace }
    guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(cleaned.count / 2)
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let next = cleaned.index(index, offsetBy: 2)
        guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return Data(bytes)
}

/// Classic hex dump: 16 bytes per line, 4-digit offset prefix.
func hexDump(_ data: Data) -> String {
    let bytes = [UInt8](data)
    var lines: [String] = []
    lines.reserveCapacity(bytes.count / 16 + 1)
    var offset = 0
    while offset < bytes.count {
        let chunk = bytes[offset..<min(offset + 16, bytes.count)]
        let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
        lines.append(String(format: "%04X: %@", UInt32(offset), hex))
        offset += 16
    }
    return lines.joined(separator: "\n")
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
    guard args.count >= 2 else {
        print("fbdcli: edid apply: expected <id> <file-or-hex>")
        return 1
    }
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
    guard data.count >= 128 else {
        print("fbdcli: edid apply: EDID must be at least 128 bytes (got \(data.count))")
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
    guard args.count >= 2 else {
        print("fbdcli: profile apply: expected <id> <index-or-url>")
        return 1
    }
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
