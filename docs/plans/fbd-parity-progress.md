# FBD ⇄ BetterDisplay parity — progress log

Working branch: `feat/betterdisplay-parity`
Base commit: **`256ec2f`** (v1.6.0 + 2 post-release commits; in sync with `origin/main` on 2026-10-14)

Reference app: BetterDisplay 5.1.1 (build 53784), arm64, compared by its public, observable
behaviour only.

---

## Phase 0 — orient, baseline, agree scope

### Baseline (recorded before touching any code)

| Gate | Command | Result |
|---|---|---|
| Build | `swift build --disable-sandbox` | ✅ `Build complete! (8,27 secs)` — 0 warnings |
| Tests | `swift test --disable-sandbox` | ✅ **exit 0**, 0 failures |
| App bundle | `make app` | ✅ exit 0 → `build/FBD.app` (Mach-O universal x86_64+arm64, ad-hoc signed) |

The executed test count is the honest number (a `grep` for `func test` over-counts);
test totals recorded in this log are point-in-time snapshots and go stale — run
`swift test` for the current figure.

**Compiler warnings in the test target (2 distinct, reported twice each):**
`Tests/FBDCoreTests/HTTPServerTests.swift:307` — *immutable value `round` was never used*;
`Tests/FBDCoreTests/HTTPServerTests.swift:402` — *variable `boundPort` was written to, but never read*.

**A note on flakiness (important for later phases).** The *first* baseline run, executed
concurrently with other work, reported **4 assertion failures in 2 test cases**:
`HTTPServerTests.testIdleConnectionIsDropped` and
`HTTPServerTests.testOPTIONSGetsCORSHeadersWithoutHandlerInvocation` — both raw-`NWConnection`
socket tests with a 5 s `expectation` timeout. Re-running the suite in isolation (nothing else
running) gives **exit 0, all green**, and `--filter HTTPServerTests` alone also passes.
So those two are load-sensitive timing tests, **not** a pre-existing functional break. Anything
I claim as "green" later is measured on an otherwise-idle machine.

### Environment facts confirmed

- `swift --version` → Apple Swift 6.4 (swiftlang-6.4.0.34.1), target `arm64-apple-macosx27.0.0`.
- BetterDisplay's documented CLI and visible Settings UI were used to compare public
  behaviour. No binary analysis of BetterDisplay is part of this repository.

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

Screenshots + AX trees captured locally for this phase (FBD's own UI, so no licensing concern —
the "before" half of the Phase 5 pair). They are not committed; the names below are the captures.

| # | Surface | File | Panel size |
|---|---|---|---|
| 01 | Menu-bar panel (main page) | `01-menu-bar-panel.png` / `.ax.txt` | 460 × 650 |
| 02 | Settings → Overview | `02-settings-overview.png` / `.ax.txt` | 460 × 860 |
| 03 | Settings → Per-Display | `03-settings-per-display.png` / `.ax.txt` | 460 × 860 |

**How to drive it (reproducible):** left-click the status item toggles the panel; `open
"fbd://open"` goes straight to Settings; Escape closes. `scripts/UIDriver.swift` supplies
`click` / `key` / `panel-state` / `ax-frame` / `status-sweep`; AX trees via
an Accessibility-tree dump; window-scoped screenshots via `screencapture -l<CGWindowNumber>`.

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

**Suite grew substantially this phase; 0 failures.**
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
- **Evidence**: the Phase 5 after-captures (7 screenshots + AX trees) and their pane-mapping
  notes, held locally, mapping each BetterDisplay pane to its FBD screen and stating plainly
  where FBD does *not* mirror it.

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
| Tests | `swift test --disable-sandbox` | ✅ exit 0, 0 failures |
| App bundle | `make app` | ✅ exit 0 → `build/FBD.app` |
| UI smoke | `make ui-smoke` | ✅ **5/5** against the rebuilt app |
| CLI | `swift run fbdcli list` / `fbdcli config …` | ✅ runs; every `config` round-trip verified |
| Ledger | `docs/PRIVATE_APIS.md` | ✅ no new private API, so deliberately unchanged |
| Changelog | `CHANGELOG.md` | ✅ `[Unreleased]` section with verification and exclusions |

Nothing was committed and nothing was pushed; all work is in the working tree on the branch
`feat/betterdisplay-parity`, ready for review.

---

## Follow-up items (continuing past the plan's phases)

The user asked for the remaining backlog to continue after the plan's list closed. Each item is a
separate commit on the same branch.

- **`fbdcli config` completed** (`cb3ae63`) — `group-sync <group> <0-100>`,
  `connections connect-all|disconnect-all-but-main|swap-identical`, and
  `model <key> [value]`. The last also makes each brightness-model value settable on its own rather
  than only as a whole blob. Every path validates and refuses bad input.
