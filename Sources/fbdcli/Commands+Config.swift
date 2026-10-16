import FBDCLIParser
import FBDCore
import CoreGraphics
import Foundation

// MARK: - Configuration (BetterDisplay-parity surfaces)

/// Parse an on/off word. Returns nil for anything else, so a typo is refused
/// rather than silently treated as "off".
func parseOnOffWord(_ raw: String) -> Bool? {
    switch raw.lowercased() {
    case "on", "1", "true", "yes": return true
    case "off", "0", "false", "no": return false
    default: return nil
    }
}

func printConfigUsage() {
    print("usage: fbdcli config [show]")
    print("       fbdcli config protect <id> [all|<property>[,<property>…]]")
    print("       fbdcli config favourite <id> list|save|apply [slot]")
    print("       fbdcli config preset <id> list|save <name>|apply <name|id>|delete <name|id>")
    print("       fbdcli config lockdim [on|off]")
    print("       fbdcli config lockdim-target [0-100]")
    print("       fbdcli config keytarget [mouse|focused|all|audio]")
    print("       fbdcli config group-policy <group> [policy]")
    print("       fbdcli config group-enabled <group> [on|off]")
    print("       fbdcli config group-sync <group> <0-100>")
    print("       fbdcli config connections connect-all|disconnect-all-but-main|swap-identical")
    print("       fbdcli config model <key> [value]")
    print("       fbdcli config device list|add|remove|attach|detach|attachments …")
    print("properties: \(ProtectedProperties.ordered.map(\.name).joined(separator: ", "))")
    print("preset symbols: \(DisplayPresetSymbol.all.map(\.symbolName).joined(separator: ", "))")
    print("model keys: prefer-hardware, hardware-min, hardware-max, hdr-sdr-peak, hdr-hdr-peak, "
        + "software-zero, min-hardware, switchover, upscale-max, startup-policy")
}

/// `fbdcli config …` — the settings behind the BetterDisplay-parity features:
/// per-property configuration protection, resolution favourites, named display
/// presets, lock dimming, the keyboard control target, and display-group sync
/// policy.
///
/// These are *settings*, not hardware writes, so they run locally against the
/// same `Settings.defaults` suite the app reads: one write path, no DDC bus
/// contention, and the app picks the change up on its next read.
@MainActor
func cmdConfig(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let sub = args.first else { return printConfigSummary() }
    let rest = Array(args.dropFirst())
    switch sub {
    case "show": return printConfigSummary()
    case "protect": return cmdConfigProtect(controller, args: rest)
    case "favourite", "favorite": return cmdConfigFavourite(controller, args: rest)
    case "preset": return cmdConfigPreset(controller, args: rest)
    case "lockdim": return cmdConfigLockDim(rest)
    case "lockdim-target": return cmdConfigLockDimTarget(rest)
    case "keytarget": return cmdConfigKeyTarget(rest)
    case "group-policy": return cmdConfigGroupPolicy(rest)
    case "group-enabled": return cmdConfigGroupEnabled(rest)
    case "group-sync": return cmdConfigGroupSync(controller, rest)
    case "connections": return cmdConfigConnections(controller, rest)
    case "model": return cmdConfigModel(rest)
    case "device": return cmdConfigDevice(controller, rest)
    case "identity": return cmdConfigIdentity(rest)
    case "transfer": return cmdConfigTransfer(controller, args: rest)
    case "vscreen": return cmdConfigVirtualScreen(controller, args: rest)
    case "uiscale": return cmdConfigUIScale(controller, args: rest)
    default:
        print("fbdcli: config: unknown subcommand '\(sub)'")
        printConfigUsage()
        return 1
    }
}

@MainActor
func printConfigSummary() -> Int32 {
    let prefs = Settings.brightnessPreferences
    print("lock dim: \(Settings.lockDimEnabled ? "on" : "off") at \(Int(Settings.lockDimTargetPercent))%")
    print("keyboard control target: \(Settings.keyboardControlTarget.rawValue)")
    print("brightness model: preferHardware=\(prefs.preferHardwareControl ? "on" : "off") "
        + "hardwareNits=\(Int(prefs.hardwareMinNits))-\(Int(prefs.hardwareMaxNits)) "
        + "hdrPeakNits=\(Int(prefs.hdrPeakSDRNits))/\(Int(prefs.hdrPeakHDRNits)) "
        + "softwareZero=\(Int(prefs.softwareZeroPercent))% "
        + "minHardware=\(Int(prefs.minHardwarePercent))% "
        + "switchover=\(Int(prefs.dimmingSwitchoverPercent))% "
        + "upscaleMax=\(Int(prefs.upscaleMaxPercent))% "
        + "startup=\(prefs.startupControlValuePolicy.rawValue)")
    print("configuration protection: \(Settings.configProtectionEnabled ? "on" : "off")")
    return 0
}

