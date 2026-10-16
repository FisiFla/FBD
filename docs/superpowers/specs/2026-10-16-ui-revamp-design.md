# UI revamp: Control Center–style popover with Liquid Glass

Date: 2026-10-16 · Status: approved design, pending implementation plan

## Why

FBD's panel follows most of Crisp's design rules (see
`docs/plans/reference-projects-freedisplay-crisp.md`) yet still reads worse than Crisp or
BetterDisplay. The gap is information architecture and container, not rules:

- The panel is a titled, resizable `NSPanel` (`StatusItemController.swift:27`): traffic
  lights, fixed size, half of it empty.
- Every display card shows every section inline (filters, resolutions, XDR, colour profile,
  a DDC paragraph), so the 90% task — set brightness — competes with everything else.
- Body/title-size type and generous padding make a menu-bar utility feel like a document.
- A bottom bar of text links duplicates the sections above it.
- Settings opens *inside* the panel with a back button and sidebar.
- Raw identifiers leak into the UI (`refreshRate`, `hdrMode`, `mainStatus`).

Goal: the panel shows the common case at a glance and puts depth one click away, in the
visual language of macOS Control Center, using Liquid Glass on macOS 26+.

## Success criteria

1. Opening the status item shows a borderless popover sized to its content (no traffic
   lights, no empty area), ~340 pt wide.
2. Brightness (and volume, where DDC answers) for every display is adjustable from the
   front page without any click beyond the drag.
3. Every other per-display control is reachable in ≤ 2 clicks (row `›` → detail page).
4. Settings opens in its own standard window; the popover never shows Settings.
5. No raw identifier appears in any user-facing string; every string is localised
   (en · zh-Hans · zh-Hant) and covered by `LocalizationTests`.
6. On macOS 26+ the backdrop, quick toggles, page header, small action buttons and slider
   thumb are Liquid Glass; on macOS 13–25 the same UI renders with materials, no glass.
7. CI and release builds use the Xcode 26+ SDK so shipped builds contain glass.
8. All existing tests pass; new `PanelModel` tests pass; `make ui-smoke` passes.

## Structure and navigation

**Container.** Borderless, non-activating popover anchored under the status item. One
glass backdrop with rounded corners. Fixed width ~340 pt; height = content height, capped
at 85% of the screen's visible height, then the page scrolls. Escape (with the existing
guards against sheets, dialogs and marked text) and click-outside close it.

**Page stack.** Pages slide horizontally inside the popover; a slim header carries `‹` and
the page title. Depth is one level, with `All modes` as the only second level (inside a
display page). Routes:

| route | page |
|---|---|
| `.home` | front page |
| `.display(id)` | display detail |
| `.allModes(id)` | every display mode, flat checkmark list |
| `.virtualScreens` | virtual screens: list, create, destroy |
| `.groups` | display groups: list, sync, delete |
| `.newPreset` | name + icon for a new preset from the current state |

**Front page, top to bottom**

1. **Displays** — per display, a block:
   - row: kind symbol · name · `resolution · Hz` (secondary) · power button · `›`
     (opens `.display(id)`);
   - brightness slider, keeping the two-tone XDR track (hardware / XDR boost), with the
     value shown as an overlay only while dragging;
   - volume slider, only when the display answers DDC volume.
2. **Quick toggles** — round tiles with label and On/Off: Dark Mode · Night Shift ·
   True Tone · Keep Awake. A tile the system cannot drive is shown disabled with its
   reason in the tooltip (matches existing graceful degradation).
3. **Presets** — one-click rows (preset icon + name; applies to its display), then
   `New preset…`.
4. **Navigation rows** — `Virtual screens · N` `›`, `Display groups · N` `›`.
5. **Footer** — `Settings…` (opens the Settings window), `Check for Updates`, `Quit FBD`,
   as list rows with icon chips.

**Display detail page** (`.display(id)`), sections in order:
resolution (curated checkmark list + `Show all N modes` → `.allModes(id)`) · refresh rate
(checkmark list) · XDR / HDR · colour profile (checkmark list + restore default) ·
filters · monitor controls (DDC contrast, input; if no DDC, one dimmed line
"Monitor controls unavailable — no DDC/CI") · display actions (make main, rotate,
disconnect — destructive ones confirmed, as today).

## Visual language

Builds on `FBDTheme` tokens.

- **Type scale** (new `FBDTheme` font tokens): display name 13 pt semibold; secondary
  text 11 pt `.secondary`; section header 11 pt semibold `.secondary`. No large titles in
  the popover; the old "FBD · Free Better Display" header is removed.
- **`FBDListRow`** — 26 pt round icon chip · label · optional trailing value · optional
  `›`; 32 pt tall; whole row is the hit target with a subtle hover highlight. Used for
  presets, navigation rows, footer and detail-page lists.