- **Saved network-device registry** — FBD had four working network controllers (LG webOS, Samsung,
  Philips, Yamaha) but nothing remembered a device, and reaching one meant repeating brand + host
  every time. `NetworkDeviceRegistry` stores name/brand/host[/Yamaha zone] through the same settings
  write path, `config device list|add|remove` manages them, and `fbdcli tv <name> …` addresses one
  by name. Host validation is fail-closed: a scheme, path, credentials, query or `:port` suffix is
  refused when the device is added, because the host is interpolated into a request URL by the
  controllers.

  Two things were found by testing rather than by design: a bare IPv6 literal (`fe80::1`) was
  rejected because its `:1` looked like a port suffix, and `[fe80::1]:3000` was *accepted* when it
  should not have been. Both are fixed and covered.

  `NetworkDeviceRegistryTests` (20 cases) covers validation, dedup, the size bound and corrupt-blob
  handling. 0 failures.
- **Fixed: the keyboard control target was a dead setting.** `Settings.keyboardControlTarget` was
  written by the Settings UI and by `fbdcli config keytarget`, and displayed back, but nothing ever
  read it: `HotkeyController.handleMediaKey` still called the old `MediaKeyRouter.decide(...)` with a
  display chosen purely from the pointer position. The new `MediaKeyRouter.resolve(...)` seam existed
  and was unit-tested, but no live path called it — so the setting changed nothing while appearing to
  work. This is the same failure mode as the lock-dim controller that was never started; both were
  found by reading the call sites rather than by a failing test, which is the lesson worth keeping.

  `handleMediaKey` now resolves the target screen through `Settings.keyboardControlTarget` and acts on
  every screen that resolves (`.allSuitableScreens` is genuinely multi-screen). `.mouseScreen` — the
  default — reproduces the previous behaviour exactly, and the old fallback chain is retained so a
  press is never silently swallowed. `focusedDisplayID` is derived from `NSScreen.main` by frame.

  Still not wired: the HTTP API has no route for these surfaces.
- **Audited every new setting for a live consumer.** After two dead-UI bugs found by reading rather than by
  a failing test, each new setting was traced to its live call site rather than to its test. Result —
  all live: `lockDimEnabled`/`lockDimTargetPercent` (`lockDim.start()` at AppCore:72, and
  `LockDimStateMachine` re-reads the policy on every event, so a settings write takes effect at once);
  `BrightnessPreferences` (`CombinedBrightness.swift:76`, `injectedPreferences ?? Settings.brightnessPreferences`);
  `ProtectedProperties` (`ConfigProtectionController.restoreIfNeeded` gates every restore step on
  `applicableProperties(for:)`, so the per-property selection is genuinely consulted);
  `SafeMode` (the AppCore gate); the group enabled flag and activation policy (read by `syncPlan`);
  `ModeFavourites` (the per-display menu and the CLI); `NetworkDeviceRegistry` (the CLI).
- **Fixed: group sync could be configured in the UI but never triggered from it.** The audit's one real
  finding. The Settings page exposed the enabled flag and the activation policy, and the Mirror/Unmirror
  buttons, but nothing in the app could perform a synchronised apply — only `fbdcli config group-sync`.
  A user could set group sync up entirely in the UI and have no way to use it there.

  `DisplayGroupsController.syncValue(inGroup:connectedIDs:currentBrightness:)` is the pure half: it returns
  the first *connected* member's brightness together with the display that value came from, so the plan's
  luminance matching converts from the right panel rather than from whichever member sorts first. It
  returns nil rather than guessing when the group is unknown or disabled, nothing is connected, or the
  value cannot be read. The Settings page's new **Sync now** button reads brightness once up front and
  hands the controller a plain dictionary lookup, so no DDC traffic happens off a button press.
  `DisplayGroupsSyncValueTests` (7 cases) covers all six nil paths and the source-selection rule.
  FBDCoreTests 656.
- **Fixed: the UI smoke gate could pass without testing anything — and it was not an app bug.** `make ui-smoke`
  began failing 4/5 deterministically and read exactly like a regression from the Phase 5 Settings rewrite. It
  was not. The gate passed 5/5 with `--status-x`, and no app code was at fault; the defect was entirely in
  the gate's step 1.

  `statusSweep` starts its sweep at x=1710 and returns as soon as *any* panel is open. So when a previous run
  left a panel open, the sweep reported `FOUND_X=1710` — a click that never touched the status item (which
  sits at 1534). Step 1 then reported **PASS** while the panel was on an unknown page, and every later
  accessibility lookup failed in a way that looks precisely like the app having lost its controls. The script
  pressed Escape first but never verified the panel had actually closed, so nothing caught it.

  Step 1 now starts from a *verified* closed panel — Escape, then the panel's own `Close FBD panel` button as
  a fallback — and refuses to continue rather than test a stale panel. Verified from all three states that
  mattered: a clean running app, a panel deliberately left open on Settings (the state that produced 4/5), and
  a fresh launch with the app killed beforehand. **5/5 in each.**

  Two things I asserted while diagnosing this were wrong, recorded here so nobody repeats them:

  - `panelState()` keys on panel **height** (`height >= 800 ? "settings" : "main"`), not the 460 width. The
    760×860 Settings size introduced in Phase 5 was never involved.
  - `Back to FBD` was never missing from the app. It is not on the main page — it belongs to the Settings
    page, which is exactly where the gate looks for it, and where it is found (step 4 passes).

  Both claims came from reading the script's step *labels* rather than the code behind them: `(460x860)` is
  descriptive text, not an assertion. The stale label has been corrected to `(760x860)`.