/// `config uiscale [on|off|show]` — report and switch GUI-scale matching.
///
/// `show` prints what each display's interface actually measures, in points per
/// millimetre, and what would be applied to bring the others into line with the
/// reference. It **reports** rather than applies: a resolution change moves every
/// open window on that display, so it is asked for rather than happening as a side
/// effect of asking what the scales are.
///
/// The physical size comes from `CGDisplayScreenSize`. The gap matrix carried this row
/// as blocked on "reliable physical sizes"; that API returns a real figure for the
/// built-in panel (344×222 mm), so the row was blocked on nobody having looked. A panel
/// that reports no size is reported as unknown and skipped rather than guessed at.
@MainActor
func cmdConfigUIScale(_ controller: DisplayController, args: [String]) -> Int32 {
    if let first = args.first {
        switch first {
        case "on", "off":
            Settings.uiScaleMatchingEnabled = (first == "on")
            print("ui scale matching = \(first)")
            return 0
        case "show":
            break
        default:
            print("fbdcli: config uiscale: expected on, off or show (got '\(first)')")
            return 1
        }
    }

    let tolerance = max(Settings.uiScaleMatchingTolerancePercent, 0) / 100
    print("ui scale matching: \(Settings.uiScaleMatchingEnabled ? "on" : "off")"
        + ", tolerance \(Settings.uiScaleMatchingTolerancePercent)%")

    let displays = controller.displays.filter { !$0.isVirtual }
    guard let reference = displays.first(where: { $0.guiScale != nil }), let target = reference.guiScale else {
        print("no display reports a physical size — nothing to match against")
        return 1
    }
    print(String(format: "reference: %@ at %.4f points/mm", reference.name, target))

    for display in displays {
        let size = display.physicalSizeMM
        let sizeText = size.map { String(format: "%.0f×%.0f mm", $0.width, $0.height) } ?? "size unknown"
        var line = "  \(display.name) [\(display.id)] \(sizeText)"
        guard let scale = display.guiScale, let size else {
            line += " — skipped, no scale"
            print(line)
            continue
        }
        let plan = UIScaleMatching.plan(
            target: target,
            current: uiScaleCandidate(for: display),
            candidates: uiScaleCandidates(for: display, physicalWidthMM: size.width),
            tolerance: tolerance
        )
        switch plan {
        case .alreadyMatched:
            line += String(format: " — %.4f points/mm, matched", scale)
        case .changeTo(let candidate):
            line += String(format: " — %.4f points/mm, would switch to \(Int(candidate.logicalWidth)) points wide", scale)
        case .noCandidate:
            line += String(format: " — %.4f points/mm, no mode gets within tolerance", scale)
        }
        print(line)
    }
    return 0
}

/// The display's current mode reduced for the scale choice, or nil when its scale
/// cannot be read.
@MainActor
private func uiScaleCandidate(for display: Display) -> UIScaleMatching.Candidate? {
    guard let mode = display.currentMode, let physical = display.physicalSizeMM,
          let scale = UIScaleMatching.scale(
              logicalWidth: Double(mode.width), physicalWidthMM: physical.width
          ) else {
        return nil
    }
    return UIScaleMatching.Candidate(
        modeID: mode.modeNumber, logicalWidth: Double(mode.width), scale: scale
    )
}

/// Every offered mode reduced for the scale choice, dropping the ones whose scale
/// cannot be computed.
@MainActor
private func uiScaleCandidates(for display: Display, physicalWidthMM: Double) -> [UIScaleMatching.Candidate] {
    display.modes.compactMap { mode in
        guard let scale = UIScaleMatching.scale(
            logicalWidth: Double(mode.width), physicalWidthMM: physicalWidthMM
        ) else {
            return nil
        }
        return UIScaleMatching.Candidate(
            modeID: mode.modeNumber, logicalWidth: Double(mode.width), scale: scale
        )
    }
}

