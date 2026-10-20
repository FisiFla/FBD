# FBD — Architecture

## Targets

```
FBDCore        library — all logic (models, controllers, private-API wrappers, DDC protocol)
FBD            executable — LSUIElement menu-bar app (AppKit + SwiftUI)
fbdcli         executable — CLI (command bodies + HTTP routing)
FBDCLIParser   library — CLI command vocabulary + all argument/spec parsers +
               the routed-CLI request/URL builders (HTTPRoutingPlan,
               HTTPRequestBuilder) + the CLI's grammar table, the agent-skill
               document and the write-outcome taxonomy — all unit-tested;
               fbdcli delegates. No FBDCore dependency: plain values only
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
- **Brightness layering**: the brightness of a display is carried by up to three layers — the hardware (Apple or DDC), the native XDR upscale, and the software overlay (a dim or a boost). `CombinedBrightness` picks the route through `XDRBoostPlanner` and keeps the layers from fighting each other: a boost and a dim cancel out, so a route that needs one releases the other.
- **The below-floor blend** (`BrightnessFloorBlend`) is the one layer that deliberately splits a request in two. A monitor's brightness scale rarely reaches black, so below a threshold the hardware is pinned at the threshold and the software layer carries the rest as a multiplicative dim — the same effect Crisp gets from a transfer table, expressed through FBD's existing screen-filter path (`ScreenFilterParams.brightness`) rather than a new shader. The threshold is a fraction of the *hardware* scale, never below a measured floor. While the blend is in force the hardware read-back reports the floor, so `reconstructSlider` rebuilds the logical position from the software factor: the slider must report what the user asked for, not what the panel can do. In HDR the DDC scale says nothing about the panel's luminance, so the whole range goes to the software layer and the hardware is left alone. The blend is off by default and needs Screen Recording permission; without a surface that outlives the call (a one-shot `fbdcli` run) it does not engage at all, because a pinned hardware with nothing left to dim it would leave the screen brighter than the slider says.
- **The HiDPI ladder** (`HiDPILadder`, `HiDPIOverrideCommand`, `HiDPIOverrideService`) is split the same way the DDC work is: the *command model* is pure and unit-tested (which ladder, which path, whether the file on disk already says that, the exact command), and the *executor* (`PrivilegedCommandExecuting`) is the only part that knows about privilege escalation. Today the executor is a one-shot `do shell script "…" with administrator privileges`; the privileged helper (ADR 0005) replaces just that one type when it can be signed. Only numbers and Base64 ever reach the shell — the vendor/product identifiers, the serial and the ladder — and the plist is staged next to its destination and moved into place, so a failed write never leaves a half-written override behind.

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

## The CLI's write contract

`fbdcli` writes in two ways: directly against the controllers (when the app is not running) or
over the app's HTTP API (when it is). Both end in the same place — a state change the user may
or may not be able to see.

The CLI therefore distinguishes three outcomes of a write, and never blurs them:

- **applied** — the app confirmed it;
- **refused / failed** — the write did not happen;
- **reply lost** — the request went out and no answer came back, so the app *may have
  committed it*.

The third case is the one that matters for an agent or a script: repeating the command would
apply the change twice. So a lost reply prints *the command may have applied* together with the
command that reads the state back (`fbdcli brightness 1`), and exits **75** (`EX_TEMPFAIL`)
rather than the usual failure code 2. No error message invites a blind retry.

The read-back commands come from one table (`CLIGrammar` in `FBDCLIParser`), which is also
what the agent skill's grammar table is generated from — so the skill, the help text and the
runtime hints cannot drift apart. `fbdcli skill install <claude|codex>` writes that skill as a
`SKILL.md`; the document is compiled in, so `--print` and the installed file are byte-for-byte
the same.

## Diagnostics

Two smoke harnesses live in `scripts/`. Both drive the real code paths — the app's own
controllers, not a reimplementation — and both are manual: they need hardware or an
Accessibility grant, so neither runs in CI.

- **`scripts/ui-smoke.sh`** — drives the popover through Accessibility and CGEvent: opens the
  panel, moves a brightness slider, walks into a display page and back, opens and closes
  Settings. Needs Accessibility permission for the calling terminal.
- **`scripts/ddc-smoke.sh`** — exercises the DDC/CI path against an attached display. It
  enumerates the displays through the app's own matching layer (`fbdcli list --json` →
  `DisplayController` → `ExternalController` → `IOAVServiceAPI`), so a display paired to the
  wrong DDC channel shows up as a wrong answer rather than as a missing row, and then per
  display parses the EDID, parses the capabilities string and reads brightness, contrast and
  volume. Read-only by default.

  `--write-test` adds one set-and-read-back round trip per feature (one step, then the
  original value restored — and restored again if the script is interrupted); `--write-all`
  extends it to contrast and volume. `--json` prints the machine-readable evidence format
  (the same shape the `--ledger` block is written in), and `--ledger` appends a timestamped
  evidence block to `docs/PRIVATE_APIS.md`. With no DDC-capable display attached, every check
  is skipped and the script exits 0.
