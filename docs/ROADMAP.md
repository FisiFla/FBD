# FBD — Roadmap

Status: **Tier 1 complete** (compiles, 40 unit tests green, CLI smoke-tested on macOS 27).
Stop condition for Tier 1 ("DDC brightness works on an external monitor") requires
real hardware — verification steps at the bottom.

## Tier 1 — Core ✅ (this milestone)

- [x] SwiftPM scaffold: `FBDCore` library, `FBD` app, `fbdcli`, `CPrivateAPI`, tests
- [x] Menu-bar app (LSUIElement, `fbd://` scheme) with popover UI: display list, brightness sliders, DDC controls, resolution picker, settings
- [x] Display enumeration (CG public APIs) + reconfiguration callbacks + `NSScreen` names
- [x] Apple brightness via `DisplayServices` (read/set/linear/ambient-light)
- [x] DDC/CI: VCP read/write, brightness/contrast/volume/mute/input, capabilities (VCP 0xF3) + auto-config, per-display cooldown + debounce
- [x] CGS mode listing + apply (resolution picker, refresh rates), SLS rescan
- [x] Rosetta detection + graceful degradation; UserDefaults persistence
- [x] Unit tests: DDC wire format, capabilities parser (hex VCP), mode mapping, settings
- [x] Docs: README, AGENTS.md, ARCHITECTURE.md, PRIVATE_APIS.md, ROADMAP.md

## Tier 2 — XDR/HDR

- [ ] Native XDR upscaling: SkyLight preset rewrite (`SLSDisplaySetPresetData` + `PresetHostMaxPotentialEDRHeadroom`, `PresetMaxHDRLuminance`, `PresetSDRMaxNits`, …)
- [ ] Direct built-in XDR: `IOMobileFramebufferOpen` + `SetColorRemapMode` (color-table method)
- [ ] Software XDR: Metal overlay at `CGShieldingWindowLevel` (+ ScreenCaptureKit self-streaming variant)
- [ ] Combined brightness controller (hardware + software dimming + upscale in one curve)
- [ ] Dim-to-black · forced HDR mode (`SLSDisplaySetHDRModeEnabled`) · XDR preset selector · nits-normalized brightness sync
- [ ] Brightness-change notifications (DisplayServices register — needs the global registry noted in PRIVATE_APIS.md)

## Tier 3 — Virtual displays & layout

- [ ] Virtual screens: `CGVirtualDisplay*` via dlopen (macOS 13–15) + SidecarCore `SidecarDisplayManager` fallback (macOS 26+)
- [ ] HDR-capable / high-refresh virtual modes · lock/wake connect-disconnect
- [ ] Soft disconnect (`CGSConfigureDisplayEnabled`) · auto-disconnect built-in on external
- [ ] Display groups · UI-scale matching · layout protection · mirrored sets

## Tier 4 — EDID & advanced config

- [ ] EDID export/parse (pure parser + tests) · override via `IOAVServiceSetVirtualEDIDMode` (AS) / chunked I2C write (Intel)
- [ ] Flexible scaling (custom CGS modes) · color profiles (`ColorSyncDeviceSetCustomProfiles`) · underscan (`SLSDisplaySetUnderscan`) · config protection

## Tier 5 — Streaming & integrations

- [ ] PiP · local streaming · video filters (ScreenCaptureKit + Metal)
- [ ] Custom OSD (OSD.framework) · Night Shift / True Tone (CoreBrightness)
- [ ] Network TV/AVR control (LG webOS, Samsung Tizen, Philips, Yamaha) — class map in the RE report
- [ ] `fbdcli` remote/HTTP API · App Intents / Shortcuts · Sparkle updates

## Hardware verification checklist (Tier 1)

On a Mac with an external monitor (Apple Silicon):

```bash
make app && open build/FBD.app
swift run fbdcli list                          # external display shows ddc:yes
swift run fbdcli caps <external-id>            # capabilities string + parsed VCP codes
swift run fbdcli brightness <external-id> 60   # monitor brightness changes
swift run fbdcli volume <external-id> 30       # monitor volume (if supported)
swift run fbdcli set-mode <external-id> 1920x1080@60
```
Expected: brightness/volume sliders in the menu-bar popover work on the external
monitor; `ddc-test` reports success steps. Monitors with no DDC/CI support (most
TVs) will report unavailable — that is correct behavior.
