import CoreGraphics
import Foundation

// MARK: - The seam

/// The display-control surface the HTTP executor depends on. One adapter is
/// the real DisplayController; the second is a test fake — two adapters make
/// the seam real (the ExternalControlling pattern).
@MainActor
public protocol DisplayControlling: AnyObject {
    var displays: [Display] { get }
    func display(withID id: CGDirectDisplayID) -> Display?

    func getBrightness(for display: Display) -> Double?
    @discardableResult func setBrightness(_ value: Double, on display: Display) -> Bool
    func readDDCControls(for display: Display) -> DisplayController.DDCControls
    func readDDCCapabilities(for display: Display) -> DDC.DDCCapabilities?
    func setContrast(_ value: Double, on display: Display) -> Bool
    func setVolume(_ value: Double, on display: Display) -> Bool
    func setMuted(_ muted: Bool, on display: Display) -> Bool
    func setInputSource(_ source: UInt16, on display: Display) -> Bool
    func applyMode(_ mode: DisplayMode, to display: Display) -> Bool
    func setXDRUpscaleTarget(_ nits: Int, on display: Display) -> Bool
    func disableXDRUpscaling(on display: Display) -> Bool
    func setRotation(_ degrees: Int, on display: Display) -> Int?
    func setScreenFilter(_ params: ScreenFilterParams, on display: Display) -> Bool
    func stopScreenFilter(on display: Display)
    func activeBoostDisplayIDs() -> [UInt32]

    // The remaining state a display preset re-applies. They live on the seam so
    // the preset path (HTTP/CLI/UI) shares one implementation with config
    // protection's restore rather than reaching past it to DisplayController.
    func setAsMainDisplay(_ display: Display) -> Bool
    func selectPreset(_ index: Int, on display: Display) -> Bool
    func setHDRMode(_ enabled: Bool, on display: Display) -> Bool

    // Virtual displays — routed through the single VirtualScreenController so
    // CLI, HTTP and UI share one surface.
    var virtualScreens: [VirtualScreenInstance] { get }
    var virtualConfigs: [VirtualScreenConfig] { get }
    var virtualAvailable: Bool { get }
    @discardableResult func createVirtual(_ config: VirtualScreenConfig) -> Bool
    @discardableResult func destroyVirtual(id: String) -> Bool
    func virtualDisplayID(for id: String) -> CGDirectDisplayID?
}

extension DisplayController: DisplayControlling {
    public var virtualScreens: [VirtualScreenInstance] { VirtualScreenController.shared.screens }
    public var virtualConfigs: [VirtualScreenConfig] { VirtualScreenController.shared.configs }
    public var virtualAvailable: Bool { VirtualScreenController.shared.isAvailable }
    @discardableResult
    public func createVirtual(_ config: VirtualScreenConfig) -> Bool {
        VirtualScreenController.shared.create(config)
    }
    @discardableResult
    public func destroyVirtual(id: String) -> Bool {
        VirtualScreenController.shared.destroy(id: id)
    }
    public func virtualDisplayID(for id: String) -> CGDirectDisplayID? {
        VirtualScreenController.shared.displayID(for: id)
    }
}

// MARK: - The executor