- **The HTTP API now covers the parity settings.** `GET /api/config` reports lock dim, the keyboard control
  target and its valid values, the brightness model and configuration protection; `POST /api/config/lockdim`
  and `POST /api/config/keytarget` set them. `HTTPRouter.routeConfig` is pure — validation lives there, next
  to the other namespaces — and the executor does the writes through `Settings`. The route namespace is
  deliberately *not* `/api/displays`: these are application settings, not a display's hardware.

  Both writes are honest about when they take effect, which the earlier audit established rather than
  assumed: lock dim re-reads its policy on every lock event, and the media-key path reads the control target
  on every press, so neither needs a restart.

  `HTTPConfigRouteTests` (14 cases) covers authentication on both read and write, the method gate, the
  bounds on `targetPercent`, the boolean-bridges-to-NSNumber trap (JSON `true` must not silently mean 1%),
  and that an unknown target's error names the valid values.

  Verified live against the rebuilt app, not just in unit tests: `401` without a token, the settings JSON on
  read, both writes taking effect immediately (`keyboard control target: focusedScreen`, `lock dim: on at
  25%`), the two refusals, and `404` for a GET on a write-only path.

  Still not exposed over HTTP: resolution favourites, group *sync apply*, connection management, the
  per-display protection-property selection and the saved-device registry. Those are actions against
  hardware or per-display state, each needing its own validation and error contract.
- **The remaining HTTP surfaces, and two bugs the work exposed.** `POST /api/config/connections`,
  `POST /api/config/protection`, `POST /api/config/device` and `POST /api/config/favourite` now cover
  connection management, the per-display protection selection, the saved-device registry and resolution
  favourites (list / record the current mode / recall). Only group *sync apply* is left, and its reason is
  structural rather than effort: it matches brightness in nits, so the executor's `DisplayControlling`
  seam would need `hardwareCeilingNits` added, or the endpoint would quietly skip the luminance matching
  the CLI performs.

  **Bug one, caught by the tests.** The guard I first wrote to reject a JSON boolean used `value is Bool`.
  That is true for `NSNumber(1)` — and `NSNumber(0)` — because Swift bridges NSNumber to Bool. So
  `{"display": 1}` was rejected while `{"display": "7"}` worked, and display 1 is usually the main
  display. The same flawed guard was already in the `targetPercent` check from the earlier lockdim work,
  where it wrongly rejected `{"targetPercent": 1}`. Both now compare the CoreFoundation type id, which is
  exact, and both have regression tests asserting the numbers 0 and 1 are accepted while a real boolean is
  refused. A grep confirmed no other instance of the pattern in the codebase.

  **Bug two, and a mistake of mine worth recording.** To check that a written favourite could be undone I
  backed the value up with `defaults read` and restored it afterwards — but **`defaults read` truncates
  long `Data` with a `...` in the middle**. My capture was 16 bytes of a 125-byte value, my "byte-for-byte"
  check compared the truncated value against itself and passed, and writing it back destroyed a real
  recorded favourite. It was recoverable because the API's own `list` output described the lost entry
  (slot 1, 1728x1117 at 120 Hz, not HiDPI — the current mode), so recreating it through the app produced a
  value of exactly the original 125 bytes with identical content, confirmed by the API and by the stored
  length.

  Two lessons: never round-trip preference values through `defaults read` — export the plist, or compare
  lengths and content instead of trusting the hex; and a file that survived the inspect step proves nothing
  unless the check could have failed.
