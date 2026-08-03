# FBD — Roadmap

Status: **All five tiers shipped** (268 unit tests green; CI green on every
push). 40+ hardening cycles applied since the tiers: HTTP API auth +
router extraction, EDID validation, virtual-display registry, DDC retries,
parser fuzz, a11y, NSPanel glass UI, Sparkle release prep, XDR software
boost (live-verified), UI regression harness. See CHANGELOG.md for the
per-cycle record.

Remaining open items (all external/hardware-bound — see
.ai_infinite_backlog.md Pending):
- Tier 1 stop condition ("DDC brightness works on an external monitor")
  still requires real hardware.
- macOS 27 caveats (docs/PRIVATE_APIS.md): `SLSDisplaySetPresetData` is
  write-protected (native XDR upscaling self-tests and falls back to the
  software method — preset SWITCHING works, verified live); the direct
  IOMobileFramebuffer color-table method is entitlement-gated; the CG
  virtual-display path (macOS 13-15) awaits hardware verification.
- Distribution: signing + notarization + appcast host (user resources;
  RELEASING.md has the full path).

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

## Tier 2 — XDR/HDR ✅ (shipped)

- [x] Native XDR upscaling: SkyLight preset rewrite (preset enumeration, `SLSDisplaySetPresetData` + `SetActivePresetIndex`, factory restore). **macOS 13–15**: works. **macOS 27**: preset writes are write-protected (verified by probe) → runtime self-test + automatic software fallback
- [ ] Direct built-in XDR: `IOMobileFramebufferOpen` — **entitlement-gated on macOS 27** (kIOReturnNotPrivileged); wrappers ship probe-only, degrade gracefully. Open item: private entitlement or older-OS support
- [x] Software XDR: Metal overlay at `CGShieldingWindowLevel` with ScreenCaptureKit capture + brightness shader (the working upscale method on macOS 27; live-verified with luma measurements: 0.118 -> 0.185 boost on, exact return off, zero leaked windows)
- [x] Combined brightness controller: nits-based curve (hardware 0…100 % → native XDR → software boost), maxNits/hardwareMaxNits helpers
- [x] Dim-to-black overlay · forced HDR mode (`SLSDisplaySetHDRModeEnabled`) · XDR preset selector (live-verified preset switching) · brightness-change notifications (DisplayServices registry, lunar pattern)
- [x] fbdcli: `xdr`, `preset`, `hdr` commands · menu-bar UI: XDR/HDR section (upscale toggle, nits slider, preset picker, HDR toggle) + settings toggles

## Tier 3 — Virtual displays & layout ✅ (shipped)

- [x] Virtual screens: `SLVirtualDisplay*` (SkyLight) on macOS 26+ — live-verified
      create/destroy/label via app + CLI; `CGVirtualDisplay*` via dlopen on
      macOS 13–15 (untestable here — awaits 13–15 hardware)
- [x] HDR-capable / high-refresh virtual modes · lock/wake connect-disconnect · auto-connect
- [x] Soft disconnect (`CGSConfigureDisplayEnabled`) · auto-disconnect built-in on external
- [x] Display groups (cross-process shared state) · layout protection · mirrored sets

## Tier 4 — EDID & advanced config ✅ (shipped)

- [x] EDID export/parse (pure parser + 6 tests; checksum bug caught by tests) · override via `IOAVServiceSetVirtualEDIDMode` (AS) / Intel chunked I2C write documented as unsupported (needs framebuffer I2C)
- [x] Color profiles (`ColorSyncDeviceSetCustomProfiles`; `CGDisplayCreateUUIDFromDisplayID` is public in ColorSyncDevice.h) · underscan (`SLSDisplaySetUnderscan`, user-initiated) · config protection (mode+brightness+preset re-apply on reconnect)
- [ ] Flexible scaling — realized via virtual screens + mirroring (Tier 3); custom CGS mode creation needs the private mode-list API (future)
- [ ] Built-in panel EDID: not exposed by macOS 27 (no IODisplayConnect service, no IODisplayEDID key) — export reports unavailable honestly

## Tier 5 — Streaming & integrations ✅ (shipped)

- [x] PiP with video filters (ScreenCaptureKit + Metal: brightness/contrast/saturation shader, draggable floating window)
- [x] Custom OSD (SwiftUI HUD following brightness changes) · Night Shift (CBBlueLightClient — LIVE-VERIFIED: read/set 0–100 %) · True Tone (CBTrueToneClient, unavailable on macOS 26.3+ per lunar)
- [x] Network TV/AVR: LG webOS (WebSocket ssap://), Samsung Tizen (WebSocket + pairing token), Philips (HTTP jointSPACE), Yamaha (YXC XML)
- [x] Local HTTP API (127.0.0.1 only) — LIVE-VERIFIED: GET /api/displays, POST brightness {"ok":true} round-trip through the app
- [x] App Intents: Set/GetBrightness, SetVolume, ListDisplays, EnableXDRUpscaling (FBDIntents target, package wired in the app)
- [x] Sparkle updates (2.9.5 via SPM; SUFeedURL + Ed25519 keys configured — requires a signed release + appcast host decision)
- [x] CLI: http/pip/osd/nightshift/truetone/tv commands; Settings: Integrations section
- [x] fbdcli routes every control command through the app's local HTTP API
      when the app is running (single-driver; --direct forces local)

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
