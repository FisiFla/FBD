# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

<!-- NOT an iOS target. FBD is a macOS 13.2+ app; the schema accepts only
     web / ios / android / adaptive, and `ios` is recorded as the nearest
     Apple-native value so SwiftUI guidance loads. Chosen explicitly by the
     maintainer with this caveat attached. -->

## Users

Two confirmed audiences:

- **Multi-display power users** — three or more displays, usually DDC-capable external
  panels. They switch inputs, match brightness across panels with different ceilings,
  arrange and mirror displays, and run virtual screens.
- **Laptop users with one external monitor** — the common Apple-Silicon setup: a built-in
  panel plus one screen. They want the brightness and volume keys to act on the right
  display, and the built-in panel to behave predictably.

Left undecided rather than assumed: whether "people who drive FBD from `fbdcli` / the HTTP
API / Shortcuts" is a third audience or a mode of the two above. Those surfaces exist and
are documented, but this was not confirmed either way.

## Product Purpose

A free, MIT-licensed macOS menu-bar app for display control: brightness (Apple and DDC/CI),
volume, contrast, input switching, resolution and refresh rate, virtual displays, XDR/HDR
brightness upscaling, full-screen software filters, rotation, EDID overrides, and
per-display event automation.

Success means doing what BetterDisplay does, with no Pro tier, no licence, and no telemetry,
and degrading gracefully wherever Apple locks a private API down.

## Positioning

Feature parity with a paid product, given away. The mechanism a neighbouring product could
not truthfully copy is the combination of a documented private-API ledger, per-macOS-version
degradation instead of breakage, and the same capability reachable three ways — panel, CLI,
and HTTP / Shortcuts.

## Operating Context

- Lives in the menu bar. The panel is the primary surface; Settings holds the long forms.
- Real work goes over the DDC/CI I2C bus, which is slow and stateful: writes are serialised
  per display, cooled down between commands, and brightness writes are debounced.
- Frequently driven by scripts rather than by hand: `fbdcli`, a token-gated local HTTP API on
  127.0.0.1, `fbd://` URLs, and Shortcuts actions.
- When something misbehaves, users read the masked settings dump and the private-API ledger.

## Capabilities and Constraints

- **Target: macOS 13.2+, Swift 5 mode.** Despite the Platform value above, this is macOS only.
- Apple Silicon preferred. **DDC/CI requires native arm64** — it does not work under Rosetta
  or on Intel Macs.
- Built-in display disconnect is refused on base-M3 MacBooks unless an explicit override is
  set, because the built-in panel may not come back without a reboot.
- Private APIs are declared in `Sources/CPrivateAPI/include/fbd_private_api.h`, wrapped in
  `Sources/FBDCore/PrivateAPI/`, and ledgered in `docs/PRIVATE_APIS.md`. **Never crash on a
  missing private API — degrade and say so.**
- Every persisted setting goes through `Settings.defaults`; nothing writes UserDefaults
  directly.
- The controller public API is the contract for the panel, the CLI and the tests alike.
- Layout: a SwiftPM package — `FBDCore` (all logic), `FBD` (app), `fbdcli`, `FBDIntents`,
  `FBDCLIParser`, `CPrivateAPI`.
- Gates: `swift build` / `swift test --disable-sandbox`, `make app`, `make ui-smoke`,
  `swift run fbdcli list`.

## Brand Commitments

- Name **FBD / Free Better Display**; MIT, public repository.
- An **independent implementation**, explicitly not affiliated with BetterDisplay or its
  author.
- No telemetry. Updates via Sparkle, optional.
- **BetterDisplay-derived material must never be committed.** Its reference screenshots and
  the notes taken from them live outside the repository, and its wording is paraphrased
  rather than copied — only CLI parameter names are reproduced verbatim.
- `AGENTS.md` previously described the repository as private; that was confirmed stale and
  corrected, because it bears directly on the rule above.

## Evidence on Hand

- `README.md` — the feature matrix by macOS version, requirements, and every surface.
- `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`, `docs/PRIVATE_APIS.md`, `CHANGELOG.md`.
- `docs/plans/` — the BetterDisplay and FBD feature inventories, the gap matrix with a route,
  effort, risk and test plan per row, and the parity progress log.
- `docs/plans/fbd-ui-before/` and `fbd-ui-after/` — before/after captures of FBD's own UI.
- 806 unit tests, a UI smoke harness (`make ui-smoke`) and an AX driver in `scripts/`.
- Absences future work must not fabricate: **external-monitor DDC has not been verified on
  real hardware**, and signing / notarisation are not done.

## Product Principles

1. Parity without a paywall — a capability the user needs is never behind a licence.
2. Degrade loudly, never crash — a locked-down private API switches a feature off and says so.
3. One capability, several surfaces — panel, CLI and HTTP / Shortcuts stay in step.
4. Respect the bus — DDC work is serialised, cooled down and debounced by default.
5. Measure the real UI, do not model it — a plausible mechanism is not evidence.

## Accessibility & Inclusion

- Controls are labelled for VoiceOver, and composite controls are collapsed into a single
  named element rather than exposing anonymous sub-buttons.
- Media-key interception and the UI test harness both require Accessibility permission, and
  the app says so rather than failing silently.
- Undecided: no formal accessibility standard has been set (no WCAG level, no minimum
  hit-target size). A prior review flagged sub-28pt icon-only hit targets; that is still open.
