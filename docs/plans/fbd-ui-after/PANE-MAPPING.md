# Phase 5 — BetterDisplay pane → FBD screen mapping

Reference screenshots: `~/Downloads/bd_poc/bd-ui-reference/` (**outside this repository**, by
decision at the Phase 3 gate — BetterDisplay UI material is not redistributed).
FBD results: this directory (`00-menu-bar-panel` … `15-settings-about`), each with a matching
`.ax.txt` accessibility tree.

The goal was *inspired, not cloned*: same grouping and depth of control, FBD's own wording,
SF Symbols and design tokens. No BetterDisplay string, asset or colour is reproduced here.

## Sidebar

| BetterDisplay pane | FBD page | Notes |
|---|---|---|
| `Displays` | **Displays** | Long page: arrangement grid, bulk connection actions, then one card per display. |
| `Groups` | **Groups** | Group list, enable flag, activation policy, mirror/unmirror. |
| `Application` | **Application** | General, brightness model, XDR/HDR, DDC, integrations, experimental, EDID & protection, automation. |
| `Menu` | **Menu** | Display-list and panel-contents options. |
| `Keyboard` | **Keyboard** | Media keys, keyboard-control target. |
| `Pro` | *(none — deliberately)* | FBD has no Pro tier and no licence surface; see the scope note's "deliberately out of scope". |
| `About` | **About** | Version and links. |

## Per-display page

| BetterDisplay section | FBD equivalent | Notes |
|---|---|---|
| General settings | per-display card (name, kind tag, mode line, brightness) | FBD's card is the panel's card, reused in Settings. |
| Device Control (controller list) | *(not adopted)* | FBD's control routing is internal (`DisplayControlling`, `CombinedBrightness`); exposing an attachable-controller list was not in the agreed scope. |
| Brightness / XDR upscaling | per-display card + **Application → Brightness model** | FBD keeps the model global and the per-display controls on the card. |
| Combined brightness tuning | **Application → Brightness model** | Switchover point, minimum hardware level, re-defined 0 %, upscaling maximum. |
| Image Adjustments | per-display card → **Filters** disclosure | FBD applies filters through one Metal pass. |
| System Configuration and Flexible Scaling | *(not adopted)* | Needs an unidentified private mode-list API — matrix #22/#27, not attempted. |
| Display EDID | per-display card + **Application → EDID & Protection** | EDID export/apply/restore live in `fbdcli edid`; Settings carries the auto-apply policy. |
| *(no BetterDisplay equivalent)* | per-display **Configuration protection** card | Per-property protection, new in this work. |
| *(no BetterDisplay equivalent)* | per-display **Resolution favourites** card | Five recall slots, new in this work. |

## Menu-bar quick menu

| BetterDisplay quick-menu row | FBD equivalent | Notes |
|---|---|---|
| Brightness + slider | per-display card brightness slider (% and nits) | Already at parity. |
| Display mode / refresh / colour mode | per-display **More** menu: Display Mode, Refresh Rate, Color Mode | Already grouped as submenus. |
| Apple display preset | per-display **More** menu: Apple Display Preset | Already at parity. |
| Screen rotation / Mirror / PiP / Stream | per-display **More** menu | Already at parity. |
| Manage display | per-display **More** menu: Manage Display | Already at parity. |
| *(no BetterDisplay equivalent)* | per-display **More** menu: **Resolution Favourites** | Added in this work. |
| Configuration protection / Manage display / HiDPI / Notch / Brightness upscaling / Auto brightness / Device control / Set up permissions / Settings / More | *(not adopted as a flat list)* | FBD's panel is a per-display card with collapsible sections rather than a flat row list. The **structure** (grouped submenus per display) is already present; a wholesale flat-row conversion was **not** done — see the progress log's Phase 5 "not done" entry. |

## What this mapping deliberately does not claim

- FBD's panel is not a flat 20-row list like BetterDisplay's quick menu. Its per-display card with
  grouped disclosures carries the same information, but a reader comparing the two will see a
  different presentation, not the same one.
- `Menu` and `Keyboard` are thinner in FBD than in BetterDisplay because FBD simply has fewer
  options there; the pages exist so the taxonomy matches and the options have a home.
- The `Pro` pane has no FBD counterpart on purpose.
