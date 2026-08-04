# HANDOFF — FBD

Last updated: 2026-08-04 (v1.4.0 released)

## Verify conditions (before declaring any task done)

- `swift test --disable-sandbox` — all suites green (288 tests as of v1.4.0)
- `make app` builds cleanly
- `make ui-smoke` — 5/5 (needs Accessibility; may be flaky headless)
- Live-verify any touched control path via `fbdcli` (direct + routed) and the
  HTTP API (`curl -H "X-FBD-Token: $TOKEN" 127.0.0.1:8765/api/health`)

## Current state

- v1.4.0 live: Per-Display control page, drag-to-arrange grid, seams from the
  architecture pass (CombinedBrightness, HTTPExecutor/DisplayControlling).
- 288 tests, ui-smoke 5/5, appcast + assets verified on every release.
- Known constraints (ADRs): one virtual display per process on macOS 27;
  virtual screens are not dimmable/resizable (ADR-0001); arrangement uses the
  public CG API (ADR-0002).

## Open (user-gated)

- Developer ID cert for signed releases + working auto-update (RELEASING.md).
- Rotation + two-display drag verification on real hardware.
- DDC-monitor checklist (the connected LG exposes no DDC bus).

## Where things live

- Glossary: `CONTEXT.md` · decisions: `docs/adr/` · private APIs:
  `docs/PRIVATE_APIS.md` · plans: `docs/plans/` · agent wiring:
  `docs/agents/`
