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

```
UI (SwiftUI views) ──► DisplayController (@MainActor, singleton)
                          │  routes by capability
                          ├─► AppleController ──► DisplayServicesAPI (Apple displays)
                          ├─► DDCController ──► ExternalController ──► IOAVServiceAPI (I2C, arm64)
                          ├─► CombinedController (Tier 2 curve; Tier 1 = routing)
                          ├─► OverlayController (@MainActor; ScreenCaptureKit +
                          │    Metal — software boost, dim-to-black, PiP)
                          └─► ResolutionController ──► CGSAPI + SkyLightAPI
Display state (ObservableObject, @Published) ◄── notifications: .fbdDisplaysChanged / .fbdDisplayUpdated
```

- `DisplayController` is the single public entry point for UI, CLI, and future integrations.
- `Display` is a reference-type `ObservableObject`; instances are preserved across refreshes by display id (SwiftUI observes identity).
- Controllers never throw to callers — they return nil/false and `os_log` (private APIs degrade, UI stays alive).
- DDC I2C access is serialized per display (per-display `DispatchQueue`) with a cooldown (`Settings.ddcCooldownMilliseconds`, default 1 s) between writes.
- Brightness writes are debounced (`Settings.brightnessDebounceMilliseconds`, default 100 ms) in `DisplayController`.

## Concurrency

Swift 5 mode. `@MainActor` on: `DisplayController`, app/UI types. Plain classes: `AppleController`, `ExternalController`, `DDCController`, `CombinedController`, `ResolutionController`. C callbacks (display reconfiguration) hop to main. `fbdcli` uses `MainActor.assumeIsolated` (top-level runs on the main thread).

## Layering rules

1. `PrivateAPI/` wrappers only talk to C/ObjC; they throw `PrivateAPIError` or return nil.
2. `Controllers/` consume `PrivateAPI/` + `Models/` + `Settings`; they never import AppKit (except `DisplayController`, which uses `NSScreen` for names).
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
