# FreeDisplay and Crisp — what to take

The user found two sibling projects that solve FBD's problem:
[FreeDisplay](https://github.com/huberdf/FreeDisplay) and
[Crisp](https://github.com/didriksg/Crisp), the latter a FreeDisplay fork that went
considerably further. FBD already tracks BetterDisplay parity in
`fbd-gap-matrix.md`; this doc tracks these two, because they are closer cousins —
same platform, same private APIs, same "free alternative to BetterDisplay" mission —
and because Crisp's UI is better solved than FBD's.

## Sources, licences and the copying rule

| project | licence | what that permits here |
|---|---|---|
| **FreeDisplay** (huberdf) | MIT declared in its README; the repository ships **no LICENSE file** | look, do not copy |
| **Crisp** (didriksg) | **MIT**, © 2026 Didrik Galteland. Its `ACKNOWLEDGMENTS.md` reproduces (and corrects) FreeDisplay's licence text | look, do not copy |

Both are MIT, so reusing code would be legal *with* attribution. Nothing here is
reused: the capability lists and Crisp's design doctrine are **paraphrased**, not
quoted, matching the wording policy this repo already applies to BetterDisplay
switches, and every implementation below is FBD's own. Credit for the *ideas* is
this document.

An absence worth stating plainly: FreeDisplay's README declares MIT but the repo
carries no licence file. That is a gap in *their* housekeeping, not a permission
FBD should rely on, so nothing is taken from it beyond "this feature exists".

## Capability comparison

"FBD" is the state of this tree, checked in the code rather than from the matrix
(whose status column is known stale — see `fbd-gap-matrix.md` notes).

| capability | FreeDisplay | Crisp | FBD | verdict |
|---|:--:|:--:|---|---|
| Hardware brightness/contrast over DDC / IOAVService | ✅ | ✅ | ✅ | — |
| Software dimming below the hardware floor | ✅ | ✅ | ✅ | — |
| XDR/HDR **Extra Brightness** | ✗ (declared out) | ✅ | ✅ | FBD level |
| DDC speaker volume | — | ✅ | ✅ | — |
| Brightness keys follow pointer / focused / all | ✅ (pointer) | ✅ (+chosen few, custom shortcuts) | ✅ pointer·focused·all·audio | Crisp adds **user-chosen subsets** |
| ICC profile switching | ✅ | ✅ | ✅ | — |
| Image adjustment (gamma/contrast/gain/invert) | ✅ | ✅ | ✅ | — |
| Virtual displays / HiDPI | ✅ | ✅ | ✅ | — |
| **Smooth, fine-grained scaling** | — | ✅ | ✗ | **gap** — FBD row #22 (high risk: needs the mode-list private API) |
| "Make my external crisp" HiDPI flow (auto for 1440p+) | ✅ | ✅ | ✗ (manual modes only) | **gap** |
| Named display presets, with an icon | ✅ | ✅ | ✗ (mode favourites + XDR presets only) | **gap** |
| Shortcuts / App Intents | — | ✅ broad | ✅ 8 intents, no preset/input/disconnect action | **narrow gap** |
| Arrangement canvas + main-display switch | ✅ | ✅ drag-to-arrange | ✅ `ArrangementGridView` | Crisp's is interactive |
| **Edge-crossing pointer** between misaligned displays | — | ✅ | ✗ | **gap** |
| Disconnect displays, remembered across sleep/reboot | — | ✅ | ✅ per-display enable/disable + auto-disconnect built-in | close |
| Input switching over DDC | — | ✅ in the menu | ✅ CLI + DDC only | **surface it in the UI** |
| System toggles: Dark Mode / Night Shift / True Tone | Night Shift only | ✅ all three | ✅ Night Shift + True Tone | **gap: Dark Mode** |
| **Keep awake** | — | ✅ | ✗ | **gap, cheap** |
| Notch hiding | ✅ | ✅ | ✗ — a dead Notch toggle was **deliberately removed** | deliberate; revisit only if wanted |
| Launch at login | ✅ | ✅ | ✅ | — |
| Combined brightness, auto-brightness, ambient-light toggle | ✅ | ✅ | ✅ | — |
| **Localisation** | — | ✅ en · 简体中文 · 繁體中文 | ✅ en · 简体中文 · 繁體中文, the panel first | — |
| PiP / streaming | ✗ (declared out) | ✗ | ✅ | **FBD ahead** |
| Automation, TV/AVR/network devices, HTTP API, `fbdcli` | ✗ | partial (`crispctl`) | ✅ | **FBD ahead** |
| EDID override | ✗ (needs SIP off) | — | ✅ | **FBD ahead** |

So FBD is ahead on automation, devices and streaming, and behind on **scaling
finesse, presets, a few cheap system toggles, and localisation**.

## What Crisp's UI does better

Crisp ships `docs/DESIGN.md`, a design doctrine grounded in Apple's HIG with the
sources linked. Paraphrased, the rules that bear on FBD:

1. **Glass belongs on the backdrop only.** The panel's chrome is glass; the content
   on it uses standard materials. Stacking a material inside an already-glassy panel
   is glass-on-glass, which flattens the hierarchy and makes the chrome compete with
   the content it frames.
2. **A discrete selection is a flat one-click checkmark list** — resolution, refresh
   rate, preset, colour profile — not a nested menu that costs two clicks. A
   checkmark states the attribute already in effect.
3. **An adjustment is a slider or stepper.** A panel should not ask for typed text;
   Crisp names its one exception (naming a preset) and says why rather than hiding it.
4. **Icons are all-or-none within a group**, and section rows use one uniform chip
   treatment rather than icons on some rows and not others.
5. **Depth expands in place** — a disclosure with a chevron — rather than pushing a
   second navigation level.
6. **One inline editor at a time**: opening one edit form closes any other.
7. **Empty states are centred**, not left as an orphaned row.
8. **The expanded detail region is a full-width shaded band**, not a floating
   rounded card — the same "one surface" logic as rule 1.
9. On macOS 26 no glass material can hold the system HUD's backdrop, so Crisp's
   banner blurs its own backdrop under a flat grey; macOS 27 offers a glass variant.
   Relevant to FBD's `CustomOSD`, which is the one surface outside the panel that
   samples what is behind it.

### Where FBD stands against them

| rule | FBD today |
|---|---|
| 1 · no glass-on-glass | ✅ fixed — `fbdChromeBand()`; was violated at `DisplayListView.swift:232`, `:277`, `:361` |
| 2 · checkmark lists | partial — the panel's mode/refresh/colour live in a `.menu` picker (two clicks) |
| 3 · sliders, not typing | mostly ✅; the nits ranges are typed |
| 4 · icons all-or-none | ✅ uniform — every section row carries an icon at the same font and tint; checked against the rendered panel, not just the source |
| 5 · expand in place | ✅ `More controls` disclosure; but folded content also pushes to Settings |
| 6 · one editor at a time | ✅ not applicable — the panel has no inline *forms*, so there is nothing for the rule to sequence. Verified by looking at the rendered panel and by grepping for editor state |
| 7 · centred empty states | ✅ already centred (`DisplayListView.swift:283`) |
| 8 · shaded band, not a card | ✅ fixed — `fbdPanelBand()`; rows and sections were floating rounded cards *inside* the panel until now, and the expanded detail is part of the row's band |
| 9 · the HUD's material | ✅ offered, with a measured caveat — FBD's HUD is a vibrancy view in `.withinWindow` mode, which samples the window's *own* content (the SwiftUI content and nothing else), so it draws a flat panel rather than sampling the desktop. The OS's glass (`NSGlassEffectView`, macOS 26+) is now offered as `OSDStyle.Background.glass`, default unchanged. Captured on macOS 27: it renders correctly and the difference is subtle — which matches this rule's own finding that no glass material holds a HUD's backdrop on macOS 26. `.behindWindow` was measured too and is not a substitute |

## Plan, in value order

1. **Material discipline in the panel** — **done.** The three chrome sites now use
   `FBDTheme.chromeBandOpacity` via `fbdChromeBand()`, so the panel holds one
   material (its backdrop) instead of four.
2. **Keep awake** — **done.** A Settings → Menu → System toggle holds a
   `NoDisplaySleepAssertion` while FBD runs; verified with `pmset -g assertions`,
   which shows the assertion while the app is up and nothing after it quits. It is
   app-side by necessity: the assertion belongs to the process holding it.
3. **Dark Mode toggle** — **done.** FBD's Night Shift + True Tone are now Crisp's set. Crisp's own
   mechanism is the one used: SkyLight's appearance theme (`SLSGetAppearanceThemeLegacy` /
   `SLSSetAppearanceThemeLegacy` / `SLSSetAppearanceThemeNotifying`), resolved at runtime through a
   C shim so a Mac without it degrades rather than crashing, with the notifying variant preferred
   so the switch crossfades exactly as Control Center's does. Surfaced as `fbdcli dark-mode
   [on|off]` and a toggle beside True Tone. Not stored in `Settings`: it is the system's switch,
   and another app can change it.
4. **Input switching in the per-display UI** — **done, and the gap was smaller than the table
   said.** `DDCPanelView` (used by the panel's per-display row *and* Settings → Displays) has had a
   named input menu plus a raw VCP override for a while, so "CLI + DDC only" was wrong. What was
   genuinely missing is the feature that makes such a menu honest: it could not say which input was
   **in effect**. It can now, because VCP 0x60 rides in the same batched DDC read as
   contrast/volume/mute — no extra traffic, off the main actor — so the menu marks the current input
   with a checkmark, its title names it, and when the display refuses to answer it falls back to the
   last input set rather than inventing one.
5. **Checkmark lists for the panel's discrete selections** — **done, though not as rule 2
   literally reads.** All four of the panel's lists already showed a checkmark on the value in
   effect, so the missing part was the *cost* of reaching them: the resolutions section now
   shows a curated list (one row per logical size at the current mode's aspect ratio, HiDPI
   preferred, and the mode in effect always present) with **Show all N modes** one click away.
   A flat list of all 132 modes would have been a wall, not a list.
6. **Uniform section chips** (rule 4).
7. **Named display presets with icons**, plus the App Intent to apply one.
8. **Localisation** — **done, for the panel.** en · 简体中文 · 繁體中文, the same three Crisp ships.
   Three `.lproj/Localizable.strings` sit beside the icon and the Makefile copies them into the
   bundle, which is where macOS looks; **no code change was needed**, because SwiftUI already
   resolves the literals against the app bundle. 37 strings cover the panel's own surface — the
   display list, the per-display menu, the sections, the DDC panel and the chrome — and the rest
   falls back to English. That is what "scaffold" means here, and the drift test that keeps the
   three files in step is what makes adding the remaining strings safe.
9. **Edge-crossing pointer** for displays whose edges do not line up.
10. **Smooth scaling / the HiDPI-crisp flow** — the highest value and the highest
    risk: it needs a new display mode, which FBD has not identified a safe API for
    (row #22), and a wrong write can leave the only attached display unusable.

Not pursued: notch hiding (FBD removed it deliberately), and the PiP work Crisp does
not have.