/// `config vscreen list|associate|disassociate|apply` — associate a virtual screen
/// with real displays, so an arrangement is recalled when it attaches.
///
/// `associate` records the arrangement the displays have **right now**, which is the
/// only sane way to say "put them back like this" — asking someone to type origins
/// would be a text field where the UI has a grid.
///
/// There is no mirroring here. Mirroring a virtual screen means addressing it as a
/// display, and ADR-0001 records that a virtual screen FBD created does not appear in
/// its own process's display list, so that half of the row is not reachable — see
/// `VirtualScreenAssociation`, which deliberately stores no flag for it.
@MainActor
func cmdConfigVirtualScreen(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let sub = args.first else {
        print("fbdcli: config vscreen: expected list, associate, disassociate or apply")
        return 1
    }
    let rest = Array(args.dropFirst())

    switch sub {
    case "list":
        let associations = Settings.loadVirtualScreenAssociations()
        guard !associations.isEmpty else {
            print("no virtual-screen associations")
            return 0
        }
        for association in associations {
            let placements = association.placements
                .map { "\($0.identity)@\($0.x),\($0.y)" }
                .joined(separator: " ")
            print("\(association.virtualScreenID): \(placements)")
        }
        return 0

    case "associate":
        guard let screenID = rest.first, !screenID.isEmpty else {
            print("fbdcli: config vscreen associate: expected a virtual-screen id")
            return 1
        }
        let displayArgs = Array(rest.dropFirst())
        guard !displayArgs.isEmpty else {
            print("fbdcli: config vscreen associate: expected at least one display id")
            return 1
        }
        var placements: [VirtualScreenAssociation.Placement] = []
        for rawID in displayArgs {
            guard let displayID = requireDisplayID(rawID), let display = controller.display(withID: displayID) else {
                return 1
            }
            let origin = CGDisplayBounds(display.id).origin
            placements.append(.init(identity: display.identityKey, x: Int32(origin.x), y: Int32(origin.y)))
        }
        // One association per screen: associating again replaces rather than
        // stacking a second arrangement for the same screen.
        var associations = Settings.loadVirtualScreenAssociations()
            .filter { $0.virtualScreenID != screenID }
        associations.append(VirtualScreenAssociation(virtualScreenID: screenID, placements: placements))
        associations.sort { $0.virtualScreenID < $1.virtualScreenID }
        Settings.saveVirtualScreenAssociations(associations)
        print("associated \(screenID) with \(placements.count) display(s) at their current positions")
        return 0

    case "disassociate":
        guard let screenID = rest.first, !screenID.isEmpty else {
            print("fbdcli: config vscreen disassociate: expected a virtual-screen id")
            return 1
        }
        let remaining = Settings.loadVirtualScreenAssociations()
            .filter { $0.virtualScreenID != screenID }
        Settings.saveVirtualScreenAssociations(remaining)
        print("disassociated \(screenID)")
        return 0

    case "apply":
        guard let screenID = rest.first, !screenID.isEmpty else {
            print("fbdcli: config vscreen apply: expected a virtual-screen id")
            return 1
        }
        let attached = controller.displays.map { (identity: $0.identityKey, displayID: $0.id) }
        let applied = LayoutProtectionController().applyAssociation(
            forVirtualScreen: screenID,
            attached: attached,
            associations: Settings.loadVirtualScreenAssociations()
        )
        guard applied else {
            print("fbdcli: config vscreen apply: nothing applied for \(screenID) "
                + "(no association, or its displays are not all attached)")
            return 1
        }
        print("applied the arrangement associated with \(screenID)")
        return 0

    default:
        print("fbdcli: config vscreen: unknown subcommand '\(sub)'")
        return 1
    }
}

/// `config identity [<method>]` — which key a display's stored settings are filed
/// under.
@MainActor
func cmdConfigIdentity(_ args: [String]) -> Int32 {
    let methods = DisplayIdentityMethod.allCases.map(\.rawValue).joined(separator: ", ")
    guard let raw = args.first else {
        print("identity method: \(Settings.displayIdentityMethod.rawValue)")
        print("available: \(methods)")
        for method in DisplayIdentityMethod.allCases {
            print("  \(method.rawValue): \(method.label) — \(method.caveat)")
        }
        return 0
    }
    guard let method = DisplayIdentityMethod(rawValue: raw) else {
        print("fbdcli: config identity: expected one of \(methods) (got '\(raw)')")
        return 1
    }
    Settings.displayIdentityMethod = method
    print("identity method = \(method.rawValue)")
    print("Note: this re-keys per-display settings. Move an existing display's across with")
    print("      `fbdcli config transfer <from-id> <to-id>`.")
    return 0
}