/// Executes a parsed HTTP route against the display-control surface.
///
/// The whole HTTP API surface used to live in the app target's `AppCore`
/// (untestable — no test target for the app). Moved here so every route's
/// behavior is testable through the `DisplayControlling` seam with a fake;
/// the router (path → route) and this executor (route → action) are the two
/// halves of the local API, both in FBDCore.
@MainActor
public enum HTTPExecutor {
    /// Run `route` and produce the HTTP status + JSON body.
    public static func execute(
        _ route: HTTPRoute,
        controller: DisplayControlling,
        version: String
    ) -> (Int, String) {
        switch route {
        case .health:
            let boostIDs = controller.activeBoostDisplayIDs()
            return (200, HTTPJSON.encode([
                "ok": true,
                "version": version,
                "displays": controller.displays.count,
                "boostActive": boostIDs,
            ]))
        case .listDisplays:
            let list = controller.displays.map { HTTPJSON.display($0) }
            return (200, HTTPJSON.encode(["displays": list]))
        case .displayInfo(let id):
            guard let display = controller.display(withID: id) else {
                return (404, HTTPJSON.error("display not found"))
            }
            var info = HTTPJSON.display(display)
            // Live brightness when the model value is stale (nothing read it yet).
            if info["brightness"] == nil, let value = controller.getBrightness(for: display) {
                info["brightness"] = value
            }
            info["modes"] = display.modes.map { HTTPJSON.mode($0) }
            return (200, HTTPJSON.encode(info))
        case .displayControls(let id, let what):
            guard let display = controller.display(withID: id) else {
                return (404, HTTPJSON.error("display not found"))
            }
            switch what {
            case "controls":
                let controls = controller.readDDCControls(for: display)
                let json: [String: Any] = [
                    "contrast": controls.contrast as Any? ?? NSNull(),
                    "volume": controls.volume as Any? ?? NSNull(),
                    "muted": controls.muted as Any? ?? NSNull(),
                    "inputSource": controls.inputSource as Any? ?? NSNull(),
                ]
                return (200, HTTPJSON.encode(["displayID": display.id, "controls": json]))
            default: // "caps"
                if let caps = controller.readDDCCapabilities(for: display) {
                    return (200, HTTPJSON.encode(["displayID": display.id, "raw": caps.raw, "mccsVersion": caps.mccsVersion, "vcp": caps.vcpCodes.sorted().map { String(format: "0x%02X", $0) }]))
                }
                return (404, HTTPJSON.error("no capabilities for display"))
            }
        case .displayAction(let id, let action):
            guard let display = controller.display(withID: id) else {
                return (404, HTTPJSON.error("display not found"))
            }
            switch action {
            case .contrast(let value):
                guard controller.setContrast(value, on: display) else { return (500, HTTPJSON.error("write not accepted")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .brightness(let value):
                guard controller.setBrightness(value, on: display) else { return (500, HTTPJSON.error("no control path for display")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .volume(let value):
                guard controller.setVolume(value, on: display) else { return (500, HTTPJSON.error("write not accepted")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .mute(let muted):
                guard controller.setMuted(muted, on: display) else { return (500, HTTPJSON.error("write not accepted")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .input(let source):
                guard controller.setInputSource(source, on: display) else { return (500, HTTPJSON.error("write not accepted")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .mode(let width, let height, let hz):
                guard let mode = HTTPJSON.bestMode(matchingWidth: width, height: height, hz: hz, in: display) else {
                    return (404, HTTPJSON.error("no matching mode"))
                }
                guard controller.applyMode(mode, to: display) else {
                    return (500, HTTPJSON.error("mode switch failed"))
                }
                return (200, HTTPJSON.encode(["ok": true, "mode": mode.key]))
            case .xdr(let nits):
                guard controller.setXDRUpscaleTarget(nits, on: display) else { return (500, HTTPJSON.error("XDR upscaling failed")) }
                return (200, HTTPJSON.encode(["ok": true, "nits": nits]))
            case .xdrDisable:
                guard controller.disableXDRUpscaling(on: display) else { return (500, HTTPJSON.error("failed to disable XDR upscaling")) }
                return (200, HTTPJSON.encode(["ok": true]))
            case .rotate(let degrees):
                guard controller.setRotation(degrees, on: display) != nil else {
                    return (500, HTTPJSON.error("failed to rotate display"))
                }
                return (200, HTTPJSON.encode(["ok": true, "degrees": degrees]))
            case .filter(let params):
                guard controller.setScreenFilter(params, on: display) else {
                    return (500, HTTPJSON.error("failed to apply filter"))
                }
                return (200, HTTPJSON.encode(["ok": true]))
            case .filterOff:
                controller.stopScreenFilter(on: display)
                return (200, HTTPJSON.encode(["ok": true]))
            }
        case .systemAudioDevices:
            let audio = SystemVolumeController.shared
            audio.refresh()
            return (200, HTTPJSON.encode([
                "devices": audio.devices.map {
                    ["id": Int($0.id), "name": $0.name, "hasVolumeControl": $0.hasVolumeControl]
                },
            ]))

        case .systemVolume(let device, let value):
            let audio = SystemVolumeController.shared
            if let device {
                // select() re-reads that device, so a caller can name an output
                // instead of acting on whatever the default happens to be.
                audio.select(device)
            }
            guard let value else {
                // The HAL read is asynchronous by design, so this reports the
                // last known state rather than blocking the request on a device
                // that may take hundreds of milliseconds to answer.
                var payload: [String: Any] = [
                    "muted": audio.isMuted,
                    "controllable": audio.isControllable,
                ]
                if let level = audio.volume { payload["volume"] = level }
                if let name = audio.deviceName { payload["device"] = name }
                if let selected = audio.selectedDevice { payload["selected"] = Int(selected) }
                return (200, HTTPJSON.encode(payload))
            }
            // A device we have already read and know has no software volume
            // cannot accept this. A 409 says so; replying "ok" for a write the
            // HAL drops would be a lie. Before the first read we do not know, so
            // the write is passed through and the GET is the source of truth.
            if audio.deviceName != nil, !audio.isControllable {
                return (409, HTTPJSON.error("output device exposes no software volume control"))
            }
            audio.set(value)
            return (200, HTTPJSON.encode(["ok": true, "requested": value]))

        case .virtualList:
            let screens = controller.virtualScreens.map { ["id": $0.id, "name": $0.config.name, "displayID": $0.displayID] }
            let configs = controller.virtualConfigs.map { ["id": $0.id, "name": $0.name] }
            return (200, HTTPJSON.encode(["screens": screens, "configs": configs]))
        case .virtualCreate(let request):
            guard controller.virtualAvailable else {
                return (500, HTTPJSON.error("virtual displays unavailable on this macOS"))
            }
            let config = VirtualScreenConfig(
                name: request.name,
                width: request.width,
                height: request.height,
                refreshRate: request.hz,
                isHDR: request.isHDR,
                autoConnect: true
            )
            guard controller.createVirtual(config) else {
                return (500, HTTPJSON.error("failed to create virtual display"))
            }
            let displayID = controller.virtualDisplayID(for: config.id) ?? 0
            return (201, HTTPJSON.encode(["ok": true, "id": config.id, "displayID": displayID]))
        case .virtualDestroy(let id):
            guard controller.destroyVirtual(id: id) else {
                return (404, HTTPJSON.error("no virtual display '\(id)'"))
            }
            return (200, HTTPJSON.encode(["ok": true]))
        case .configStatus:
            // Read-only, and the whole point of the endpoint: a script can see
            // what the parity surfaces are set to without shelling out per key.
            let model = Settings.brightnessPreferences
            return (200, HTTPJSON.encode([
                "lockDim": [
                    "enabled": Settings.lockDimEnabled,
                    "targetPercent": Settings.lockDimTargetPercent,
                ],
                "keyboardControlTarget": Settings.keyboardControlTarget.rawValue,
                "keyboardControlTargets": KeyboardControlTarget.allCases.map(\.rawValue),
                "configurationProtectionEnabled": Settings.configProtectionEnabled,
                "brightnessModel": [
                    "preferHardwareControl": model.preferHardwareControl,
                    "hardwareMinNits": model.hardwareMinNits,
                    "hardwareMaxNits": model.hardwareMaxNits,
                    "hdrPeakSDRNits": model.hdrPeakSDRNits,
                    "hdrPeakHDRNits": model.hdrPeakHDRNits,
                    "softwareZeroPercent": model.softwareZeroPercent,
                    "minHardwarePercent": model.minHardwarePercent,
                    "dimmingSwitchoverPercent": model.dimmingSwitchoverPercent,
                    "upscaleMaxPercent": model.upscaleMaxPercent,
                    "startupControlValuePolicy": model.startupControlValuePolicy.rawValue,
                ],
            ]))

        case .configLockDim(let enabled, let targetPercent):
            // Omitted targetPercent keeps the stored one, so toggling the flag
            // never silently rewrites the level. `clamped()` is the same
            // normalisation the app and the CLI apply.
            let policy = LockDimPolicy(
                enabled: enabled,
                targetPercent: targetPercent ?? Settings.lockDimTargetPercent
            ).clamped()
            Settings.lockDimEnabled = policy.enabled
            Settings.lockDimTargetPercent = policy.targetPercent
            return (200, HTTPJSON.encode([
                "ok": true,
                "enabled": policy.enabled,
                "targetPercent": policy.targetPercent,
            ]))

        case .configKeyboardTarget(let target):
            Settings.keyboardControlTarget = target
            return (200, HTTPJSON.encode(["ok": true, "target": target.rawValue]))

        case .configConnections(let action):
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
                // Not failure: the planner declines `disconnectAllButMain` with no
                // main display, and `swapIdentical` with anything but two matches.
                return (200, HTTPJSON.encode(["ok": true, "steps": 0, "changed": 0]))
            }
            let changed = DisconnectController().apply(steps)
            return (200, HTTPJSON.encode(["ok": true, "steps": steps.count, "changed": changed]))

        case .configProtection(let displayID, let properties):
            guard let display = controller.display(withID: displayID) else {
                return (404, HTTPJSON.error("display not found"))
            }
            ConfigProtectionController().setProtectedProperties(properties, for: display)
            // `names` renders in canonical order — the same rendering `fbdcli
            // config protect` prints, so the two surfaces agree.
            return (200, HTTPJSON.encode(["ok": true, "properties": properties.names]))

        case .configDevice(let action):
            switch action {
            case .list:
                let devices = NetworkDeviceRegistry.list().map { device in
                    ["name": device.name, "brand": device.brand.rawValue, "host": device.host, "zone": device.zone ?? ""]
                }
                return (200, HTTPJSON.encode(["devices": devices]))

            case .add(let name, let brand, let host, let zone):
                switch NetworkDeviceRegistry.add(name: name, brand: brand, host: host, zone: zone) {
                case .success(let device):
                    return (201, HTTPJSON.encode(["ok": true, "name": device.name, "host": device.host]))
                case .failure(let failure):
                    // 409: the request was well-formed, it conflicts with what is
                    // already stored.
                    return (409, HTTPJSON.error(failure.message))
                }

            case .remove(let name):
                guard NetworkDeviceRegistry.remove(named: name) else {
                    return (404, HTTPJSON.error("no device named '\(name)'"))
                }
                return (200, HTTPJSON.encode(["ok": true]))
            }

        case .configFavourite(let displayID, let action):
            guard let display = controller.display(withID: displayID) else {
                return (404, HTTPJSON.error("display not found"))
            }
            // Favourites are stored per display *identity*, not per display id, so
            // they survive a reconnect that renumbers the display.
            let identity = display.identityKey
            switch action {
            case .list:
                let stored: [[String: Any]] = ModeFavourites.favourites(for: identity).map { favourite in
                    [
                        "slot": favourite.slot,
                        "width": Int(favourite.width),
                        "height": Int(favourite.height),
                        "refreshRate": favourite.refreshRate,
                        "isHiDPI": favourite.isHiDPI,
                    ]
                }
                return (200, HTTPJSON.encode(["favourites": stored]))

            case .save(let slot):
                guard let mode = display.currentMode else {
                    return (409, HTTPJSON.error("this display reports no current mode"))
                }
                guard ModeFavourites.save(mode, into: slot, for: identity) else {
                    return (400, HTTPJSON.error("slot must be between 1 and \(ModeFavourites.slotCount)"))
                }
                return (200, HTTPJSON.encode(["ok": true, "slot": slot]))

            case .apply(let slot):
                let recall = ModeFavourites.recall(slot: slot, for: identity, against: display.modes)
                // A favourite whose mode is gone is reported, never approximated:
                // applying a near-miss resolution is worse than doing nothing.
                guard let mode = recall.displayMode else {
                    return (404, HTTPJSON.error("favourite \(slot) has no matching mode on this display"))
                }
                guard controller.applyMode(mode, to: display) else {
                    return (500, HTTPJSON.error("the display refused that mode"))
                }
                return (200, HTTPJSON.encode(["ok": true, "slot": slot, "modeNumber": Int(mode.modeNumber)]))
            }

        case .configPreset(let displayID, let action):
            guard let display = controller.display(withID: displayID) else {
                return (404, HTTPJSON.error("display not found"))
            }
            // Like favourites, presets are stored per display *identity*, so
            // they survive a reconnect that renumbers the display.
            let presetIdentity = display.identityKey
            switch action {
            case .list:
                let stored: [[String: Any]] = DisplayPresets.presets(for: presetIdentity).map { preset in
                    [
                        "id": preset.id.uuidString,
                        "name": preset.name,
                        "symbol": preset.symbol.symbolName,
                        "properties": preset.properties.names,
                    ]
                }
                return (200, HTTPJSON.encode(["presets": stored]))

            case .save(let name, let symbol, let properties):
                let preset = DisplayPreset(
                    name: name,
                    symbol: symbol,
                    properties: properties,
                    state: DisplayStateSnapshot.capture(
                        for: display,
                        resolution: ResolutionController(),
                        controller: controller
                    )
                )
                guard DisplayPresets.save(preset, for: presetIdentity) else {
                    // The name is validated by the router, so the only refusal
                    // left here is a name already taken — a conflict with what
                    // is stored, not a malformed request.
                    return (409, HTTPJSON.error("a preset named '\(name)' already exists"))
                }
                return (201, HTTPJSON.encode(["ok": true, "id": preset.id.uuidString, "name": preset.name]))

            case .apply(let reference):
                guard let preset = DisplayPresets.resolve(reference, for: presetIdentity) else {
                    return (404, HTTPJSON.error("no preset '\(reference)' for this display"))
                }
                let outcome = DisplayPresetApplier.apply(
                    preset,
                    to: display,
                    resolution: ResolutionController(),
                    controller: controller
                )
                return (200, HTTPJSON.encode([
                    "ok": true,
                    "id": preset.id.uuidString,
                    "applied": outcome.applied.names,
                    "unavailable": outcome.unavailable.names,
                ]))

            case .delete(let reference):
                guard let preset = DisplayPresets.resolve(reference, for: presetIdentity) else {
                    return (404, HTTPJSON.error("no preset '\(reference)' for this display"))
                }
                guard DisplayPresets.remove(id: preset.id, for: presetIdentity) else {
                    return (500, HTTPJSON.error("the preset could not be removed"))
                }
                return (200, HTTPJSON.encode(["ok": true, "id": preset.id.uuidString]))
            }
        }
    }
}