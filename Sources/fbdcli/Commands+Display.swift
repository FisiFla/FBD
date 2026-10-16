import FBDCLIParser
import FBDCore
import CoreGraphics
import Foundation

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
    if !display.isHDRModeCapable {
        print("note: HDR framebuffer mode unsupported here; brightness upscaling is available via 'xdr <id>'")
    }
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
    guard requireArgCount(args, 2, usage: "fbdcli: virtual create: expected <name> <W>x<H>[@<hz>] [--hdr] [--no-auto]") else { return 1 }
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

/// Parse a display id, requiring the display to be **online**; prints a message
/// and returns nil on failure (caller exits 1).
///
/// Only for commands that need a live display. `enable` must not use this: a
/// soft-disabled external display leaves the online list entirely on this OS,
/// so requiring online-ness there turned `disable` into a one-way trip.
func requireOnlineDisplay(_ idString: String?) -> CGDirectDisplayID? {
    guard let idString, !idString.isEmpty else {
        print("fbdcli: missing display id")
        return nil
    }
    guard let id = requireDisplayID(idString) else {
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
        guard BuiltInDisconnectGuard.builtInDisconnectAllowed else {
            print("fbdcli: refusing to disable the built-in display — on this Mac (base M3) it may")
            print("        not reconnect without a reboot. Set \"Allow built-in display disconnect\"")
            print("        in FBD's Settings if you accept that risk, then re-run.")
            return 2
        }
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
        print("fbdcli: layout: expected save, restore, protect, or edge-crossing [on|off]")
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
    case "edge-crossing":
        return cmdLayoutEdgeCrossing(args: rest)
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

/// `fbdcli layout edge-crossing [on|off]` — get or set pointer crossing between
/// displays whose facing edges do not line up.
///
/// A setting, not a hardware write: the app picks it up within a couple of
/// seconds and installs or removes its pointer monitor. Nothing else to report,
/// so this mirrors `layout protect`.
@MainActor
func cmdLayoutEdgeCrossing(args: [String]) -> Int32 {
    if let arg = args.first {
        let enabled: Bool
        switch arg {
        case "on": enabled = true
        case "off": enabled = false
        default:
            print("fbdcli: layout edge-crossing: expected on or off (got '\(arg)')")
            return 1
        }
        Settings.edgeCrossingEnabled = enabled
    }
    print("edge crossing: \(Settings.edgeCrossingEnabled ? "on" : "off")")
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
    guard requireArgCount(args, 2, usage: "fbdcli: group add: expected <name> <id>") else { return 1 }
    let groups = DisplayGroupsController()
    guard let group = requireGroup(args[0], in: groups) else { return 1 }
    guard let id = requireDisplayID(args[1]) else {
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
    guard requireArgCount(args, 2, usage: "fbdcli: group remove: expected <name> <id>") else { return 1 }
    let groups = DisplayGroupsController()
    guard let group = requireGroup(args[0], in: groups) else { return 1 }
    guard let id = requireDisplayID(args[1]) else {
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

/// `fbdcli rotate <id> <0|90|180|270>` — rotate a display (SLS private API).
@MainActor
func cmdRotate(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let id = args.first, let display = requireDisplay(id, in: controller) else { return 1 }
    guard args.count >= 2, let degrees = Int(args[1]), [0, 90, 180, 270].contains(degrees) else {
        print("fbdcli: rotate: expected <0|90|180|270> (got '\(args.count >= 2 ? args[1] : "")')")
        return 1
    }
    guard let applied = controller.setRotation(degrees, on: display) else {
        print("fbdcli: rotate: failed to rotate display \(display.id)")
        return 2
    }
    print("display \(display.id) rotated to \(applied)°")
    return 0
}

/// `fbdcli filter <id> off` — stop the full-screen software filter.
/// `fbdcli filter <id> <contrast> <saturation> <gamma> <temperature> [flags]`
/// — apply it (0.5-2 contrast, 0-2 saturation, 0.4-2.5 gamma, 0.5-1.5 temp).
/// Flags: `--invert`, `--sharpness n`, `--radius px`, `--zoom n`,
/// `--pan x y`, `--lut path.cube`.
@MainActor
func cmdFilter(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let id = args.first, let display = requireDisplay(id, in: controller) else { return 1 }
    let filterArgs = Array(args.dropFirst())
    if filterArgs.first == "off" {
        controller.stopScreenFilter(on: display)
        print("filter off")
        return 0
    }
    let parsed: ScreenFilterArgs
    switch ScreenFilterArgs.parse(filterArgs) {
    case .failure(let failure):
        print("fbdcli: filter: \(failure.message)")
        return 1
    case .success(let value):
        parsed = value
    }
    let params = ScreenFilterParams(
        contrast: parsed.contrast, saturation: parsed.saturation,
        gamma: parsed.gamma, temperature: parsed.temperature,
        invert: parsed.invert,
        sharpness: parsed.sharpness ?? 0,
        unsharpRadius: parsed.unsharpRadius ?? 1,
        zoom: parsed.zoom ?? 1,
        offsetX: parsed.offsetX ?? 0,
        offsetY: parsed.offsetY ?? 0,
        lutPath: parsed.lutPath
    )
    // Check the cube here so a bad file is a clear CLI error rather than a
    // silently-skipped correction in the overlay.
    if let lutPath = params.lutPath {
        do {
            _ = try LUTCubeParser.parse(contentsOf: URL(fileURLWithPath: lutPath))
        } catch {
            print("fbdcli: filter: LUT '\(lutPath)' is not usable: \(error)")
            return 1
        }
    }
    guard controller.setScreenFilter(params, on: display) else {
        print("fbdcli: filter: failed to apply filter (Screen Recording permission needed)")
        return 2
    }
    var summary = "contrast \(params.contrast), saturation \(params.saturation), gamma \(params.gamma), temperature \(params.temperature)"
    if params.invert { summary += ", invert" }
    if params.sharpness > 0 { summary += ", sharpness \(params.sharpness), radius \(params.unsharpRadius)" }
    if params.zoom > 1 { summary += ", zoom \(params.zoom)" }
    if params.offsetX != 0 || params.offsetY != 0 {
        summary += ", pan \(params.offsetX) \(params.offsetY)"
    }
    if let lutPath = params.lutPath { summary += ", lut \(lutPath)" }
    print("filter applied (\(summary))")
    return 0
}
