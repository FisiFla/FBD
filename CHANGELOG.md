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

### Fixed
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
