# FBD ⇄ BetterDisplay parity — progress log

Plan: `~/Downloads/FBD-betterdisplay-parity-plan.md`
Working branch: `feat/betterdisplay-parity`
Base commit: **`256ec2f`** (v1.6.0 + 2 post-release commits; in sync with `origin/main` on 2026-10-14)

Reference app: `/Applications/BetterDisplay.app` — **5.1.1, build 53784**, arm64. Treated as a
read-only oracle; not patched, re-signed or modified in this task.

---

## Phase 0 — orient, baseline, agree scope

### Baseline (recorded before touching any code)

| Gate | Command | Result |
|---|---|---|
| Build | `swift build --disable-sandbox` | ✅ `Build complete! (8,27 secs)` — 0 warnings |
| Tests | `swift test --disable-sandbox` | ✅ **exit 0** — **477 tests, 0 failures** |
| App bundle | `make app` | ✅ exit 0 → `build/FBD.app` (Mach-O universal x86_64+arm64, ad-hoc signed) |

**Real test count: 477** — `FBDCoreTests` 341 + `FBDCLIParserTests` 136. This matches the
figure in `README.md`/`AGENTS.md` exactly, so the drift the plan warned about has already been
corrected upstream. (`grep -rc 'func test' Tests/` counts 478 — one helper is named
`test`-prefixed but is not a test case; the executed count is the honest number.)

**Compiler warnings in the test target (2 distinct, reported twice each):**
`Tests/FBDCoreTests/HTTPServerTests.swift:307` — *immutable value `round` was never used*;
`Tests/FBDCoreTests/HTTPServerTests.swift:402` — *variable `boundPort` was written to, but never read*.

**A note on flakiness (important for later phases).** The *first* baseline run, executed
concurrently with other work, reported **4 assertion failures in 2 test cases**:
`HTTPServerTests.testIdleConnectionIsDropped` and
`HTTPServerTests.testOPTIONSGetsCORSHeadersWithoutHandlerInvocation` — both raw-`NWConnection`
socket tests with a 5 s `expectation` timeout. Re-running the suite in isolation (nothing else
running) gives **exit 0, 477/477 green**, and `--filter HTTPServerTests` alone also passes.
So those two are load-sensitive timing tests, **not** a pre-existing functional break. Anything
I claim as "green" later is measured on an otherwise-idle machine.

### Environment facts confirmed

- `swift --version` → Apple Swift 6.4 (swiftlang-6.4.0.34.1), target `arm64-apple-macosx27.0.0`.
- BetterDisplay's CLI oracle is **live and usable** from this session — no lldb/hooking needed
  for behaviour: `get -pip` → `off`, `get -brightness` → `0.681`.
- Accessibility (AX) reads of BetterDisplay work from this session, so the Settings-window
  walk-through is drivable directly.
- Prior RE tooling exists (`/tmp/bd_lldb/`, `~/Downloads/bd_poc/`) and is fresh (same day,
  same 5.1.1 install). The dumps there are used as **cross-checks**; every load-bearing claim
  in the inventory is re-verified live.

### Tooling written for this task (scratch, not committed)

- `$TMPDIR/bd.sh` — `run_bd <seconds> <args…>`: invoke the BetterDisplay CLI with a hard
  timeout. **Necessary**: some operations (e.g. a bare `--help`) block indefinitely, and a
  hung CLI call otherwise eats the whole command budget.
- `$TMPDIR/bd_help.txt` — the full captured CLI integration help
  (`"$BD" help`). This is the primary, machine-readable feature oracle for Phase 1: it
  enumerates every operation and every parameter, with a one-line description and a
  device-specific / Pro classification for each.

---

## Phase 0 (cont.) — FBD's current UI surfaces

Screenshots + AX trees committed under **`docs/plans/fbd-ui-before/`** (FBD's own UI, so no
licensing concern — these are the "before" half of the Phase 5 pair).

| # | Surface | File | Panel size |
|---|---|---|---|
| 01 | Menu-bar panel (main page) | `01-menu-bar-panel.png` / `.ax.txt` | 460 × 650 |
| 02 | Settings → Overview | `02-settings-overview.png` / `.ax.txt` | 460 × 860 |
| 03 | Settings → Per-Display | `03-settings-per-display.png` / `.ax.txt` | 460 × 860 |

**How to drive it (reproducible):** left-click the status item toggles the panel; `open
"fbd://open"` goes straight to Settings; Escape closes. `scripts/UIDriver.swift` supplies
`click` / `key` / `panel-state` / `ax-frame` / `status-sweep`; AX trees via
`/tmp/bd_lldb/ax2 <pid> dump`; window-scoped screenshots via `screencapture -l<CGWindowNumber>`.

### Current information architecture (measured, not from docs)

**Status item** — left-click: toggle panel. Right-click: `Show FBD` · `Settings…` (⌘,) ·
`Check for Updates…` (⌘u) · —— · `Quit FBD` (⌘q). Tooltip and AX label `FBD — display control`.