- **Gap-matrix row #30 — display reports / export.** `DisplayReport` in FBDCore renders a detailed,
  paste-ready block per display under a header carrying the FBD and macOS versions, and `fbdcli report
  [file]` prints it or writes it out for attaching to a bug report.

  The formatter is split into a value-type `Snapshot` plus a pure `render`, which was forced by the type
  rather than chosen for elegance: `Display`'s collections are `private(set)`, so a test cannot populate one
  and the format-lock tests the gap matrix asks for would have been impossible against `Display` directly.
  For the same reason the refresh-rate de-duplication is its own pure function — left inline in the snapshot
  initialiser it would have been the one part of the report nobody could check.

  `DisplayReportTests` (8 cases) locks the **whole block** rather than sampling lines, because the point of a
  report is that two of them are comparable: a field that moves or disappears makes them not. It also pins
  that absent data reads as absent — "no DDC", "not reported", "not capable" — rather than the line being
  omitted, which would make "nothing there" indistinguishable from "nobody looked".

  Verified live: it prints, exports to a file, appears in `fbdcli help`, and an unwritable path reports the
  failure and exits 1 rather than failing silently. FBDCoreTests 702.
- **The menu-bar panel is flattened** — the last UI/IA parity piece the Phase 5 revamp left out.
  `DisplayRowView` inlined everything (header, slider, Filters, DDC, Resolutions/XDR, the disable row), so a
  single display filled most of a 650pt panel and a multi-display Mac could not see its displays at once,
  which is the one thing the panel exists for.

  The row now shows a title line (icon, name, capability badges, mode, ⋯ menu, power) plus an inline
  brightness slider carrying its nits value, and folds the rest behind one **More controls** disclosure.
  Nothing was dropped, and that was checked *before* restructuring rather than after: the ⋯ menu already
  covered mode, refresh, colour, presets, favourites, mirror, PiP, rotation, disable and Open in Settings, so
  the fold could not strand a control. Filters, DDC and the resolution/XDR sections remain one click away,
  and the same content is unfolded in Settings → Displays.

  Verified: build clean, `make ui-smoke` 5/5, the panel's AX tree reports no overlapping text, and the
  brightness slider is still discoverable by the smoke harness. Captured and inspected before committing,
  because this changes the primary surface.
- **Gap-matrix row #18 — custom control integration.** Two additions to the automation layer, following the
  matrix's route rather than copying BetterDisplay's shape:

  - a **`manual` event**, so a rule can be a control the user invokes rather than something the system
    fires. ON and OFF are two manual rules, and a shell control that prints its state is a third — its
    output already lands in the run log, which is what FBD has instead of a separate state-query field;
  - a **`notify` action**, which runs in-process rather than through a shell, so it is an action *kind*
    rather than a special payload. `AutomationEffect` is a sum type so the "starts nothing" case has no
    meaningless invocation, and `AutomationNotification.parse` treats `Title | body` with the whole string
    as the body when there is no separator.

  The scheduler **refuses the manual event entirely** — not merely manual rules — because selecting one
  would let an event topology storm run the user's commands unbidden. That is a guarantee, so it has its own
  tests.

  **Two things went wrong, and one of them was mine.** First, nothing in the app had ever called
  `requestAuthorization`: a `notify` rule would have been handed to the system and shown nothing. That is
  the dead-setting failure again, and it was found by asking what makes the action *visible* rather than
  whether the code ran. Permission is now requested when a notification rule is configured or found at
  launch, so a user who configures none is never prompted.

  Second, my first version called `UserNotificationCenter.current()` from `addRule`, which the CLI shares —
  and a bare SwiftPM binary has no bundle identity, so that **crashed `fbdcli automation add`** with
  `bundleProxyForCurrentProcess is nil`. It is now gated on `Bundle.main.bundleIdentifier`, and `deliver`
  returns false rather than raising. The live check caught it, and so did a second mistake in the same
  script: it matched only lowercase UUIDs while the CLI prints uppercase, so the ids came out empty and two
  test rules were silently left in the store. Both were cleaned up and the store verified empty.

  Verified live: adding a notification rule no longer crashes, a manual shell control runs and prints its
  output, running a notification rule from the CLI is refused with the reason, and unknown tokens name the
  valid ones (derived from the enums, so they cannot go stale). FBDCoreTests 715.
- **Gap-matrix row #17 — network devices as display controllers.** A saved device can now be attached to a
  display, and follows that display's volume when the media keys drive it. The attachment is keyed by the
  display's **identity** rather than its id, so a reconnect that renumbers the display keeps it — the same
  reason favourites are keyed that way.

  Two properties are deliberate rather than incidental. An attachment to a device that is not in the
  registry is **refused**: storing one would leave a reference the user cannot see and make the Settings
  list claim a device that is not there. And deleting a device afterwards leaves the attachment *reported*
  as dangling rather than silently resolving to nothing, because silence where the user expected a device
  reads as a bug.

  Philips is the honest exception. Its controller pairs with a PIN the user reads off the TV, and that
  pairing does not outlive the controller instance — so a fire-and-forget volume send from a media key
  cannot complete it. `NetworkDeviceCommander` reports unsupported for that brand instead of appearing to
  work, and pairing a Philips set stays an explicit `fbdcli tv philips` action. The Yamaha controller also
  has no zone concept, so a stored zone is not sent.

  Verified live: attaching, listing, refusing an unsaved device, detaching, detaching again (reported), and
  full cleanup back to "no saved devices" / "no attachments". `NetworkDeviceAttachmentTests` (9 cases)
  covers persistence through the injected suite, replacement, dangling detection, corrupt data, and the
  0…1 → 0…100 volume mapping with its clamping. FBDCoreTests 724.
