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
  handling. FBDCoreTests 649, FBDCLIParserTests 136 — **785 tests, 0 failures**.
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

  The fix that should work is collapsing the element instead of labelling it around the outside:
  `.accessibilityElement(children: .ignore)` plus `.accessibilityLabel`, `.accessibilityValue` and
  `.accessibilityAdjustableAction` on each stepper, which replaces the two unnamed buttons with one named
  adjustable control. That is a larger change per site (eight of them) and was not attempted. A real
  VoiceOver check is also still outstanding — raw AX enumeration and what VoiceOver actually announces are
  not the same thing, and this whole pass has already taught that lesson twice.
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