**Main panel** (header: title `FBD` / `Free Better Display`, a `Settings` gear, `Close FBD panel`).
Body, per display card: display name, `Built-in`/`External` tag, capability tag (`XDR`),
`More` menu-button, `Disable display`, the current mode line (`1728 × 1117 · 120.00 Hz`),
brightness slider (`Brightness for …`) with `%` **and** `nits` read-outs, then collapsible
sections: **Filters**, a DDC-availability notice, **Resolutions**, **XDR / HDR**,
a **Color Profile** popup and `Restore default`, then **Virtual Screens** and **Display Groups**.
Footer buttons: `Virtual Screens`, `Groups`, `PiP`, `Check for Updates`, `Quit FBD`.

**Settings** (header: `Back to FBD`, title, `Close FBD panel`; a two-item segmented
`Tab` radio group: **Overview** | **Per-Display**).
Overview sections, in order: **General**, **DDC / CI**, **XDR / HDR**, **Experimental**,
**Virtual Displays & Layout**, **EDID & Protection**, **Integrations**, **Automation**, **About**.
Per-Display is a long display card carrying the same brightness / filters / resolutions /
XDR controls as the main panel's card.

### The `make ui-smoke` gate — root cause of a red first run

First `make ui-smoke` run: **1/5**. Cause: the script's first `swift run --disable-sandbox
fbdcli …` call compiles `fbdcli` from cold, which takes far longer than the ~2 s the script
allows, and the `.transient` non-activating panel is dismissed while it blocks (the app sets
`panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]`).
Every AX lookup after that sees no window.

**Once `fbdcli` is warm the same gate is 5/5 green** (verified). So the gate is sound; the
fix for CI/dev use is to pre-build `fbdcli` (or reuse `build/FBD.app`'s binary), not to touch
the assertions. Recorded here so later phases don't misread it as a regression.

**Trap worth repeating:** `make ui-smoke` only launches FBD if no instance is already running
(`pgrep -f 'FBD.app/Contents/MacOS/FBD'`). After `make app`, an app launched from an *earlier*
binary keeps matching, so the gate silently tests the old build. Always `pkill` before re-running
it against a rebuild — this bit me once and produced a green run for the wrong binary.

---

## Phase 4 — the agreed gaps

Scope agreed at the Phase 3 gate: the **recommended top-8**.

### How it was built, and what that cost

The eight seams are largely independent pure-logic units, so they were **delegated to a
7-subagent fleet** to build in parallel. That produced ~2,500 lines of real code — but the host
**strips `bash` from subagents that declare `write_paths`**, so **not one of them could compile or
test its work.** They verified with the Swift language server and correctly refused to invent test
totals. The eight sandboxes were then integrated by hand and compiled: **4 call-site/type errors
and 3 genuinely wrong tests** were found and fixed. The lesson is recorded rather than glossed:
for this repo, delegation is worth it for *volume*, but the integrator must budget for a real
compile-and-fix pass, and no delegated test count can be trusted before it is run.

Three failures were real behavioural disputes, not typos:

1. `LockDimControllerTests.testDisabledPolicyIgnoresLock` passed an **enabled** policy to a test
   named "disabled". The test was wrong, not the state machine.
2. `BrightnessPreferencesTests.testClampInfiniteNitsBecomeUpperBound` contradicted its own sibling
   `testClampNaNNitsFallBackToDefaults` on the same helper. `clamp()` documents "a non-finite input
   falls back to `fallback`", and the NaN test encodes exactly that. The implementation was kept
   (an infinity is as much a sign of a corrupt blob as a NaN, and a sane default beats a
   40 000-nit ceiling) and the outlier test was corrected.
3. `ConnectionManagementTests` had two call sites with swapped argument labels.

One **dead-UI risk** was caught by reading rather than by tests: `LockDimController` was never
started by `AppCore`, so the new toggle would have done nothing. It is now wired into the launch
sequence (a disabled policy is a no-op, so starting it unconditionally is safe). This is exactly
the class of bug ADR-0001 warns about.

### Delivered

| # | gap | seam | tests |
|---|---|---|---|
| 1 | Per-property configuration protection | `ProtectedProperties` + `ConfigProtectionController` | `ProtectedPropertiesTests` 14, `ConfigProtectionControllerTests` 5 → 13 |
| 2 | Group synchronisation | `GroupSyncPlanner` + `DisplayGroupsController` | `GroupSyncPolicyTests` 33 |
| 3 | Group activation policy | `GroupActivationPolicy` | (same suite) |
| 4 | Resolution favourites | `ModeFavourites` + `ResolutionController` | `ModeFavouritesTests` 28 |
| 5 | Mode-list breadth + refresh list | `ModeFilterOptions` | `ModeBreadthTests` 31 |
| 6 | Brightness model (policies, nits ranges, curve) | `BrightnessPreferences` + `BrightnessCurve` | `BrightnessPreferencesTests` 47 |
| 7 | Startup safe mode | `SafeMode` + `AppCore` | `SafeModeTests` 13 |
| 8 | Lock dim | `LockDimController` | `LockDimControllerTests` 27 |
| 9 | Connection management | `ConnectionPlanner` + `DisconnectController` | `ConnectionManagementTests` 28, `DisconnectControllerTests` 6 |
| 10 | Keyboard control target | `KeyboardControlTarget` + `MediaKeyRouter` | `KeyboardControlTargetTests` 32 |

**FBDCoreTests: 363 → 629. FBDCLIParserTests: 136. Total 765 tests, 0 failures.**
Build adds **zero warnings**. `make ui-smoke` 5/5.

### Surfaces

- **Settings UI** for every feature above (see Phase 5).
- **`fbdcli config`** — `show`, `protect <id> [properties]`, `favourite <id> list|save|apply [slot]`,
  `lockdim [on|off]`, `lockdim-target [0-100]`, `keytarget [mouse|focused|all|audio]`,
  `group-policy <group> [policy]`, `group-enabled <group> [on|off]`. Runs locally against the shared
  defaults (settings, not hardware writes), so there is no second write path and no bus contention.
- Round-trips verified live, including the refusal paths — e.g. `config protect 1` reports the
  backwards-compatible default `resolution,preset,brightness`, and its `available` set correctly
  omits `hdrMode` on a display that does not report it.

### Not delivered in Phase 4

- **HTTP API and Shortcuts intents** were not extended to the new surfaces.
- No dedicated CLI for **group sync-apply** or **connection management** (both are in the app UI).
- The brightness-model values are settable only through the settings blob (UI), not individually
  from the CLI beyond `config show`.

### Ledger

**No new private API was introduced.** Every new seam is built on public APIs plus symbols already
in `docs/PRIVATE_APIS.md`, so the ledger is deliberately unchanged.

---

## Phase 5 — UI/IA revamp

### Delivered

- **Settings is a sidebar**, not a two-tab form: `Displays` · `Groups` · `Application` · `Menu` ·
  `Keyboard` · `About`, with long scrolling pages. The panel grows to **760 × 860** for it
  (`StatusItemController.settingsSize`), and `panelState()` still classifies it correctly because
  the height threshold is unchanged.
- **New controls land in the right places**: Displays carries the arrangement grid, the bulk
  connection actions, and per-display configuration-protection and resolution-favourite cards;
  Groups carries the enable flag and activation policy; Application carries the brightness model,
  lock dim, integrations and the safe-mode explanation; Keyboard carries the media-key options and
  the control target.
- **Design system extended** rather than styles inlined: `Sources/FBD/DesignSystem/FDBSettingsRow.swift`
  adds `SettingsRow`, `SettingsSliderRow` and reuses the existing `FBDTheme` tokens.
- **Panel menu**: the per-display `More` menu gained a **Resolution Favourites** submenu (five
  slots, each showing its recorded mode). The rest of the menu already had BetterDisplay's grouped
  submenu structure.
- **Evidence**: `docs/plans/fbd-ui-after/` (7 screenshots + AX trees) with
  `docs/plans/fbd-ui-after/PANE-MAPPING.md` mapping each BetterDisplay pane to its FBD screen and
  stating plainly where FBD does *not* mirror it.

### Not delivered in Phase 5

- **The menu-bar quick menu was not restructured** into BetterDisplay's flat row list. FBD's panel
  is a per-display card with collapsible sections; converting it to ~20 flat rows with per-section
  menu levels is a design change in its own right and was not attempted. The grouped *submenus* it
  does have were kept and extended.
- No `Pro` counterpart page (FBD has no Pro tier — by design).
- Accessibility was preserved by construction (every new control is a labelled SwiftUI control;
  the sidebar buttons carry explicit accessibility labels and a selection trait) but has not had a
  separate a11y review pass the way earlier UI work did.

---

## Phase 6 — verification

| Gate | Command | Result |
|---|---|---|
| Build | `swift build --disable-sandbox` | ✅ exit 0, **0 warnings, 0 errors** |
| Tests | `swift test --disable-sandbox` | ✅ exit 0, **765 tests, 0 failures** |
| App bundle | `make app` | ✅ exit 0 → `build/FBD.app` |
| UI smoke | `make ui-smoke` | ✅ **5/5** against the rebuilt app |
| CLI | `swift run fbdcli list` / `fbdcli config …` | ✅ runs; every `config` round-trip verified |
| Ledger | `docs/PRIVATE_APIS.md` | ✅ no new private API, so deliberately unchanged |
| Changelog | `CHANGELOG.md` | ✅ `[Unreleased]` section with verification and exclusions |

Nothing was committed and nothing was pushed; all work is in the working tree on the branch
`feat/betterdisplay-parity`, ready for review.