- **Gap-matrix row #29 — OSD style, notifications and Dock rules.** The HUD's look is now a stored
  `OSDStyle` (position, continuous/segmented bar, dark-versus-adaptive background, shadow, corner radius,
  segment count) and the Dock policy is settings-driven: a permanent Dock icon, or a brief one at launch.
  The defaults are exactly the appearance FBD shipped before this was configurable, so an untouched install
  changes nothing, and every field is clamped on both write and read — a stored radius cannot clip the
  content, and a corrupt blob lands on the defaults.

  One thing came out of it that was not the point: the HUD's content was relying on the default foreground,
  which is a *system-appearance* colour, on a background that is always the dark HUD material — so in light
  mode the text was dark on dark. The content now carries its own foreground per background style.

  **Verification, stated honestly.** `OSDStyleTests` (8 cases) covers the defaults, clamping including
  non-finite values, idempotence, the round-trip through an injected suite, and that saving clamps what is
  stored. Build clean, `make ui-smoke` 5/5. The HUD **does** render, and this was confirmed — by timing the
  command rather than by looking at pixels: `cmdOSD` waits `while osd.isVisible` (up to 1.5 s), so a showing
  HUD makes `fbdcli osd` take ~1.4 s while the baseline `fbdcli list` takes 0.09 s, and a value refused
  before `show` (`osd sun.max 999`) returns in 0.10 s. `isVisible` is `window?.isVisible`, so that run is
  the CLI's own evidence that the window was on screen.

  Two earlier attempts to verify this were both wrong, and both were instrument errors rather than missing
  evidence. The first probed `UIDriver windows`, which filters on `CGWindowOwnerName == "FBD"` — but
  `fbdcli osd` builds its own `CustomOSD` and shows it **in the CLI process**, so the HUD is owned by
  `fbdcli` and that filter could never see it. (I then wrote "needs the HTTP API" into this log and a commit
  message, which was simply false: `cmdOSD` never touches the API.) The second captured the whole screen and
  asked which frames differed from a baseline; every frame differed, because a menu-bar clock and other
  windows change constantly, so the test could not fail. A check that cannot fail is worth nothing — the
  same lesson as the `defaults read` truncation earlier in this session.

  The individual *style variations* — a segmented bar, an adaptive background, the three other positions —
  are still unobserved. The render path and the default style are confirmed; nobody has looked at the rest.
- **Accessibility audit (the deferred VoiceOver pass, done at the level AX can settle).** Two findings, both
  positive, and both measured rather than assumed:

  - **No app control lacks an accessible name.** An AX sweep of all six Settings pages and the panel reports
    only *window chrome* as unnamed: the traffic lights at `@903,40`/`@923,40`/`@943,40` (12x14, drawn by the
    window server) and scrollbar parts at `x=1641`. Every `AXButton`, `AXCheckBox`, `AXSlider`, `AXPopUpButton`
    belonging to FBD carries a name. (The sweep's own chrome filter had to be fixed first — it was written
    against the *panel's* geometry, so the Settings window's chrome initially appeared as app findings.)
  - **The hit-target finding is closed.** `.fbdIconButton()` (`FBDTheme.swift:50-53`) applies
    `frame(minWidth: 28, minHeight: 28)` with `.contentShape(Rectangle())`, so the whole 28pt target is
    hittable rather than just the glyph — and the AX tree confirms it, e.g. `Close FBD panel @1611,64 28x28`.
    The old critique's "sub-28pt hit targets persist on icon-only controls" no longer holds, and the remaining
    sub-28pt elements are the window's own traffic lights.

  **What this does *not* establish, stated plainly.** Raw AX enumeration is not a VoiceOver session. It cannot
  see announcement *order*, whether a group is read as one element or several, traits, hints, or the rotor —
  and this session has already been wrong twice by treating AX evidence as equivalent to what VoiceOver says
  (the "50 unlabelled controls" false positive, and the `.combine` measurement that silently read an empty
  tree). A real VoiceOver run on the panel and the Application page is still the one thing nobody has done.

  Still open from the same critique, and unrelated to names: no keyboard shortcuts on in-app controls, and the
  panel's dead space on a single-display rig.