/// `config transfer <from-id> <to-id> [--overwrite]` — copy one display's stored
/// settings onto another.
@MainActor
func cmdConfigTransfer(_ controller: DisplayController, args: [String]) -> Int32 {
    let overwrite = args.contains("--overwrite")
    let ids = args.filter { !$0.hasPrefix("--") }
    guard ids.count >= 2, let fromID = requireDisplayID(ids[0]), let toID = requireDisplayID(ids[1]) else {
        print("fbdcli: config transfer: expected two display ids")
        return 1
    }
    guard let from = controller.display(withID: fromID) else {
        print("fbdcli: config transfer: no display with id \(fromID)")
        return 1
    }
    guard let to = controller.display(withID: toID) else {
        print("fbdcli: config transfer: no display with id \(toID)")
        return 1
    }
    // Two displays that share an identity already share their settings, so
    // "copying" between them would be a no-op reported as a success.
    guard from.identityKey != to.identityKey else {
        print("fbdcli: config transfer: ids \(fromID) and \(toID) share an identity "
            + "(\(from.identityKey)) — nothing to move")
        return 1
    }
    guard !DisplaySettingsTransfer.familiesPresent(for: from.identityKey).isEmpty else {
        print("fbdcli: config transfer: nothing stored for \(from.identityKey)")
        return 0
    }
    let outcome = DisplaySettingsTransfer.apply(
        from: from.identityKey,
        to: to.identityKey,
        overwrite: overwrite
    )
    print("from \(from.identityKey) to \(to.identityKey)")
    var moved = outcome.moved
    if outcome.movedDeviceAttachment { moved.append(DisplaySettingsTransfer.sharedBlobFamily) }
    print("moved: \(moved.isEmpty ? "nothing" : moved.joined(separator: ", "))")
    if !outcome.kept.isEmpty {
        print("kept (the destination already had these; pass --overwrite to replace): "
            + outcome.kept.joined(separator: ", "))
    }
    return 0
}

/// `config protect <id> [properties]` — get or set which properties
/// configuration protection re-applies for a display.
@MainActor
func cmdConfigProtect(_ controller: DisplayController, args: [String]) -> Int32 {
    guard let idArg = args.first, let id = requireDisplayID(idArg) else {
        print("fbdcli: config protect: expected a display id")
        return 1
    }
    guard let display = controller.display(withID: id) else {
        print("fbdcli: config protect: no display with id \(id)")
        return 1
    }
    let protection = ConfigProtectionController()
    guard let spec = args.dropFirst().first else {
        print("protected: \(protection.protectedProperties(for: display).names.joined(separator: ","))")
        print("available: \(ProtectedProperties.available(for: display).names.joined(separator: ","))")
        return 0
    }
    guard let parsed = ProtectedProperties.parse(spec) else {
        print("fbdcli: config protect: unknown property in '\(spec)'")
        printConfigUsage()
        return 1
    }
    protection.setProtectedProperties(parsed, for: display)
    print("protected: \(parsed.names.joined(separator: ","))")
    return 0
}

/// `config favourite <id> list|save|apply [slot]` — the five mode recall slots.
@MainActor
func cmdConfigFavourite(_ controller: DisplayController, args: [String]) -> Int32 {
    guard args.count >= 2, let id = requireDisplayID(args[0]) else {
        print("fbdcli: config favourite: expected <id> list|save|apply [slot]")
        return 1
    }
    guard let display = controller.display(withID: id) else {
        print("fbdcli: config favourite: no display with id \(id)")
        return 1
    }
    let action = args[1]

    if action == "list" {
        let favourites = ModeFavourites.favourites(for: display.identityKey)
        if favourites.isEmpty {
            print("no favourites recorded")
            return 0
        }
        for favourite in favourites {
            let hidpi = favourite.isHiDPI ? " HiDPI" : ""
            let hz = favourite.refreshRate > 0 ? String(format: " @ %.2f Hz", favourite.refreshRate) : ""
            print("\(favourite.slot): \(favourite.width)x\(favourite.height)\(hidpi)\(hz)")
        }
        return 0
    }

    guard action == "save" || action == "apply" else {
        print("fbdcli: config favourite: expected list, save or apply (got '\(action)')")
        return 1
    }
    guard args.count >= 3, let slot = Int(args[2]) else {
        print("fbdcli: config favourite \(action): expected a slot number")
        return 1
    }

    let resolution = ResolutionController()
    if action == "save" {
        guard let mode = resolution.currentMode(for: display) else {
            print("fbdcli: config favourite save: no current mode to record")
            return 2
        }
        guard ModeFavourites.save(mode, into: slot, for: display.identityKey) else {
            print("fbdcli: config favourite save: slot \(slot) is out of range (1...\(ModeFavourites.slotCount))")
            return 1
        }
        print("saved slot \(slot)")
        return 0
    }

    let recall = resolution.applyFavourite(slot: slot, for: display.identityKey, to: display)
    if recall.isUnavailable {
        print("slot \(slot) has no matching mode on this display")
        return 2
    }
    print("applied slot \(slot)")
    return 0
}

