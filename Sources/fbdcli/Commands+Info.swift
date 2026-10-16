import FBDCLIParser
import FBDCore
import CoreGraphics
import Foundation

// MARK: - list

/// `fbdcli list` — one line per display: id, name, type, current mode, HiDPI,
/// DDC availability, Apple-brightness availability.
@MainActor
func cmdList(_ controller: DisplayController, args: [String]) -> Int32 {
    if args.contains("--json") {
        // Machine-readable output (same serializer the app's HTTP API uses).
        print(HTTPJSON.encode(["displays": controller.displays.map { HTTPJSON.display($0) }]))
        return 0
    }
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

// MARK: - report

/// `fbdcli report [file]` — a detailed, paste-ready report of every display, for
/// pasting into a bug report. Prints, or writes to `file` when one is given.
///
// MARK: - DPCD (live, over AUX)

/// `fbdcli dpcd <display> [address] [length]` — read a DisplayPort sink's DPCD over AUX and decode
/// it with the same decoder `report --dpcd` uses.
///
/// A **read**, and read-only by construction: the shim declares only `IODPDeviceReadDPCD`. Its
/// write-side neighbours — `IODPDeviceWriteDPCD`, the retrain and the set calls — all resolve on this
/// macOS and are deliberately absent, because a wrong write there can wedge the only attached
/// display.
@MainActor
func cmdDPCD(_ controller: DisplayController, display: Display, args: [String]) -> Int32 {
    guard IODPAPI.isAvailable else {
        print("dpcd: the IODP entry points are unavailable on this Mac")
        return 2
    }
    var address = DPCDRequest.receiverCapabilityAddress
    if let raw = args.first {
        guard let parsed = UInt32(raw, radix: 16) else {
            print("fbdcli: dpcd: address must be hex (got '\(raw)')")
            return 1
        }
        address = parsed
    }
    var length = 16
    if args.count >= 2 {
        guard let parsed = Int(args[1]) else {
            print("fbdcli: dpcd: length must be a number (got '\(args[1])')")
            return 1
        }
        length = parsed
    }
    guard let request = DPCDRequest(address: address, length: length) else {
        print("fbdcli: dpcd: length must be 1…\(DPCDRequest.maxLength)")
        return 1
    }
    switch IODPAPI.read(request, for: display) {
    case .success(let bytes):
        print("dpcd \(display.id): \(bytes.count) byte(s) from 0x\(String(format: "%04X", address))")
        print(DPCDReport.decode(DPCDBuffer(bytes, startingAt: Int(address))).render())
        return 0
    case .failure(let failure):
        print("dpcd \(display.id): \(failure.description)")
        return 2
    }
}

/// The formatting lives in `DisplayReport` in FBDCore and is locked by tests, so
/// the CLI only supplies the facts it alone can know.
/// `report --dpcd <hex>` / `--dpcd <hexaddr>:<hex>` — decode a supplied DPCD dump.
///
/// For a dump read straight off a sink, `fbdcli dpcd <display>` goes through the live AUX path
/// (`IODPAPI`); this option stays for a dump from another tool, or one captured earlier. The option
/// may be repeated with an address prefix, which matters because HDCP's BSTATUS sits at 0x68028, far
/// from the capability block.
///
/// Returns nil when the option is absent, so `report` carries on with displays.
@MainActor
func cmdReportDPCD(_ args: [String]) -> Int32? {
    guard args.contains("--dpcd") else { return nil }
    var segments: [DPCDBuffer.Segment] = []
    var index = 0
    while index < args.count {
        guard args[index] == "--dpcd" else {
            index += 1
            continue
        }
        guard index + 1 < args.count else {
            print("fbdcli: report --dpcd: missing a hex value")
            return 1
        }
        guard let segment = parseDPCDFragment(args[index + 1]) else {
            print("fbdcli: report --dpcd: expected hex bytes, optionally prefixed with a hex "
                + "address (0000:14, or 68028:00 for HDCP), got '\(args[index + 1])'")
            return 1
        }
        segments.append(segment)
        index += 2
    }
    print(DPCDReport.decode(DPCDBuffer(segments: segments)).render())
    return 0
}

/// `0014` → a segment at address 0. `68028:00` → a one-byte segment at 0x68028.
///
/// Refuses rather than trims: a stray character in a supplied dump is usually a
/// transcription mistake, and silently dropping it would decode a dump the
/// display never sent.
private func parseDPCDFragment(_ raw: String) -> DPCDBuffer.Segment? {
    var body = raw
    var start = 0
    if let colon = raw.firstIndex(of: ":") {
        guard let address = Int(raw[raw.startIndex..<colon], radix: 16) else { return nil }
        start = address
        body = String(raw[raw.index(after: colon)...])
    }
    let separators = CharacterSet(charactersIn: " ,").union(.whitespaces)
    let kept = body.unicodeScalars.filter { !separators.contains($0) }
    let cleaned = String(String.UnicodeScalarView(kept))
    guard !cleaned.isEmpty, cleaned.count % 2 == 0, cleaned.allSatisfy({ $0.isHexDigit }) else {
        return nil
    }
    var bytes: [UInt8] = []
    var cursor = cleaned.startIndex
    while cursor < cleaned.endIndex {
        let next = cleaned.index(cursor, offsetBy: 2)
        guard let value = UInt8(cleaned[cursor..<next], radix: 16) else { return nil }
        bytes.append(value)
        cursor = next
    }
    return DPCDBuffer.Segment(start: start, bytes: bytes)
}

@MainActor
func cmdReport(_ controller: DisplayController, args: [String]) -> Int32 {
    // A supplied dump is decoded on its own: it needs no display, which is also
    // the only way to exercise the decoders until the read path exists.
    if let exitCode = cmdReportDPCD(args) { return exitCode }

    let snapshots = controller.displays.map { display in
        DisplayReport.Snapshot(display: display, isMain: CGDisplayIsMain(display.id) != 0)
    }
    // This is the *app's* version when the CLI has a bundle and "unknown" when it
    // is a bare binary, which is honest rather than invented. The macOS line in
    // the header is the one that matters for diagnosing display behaviour.
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    let text = DisplayReport.render(
        snapshots,
        version: version,
        platform: ProcessInfo.processInfo.operatingSystemVersionString
    )

    guard let path = args.first(where: { !$0.hasPrefix("-") }) else {
        print(text)
        return 0
    }
    let expanded = (path as NSString).expandingTildeInPath
    do {
        try text.write(toFile: expanded, atomically: true, encoding: .utf8)
    } catch {
        print("fbdcli: report: could not write \(expanded): \(error.localizedDescription)")
        return 1
    }
    print("wrote \(snapshots.count) display(s) to \(expanded)")
    return 0
}

// MARK: - info

/// `fbdcli info <id>` — full detail for one display.
@MainActor
func cmdInfo(_ display: Display, args: [String]) -> Int32 {
    if args.contains("--json") {
        // Machine-readable output (same serializer as the app's HTTP API).
        var info = HTTPJSON.display(display)
        info["modes"] = display.modes.map { HTTPJSON.mode($0) }
        print(HTTPJSON.encode(info))
        return 0
    }
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
    // VRR / ProMotion for the CURRENT mode, queried on demand. These need a
    // live WindowServer connection and crash a process without one, so they are
    // asked for here — once, for one display — rather than stored on every
    // DisplayMode where the test suite would reach them.
    let refreshLabel: String
    if let caps = SkyLightAPI.currentModeCapabilities(displayID: display.id) {
        let label = SkyLightAPI.capabilityLabel(
            minRefreshRate: caps.minRefreshRate,
            isVRR: caps.isVRR,
            isProMotion: caps.isProMotion,
            maxRefreshRate: display.currentMode?.refreshRate ?? 0
        )
        refreshLabel = label.isEmpty ? "none reported" : label
    } else {
        refreshLabel = "unavailable"
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
    print("  refresh: \(refreshLabel)")
    return 0
}