- **Three Shortcuts actions for the parity surfaces.** `Set Lock Dim`, `Set Keyboard Control Target` and
  `Sync Display Group` join the existing display actions. Intents are discovered through the module's
  `AppIntentsPackage` conformance, so no registry needed updating. `SetKeyboardControlTargetIntent` takes a
  `String` rather than an `AppEnum` on purpose: declaring the enum conformance outside the module that owns
  `KeyboardControlTarget` would be a retroactive conformance, so the value is validated against the real
  cases instead — which lets the error name the valid ones. `Sync Display Group` reuses the same
  `syncValue` + `applyGroupSync` path as the Settings page's "Sync now".

  Verification, stated honestly: the three intents' type symbols are present in the built binary with the
  same count as the intents that already work (`SetLockDimIntent`, `SetKeyboardControlTargetIntent`,
  `SyncDisplayGroupIntent`, and the pre-existing `SetDisplayBrightnessIntent` all at 2), so they are
  compiled in and registered by the identical mechanism. Full runtime discovery in Shortcuts still needs a
  manual check on a machine with Shortcuts — the app's `AppIntentsBridge` documents that limitation, and
  `make app` runs no App Intents metadata-extraction step, which is pre-existing behaviour.

  A false alarm worth recording: grepping the bundle for the literal `"Set Lock Dim"` returned zero hits and
  looked like a dead intent. It is not — Swift merges string-literal tails, so that title shares its `Dim`
  suffix with `"LockDimController"` and is never stored contiguously. Grep for a type symbol, not the title,
  when checking whether an intent survived the build.