/// `config preset <id> list|save <name>|apply <ref>|delete <ref>` — named display
/// presets: a display's whole configuration recorded under a name, so a setup
/// made once (a scaled mode for a projector, dim and no HDR for night work) can
/// be recalled by name from the CLI, the HTTP API, the menu or Siri.
///
/// Which properties a preset carries is chosen when it is saved; `mainStatus` is
/// left out of the default set because moving the menu bar is a property of the
/// desktop, not of this display, and applying a preset should not silently
/// rearrange the user's other screens.
@MainActor
func cmdConfigPreset(_ controller: DisplayController, args: [String]) -> Int32 {
    guard args.count >= 2, let id = requireDisplayID(args[0]) else {
        print("fbdcli: config preset: expected <id> list|save <name>|apply <ref>|delete <ref>")
        return 1
    }
    guard let display = controller.display(withID: id) else {
        print("fbdcli: config preset: no display with id \(id)")
        return 1
    }
    let action = args[1]
    let rest = Array(args.dropFirst(2))

    switch action {
    case "list":
        let presets = DisplayPresets.presets(for: display.identityKey)
        if presets.isEmpty {
            print("no presets recorded")
            return 0
        }
        for preset in presets {
            let properties = preset.properties.names.joined(separator: ",")
            print("\(preset.name) [\(preset.symbol.symbolName)] \(properties)")
        }
        return 0

    case "save":
        guard let rawName = rest.first else {
            print("fbdcli: config preset save: expected a name")
            return 1
        }
        guard let name = DisplayPresets.sanitizedName(rawName) else {
            print("fbdcli: config preset save: a preset needs a name")
            return 1
        }
        var symbol: DisplayPresetSymbol = .default
        var properties = DisplayPresets.defaultProperties
        var index = 1
        while index < rest.count {
            let flag = rest[index]
            guard index + 1 < rest.count else {
                print("fbdcli: config preset save: \(flag) expects a value")
                return 1
            }
            let value = rest[index + 1]
            switch flag {
            case "--symbol":
                guard let parsed = DisplayPresetSymbol.named(value) else {
                    print("fbdcli: config preset save: unknown symbol '\(value)'")
                    print("preset symbols: \(DisplayPresetSymbol.all.map(\.symbolName).joined(separator: ", "))")
                    return 1
                }
                symbol = parsed
            case "--properties":
                guard let parsed = ProtectedProperties.parse(value) else {
                    print("fbdcli: config preset save: unknown property in '\(value)'")
                    print("properties: \(ProtectedProperties.ordered.map(\.name).joined(separator: ", "))")
                    return 1
                }
                properties = parsed
            default:
                print("fbdcli: config preset save: unexpected argument '\(flag)'")
                printConfigUsage()
                return 1
            }
            index += 2
        }
        let state = DisplayStateSnapshot.capture(
            for: display,
            resolution: ResolutionController(),
            controller: controller
        )
        let preset = DisplayPreset(
            name: name,
            symbol: symbol,
            properties: properties,
            state: state
        )
        guard DisplayPresets.save(preset, for: display.identityKey) else {
            print("fbdcli: config preset save: a preset named '\(name)' already exists")
            return 2
        }
        print("saved preset '\(name)'")
        return 0

    case "apply", "delete":
        guard let reference = rest.first else {
            print("fbdcli: config preset \(action): expected a preset name or id")
            return 1
        }
        guard let preset = DisplayPresets.resolve(reference, for: display.identityKey) else {
            print("fbdcli: config preset \(action): no preset '\(reference)' for this display")
            return 2
        }
        if action == "delete" {
            guard DisplayPresets.remove(id: preset.id, for: display.identityKey) else {
                print("fbdcli: config preset delete: could not remove '\(preset.name)'")
                return 2
            }
            print("deleted preset '\(preset.name)'")
            return 0
        }
        let outcome = DisplayPresetApplier.apply(
            preset,
            to: display,
            resolution: ResolutionController(),
            controller: controller
        )
        if outcome.applied.isEmpty && !outcome.requested.isEmpty {
            print("fbdcli: config preset apply: no part of '\(preset.name)' applies to this display")
            return 2
        }
        print("applied preset '\(preset.name)'")
        if !outcome.unavailable.isEmpty {
            print("skipped: \(outcome.unavailable.names.joined(separator: ","))")
        }
        return 0

    default:
        print("fbdcli: config preset: expected list, save, apply or delete (got '\(action)')")
        printConfigUsage()
        return 1
    }
}

