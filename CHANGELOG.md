# Changelog

All notable changes to FBD. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: semver from 1.0.0 (the first release with an update feed).

## [Unreleased]

### Added
- **Per-display options menu** (ellipsis in each display card): Display Mode
  (all modes with current marker), Refresh Rate (unique Hz values),
  Color Mode (profiles), Apple Display Preset (XDR presets), Mirror Display
  (per-target mirror/unmirror via display groups), Stream Display and
  Picture in Picture (floating video-filter window), Image Adjustments
  (video-filter window + live contrast/saturation sliders), Move Display
  (Set as Main Display via CGConfigureDisplayOrigin), Screen Rotation
  (honestly disabled — unsupported), Configuration Protection (lock current
  settings), Manage Display (disable/re-enable gated by the new setting).
- **Quick-controls row per display**: HiDPI toggle (same-size mode
  variant), Auto Brightness toggle (hardware ambient-light compensation,
  hidden when unsupported), Notch toggle (disabled — unsupported).
- **Tools footer**: Displays And Virtual Screens (scroll-to menu), Groups,
  Video Filter Window (opens a real PiP stream), System Colors (System
  Settings → Displays), Check for Updates, Quit FBD.
- **Settings tabs**: Overview / Per-Display segmented control; the
  per-display tab lists each display (offline included when enabled) with
  its mode, brightness and connect/disconnect controls.
- **New settings**: Show offline displays in Settings; Enable
  connect/disconnect for displays (gates the power/disable controls).

### Changed
- `DisplayController`: ambient-light compensation passthroughs and
  `setAsMainDisplay` (CGConfigureDisplayOrigin to (0,0)).

## [1.2.1] — 2026-08-03

### Fixed
- **Software XDR boost rendered the screen out of focus**: the ScreenCaptureKit
  capture used the display's point size (1728×1117), so the overlay redrew a
  2x display at half resolution. The capture now uses the physical pixel
  resolution (CGDisplayPixelsWide/High — 3456×2234 on the built-in).
  Verified: overlay layer resolution 1728×1117 → 3456×2234, and edge energy
  with boost on stays at ~0.91 of the unboosted screen (was heavily blurred).

## [1.2.0] — 2026-08-03

### Changed
- **UI overhaul** — premium floating-glass panel (Control Center-style):
  - Design system (`FBDTheme`, `FBDTag`, `DisplayKind`) — semantic system
    colors, shared spacing/radii/motion tokens, full dark/light adaptation.
  - Frosted-glass panel background (`NSVisualEffectView` behind transparent
    window) with rounded cards for display rows, virtual screens and groups.
  - Custom slider (`FDBSlider`) — gradient fill, floating thumb, hover/active
    micro-animations, XDR "boost zone" divider; keyboard arrows and VoiceOver
    adjustable-action support.
  - Brightness control now shows a live nits estimate on XDR displays and a
    hardware→XDR zone marker; badges distinguish Built-in / External (DDC) /
    Virtual / XDR displays.
  - Display cards: kind icon tile, capability tags, redesigned DDC panel,
    icon-labeled disclosure sections.
  - Settings regrouped into icon-labeled sections; HTTP note updated
    (applies immediately, no restart); About section with app tile.
  - Reduced Motion respected throughout.
  - **Top-bar overlap fixes** (feedback pass): a reserved 28pt frosted
    titlebar strip so content never slides under the traffic lights, with
    the bar's material extending up into the strip so the traffic lights
    sit ON the bar (unified-toolbar look) instead of floating above it; the
    bar is a single row — traffic lights and content share the band (64pt
    light clearance, content beside them), no empty gap under the buttons; the
    main header is now a fixed elevated bar (material + hairline divider,
    gear moved in from the toolbar) instead of floating; Settings got its
    own fixed header bar with a **Back** button (there was no way back
    before) and the panel grows to 460×860 on settings open (top-anchored)
    and shrinks back on Back.

## [Unreleased]

### Fixed
- **XDR software boost was dead on write-protected systems** (found via live
  testing with a real Screen Recording grant): the explicit
  `xdr <id> <nits>` command always chose the native preset path when the
  display was XDR-capable, so on macOS 27 (write-protected preset slots) it
  failed without ever trying the software overlay. `setXDRUpscaleTarget`
  now falls back to the software boost when the native write fails.
- **Boost overlay never composited**: the renderer presented Metal drawables
  manually from the capture queue on a paused MTKView, which renders nothing
  on this system. Switched to the MTKView-delegate draw pattern (frames
  stored on the capture queue, drawn on the main thread).
