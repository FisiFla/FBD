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
| **Localisation** | — | ✅ en · 简体中文 · 繁體中文 | ✗ English only | **gap** |
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
| 4 · icons all-or-none | mixed — `DesignSystem` has chips, but rows are inconsistent |
| 5 · expand in place | ✅ `More controls` disclosure; but folded content also pushes to Settings |
| 6 · one editor at a time | not verified |
| 7 · centred empty states | ✅ already centred (`DisplayListView.swift:283`) |
| 8 · shaded band, not a card | partial — content uses `FBDCard` inside the panel |

## Plan, in value order

1. **Material discipline in the panel** — **done.** The three chrome sites now use
   `FBDTheme.chromeBandOpacity` via `fbdChromeBand()`, so the panel holds one
   material (its backdrop) instead of four.
2. **Keep awake** — **done.** A Settings → Menu → System toggle holds a
   `NoDisplaySleepAssertion` while FBD runs; verified with `pmset -g assertions`,
   which shows the assertion while the app is up and nothing after it quits. It is
   app-side by necessity: the assertion belongs to the process holding it.
3. **Dark Mode toggle** — completes FBD's Night Shift + True Tone into Crisp's set.
4. **Input switching in the per-display UI** — the capability already exists over DDC
   and in the CLI; this only surfaces it where a person would look for it.
5. **Checkmark lists for the panel's discrete selections** (rule 2).
6. **Uniform section chips** (rule 4).
7. **Named display presets with icons**, plus the App Intent to apply one.
8. **Localisation** — en plus zh-Hans/zh-Hant, as Crisp does.
9. **Edge-crossing pointer** for displays whose edges do not line up.
10. **Smooth scaling / the HiDPI-crisp flow** — the highest value and the highest
    risk: it needs a new display mode, which FBD has not identified a safe API for
    (row #22), and a wrong write can leave the only attached display unusable.

Not pursued: notch hiding (FBD removed it deliberately), and the PiP work Crisp does
not have.
