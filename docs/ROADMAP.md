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

## Verified on real hardware

A second Apple Silicon Mac with an external monitor, 2026-10-28: DDC/CI against that
monitor, its EDID, the below-floor brightness blend below its own hardware floor, and HiDPI
smooth scaling through the privileged install and the display re-enumeration. One monitor,
one run — that is the scope of the claim. The evidence is in
[PRIVATE_APIS.md](PRIVATE_APIS.md).

## Not proven on hardware

- **Legacy `CGVirtualDisplay` virtual displays** on macOS 13–15 (the macOS
  26+ `SLVirtualDisplay` path is live-verified).
- **Screen rotation on an external display** — the built-in returns 1001 on
  macOS 27.
- **The three display-connection behaviours** (remembered disconnects, the
  docked built-in display, the ambient sync) — they need a display that can be
  unplugged and docked.
- **A second DDC monitor.** The transport is verified against one; a display
  with unusual reply timing or a wrong channel pairing is still untested, and
  `scripts/ddc-smoke.sh` remains the harness for that.
- **DDC across three displays at once** — the per-display queues shipped
  (#17), but the simultaneous-write timing that made them necessary has never
  been measured: the verification above used one monitor.
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
2. A second DDC display through `scripts/ddc-smoke.sh`. The transport has run
   against one monitor; the audit's residual risks — reply timing, a wrong
   channel pairing, a maximum of `0` — only show up on a display that misbehaves.
3. The privileged helper for system-level display overrides, which needs the
   signed release first (issue #23).
