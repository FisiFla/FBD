# FBD — Roadmap

Short and current: what FBD does today, what is not yet proven, and what is
next. The per-release record is in [CHANGELOG.md](../CHANGELOG.md).

## Shipped

- The menu-bar panel, the Settings window, `fbdcli`, a local HTTP API and
  Shortcuts actions — all driving the same controller.
- Apple brightness, resolution and refresh rate, Night Shift, Dark Mode, True
  Tone, virtual displays (`SLVirtualDisplay` on macOS 26+), HDR mode, the XDR
  software boost, full-screen filters, picture-in-picture and streaming, the
  on-screen HUD, display groups, per-display automation, network TV/AVR
  control, EDID export and saved devices.
- English, 简体中文 and 繁體中文 throughout the panel and the Settings pages.

## Not proven on hardware

- **DDC/CI on an external monitor** (issue #7) — needs an Apple Silicon Mac
  with a DDC-capable display. The transport is audited component by component
  in [ddc-equivalence.md](ddc-equivalence.md); the hardware leg is open, and
  `scripts/ddc-smoke.sh` is the harness for it.
- **Legacy `CGVirtualDisplay` virtual displays** on macOS 13–15 (the macOS
  26+ `SLVirtualDisplay` path is live-verified).
- **Screen rotation on an external display** — the built-in returns 1001 on
  macOS 27.
- **The below-floor brightness blend** against a real monitor with a high
  brightness floor, and the three display-connection behaviours (remembered
  disconnects, the docked built-in display, the ambient sync) — they need an
  external display attached.
- **The privileged HiDPI write** to `/Library/Displays` and the display
  re-enumeration that follows it.
- **Signed, notarised distribution** — blocked on a Developer ID certificate
  (issue #6). Until then the release asset is `FBD-unsigned.zip`, Gatekeeper
  asks the user to open it by hand, and the appcast cannot be regenerated.

## macOS caveats

- `SLSDisplaySetPresetData` is write-protected on macOS 26 and later, so the
  native XDR upscaling self-tests and falls back to the software boost.
  Preset *switching* works and is live-verified.
- The direct `IOMobileFramebuffer` colour-table method is entitlement-gated.
- The built-in panel exposes no EDID on macOS 27; FBD reports that honestly
  rather than inventing a value.
- Disconnecting the built-in display is refused on base-M3 MacBooks, where the
  panel may not come back without a reboot.

## Next

1. A Developer ID certificate, so releases are signed and notarised and the
   appcast can be regenerated (issue #6).
2. Hardware verification on an Apple Silicon Mac with an external monitor
   (issue #7).
3. The privileged helper for system-level display overrides, which needs the
   signed release first (issue #23).
