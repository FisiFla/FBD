# Changelog

All notable changes to FBD. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: semver; 0.x until the first signed/notarized release.

## [Unreleased]

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