@MainActor
func cmdConfigLockDim(_ args: [String]) -> Int32 {
    guard let raw = args.first else {
        print("lock dim: \(Settings.lockDimEnabled ? "on" : "off")")
        return 0
    }
    guard let enabled = parseOnOffWord(raw) else {
        print("fbdcli: config lockdim: expected on or off (got '\(raw)')")
        return 1
    }
    Settings.lockDimEnabled = enabled
    print("lock dim: \(enabled ? "on" : "off")")
    return 0
}

@MainActor
func cmdConfigLockDimTarget(_ args: [String]) -> Int32 {
    guard let raw = args.first else {
        print("lock dim target: \(Int(Settings.lockDimTargetPercent))%")
        return 0
    }
    guard let percent = Double(raw), (0...100).contains(percent) else {
        print("fbdcli: config lockdim-target: expected 0-100 (got '\(raw)')")
        return 1
    }
    Settings.lockDimTargetPercent = percent
    print("lock dim target: \(Int(percent))%")
    return 0
}

@MainActor
func cmdConfigKeyTarget(_ args: [String]) -> Int32 {
    guard let raw = args.first else {
        print("keyboard control target: \(Settings.keyboardControlTarget.rawValue)")
        return 0
    }
    let aliases: [String: KeyboardControlTarget] = [
        "mouse": .mouseScreen,
        "focused": .focusedScreen,
        "all": .allSuitableScreens,
        "audio": .audioDeviceMatch,
    ]
    guard let target = KeyboardControlTarget(rawValue: raw) ?? aliases[raw.lowercased()] else {
        print("fbdcli: config keytarget: expected mouse, focused, all or audio (got '\(raw)')")
        return 1
    }
    Settings.keyboardControlTarget = target
    print("keyboard control target: \(target.rawValue)")
    return 0
}

@MainActor
func cmdConfigGroupPolicy(_ args: [String]) -> Int32 {
    guard let name = args.first else {
        print("fbdcli: config group-policy: expected a group name")
        return 1
    }
    let groups = DisplayGroupsController()
    guard let group = groups.group(named: name) else {
        print("fbdcli: config group-policy: no group named '\(name)'")
        return 1
    }
    guard let raw = args.dropFirst().first else {
        print("\(group.name): \(groups.activationPolicy(forGroup: group.id).rawValue)")
        return 0
    }
    guard let policy = GroupActivationPolicy(rawValue: raw) else {
        let known = GroupActivationPolicy.allCases.map(\.rawValue).joined(separator: ", ")
        print("fbdcli: config group-policy: expected one of \(known) (got '\(raw)')")
        return 1
    }
    groups.setActivationPolicy(policy, forGroup: group.id)
    print("\(group.name): \(policy.rawValue)")
    return 0
}

@MainActor
func cmdConfigGroupEnabled(_ args: [String]) -> Int32 {
    guard let name = args.first else {
        print("fbdcli: config group-enabled: expected a group name")
        return 1
    }
    let groups = DisplayGroupsController()
    guard let group = groups.group(named: name) else {
        print("fbdcli: config group-enabled: no group named '\(name)'")
        return 1
    }
    guard let raw = args.dropFirst().first else {
        print("\(group.name): \(groups.isEnabled(groupID: group.id) ? "on" : "off")")
        return 0
    }
    guard let enabled = parseOnOffWord(raw) else {
        print("fbdcli: config group-enabled: expected on or off (got '\(raw)')")
        return 1
    }
    groups.setEnabled(enabled, forGroup: group.id)
    print("\(group.name): \(enabled ? "on" : "off")")
    return 0
}

/// `config group-sync <group> <0-100>` — apply a synchronised brightness to the
/// group's members through the tested planner.
@MainActor
func cmdConfigGroupSync(_ controller: DisplayController, _ args: [String]) -> Int32 {
    guard let name = args.first, let valueArg = args.dropFirst().first else {
        print("fbdcli: config group-sync: expected <group> <0-100>")
        return 1
    }
    guard let percent = Double(valueArg), (0...100).contains(percent) else {
        print("fbdcli: config group-sync: expected 0-100 (got '\(valueArg)')")
        return 1
    }
    let groups = DisplayGroupsController()
    guard let group = groups.group(named: name) else {
        print("fbdcli: config group-sync: no group named '\(name)'")
        return 1
    }
    let written = groups.applyGroupSync(percent / 100, inGroup: group.id, controller: controller)
    print("\(group.name): synced \(written) display(s) to \(Int(percent))%")
    return 0
}