- **`FBDToggleTile`** — 44 pt circle, label below, On/Off below that.
- **`FDBSlider`** — keep behaviour and accessibility; 6 pt track, 20 pt pill thumb,
  dim/bright symbols at the ends; value overlay only while dragging.
- **Surfaces** — one backdrop; groups separated by hairline dividers and spacing, not
  cards. Display blocks take `fbdPanelBand` shading on hover only.
- **Colour** — system appearance and system accent. No per-kind tints on the front page.
  Red only for destructive actions.
- **Copy** — user-facing labels for every enum shown in the UI
  (e.g. `refreshRate` → "Refresh rate", `mainStatus` → "Main display"), localised.

## Liquid Glass (macOS 26+)

Glass is for the controls/navigation layer floating over content (Apple's guidance; and
Crisp rule 1 — no glass on content). Placement:

| element | treatment |
|---|---|
| popover backdrop | `NSGlassEffectView` (replaces the vibrancy material) |
| quick-toggle tiles | `.glassEffect(.regular.interactive(), in: .circle)` in one `GlassEffectContainer`; On = `.tint(accent)` |
| page header (`‹` + title) | floating glass capsule; morphs between pages via `glassEffectID` in a shared namespace |
| small action buttons (power, New preset…, create/destroy virtual screen) | `.buttonStyle(.glass)` |
| slider thumb | glass pill; track stays flat |
| HUD (`CustomOSD`) | `OSDStyle.Background.glass` becomes the default on macOS 26+ (users' saved choice wins) |

Not glass: rows, lists, display blocks, the Settings window's forms.

**Fallback.** All glass goes through one set of modifiers in `DesignSystem/FBDGlass.swift`
(`fbdGlass(in:)`, `fbdGlassButton()`, `fbdGlassContainer`). Implementation is wrapped in
`#if compiler(>=6.2)` and `if #available(macOS 26, *)`; otherwise they apply
`.regularMaterial` / a translucent fill. No view outside `FBDGlass.swift` calls a glass API
directly.

**Toolchain.** `ci.yml` and `release.yml` select Xcode 26+ (`xcode-select`), failing the
job if it is absent. Deployment target stays macOS 13.2.

## Code structure

- **`PanelModel`** (`@MainActor final class`, `ObservableObject`) — owns displays, virtual
  screens, groups, presets, the current route and pending confirmations; exposes intents
  (`open(_:)`, `back()`, `applyPreset(_:)`, `setBrightness…` passthroughs). Replaces the
  ~25 `@State` properties in `DisplayListView`. FBDCore controllers are unchanged.
- **Views** (one file each): `PanelRootView` (stack, transitions, header morph),
  `HomePage` (+ `DisplayBlock`, `QuickTogglesRow`, `PresetsSection`, `NavigationRows`),
  `DisplayDetailPage`, `AllModesPage`, `VirtualScreensPage`, `GroupsPage`, `NewPresetPage`.
  `DDCPanelView`, `FilterControlsView` and the resolution/XDR logic in
  `DisplaySectionsView` are re-skinned and reused, not rewritten.
- **Design system**: `FBDListRow`, `FBDToggleTile`, `FBDPageHeader`, `FBDGlass`, slimmed
  `FDBSlider`, `FBDTheme` type scale.
- **Windows**: `StatusItemController` hosts the borderless panel and sizes it from the
  hosting view's ideal size; new `SettingsWindowController` shows `SettingsView` in a
  standard window (sidebar + grouped `Form`), opened by `Settings…` and `.fbdOpenSettings`.
- **Removed**: in-panel settings mode, footer link bar, titlebar/traffic-light code,
  `DisplayListView` (superseded by `PanelRootView` + pages).

## Rollout

1. Foundation (single owner): `PanelModel` + routes, borderless container,
   `SettingsWindowController` shell, design-system components, `FBDGlass`.
2. Parallel, one worktree each, disjoint files:
   - A — home page (`HomePage` and its subviews);
   - B — display detail + all-modes pages;
   - C — virtual screens, groups, new-preset pages;
   - D — Settings window restyle + copy fixes + HUD glass default + CI Xcode pin.
3. Merge, then visual pass.

## Testing and verification

- Unit tests for `PanelModel`: route push/pop, counts on navigation rows, volume row hidden
  when DDC volume is unavailable, confirmation state for destructive actions.
- `LocalizationTests` (both directions) cover all new strings.
- `make ui-smoke` updated to the new accessibility identifiers (status item → popover →
  brightness slider → display page → back → Settings window → close).
- Visual: build `FBD.app`, capture home page, a display page and Settings in light and dark
  on macOS 27, and the fallback path (glass disabled) — before/after set for review.

## Out of scope

New features, FBDCore behaviour changes, `fbdcli`, the HTTP API.
