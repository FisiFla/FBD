# Contributing to FBD

## Build and test

Requires macOS 13.2+ and Xcode 15+ (Swift 5.9+). Apple Silicon is needed to
exercise DDC.

```sh
make build        # debug build
make test         # swift test (uses --disable-sandbox, see the Makefile)
make app          # release app bundle -> build/FBD.app
make ui-smoke     # drives the real panel via Accessibility (needs permission)
```

CI runs a debug build, the full test suite, a release build and a strict
universal app build on every PR. Run `make test` and `swift build -c release`
before opening one.

## Layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). In short: logic lives in
`FBDCore`; `FBD` (app) and `fbdcli` (CLI) are thin; CLI parsing lives in
`FBDCLIParser` so it is unit-testable.

## Private APIs

FBD calls undocumented macOS APIs. The rules (ARCHITECTURE.md, "Layering"):

1. Declare the C symbol in `Sources/CPrivateAPI/include/fbd_private_api.h`.
2. Wrap it in `Sources/FBDCore/PrivateAPI/`: resolve at runtime, return
   nil/false (never crash) when it is missing, and `os_log`.
3. Reach private ObjC classes via `NSClassFromString` + runtime messaging, never
   by static reference.
4. Add a row to [docs/PRIVATE_APIS.md](docs/PRIVATE_APIS.md): the symbol, how it
   was verified (e.g. `dyld_info -exports`, a live call), and which macOS
   versions it was checked on. "Resolves" is not "was called"; say which.
5. Do not copy code, strings or assets from other (especially proprietary)
   apps. Behaviour may be learned from public documentation and observation.

## Pull requests

- One logical change per PR; keep diffs small and match the surrounding style.
- Code changes need tests (or a note in the PR body: `[x] no tests needed
  because: <reason>`); the `test-required` check enforces this for `Sources/`.
- Say what you verified and on what (macOS version, hardware). DDC and
  virtual-display changes in particular should state whether they ran on a
  real external display.
- Update `CHANGELOG.md` under `[Unreleased]` for user-visible changes.
- HTTP and `fbd://` surfaces stay token-gated; never loosen that for
  convenience.
- Security issues: see [SECURITY.md](SECURITY.md), not a public issue.
