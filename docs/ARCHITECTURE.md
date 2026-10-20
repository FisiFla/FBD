# FBD — Architecture

## Targets

```
FBDCore        library — all logic (models, controllers, private-API wrappers, DDC protocol)
FBD            executable — LSUIElement menu-bar app (AppKit + SwiftUI)
fbdcli         executable — CLI (command bodies + HTTP routing)
FBDCLIParser   library — CLI command vocabulary + all argument/spec parsers +
               the routed-CLI request/URL builders (HTTPRoutingPlan,
               HTTPRequestBuilder) — all unit-tested; fbdcli delegates
FBDIntents     library — Shortcuts actions (AppIntents; exposed via the app's
               FBDAppIntentsBridge)
CPrivateAPI    C target — private-framework declarations + CGS struct layout (single header)
FBDCoreTests   unit tests (FBDCore)
FBDCLIParserTests  unit tests (parsers)
```

`make app` assembles `build/FBD.app` (universal binary, Info.plist with LSUIElement + `fbd://` scheme, ad-hoc signed).

## Data flow

`AppCore` (`Sources/FBD/AppCore.swift`, `@MainActor`) is the composition root of the
menu-bar app. `start()` wires everything in order: it registers the
`.fbdDisplaysChanged` / `.fbdDisplayUpdated` observers *before* starting
`DisplayController` (so the first popover sees the populated list), then starts the
independent controllers, the HTTP server and the OSD, and applies the Dock policy.

```
AppCore (composition root, created at launch)
 ├─► StatusItemController ──► SwiftUI panel/Settings views (consume DisplayController)
 ├─► DisplayController (@MainActor singleton; display list + per-display control routing)
 │     ├─► AppleController ──► DisplayServicesAPI (Apple displays)
 │     ├─► DDCController ──► ExternalController ──► IOAVServiceAPI (I2C, arm64)
 │     ├─► CombinedBrightness (nits curve: hardware → native XDR → software)
 │     ├─► OverlayController (ScreenCaptureKit + Metal: software boost, filters, dim, PiP)
 │     ├─► XDRNativeController ──► SkyLightAPI (native preset rewrite)
 │     └─► ResolutionController ──► CGSAPI + SkyLightAPI
 ├─► VirtualScreenController, DisconnectController, LayoutProtectionController,
 │   EdgeCrossingController, EDIDController, ConfigProtectionController,
 │   LockDimController, DisplayAutomationController, KeepAwakeController,
 │   NightShift/TrueTone, PipStreamController, HotkeyController, UpdaterController (Sparkle)
 └─► HTTPServer ──► route handler ──► DisplayController / the controllers above
                    ▲
fbdcli ─────────────┘  (when the app is running — ADR 0004; otherwise direct controllers)
Display state (ObservableObject, @Published) ◄── notifications: .fbdDisplaysChanged / .fbdDisplayUpdated
```

`DisplayController` owns the display list and the per-display control paths; it is *not* the hub
for everything else. Display groups and their sync policy, named presets, configuration
protection, the pointer controllers (containment and edge crossing), keep-awake, lock-dim,
Night Shift / True Tone, virtual screens, corner-radius masks and the network TV/AVR drivers hang
off `AppCore`. Each owns its own state and its own timer and is started once from
`AppCore.start()`. The HTTP server is reconciled live against `Settings` (notification plus a
1.5 s poll for cross-process writes by the CLI), so `fbdcli http on/off` needs no restart.

- `DisplayController` is the entry point for display state and per-display control (UI, HTTP API, CLI direct mode); other subsystems are reached through `AppCore`.
- `Display` is a reference-type `ObservableObject`; instances are preserved across refreshes by display id (SwiftUI observes identity).
- Controllers never throw to callers — they return nil/false and `os_log` (private APIs degrade, UI stays alive).
- DDC I2C access is serialized per display (per-display `DispatchQueue` in `DDCQueuePool`) with a cooldown (`Settings.ddcCooldownMilliseconds`, default 1 s) between writes. Reads are paced (`Settings.ddcReadCooldownMilliseconds`, default 100 ms), served from a 5 s cache, and validated before any of their numbers are used; a display that stops answering has its reads quarantined. A display topology change (enable/disable, mode switch) pauses DDC traffic and waits for the transactions already in flight. The contract is audited against didriksg/Crisp v1.7.1 in `docs/ddc-equivalence.md`.
- Brightness writes are debounced (`Settings.brightnessDebounceMilliseconds`, default 100 ms) in `DisplayController`.