/// `config connections <action>` — bulk connect/disconnect, planned by the pure
/// `ConnectionPlanner` and executed through the guarded disconnect chokepoint.
@MainActor
func cmdConfigConnections(_ controller: DisplayController, _ args: [String]) -> Int32 {
    guard let raw = args.first else {
        print("fbdcli: config connections: expected connect-all, disconnect-all-but-main or swap-identical")
        return 1
    }
    let action: ConnectionAction
    switch raw {
    case "connect-all": action = .connectAll
    case "disconnect-all-but-main": action = .disconnectAllButMain
    case "swap-identical": action = .swapIdentical
    default:
        print("fbdcli: config connections: expected connect-all, disconnect-all-but-main or swap-identical (got '\(raw)')")
        return 1
    }

    let descriptors = controller.displays.map { display in
        DisplayDescriptor(
            displayID: display.id,
            isOnline: display.isOnline,
            isBuiltin: display.isBuiltin,
            isMain: CGDisplayIsMain(display.id) != 0,
            vendor: display.vendorNumber,
            model: display.modelNumber,
            serial: display.serialNumber
        )
    }
    let steps = ConnectionPlanner.plan(
        action: action,
        displays: descriptors,
        allowsAffectedBuiltInDisconnect: Settings.allowBuiltInDisconnectOnAffectedMacs
    )
    guard !steps.isEmpty else {
        // Not an error: the planner refuses `disconnectAllButMain` with no main
        // display, and `swapIdentical` with anything but exactly two matches.
        print("no steps: the planner declined this action for the current display set")
        return 0
    }
    let applied = DisconnectController().apply(steps)
    print("\(applied) of \(steps.count) display(s) changed")
    return applied == steps.count ? 0 : 2
}

/// Mutate the brightness-model preferences through the single write path.
@MainActor
func mutateBrightnessPreferences(_ mutate: (inout BrightnessPreferences) -> Void) {
    var preferences = Settings.brightnessPreferences
    mutate(&preferences)
    Settings.brightnessPreferences = preferences
}

/// `config model <key> [value]` — read or write one brightness-model value.
@MainActor
func cmdConfigModel(_ args: [String]) -> Int32 {
    let prefs = Settings.brightnessPreferences
    guard let key = args.first else {
        return printConfigSummary()
    }
    let raw = args.dropFirst().first

    /// Print the current value when no value was supplied.
    func report(_ text: String) -> Int32 {
        print("\(key): \(text)")
        return 0
    }
    /// A nits-denominated field.
    func nits(_ current: Double, _ keyPath: WritableKeyPath<BrightnessPreferences, Double>) -> Int32 {
        guard let raw else { return report("\(Int(current)) nits") }
        guard let value = Double(raw), (0...40_000).contains(value) else {
            print("fbdcli: config model \(key): expected 0-40000 (got '\(raw)')")
            return 1
        }
        mutateBrightnessPreferences { $0[keyPath: keyPath] = value }
        return report("\(Int(value)) nits")
    }
    /// A percentage field.
    func percent(_ current: Double, _ range: ClosedRange<Double>, _ keyPath: WritableKeyPath<BrightnessPreferences, Double>) -> Int32 {
        guard let raw else { return report("\(Int(current))%") }
        guard let value = Double(raw), range.contains(value) else {
            print("fbdcli: config model \(key): expected \(Int(range.lowerBound))-\(Int(range.upperBound)) (got '\(raw)')")
            return 1
        }
        mutateBrightnessPreferences { $0[keyPath: keyPath] = value }
        return report("\(Int(value))%")
    }

    switch key {
    case "prefer-hardware":
        guard let raw else { return report(prefs.preferHardwareControl ? "on" : "off") }
        guard let on = parseOnOffWord(raw) else {
            print("fbdcli: config model prefer-hardware: expected on or off (got '\(raw)')")
            return 1
        }
        mutateBrightnessPreferences { $0.preferHardwareControl = on }
        return report(on ? "on" : "off")

    case "hardware-min": return nits(prefs.hardwareMinNits, \.hardwareMinNits)
    case "hardware-max": return nits(prefs.hardwareMaxNits, \.hardwareMaxNits)
    case "hdr-sdr-peak": return nits(prefs.hdrPeakSDRNits, \.hdrPeakSDRNits)
    case "hdr-hdr-peak": return nits(prefs.hdrPeakHDRNits, \.hdrPeakHDRNits)

    case "software-zero": return percent(prefs.softwareZeroPercent, 0...100, \.softwareZeroPercent)
    case "min-hardware": return percent(prefs.minHardwarePercent, 0...100, \.minHardwarePercent)
    case "switchover": return percent(prefs.dimmingSwitchoverPercent, 0...100, \.dimmingSwitchoverPercent)
    case "upscale-max": return percent(prefs.upscaleMaxPercent, 100...1000, \.upscaleMaxPercent)

    case "startup-policy":
        guard let raw else { return report(prefs.startupControlValuePolicy.rawValue) }
        let aliases: [String: StartupControlValuePolicy] = [
            "assume": .assumeLastUsed, "write": .writeToDevice, "read": .readFromDevice,
        ]
        guard let policy = StartupControlValuePolicy(rawValue: raw) ?? aliases[raw.lowercased()] else {
            print("fbdcli: config model startup-policy: expected assume, write or read (got '\(raw)')")
            return 1
        }
        mutateBrightnessPreferences { $0.startupControlValuePolicy = policy }
        return report(policy.rawValue)

    default:
        print("fbdcli: config model: unknown key '\(key)'")
        print("keys: prefer-hardware, hardware-min, hardware-max, hdr-sdr-peak, hdr-hdr-peak, "
            + "software-zero, min-hardware, switchover, upscale-max, startup-policy")
        return 1
    }
}

