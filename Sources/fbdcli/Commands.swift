import FBDCore
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
