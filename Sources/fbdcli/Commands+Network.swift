import FBDCLIParser
import FBDCore
import CoreGraphics
import Foundation

// MARK: - HTTP API settings (Tier 5)

/// `fbdcli settings` — print a masked settings dump for support/debugging.
@MainActor
func cmdSettings() -> Int32 {
    print(Settings.debugSummary)
    return 0
}

/// `fbdcli auth-token` — print the local HTTP API token (generated on first
/// access, shared with the app via the defaults domain).
@MainActor
func cmdAuthToken() -> Int32 {
    print(Settings.httpAPIToken)
    return 0
}

/// `fbdcli http on [port]` / `http off` / `http status` — manage the app's
/// HTTP control API setting. The server itself is owned by the app process
/// (it reads these settings at launch), so changes apply after a restart.
@MainActor
func cmdHTTP(args: [String]) -> Int32 {
    guard let sub = args.first else {
        print("fbdcli: http: expected on, off, or status")
        return 1
    }
    switch sub {
    case "on":
        if let portString = args.dropFirst().first {
            guard let port = Int(portString), (1024...65535).contains(port) else {
                print("fbdcli: http on: port must be between 1024 and 65535 (got '\(portString)')")
                return 1
            }
            Settings.httpServerPort = port
        }
        Settings.httpServerEnabled = true
        // The app watches UserDefaults and reconciles the server live.
        print("HTTP API enabled on port \(httpPortLabel(Settings.httpServerPort))")
    case "off":
        Settings.httpServerEnabled = false
        print("HTTP API disabled")
    case "status":
        print("HTTP API: \(Settings.httpServerEnabled ? "enabled" : "disabled")"
            + " (port \(httpPortLabel(Settings.httpServerPort)))")
    default:
        print("fbdcli: http: unknown subcommand '\(sub)' (expected on, off, or status)")
        return 1
    }
    print("Note: the app applies HTTP settings live — no restart needed.")
    return 0
}

/// "0" (Settings default) means the app picks an ephemeral port at launch.
func httpPortLabel(_ port: Int) -> String {
    port == 0 ? "ephemeral" : String(port)
}

// MARK: - TV / AVR network control (Tier 5)

/// `fbdcli tv <brand> <host> [volume <v>|power|input <name>]` — thin wrappers
/// over the network controllers. All calls are async with completion handlers;
/// the main thread blocks on a semaphore until the result lands (completions
/// fire on the controllers' own queues, so no run-loop pumping is needed).
@MainActor
func cmdTV(args: [String]) -> Int32 {
    // A saved device can stand in for `<brand> <host>`, so the common case is
    // `fbdcli tv living-room volume 20` rather than repeating both every time.
    // A word that *is* a brand is always read as a brand, so the shorthand can
    // never shadow the explicit form.
    var args = args
    if let first = args.first,
       NetworkDevice.Brand(rawValue: first.lowercased()) == nil,
       let device = NetworkDeviceRegistry.device(named: first) {
        args = [device.brand.rawValue, device.host] + Array(args.dropFirst())
    }
    switch TVCommandValidation.parse(args) {
    case .failure(let failure):
        print("fbdcli: tv: \(failure.message)")
        return 1
    case .success(let command):
        switch command.brand {
        case .lg:
            return cmdTVLG(host: command.host, action: command.action)
        case .samsung:
            return cmdTVSamsung(host: command.host, action: command.action)
        case .philips:
            return cmdTVPhilips(host: command.host, action: command.action)
        case .yamaha:
            return cmdTVYamaha(host: command.host, action: command.action)
        }
    }
}

/// Shared "result printed, exit code chosen" tail for the tv commands.
func printTVResult(brand: String, host: String, action: TVCommand.Action, ok: Bool?) -> Int32 {
    let actionLabel: String
    switch action {
    case .power:
        actionLabel = "power"
    case .volume(let level):
        actionLabel = "volume \(level)"
    case .input(let name):
        actionLabel = "input '\(name)'"
    }
    if ok == true {
        print("tv \(brand) \(host): \(actionLabel) ok")
        return 0
    }
    print("tv \(brand) \(host): \(actionLabel) failed")
    print("note: requires the device to be in network/API mode (and powered on)")
    return 2
}

