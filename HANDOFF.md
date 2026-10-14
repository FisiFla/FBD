# HANDOFF — FBD

Last updated: 2026-10-14

## Verify conditions (before declaring any task done)

- `swift test --disable-sandbox` — all suites green (no count is recorded here on
  purpose: a number in prose goes stale every time a test is added)
- `make app` builds cleanly
- `make ui-smoke` — 5/5 (needs Accessibility; may be flaky headless)
- Live-verify any touched control path via `fbdcli` (direct + routed) and the
  HTTP API (`curl -H "X-FBD-Token: $TOKEN" 127.0.0.1:8765/api/health`)

## Current state

- v1.6.0 is the last release. `main` carries a further unreleased parity + UI pass —
  new settings seams, a `/api/config` namespace, Shortcuts actions, manual/notification
  automation, display-attached network devices, a configurable HUD, and a flattened
  menu-bar panel. See the `[Unreleased]` section of `CHANGELOG.md` for the record, and
  `docs/plans/fbd-parity-progress.md` for what was verified and what was not.
- All suites green, `make app` clean, `make ui-smoke` 5/5.
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