- **Accessibility pass on the Settings controls — one real fix, plus a false finding of my own corrected.**
  Added an `ax-dump` command to `scripts/UIDriver.swift` that enumerates interactive accessibility elements
  with their resolved names, so an unnamed control is visible rather than guessed at.

  **Real fix:** `SettingsSliderRow` drew its title and current value as *siblings* of the `Slider` and never
  labelled the slider itself, so VoiceOver had no idea what those sliders changed. Both are now attached
  (`.accessibilityLabel` + `.accessibilityValue`), and the dump confirms it: the brightness-model sliders now
  report `label='Redefine 0% software brightness'`, `'Minimum hardware level'`, `'Software dimming
  switchover'` and `'Upscaling maximum'`. A `Slider` has no adjacent-label convention, so those really were
  unnamed.

  **Corrected false finding:** the first version of the dump read only `AXDescription`/`AXTitle` and reported
  ~50 controls on the Application page as unlabelled, including every checkbox. That was wrong. A control
  whose label is drawn beside it — the AppKit convention macOS SwiftUI follows — exposes its name through
  `AXTitleUIElement` instead. Once the probe resolved that, the checkboxes report `label='Launch at Login'`,
  `'Prefer hardware brightness control'`, `'Stored control values on startup'`, `'Dim to black'` and so on.
  The corrected count for the page is 33, not 60. The lesson is the same one this session keeps teaching:
  suspect the instrument before the code.

  **The one genuine remaining gap — and a fix that measurably failed.** Of those 33, 12 are container
  `AXGroup`s (not controls) and 14 are the 11×8 halves SwiftUI renders for a `Stepper`. I added
  `.accessibilityLabel` to all eight `Stepper`s and re-measured: **the count went 33 → 32 and all 14 inner
  buttons are still unlabelled.** `.accessibilityLabel` on a `Stepper` does not reach the buttons it
  decomposes into, so that change did not achieve its goal. It is kept because it does name the stepper
  element itself (which is what VoiceOver focuses), but it is **not** a fix for the inner buttons and is
  recorded as unproven rather than as an improvement.

  **Resolved — collapse the element, not label around it.** The fix that works is
  `.accessibilityElement(children: .combine)` plus `.accessibilityLabel` and `.accessibilityValue` on each
  `Stepper`, which replaces the two anonymous 11×8 increment/decrement buttons with one named element.
  Applied to all eight steppers (seven on the Application page, one in the panel's virtual-screen form) and
  **measured with a self-validating harness: 14 unlabelled buttons → 0**, with each stepper now appearing as
  a single named element (e.g. `'Hardware maximum' @1094,427`).

  Three things this cost, all recorded because they cost real time:

  - `.accessibilityLabel` alone does **not** work on a `Stepper` (33 → 32). The label lands on the stepper
    element while the buttons it decomposes into stay anonymous, so the count barely moves.
  - `.accessibilityElement(children: .ignore)` with an explicit `accessibilityAdjustableAction` — the
    approach this log previously predicted — turned out to be unnecessary. `.combine` is enough and needs no
    duplicated step/range logic per site.
  - The measurement harness now refuses to report a number unless the capture is verified to be showing the
    page (window state plus a known marker string). A stale *or empty* AX tree otherwise reports "0
    unlabelled", which is exactly how a bogus result was believed once already — the two attempts that
    followed were spent chasing a change that had in fact been a no-op.

  Still outstanding: a real VoiceOver check. Raw AX enumeration and what VoiceOver actually announces are
  not the same thing, and this pass has taught that lesson twice.
- **The status-item sweep is gone: the gate now drives the app deterministically.** The gate found the
  menu-bar item by clicking every 8pt from x=1710 until a panel happened to open. That is not merely slow, it
  is *unsound*: it cannot tell a real hit from a stale panel, which is exactly how it came to report a click
  that never landed and let step 1 pass while testing nothing.

  Two replacements, both reading the app's own surfaces instead of guessing:

  - `UIDriver status-frame` reads the item's **real** frame from the accessibility tree — an app's status
    items hang off its `AXExtrasMenuBar` attribute. They are *not* CGWindows: with the panel closed the
    process owns no windows at all, which is the underlying reason anyone wrote a sweep. The item spans
    x=1507..1531, so the old sweep's first "hit" at x=1534 was **3pt past its edge** — it was landing by luck.
  - **`fbd://close`** joins `fbd://open`, so panel teardown is a documented app route instead of synthetic
    Escape keypresses or hunting for the close button. Setup and teardown are now both one `open` call.

  Verified from the worst case rather than the convenient one: with the panel *deliberately left open on
  Settings*, the gate reports **5/5** where the sweep-based version reported 4/5.

  `UIDriver` also gains `windows` (FBD's windows with layer and bounds — the command that showed the status
  item has no window). `status-sweep` is marked superseded in place rather than deleted, so nothing that
  still calls it breaks silently.
- **Named display presets** — the one item the Crisp review's value order still listed as unbuilt
  (`docs/plans/reference-projects-freedisplay-crisp.md`, item 7). FBD could already recall a resolution
  per slot and restore protected properties on reconnect, but it had no way to name and re-apply a
  display's *whole* configuration.

  The feature is built on an extraction rather than a new mechanism. `ConfigProtectionController` already
  captured and re-applied exactly the state a preset needs — mode, refresh rate, brightness, the XDR
  preset, HDR mode, main-display status, rotation and the colour profile — in a private `SavedState`
  struct. That struct is now the public `DisplayStateSnapshot`, with `capture` and `apply` on it;
  `ConfigProtectionController` calls the same two methods, so reconnect-restore and preset-apply cannot
  drift apart. It was a **byte-compatible** move: the fields and their names are unchanged, so a blob an
  older FBD wrote still decodes, which `ConfigProtectionControllerTests` pins.

  What sits on top:

  - `DisplayPreset` (id, name, symbol, the properties it carries, the snapshot) and a store that mirrors
    `ModeFavourites` exactly — one JSON array per display under `displayPresets.<identity>`, saved order,
    the key removed when the last preset goes. It refuses an empty name and a name already in use on that
    display, case-insensitively, which is what makes `apply <name>` unambiguous.
  - A **closed** symbol set (`DisplayPresetSymbol`, twelve SF names) for the same reason the menu-bar icon
    is closed: a name that fails to resolve would draw a blank row. A stored name that no longer resolves
    decodes to the default rather than failing the whole preset.
  - `DisplayPresetApplier`, which intersects the preset's properties with what the display can actually
    accept and returns both halves. `ProtectedProperties.available(for:)` already decided what a display
    can report; the applier is where that becomes an honest result instead of a silent partial apply.
  - Four surfaces: `fbdcli config preset <id> list|save|apply|delete`, the `POST`/`GET`/`DELETE` route
    under `/api/config/preset`, a Settings → Displays section, a quick apply menu in the panel, and the
    `Apply Display Preset` App Intent.

  One deliberate default: `mainStatus` is **not** in a preset's property set. A preset restores a display's
  own configuration; taking the menu bar off another display as a side effect of "apply Desk preset" is
  not what anyone means by it, so it is restored only when named explicitly.

  Verified as far as this machine allows.

  - `swift test --disable-sandbox`: 0 failures, exit 0. New: `DisplayPresetsTests`
    (22), 13 router tests in `HTTPConfigRouteTests` (51 in the file), one executor round trip in
    `HTTPExecutorTests`. Touched and still green: `ConfigProtectionControllerTests` (13 — including the
    legacy-blob decode, which is what proves the snapshot extraction was format-compatible) and
    `LocalizationTests` (5, the new strings in all three languages).
  - The live path was exercised end to end against the built-in panel: `fbdcli config preset 1
    list|save|apply|delete` (save → list → apply by name and in lower case → delete → delete again
    returning 2), and the same four actions over `POST /api/config/preset` with the app running and
    its API enabled through `fbdcli http on` — save, a duplicate refused 409, list, apply reporting
    `unavailable: []`, and apply-after-delete replying `no preset`. The HTTP setting was turned back
    off afterwards and the store left no residue (`displayPresets.*` absent from the suite).
  - **`make ui-smoke` did not run here, and that is an environment fact, not a result.** The gate
    needs Accessibility permission for the calling process, and a trust probe from this shell reports
    `AXIsProcessTrusted = false`; every step fails at the AX read (`status-item-not-found`), with the
    app itself up and running. Two things bound the risk that it would have caught something: the
    gate's five steps never reach the presets section (panel opens, brightness slider, gear → Settings,
    back, close), and the panel sizes it asserts are hardcoded constants in `StatusItemController`
    (`settingsSize`, `mainSize`), not content-driven, so a section added inside Settings' scroll view
    cannot move them. The section still wants a real look on a machine with the permission granted.



