# FBD — repo index

- `AGENTS.md` — project instructions + build/test commands (read first)
- `CONTEXT.md` — domain glossary
- `README.md` / `CHANGELOG.md` / `RELEASING.md` — usage, history, release flow
- `HANDOFF.md` — current state + verify conditions
- `SECURITY.md` — vulnerability reporting
- `docs/` — ADRs (`adr/`), private-API ledger (`PRIVATE_APIS.md`),
  plans (`plans/`), agent wiring (`agents/`), architecture (`ARCHITECTURE.md`)
- `Sources/` — `FBD` (SwiftUI app), `FBDCore` (controllers, seams,
  HTTP executor), `fbdcli` + `fbdcli-parser`, `FBDIntents` (Shortcuts),
  `CPrivateAPI` (C bridge for private symbols)
- `Tests/FBDCoreTests/` — the unit suite (`swift test --disable-sandbox`)
- `scripts/` — `ui-smoke.sh` + `UIDriver.swift` (live UI regression)
- `.github/workflows/` — CI, release, test-required gate
