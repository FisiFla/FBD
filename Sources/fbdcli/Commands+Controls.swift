import FBDCLIParser
import FBDCore
import CoreGraphics
import Foundation

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
            return reportWriteFailure(
                outcome: .failed(reason: "no control path (DDC unavailable or non-Apple display)"),
                command: "brightness \(display.id)",
                readBack: readBackCommand(.brightness, String(display.id))
            )
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
            print("brightness \(display.id) set to \(String(format: "%.1f", value)) (not verified on hardware: no read-back available)")
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
            return reportWriteFailure(
                outcome: .failed(reason: "the write was not sent (DDC unavailable?)"),
                command: "contrast \(display.id)",
                readBack: readBackCommand(.contrast, String(display.id))
            )
        }
        print("contrast \(display.id) set to \(String(format: "%.1f", value))")
        return 0
    }
    guard !ddcUnusable(display) else { return 2 }
    guard let value = controller.readContrast(for: display) else {
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
            return reportWriteFailure(
                outcome: .failed(reason: "the write was not sent (DDC unavailable?)"),
                command: "volume \(display.id)",
                readBack: readBackCommand(.volume, String(display.id))
            )
        }
        print("volume \(display.id) set to \(String(format: "%.1f", value))")
        return 0
    }
    guard !ddcUnusable(display) else { return 2 }
    guard let value = controller.readVolume(for: display) else {
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
/// `fbdcli sysvolume [0-100] [--device <id|name>] [--list]` — the **Mac's own**
/// output volume over CoreAudio (#20).
///
/// Distinct from `volume <id>`, which drives a *display's* speakers over DDC.
/// Both exist because they are different devices; there is one code path per
/// device, and this is the only path to the Mac's.
///
/// Not every output can be controlled: an HDMI output (a TV's speakers) exposes
/// no software volume at all. That is reported rather than papered over, because
/// printing "set to 30" for a write the HAL drops is worse than failing.
func cmdSysVolume(args: [String]) -> Int32 {
    let volume = SystemVolumeController.shared

    if args.contains("--list") {
        volume.refresh()
        waitForOutputDevices(volume)
        guard !volume.devices.isEmpty else {
            print("fbdcli: sysvolume: no output devices found")
            return 2
        }
        print("output devices:")
        for device in volume.devices {
            let control = device.hasVolumeControl ? "volume" : "no volume control"
            let marker = device.id == volume.selectedDevice ? "  selected" : ""
            print("  \(device.id)  \(device.name)  (\(control))\(marker)")
        }
        return 0
    }

    var rest = args
    if let index = rest.firstIndex(of: "--device") {
        guard index + 1 < rest.count else {
            print("fbdcli: sysvolume: --device expects an id or a name")
            return 1
        }
        let spec = rest[index + 1]
        rest.removeSubrange(index...(index + 1))
        guard let chosen = resolveOutputDevice(spec, on: volume) else { return 2 }
        volume.select(chosen)
    }

    if let argument = rest.first {
        guard let percent = parsePercent(argument, command: "sysvolume") else { return 1 }
        volume.set(percent / 100.0)
        return reportSystemVolume(volume, afterWrite: true)
    }
    volume.refresh()
    return reportSystemVolume(volume, afterWrite: false)
}

/// Resolve a device spec: a numeric id, or an unambiguous name substring.
///
/// `AudioDeviceID` is a `UInt32`; spelled that way so the CLI does not pull in
/// CoreAudio for a single type name.
@MainActor
private func resolveOutputDevice(_ spec: String, on volume: SystemVolumeController) -> UInt32? {
    volume.refresh()
    waitForOutputDevices(volume)

    if let id = UInt32(spec), volume.devices.contains(where: { $0.id == id }) {
        return id
    }
    let matches = volume.devices.filter { $0.name.localizedCaseInsensitiveContains(spec) }
    guard let first = matches.first else {
        print("fbdcli: sysvolume: no output device matches '\(spec)' (use --list)")
        return nil
    }
    // An ambiguous name is refused rather than guessed: picking the wrong output
    // silently would be worse than asking for an id.
    guard matches.count == 1 else {
        print("fbdcli: sysvolume: '\(spec)' matches \(matches.count) devices; pass an id from --list")
        return nil
    }
    return first.id
}

@MainActor
private func waitForOutputDevices(_ volume: SystemVolumeController) {
    let deadline = Date().addingTimeInterval(2)
    while volume.devices.isEmpty, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

/// Wait for the deferred HAL work, then report what the device **actually**
/// holds — not what was requested.
@MainActor
private func reportSystemVolume(_ volume: SystemVolumeController, afterWrite: Bool) -> Int32 {
    if afterWrite {
        // The write is deliberately asynchronous so a slow USB device cannot
        // block; give it time to land before reading it back.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        volume.refresh()
    }
    let deadline = Date().addingTimeInterval(2)
    while volume.deviceName == nil, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    guard let level = volume.volume else {
        let name = volume.deviceName.map { " '\($0)'" } ?? ""
        return reportWriteFailure(
            outcome: .failed(reason: "the output device\(name) exposes no software volume control — "
                + "nothing changed (HDMI and some USB outputs have none; use --list, then --device)"),
            command: "sysvolume",
            readBack: readBackCommand(.sysvolume)
        )
    }
    print(String(
        format: "system volume %.1f%% (%@)%@",
        level * 100,
        volume.deviceName ?? "unknown device",
        volume.isMuted ? " — muted" : ""
    ))
    return 0
}

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
            return reportWriteFailure(
                outcome: .failed(reason: "the write was not sent (DDC unavailable?)"),
                command: "mute \(display.id)",
                readBack: readBackCommand(.mute, String(display.id))
            )
        }
        print("mute \(display.id) = \(state ? "on" : "off")")
        return 0
    }
    guard !ddcUnusable(display) else { return 2 }
    guard let muted = controller.readMuted(for: display) else {
        log.warning("mute read failed for \(display.id)")
        print("mute read failed for display \(display.id)")
        return 2
    }
    print(muted ? "on" : "off")
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
            return reportWriteFailure(
                outcome: .failed(reason: "the write was not sent (DDC unavailable?)"),
                command: "input \(display.id)",
                readBack: readBackCommand(.input, String(display.id))
            )
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
    if let value = controller.readInputSource(for: display) {
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
func cmdCaps(_ controller: DisplayController, display: Display) -> Int32 {
    guard !ddcUnusable(display) else { return 2 }
    guard let caps = controller.readDDCCapabilities(for: display) else {
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
    // The offered list rather than the raw one, so the mode-list options are visible
    // here too and the CLI cannot disagree with the panel about what is offerable.
    let offered = display.offeredModes
    guard !offered.isEmpty else {
        print("no modes reported for display \(display.id)")
        return 2
    }
    let hidden = display.modes.count - offered.count
    if hidden > 0 {
        print("\(hidden) mode(s) hidden by the mode-list options (\"Allow unsafe modes\" is off)")
    }
    let currentNumber = display.currentMode?.modeNumber
    for mode in offered {
        let hidpi = mode.isHiDPI ? "hidpi" : "lodpi"
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
    guard requireArgCount(args, 2, usage: "fbdcli: set-mode: expected <id> <W>x<H>[@<hz>]") else { return 1 }
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

    guard controller.applyMode(best, to: display) else {
        return reportWriteFailure(
            outcome: .failed(reason: "the mode \(best.key) was not applied"),
            command: "set-mode \(display.id)",
            readBack: readBackCommand(.setMode, String(display.id))
        )
    }
    print("applied \(best.key) (\(best.isHiDPI ? "hidpi" : "lodpi"), \(best.isSafe ? "safe" : "unsafe"))")
    return 0
}

// MARK: - ddc-test

/// `fbdcli ddc-test <id>` — DDC diagnostics: arch + Rosetta status, Apple
/// Silicon, AVService presence, then live readCapabilities and readVCP
/// (brightness). Exit 0 when both DDC reads work, 2 otherwise.
@MainActor
func cmdDdcTest(_ controller: DisplayController, display: Display) -> Int32 {
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

    let avService = hasAVService(display)
    print("  avService: \(avService ? "found" : "not found")")

    var ok = true

    // Step 1: capabilities read.
    if let reason = ddcFailureReason(for: display) {
        print("  step readCapabilities: failed — \(reason)")
        ok = false
    } else if let caps = controller.readDDCCapabilities(for: display) {
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
    } else if let value = controller.readRawVCP(DDC.VCPCode.brightness.rawValue, for: display) {
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