- **Pointer crossing between displays whose edges do not line up** — the last item the Crisp review's
  value order still listed as unbuilt (`docs/plans/reference-projects-freedisplay-crisp.md`, item 9), and
  the one of the two that remained that was not settled as not-doable. macOS stops the pointer at an edge
  no other display covers, so a short display beside a tall one traps it in the gap.

  `EdgeCrossingMath.landing(from:push:displays:slack:)` is the whole decision, pure and testable without
  moving anyone's pointer: it finds the display the pointer is on — or the nearest one, because macOS
  clamps the pointer a fraction past an edge, which is exactly where the feature matters — and for the
  pushed edge offers each neighbour whose facing edge meets it within a point a landing point clamped
  inside that neighbour, keeping the smallest slide along the shared axis. It returns nothing when macOS
  would cross there by itself, when the edges do not meet (a deliberate gap is a gap), or when no display
  is under the pointer.

  `EdgeCrossingController` supplies the bounds, the events and the reconcile timer. Three measured facts
  shaped it:

  - **The push direction cannot come from polling.** A probe warping the pointer at and past an edge found
    macOS clamping it to the displays' bounds — a warp to (-400,300) reads back as (0,300) — so a pointer
    pinned at an edge reports zero movement between samples. The direction comes from the mouse-moved
    event's own hardware delta. (`CGGetLastMouseDelta` is no longer in the Swift SDK: the overlay marks it
    unavailable.)
  - **A mouse-moved monitor needs no Accessibility grant,** only key events do. That is the trade
    `CursorContainmentController` refuses for a `CGEventTap`, and it does not arise here, so this is a
    monitor rather than a tap. If it never fires the feature is inert — it cannot fight the user.
  - **A warp holds hardware input back for a quarter of a second** by default, which reads as the pointer
    sticking. On macOS 27 only zeroing the event source's `localEventsSuppressionInterval` lifts it;
    `CGAssociateMouseAndMouseCursorPosition` does not.

  Off by default (`Settings.edgeCrossingEnabled`; Settings → Displays, or `fbdcli layout edge-crossing
  [on|off]`). A 1.5 s reconcile timer installs or removes the monitor as the preference changes, because
  the CLI writes it from another process and `UserDefaults` does not notify across processes — the same
  reason AppCore polls for the HTTP server setting. Settings and CLI only: like `layout protect`, which
  has none either, a preference gets no HTTP route, and it is not an App Intent.

  Verified as far as this machine allows.

  - `swift test --disable-sandbox`: 0 failures, exit 0 — the 18 new
    `EdgeCrossingMathTests` included, and `LocalizationTests` still green with the two new strings in all
    three languages. `make app` builds `build/FBD.app` clean.
  - The CLI path was exercised live: `layout edge-crossing` reports off by default, `on`/`off` set it and
    read back, an unknown word is refused with exit 1, and a bare `layout` prints the usage line.
  - **The monitor path was exercised end to end with a temporary second display**, because this Mac has
    one. With a virtual display created through the running app's own API, the log shows
    `edge crossing: watching the pointer across 2 display(s)`; toggling the preference off and on *from
    the CLI process* produced that line a second time, which can only happen if the setting was picked up
    across processes and the monitors were first removed and then installed again. With one display the
    controller logs nothing at all — it removes its monitors rather than watching. Cleanup: the virtual
    display was destroyed, the HTTP setting turned back off, and the store left no residue.
  - **The warp itself is unverified here.** It needs two real displays *misaligned at an edge* and a
    genuine hand movement — warps do not generate `NSEvent` moves, and synthesised events need the
    Accessibility trust this shell does not have (`AXIsProcessTrusted()` is false). The geometry is pinned
    by the 18 pure tests instead, including the invariant that every landing point lies inside the display
    it crosses to, which is what makes a warp stick rather than being clamped straight back.
  - `make ui-smoke` cannot run from this shell either (the same Accessibility fact, recorded above for
    item 7). The one new UI surface is a toggle and a caption in Settings → Displays, which the gate's
    five steps do not reach.