/// `tv lg <host> [volume <v>|power|input <name>]` — LG webOS (ssap://, port 3000).
@MainActor
func cmdTVLG(host: String, action: TVCommand.Action) -> Int32 {
    let tv = LGWebOSController()
    let semaphore = DispatchSemaphore(value: 0)
    var connectOK = false
    var connectInfo = ""
    let savedKey = Settings.tvLGClientKey.isEmpty ? nil : Settings.tvLGClientKey
    tv.connect(host: host, clientKey: savedKey) { ok, info in
        connectOK = ok
        connectInfo = info ?? ""
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 20)
    if Settings.tvLGClientKey.isEmpty, !connectInfo.isEmpty {
        Settings.tvLGClientKey = connectInfo
        print("client key persisted for future connections")
    }
    guard connectOK else {
        print("tv lg \(host): connection failed — \(connectInfo.isEmpty ? "no reply" : connectInfo)")
        print("note: requires the TV to be powered on and in network mode (accept the pairing prompt on the TV if this is the first connection)")
        return 2
    }
    var commandResult: Bool?
    switch action {
    case .volume(let level):
        tv.setVolume(level) { commandResult = $0 }
    case .power:
        tv.powerOn { commandResult = $0 }
    case .input(let name):
        tv.setInput(name) { commandResult = $0 }
    }
    _ = semaphore.wait(timeout: .now() + 10)
    return printTVResult(brand: "lg", host: host, action: action, ok: commandResult)
}

/// `tv samsung <host> [volume <v>|power|input <name>]` — Samsung Tizen
/// (samsung.remote.control, port 8002). Power/input map to KEY_POWER/KEY_SOURCE;
/// volume is applied via repeated KEY_VOLUP presses.
@MainActor
func cmdTVSamsung(host: String, action: TVCommand.Action) -> Int32 {
    let tv = TizenController()
    let semaphore = DispatchSemaphore(value: 0)
    var connectOK = false
    var connectInfo = ""
    tv.connect(host: host) { ok, info in
        connectOK = ok
        connectInfo = info ?? ""
        semaphore.signal()
    }
    // First pairing shows a dialog on the TV; the controller waits up to 60 s.
    _ = semaphore.wait(timeout: .now() + 65)
    guard connectOK else {
        print("tv samsung \(host): connection failed — \(connectInfo.isEmpty ? "no reply" : connectInfo)")
        print("note: requires the TV to be powered on and in network mode (accept the pairing dialog on the TV if prompted)")
        return 2
    }
    var commandResult: Bool?
    switch action {
    case .volume(let level):
        tv.setVolume(level) { commandResult = $0 }
    case .power:
        tv.sendKey("KEY_POWER") { commandResult = $0 }
    case .input:
        tv.sendKey("KEY_SOURCE") { commandResult = $0 }
    }
    // setVolume presses keys up to ~12 s; give the sequence room to finish.
    _ = semaphore.wait(timeout: .now() + 30)
    return printTVResult(brand: "samsung", host: host, action: action, ok: commandResult)
}

/// `tv philips <host> [volume <v>|power|input <name>]` — Philips Android TV
/// (jointSPACE, port 1926). The CLI has no PIN-entry UI, so the host is used
/// directly — this works for already-paired TVs and Simple-IP mode.
@MainActor
func cmdTVPhilips(host: String, action: TVCommand.Action) -> Int32 {
    let tv = PhilipsTVController()
    tv.host = host
    let semaphore = DispatchSemaphore(value: 0)
    var commandResult: Bool?
    let completion: (Bool) -> Void = { ok in
        commandResult = ok
        semaphore.signal()
    }
    switch action {
    case .volume(let level):
        tv.setVolume(level, completion: completion)
    case .power:
        tv.powerOn(completion: completion)
    case .input(let name):
        tv.setInput(name, completion: completion)
    }
    _ = semaphore.wait(timeout: .now() + 15)
    return printTVResult(brand: "philips", host: host, action: action, ok: commandResult)
}

/// `tv yamaha <host> [volume <v>|power|input <name>]` — Yamaha AVR (YXC, port
/// 80). Volume is the raw YXC scale 0…161 (0.5 dB steps); the CLI passes the
/// 0…100 value through (clamped by the controller).
@MainActor
func cmdTVYamaha(host: String, action: TVCommand.Action) -> Int32 {
    let tv = YamahaAVRController()
    tv.host = host
    let semaphore = DispatchSemaphore(value: 0)
    var commandResult: Bool?
    let completion: (Bool) -> Void = { ok in
        commandResult = ok
        semaphore.signal()
    }
    switch action {
    case .volume(let level):
        tv.setVolume(level, completion: completion)
    case .power:
        tv.powerOn(completion: completion)
    case .input(let name):
        tv.setInput(name, completion: completion)
    }
    _ = semaphore.wait(timeout: .now() + 15)
    return printTVResult(brand: "yamaha", host: host, action: action, ok: commandResult)
}
