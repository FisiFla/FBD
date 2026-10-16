# 3. Hybrid XDR upscaling: native preset rewrite with a software-boost fallback

Date: 2026-10-16

## Status

Accepted.

## Context

XDR brightness upscaling (driving an XDR panel above its SDR ceiling) has two
implementations:

- **Native**: rewrite the display's preset via SkyLight
  (`SLSDisplaySetPresetData` + `SetActivePresetIndex`). Works on macOS 13-15.
  On macOS 27 the write is protected (verified by probe), while preset
  *switching* still works. The alternative private route, direct
  `IOMobileFramebuffer` colour-table writes, is entitlement-gated
  (`kIOReturnNotPrivileged`) and ships probe-only.
- **Software**: a Metal overlay at `CGShieldingWindowLevel` fed by
  ScreenCaptureKit with a brightness shader. It works everywhere, but needs
  the Screen Recording permission and costs GPU time.

Neither alone covers every supported macOS version, and Apple changes which
private writes are protected between releases.

## Decision

Keep both and choose at runtime, native first. `XDRNativeController`
self-tests whether preset writes take effect; `CombinedBrightness` plans the
nits curve (hardware range, then native upscaling, then software boost) and
falls back to the overlay when the native path is unavailable or a write
fails. The software fallback defaults ON so macOS 27 works out of the box;
`xdr <id> <nits>` and the combined slider share the same fallback logic
(an earlier version only had it on the slider path).

## Consequences

- One user-facing feature across OS versions, with no per-version code paths in
  the UI.
- The overlay path needs Screen Recording; without it the feature degrades to
  "off" and the UI says so.
- The self-test, not an OS-version check, is the source of truth: a future
  macOS that unprotects (or protects) the write needs no code change.
- The two paths must stay behaviourally equivalent from the caller's view;
  tests cover the planner (`XDRBoostPlanner`) rather than the pixels.