- **Boost overlay leaked after "off"**: tearing down could race the session
  deallocation and leave the last brightened Metal frame frozen on-screen
  (the screen stayed boosted until the app quit). Teardown now hides the
  window synchronously (alpha 0 + orderOut) before stopping the stream, and
  overlay windows are `isReleasedWhenClosed` so close() destroys them.

### Changed
- `GET /api/health` now reports `boostActive` (display IDs with a live
  software-boost session) — observability for the overlay.

## [Unreleased]

### Fixed
- **Panel showed "Brightness unavailable" at launch**: nothing performed an
  initial brightness read — the value only appeared after a write or an
  external change. `DisplayController.refresh()` now reads each
  brightness-capable display once at enumeration.
- **Top bar sat ~34pt below the traffic lights**: the SwiftUI root was
  inset by the titlebar safe area despite `.fullSizeContentView`; the root
  now uses `.ignoresSafeArea()` so the material bar actually extends up
  under the buttons.

### Verified (with Accessibility permission granted)
- Full UI flow driven end-to-end: status-item click opens the main page,
  the custom brightness slider sets real brightness (24.8% / 71.4%
  read-backs), the gear opens Settings (window grows to 860), Back returns
  to the main page (650), the close × hides the panel. Button hit areas
  were verified against the live Accessibility frames.

## [Unreleased]

### Fixed
- **Settings toggles turned gray after the panel lost focus**: the panel is
  a `.nonactivatingPanel` that rarely holds key status, so SwiftUI rendered
  every control in the gray "inactive" variant whenever another window had
  focus (observed live: switches blue on first open, gray after clicking
  outside). The panel root now forces `controlActiveState = .key`, and the
  settings switches get an explicit `.tint(.blue)` on-state. Verified by
  pixel-sampling the switch fill while focused and unfocused (both blue).



### Added
- AppIntents bridge (`FBDAppIntentsBridge`) so the Shortcuts actions from the
  `FBDIntents` module are discoverable by macOS (previously compiled but
  unreachable from Shortcuts).
- `fbdcli list --json` — machine-readable output using the same serializer as
  the app's HTTP API.
- Media-key interception status surfacing: the Settings panel shows an
  "Media keys unavailable" hint when Accessibility permission is missing or
  revoked; the event tap auto-re-enables after system suspension and retries
  installation when the app is re-activated after granting permission.
- Accessibility labels: status-bar button, panel close/settings buttons,
  per-display brightness sliders (label + percent value).
- Right-click status-item menu (Show FBD / Settings… / Quit FBD);
  `fbdcli settings` masked settings dump for bug reports; `GET /api/health`
  unauthenticated endpoint.
- Parser fuzz sweeps (EDID/VCP/capabilities, 1,200 seeded iterations) and
  Swift-6-readiness fixes (NSLock → `withLock` in async contexts).

### Fixed
- XDR upscaling on macOS 27: the software boost fallback now defaults ON and
  is reachable from the explicit `xdr <id> <nits>` command (previously only
  the combined slider path fell back, and the default disabled it — the
  documented macOS 27 path was dead out of the box). The combined slider's
  below-ceiling path now stops an active overlay boost (the overlay does not
  set `isXDRUpscaled`, so the screen could previously stay brightened after
  dragging below the ceiling), and `isCombinedCapable` accepts the software
  fallback when the native path self-tests as write-protected. The overlay
  itself requires **Screen Recording** permission (documented in README).
- Routed `virtual destroy <name>` sent the raw name as the config id; names
  are now resolved to persisted ids before calling the app.
- Routed `virtual create` ignored the `isHDR` flag from the request body
  (hardcoded `false`).
- EDID overrides are now structurally validated (size 128–512, multiple of
  128, header, base-block checksum) at the CLI, controller and persistence
  gates — garbage can no longer reach the display registry or the
  auto-apply store.
- `Display.isVirtual` now uses an authoritative, cross-process registry of
  FBD-created virtual display IDs (persisted in Settings); the magic-ID
  fingerprints remain only as a fallback for Sidecar/AirPlay displays.
- HTTP server: declared `Content-Length` above 1 MB is rejected with 413
  before buffering; `Expect: 100-continue` is acknowledged so curl/URLSession
  clients no longer hang.
- `ColorProfileController` no longer force-unwraps the ColorSync UUID (crash
  when a display disconnects mid-flight).
- Release builds no longer silently copy a stale binary when the build fails
  (Makefile fails loudly now).

### Added (cycles 31-41)
- `fbdcli info <id> --json`; `fbdcli settings` masked dump (cycle 13);
  zsh completion (`completions/_fbdcli`).