## OS-version differences

Apple changes private display APIs between releases, so FBD prefers runtime
capability checks over version checks, and every private path has a fallback:

- **Symbol resolution at runtime**: private C functions are declared in
  `CPrivateAPI` and called through `PrivateAPI/` wrappers that return nil/false
  when a symbol or framework is missing. `CGVirtualDisplay` is loaded with
  `dlopen`/`dlsym` (`CGVirtualDisplayAPI.isAvailable`); the SkyLight
  `SLVirtualDisplay` path is checked via `VirtualDisplayAPI.isAvailable`. macOS 26+
  uses the latter, 13-15 the former.
- **Runtime self-tests**: native XDR upscaling probes whether preset writes take
  effect (`XDRNativeController`); when write-protected (macOS 27) `CombinedBrightness`
  falls back to the software boost overlay (ADR 0003).
- **Classes by name**: types that exist only on newer SDKs/OSes are looked up via
  `NSClassFromString` and configured through KVC (`OSDGlass` for `NSGlassEffectView`,
  macOS 26+; Night Shift / True Tone clients), because `#available` does not help when the
  symbol is missing at *compile* time on older SDKs (CI builds with the macOS 15 SDK).
- **`#available` sites** (the only ones): `VirtualScreenController` (session
  notifications, macOS 14+), `AppIntentsBridge` and `FBDIntents` (App Intents,
  macOS 13/14+).
- **Hardware gates**: DDC requires native arm64 (`IOAVServiceAPI.isAppleSilicon`,
  Rosetta detected and warned); the built-in-display disconnect is refused on base-M3
  Macs.

Per-version behaviour is tabulated in the README and `docs/PRIVATE_APIS.md`.

## Concurrency

Swift 5 mode. `@MainActor` on `DisplayController`, `AppCore` and the app/UI types, plus the
controllers that own a window, a timer or an event monitor — configuration protection, cursor
containment, edge crossing, the custom OSD, display automation, hotkeys, the overlay and PiP,
system volume. The rest are plain classes: the capability routers (`AppleController`,
`ExternalController`, `DDCController`) and the curve/mode helpers (`CombinedBrightness`,
`ResolutionController`, `EDIDController`, `XDRNativeController`). C callbacks (display
reconfiguration) hop to main. `fbdcli` uses `MainActor.assumeIsolated` (top-level runs on the
main thread).

## Layering rules

1. `PrivateAPI/` wrappers only talk to C/ObjC; they throw `PrivateAPIError` or return nil.
2. `Controllers/` consume `PrivateAPI/` + `Models/` + `Settings`. Most are AppKit-free; the ones
   that must touch it import it and are deliberately few — `DisplayController` (for `NSScreen`
   names), `OverlayController`, `PipStreamController`, `HotkeyController`, `CustomOSD`,
   `OSDGlass`, `DisplayAutomationController`, `EDIDController`, `VirtualScreenController`,
   `EdgeCrossingController`. Anything that does not need a window or an event stays testable
   without a running app.
3. UI/CLI consume only the controller public API.
4. New private APIs: declare in `CPrivateAPI/include/fbd_private_api.h`, wrap in `PrivateAPI/`, document in `docs/PRIVATE_APIS.md`.

## Settings

`Settings` enum in FBDCore — UserDefaults-backed (`Storage` property wrapper), domain `dev.fisifla.fbd`. Per-display state (DDC feature sets) keyed by `Display.identityKey` (`vendor-model-serial`).

## HTTP API design decisions

- **`Connection: close` (no keep-alive) is deliberate.** The control API is
  local, low-rate and per-request authenticated; the hand-rolled server
  keeps one request per connection for simplicity and bounded memory.
  Clients (fbdcli, curl) reconnect per call — measured overhead is
  negligible on loopback.
- **`Expect: 100-continue` is honored** (interim response before the body);
  declared `Content-Length` above 1 MB is rejected with 413 before
  buffering; idle connections are dropped after 10 s.
- **`/api/health` is the only unauthenticated endpoint** (uptime checks).
