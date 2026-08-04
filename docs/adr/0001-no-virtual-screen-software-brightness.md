# 1. No software-brightness/resolution sliders on virtual screens

Date: 2026-08-04

## Status

Accepted.

## Context

Feature request #1 asked for a Software Brightness slider and a Resolution
slider on each virtual-screen card (BetterDisplay parity). Verified live on
macOS 27 (2026-08-04): an SLVirtualDisplay created by FBD does **not** appear
in `CGGetActiveDisplayList` for the app's process, so:

- FBD cannot enumerate it as a controllable `Display`;
- the software-brightness overlay (ScreenCaptureKit capture keyed by CG
  display ID) has nothing to capture;
- live resolution change is not supported by SLVirtualDisplay — the only
  mechanism would be destroy + recreate, which is destructive and macOS 27
  allows only one virtual display per process (see the second-display crash
  fix).

## Decision

Do not build software-brightness or live-resolution controls for virtual
screens. Virtual screens stay creation-form-configured (name, size, Hz, HDR).
The arrangement grid (ADR-0002) is the replacement feature for this slot.

## Consequences

- No dead UI: every control on a virtual card can work.
- A future port that owns the virtual framebuffers (a custom virtual display
  implementation) may revisit this.