- Live HTTP server reconciliation: `fbdcli http on/off` applies without
  an app restart (Settings watch + poll).
- `make bump-version`; secrets-ready release workflow
  (`.github/workflows/release.yml`).

### Fixed (cycles 31-41)
- `pip` controller instance mismatch (start/stop used different
  instances) — now shared.
- `applyMode` failures surfaced: the HTTP API returns 500 and `fbdcli
  set-mode` exits 2 instead of reporting false success.
- SIGTERM now routes through `NSApp.terminate` so AppKit cleanup runs on
  `kill` (cycle 27).
- XDR upscaling fallback on macOS 27: software boost defaults on, the
  explicit `xdr` command falls back to the overlay, below-ceiling drags
  stop an active overlay boost (cycles 21-22, planner-tested).
- Mode-spec and `tv` brand leniency fixes (cycles 17, 23).

### Verified (cycles 31-41)
- Close-read audit series across every remaining path (2 real fixes
  found, rest clean); memory-leak audit (framework-internal only);
  dependency drift (all current); full 23-command live regression matrix
  (cycle 30); launch-captured settings audit (clean); repo hygiene.

### Added (cycles 22-29)
- `XDRBoostPlanner`: the XDR fallback decision chain is a pure, tested layer
  shared by the slider and the `xdr` command.
- `completions/_fbdcli`: zsh tab-completion for all 32 commands and
  subcommands.
- Release workflow (`.github/workflows/release.yml`): tag-triggered
  sign/notarize/publish when the five secrets are configured; graceful
  unsigned-artifact fallback otherwise.
- `make bump-version VERSION=x.y.z [BUILD=n]` release helper.
- Shell/observability: `fbdcli settings` (masked dump), `GET /api/health`.

### Fixed (cycles 22-29)
- XDR upscaling on macOS 27: the software boost fallback now defaults ON and
  is reachable from the explicit `xdr` command; the below-ceiling slider
  path stops an active overlay boost; `isCombinedCapable` accepts the
  fallback when native preset writes are write-protected. The overlay needs
  **Screen Recording** permission (documented).
- SIGTERM now routes through `NSApp.terminate` so AppKit cleanup
  (willTerminate observers, e.g. the EDID factory restore on quit) runs on
  `kill`/session end.
- Mode-spec leniency: `1920x1080@` / `1920x` are rejected instead of
  silently dropping the trailing part.
- `fbdcli tv` brands match case-insensitively (`LG` now works).

### Verified (cycles 22-29)
- Memory-leak audit: no application-code leaks (framework-internal XPC
  allocations only).
- `fbd://` URL scheme end-to-end (brightness URL + malformed-input
  robustness); startup latency 0.57 s; help covers all 32 commands;
  full 23-command live regression matrix clean.

### Changed
- UI: the status-item popover is now a floating `NSPanel` (title bar + close
  button, resizable 420×500–600×900, frame autosave, Escape/⌘W close,
  NavigationStack with a natural back button from Settings).
- CLI parsing moved to a testable library (`FBDCLIParser`); command
  vocabulary and `--direct` handling are unit-tested.
- HTTP request routing (auth, method, path, body validation) moved to
  `HTTPRouter` in FBDCore with full test coverage; the app only executes
  typed routes.
- DDC: VCP reads retry (configurable `ddcReadRetries`), settle time is
  configurable (`ddcSettleMilliseconds`), capabilities replies must contain a
  complete `vcp(...)` group (single-level sub-values supported).
- App icon: generated squircle (`Sources/FBD/Resources/make_icon.swift` →
  `FBD.icns`) wired into the bundle.

## [0.1.0] — 2026-07-31 (scaffolding)

### Added
- Initial SwiftPM structure: FBDCore library, menu-bar app, `fbdcli`,
  `FBDIntents`, `CPrivateAPI`.
- Tier 1: Apple + DDC/CI brightness, contrast, volume, mute, input source,
  resolution/refresh-rate control, capabilities parsing.
- Tier 2: XDR/HDR brightness upscaling (native preset path + software
  overlay fallback), presets.
- Tier 3: virtual displays (SL path on macOS 26+, CG fallback on 13–15),
  layout protection, display groups.
- Tier 4: EDID export/override, color profiles, underscan, config protection.
- Tier 5: PiP streaming, custom OSD, Night Shift / True Tone, network TV/AVR
  control, local HTTP control API, App Intents, Sparkle auto-update wiring.
- Reverse-engineering notes for BetterDisplay internals.