/// `config device list|add|remove` — the saved TV / AVR registry, so a device
/// can be addressed by name from `fbdcli tv`.
@MainActor
func cmdConfigDevice(_ controller: DisplayController, _ args: [String]) -> Int32 {
    guard let sub = args.first else {
        print("fbdcli: config device: expected list, add or remove")
        return 1
    }
    let rest = Array(args.dropFirst())
    let brands = NetworkDevice.Brand.allCases.map(\.rawValue).joined(separator: ", ")

    switch sub {
    case "list":
        let devices = NetworkDeviceRegistry.list()
        guard !devices.isEmpty else {
            print("no saved devices")
            return 0
        }
        for device in devices {
            let zone = device.zone.map { " zone \($0)" } ?? ""
            print("\(device.name): \(device.brand.displayName) at \(device.host)\(zone)")
        }
        return 0

    case "add":
        guard rest.count >= 3 else {
            print("fbdcli: config device add: expected <name> <brand> <host> [zone]")
            print("brands: \(brands)")
            return 1
        }
        guard let brand = NetworkDevice.Brand(rawValue: rest[1].lowercased()) else {
            print("fbdcli: config device add: unknown brand '\(rest[1])'")
            print("brands: \(brands)")
            return 1
        }
        let zone = rest.count > 3 ? rest[3] : nil
        switch NetworkDeviceRegistry.add(name: rest[0], brand: brand, host: rest[2], zone: zone) {
        case .success(let device):
            print("saved \(device.name): \(device.brand.displayName) at \(device.host)")
            return 0
        case .failure(let failure):
            print("fbdcli: config device add: \(failure.message)")
            return 1
        }

    case "remove":
        guard let name = rest.first else {
            print("fbdcli: config device remove: expected a device name")
            return 1
        }
        guard NetworkDeviceRegistry.remove(named: name) else {
            print("fbdcli: config device remove: no device named '\(name)'")
            return 1
        }
        print("removed \(name)")
        return 0

    case "attach":
        guard rest.count >= 2 else {
            print("fbdcli: config device attach: expected <display-id> <device-name>")
            return 1
        }
        guard let display = requireDisplay(rest[0], in: controller) else { return 1 }
        guard NetworkDeviceAttachment.attach(deviceNamed: rest[1], toDisplay: display.identityKey) else {
            print("fbdcli: config device attach: no saved device named '\(rest[1])' — save one with `fbdcli config device add`.")
            return 1
        }
        print("\(display.name) → \(rest[1]): the device now follows this display's volume")
        return 0

    case "detach":
        guard let raw = rest.first else {
            print("fbdcli: config device detach: expected <display-id>")
            return 1
        }
        guard let display = requireDisplay(raw, in: controller) else { return 1 }
        guard NetworkDeviceAttachment.detach(displayIdentityKey: display.identityKey) else {
            print("fbdcli: config device detach: \(display.name) has no attached device")
            return 1
        }
        print("\(display.name): detached")
        return 0

    case "attachments":
        let attached = NetworkDeviceAttachment.attachments()
        guard !attached.isEmpty else {
            print("no attachments")
            return 0
        }
        // A name with no device behind it is marked rather than hidden: the user
        // expected a device there, and silence would read as a bug.
        let dangling = Set(NetworkDeviceAttachment.danglingNames())
        for (identity, name) in attached.sorted(by: { $0.key < $1.key }) {
            print("\(identity) → \(name)\(dangling.contains(name) ? "  (no such device — it was removed)" : "")")
        }
        return 0

    default:
        print("fbdcli: config device: expected list, add, remove, attach, detach or attachments (got '\(sub)')")
        return 1
    }
}
