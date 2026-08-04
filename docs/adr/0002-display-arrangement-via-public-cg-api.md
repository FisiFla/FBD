# 2. Display arrangement via the public CoreGraphics configuration API

Date: 2026-08-04

## Status

Accepted.

## Context

Feature request #3 asked for a System Settings-style drag-to-arrange display
grid. Investigation found the arrangement write is available through the
**public** API: `CGBeginDisplayConfiguration` + `CGConfigureDisplayOrigin` +
`CGCompleteDisplayConfiguration(.permanently)` — the same mechanism
`setAsMainDisplay` already used and what System Settings itself uses. No
private SkyLight symbol is needed.

## Decision

Use the public CG display-configuration API for arrangement. The grid lives
in the Settings → Per-Display tab (the "Move Display" menu already pointed
there). Snapping logic is pure (`ArrangementMath`) and unit-tested; the
drag-to-commit path is a single `DisplayController.setOrigin` call.

## Consequences

- No private-API drift risk for the core arrangement path.
- The commit is permanent (like System Settings' Apply) — the existing
  LayoutProtectionController can restore arrangements.
- Live two-display drag verification is hardware-gated (only the built-in is
  connected on the dev machine); the API path itself is verified with a
  no-op commit.
