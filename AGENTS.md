# FBD — agent guide

Free, MIT-licensed macOS menu-bar app for display control (BetterDisplay parity).
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
