# FBD — AGENTS.md

Free, MIT-licensed macOS menu-bar app for display control (BetterDisplay parity).

> **When to read this file:** every task in this repo. If you're working in
> this repo, read this file, then `CONTEXT.md` and `docs/PRIVATE_APIS.md`
> before touching code. It is short and is the
> only project-level instructions file; `CONTEXT.md` carries the domain
> glossary, `docs/agents/*.md` the engineering-skill wiring, and
> `docs/PRIVATE_APIS.md` the private-API ledger.
Repo: https://github.com/FisiFla/FBD (private).

## Commands

- `swift build` — build debug (FBDCore lib, FBD app, fbdcli)
- `swift test` — unit tests
- `make app` — release bundle at `build/FBD.app` (universal; falls back to native)
- `make ui-smoke` — drives the real panel via Accessibility/CGEvent (needs a11y permission)
- `swift run fbdcli list` — CLI smoke test

## Layout

- `Sources/CPrivateAPI/` — C target: private-framework declarations (verified signatures) + CGS struct
- `Sources/FBDCore/` — all logic: `Models/`, `PrivateAPI/` (typed Swift wrappers), `Controllers/`, `Settings.swift`
- `Sources/FBD/` — app target: `main.swift`, `AppDelegate`, menu bar UI, views
- `Sources/fbdcli/` — CLI target (commands + HTTP routing)
- `Sources/fbdcli-parser/` — FBDCLIParser library (commands, validators, HTTP plans)
- `scripts/` — UIDriver + ui-smoke regression harness
- `Tests/FBDCoreTests/` — unit tests

## Rules

- Private C functions: declare in `fbd_private_api.h`, wrap in `PrivateAPI/` (throws, `os_log`, graceful degradation).
- Private ObjC classes: `NSClassFromString` + runtime messaging only, never static link.
- DDC requires native arm64 — guard with `IOAVServiceAPI.isAppleSilicon`; warn under Rosetta.
- Never crash on missing private APIs — degrade with a clear message.
- Controller public API is the contract for UI/CLI/tests — changing signatures requires updating all callers.
- Docs: `docs/PRIVATE_APIS.md` tracks every private API used and its verification source.

## Agent skills

### Issue tracker

Issues and PRDs for this repo live as GitHub issues; the engineering skills
use the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles map 1:1 to the label names: `needs-triage`,
`needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See
`docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` at the repo root plus `docs/adr/` for
decisions. Read both before exploring. See `docs/agents/domain.md`.

## Build & test

- Build: `make app` (universal, produces `build/FBD.app`) or `swift build --disable-sandbox` (debug)
- Test: `swift test --disable-sandbox` (288 unit tests) or `make test`
- UI smoke: `make ui-smoke` (drives the real panel; needs Accessibility permission)
- Release: `make bump-version VERSION=x.y.z` then the flow in `RELEASING.md`

## Rules

- Don't touch private APIs except through `Sources/FBDCore/PrivateAPI` + the
  C header — never call private symbols inline.
- Don't add a control path (brightness, XDR, filter, virtual, arrangement)
  without routing it through its controller seam (`DisplayControlling`,
  `CombinedBrightness`, `VirtualScreenController`) — the seams are what make
  the behavior testable.
- Don't leave a persisted setting with two write paths — everything goes
  through `Settings.defaults` (the suite-aware accessor).
- Don't change a controller's public API without updating every caller
  (UI, CLI, HTTP executor, tests) — the API is the contract.
- Because macOS releases move private frameworks: every private API entry
  must stay in `docs/PRIVATE_APIS.md` with its verification status.
