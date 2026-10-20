# FBD — Free Better Display

A free, MIT-licensed macOS menu-bar app for display control: brightness (Apple + DDC/CI),
volume, contrast, input switching, resolution/refresh-rate control, virtual displays,
XDR/HDR brightness upscaling, full-screen software filters (contrast, saturation,
gamma, color temperature, invert, sharpening, zoom/pan, 3D LUT), screen rotation,
EDID overrides, per-display event automation (shell, URL or notification), a configurable
on-screen HUD and Dock behaviour, saved TV/AVR control over the network, display groups
with sync policies, resolution favourites, named display presets, pointer crossing
between misaligned displays, lock-dim, and more.

**Status: beta.** The goal is BetterDisplay-class functionality — no Pro tier, no licensing,
no telemetry — and most of the surface is implemented, but parts are not yet verified on real
hardware (see the matrix below). Updates via Sparkle (optional).

[![CI](https://github.com/FisiFla/FBD/actions/workflows/ci.yml/badge.svg)](https://github.com/FisiFla/FBD/actions/workflows/ci.yml)

Every planned feature tier has code and unit tests (CI runs build + tests on every push),
but CI cannot exercise real displays. Apple locks down private display APIs differently per
macOS release; FBD degrades gracefully (feature off, UI notes it) when a path is unavailable.

## Screenshots

<img src="docs/plans/fbd-ui-revamp/home-dark.png" alt="FBD's menu-bar panel: brightness slider, quick toggles, presets and navigation rows" width="386">

The panel on macOS 27 (Liquid Glass). More, including each display's page, All Modes, Settings,
light mode and the pre-revamp panel, are in [`docs/plans/fbd-ui-revamp/`](docs/plans/fbd-ui-revamp/).

## Feature matrix by macOS version

| Feature | macOS 13–15 | macOS 26 | macOS 27 |
|---|---|---|---|
| Apple brightness / resolution | ✅ | ✅ | ✅ |
| DDC/CI (external displays, Apple Silicon) | ⚠️ implemented, not yet verified on hardware ([#7](https://github.com/FisiFla/FBD/issues/7)) | ⚠️ same | ⚠️ same |
| Virtual displays | ⚠️ `CGVirtualDisplay` (dlopen; implemented, unverified) | ✅ `SLVirtualDisplay` | ✅ `SLVirtualDisplay` (live-verified) |
| XDR upscaling (native preset rewrite) | ✅ | ✅ | ⚠️ rewrite write-protected → software boost*; preset switching ✅ |
| True Tone toggle | ✅ | ⚠️ not measured here | ✅ live-verified (macOS 27.0.1) |
| Below-floor brightness blend (DDC floor reached in software) | ⚠️ needs Screen Recording; not yet verified on hardware | ⚠️ same | ⚠️ same |
| HiDPI smooth scaling (scaled-mode ladder) | ⚠️ implemented, not yet verified on hardware; asks for an administrator password | ⚠️ same | ⚠️ same |
| Remembered disconnects · docked built-in display · ambient auto-brightness sync | ⚠️ implemented, not yet verified on hardware | ⚠️ same | ⚠️ same |
| Night Shift / OSD / PiP / EDID / profiles | ✅ | ✅ | ✅ |

Screen rotation on an external display is likewise implemented but unverified.

**True Tone works on macOS 27.** The matrix used to say the toggle *degrades*
there, on the strength of a note in Lunar's `CBTrueToneClient.h` that True Tone
stopped being controllable from third parties in macOS 26.3. Measured on
macOS 27.0.1 (built-in XDR panel, 2026-10-20): `available` is true, `enabled`
reads back, and `setEnabled:` round-trips — off reads back off, on reads back
on. FBD's toggle therefore works there; the macOS 26 cell is simply unmeasured.

\* The software boost overlay needs **Screen Recording** permission and combined
brightness mode enabled — with both in place, XDR upscaling works on macOS 27.

**A monitor's DDC brightness scale rarely reaches black.** The bottom of the
slider is usually a dead zone: the knob moves, the screen does not. The
below-floor blend splits the slider in two — above the threshold the hardware
carries the brightness exactly as before, below it the hardware is pinned at
the threshold and the software layer carries the rest as a multiplicative dim,
so the screen reaches what you asked for instead of stopping at the panel's
floor. The read-back reports the position you asked for, not the floor. It is
off by default, needs **Screen Recording** permission, and is applied per
display (Settings → the display's page).

**Built-in display disconnect is refused on base-M3 MacBooks.** On Macs with the
base M3 chip (M3 MacBook Air, entry-level M3 MacBook Pro) Apple repurposed the
built-in panel's connection to drive two external displays in clamshell mode; a
soft-disconnected built-in display may then not come back without a reboot. FBD
refuses to disconnect the built-in display on those Macs unless you set the
explicit override in Settings → Displays. BetterDisplay ships the same guard
(waydabber/BetterDisplay#4723).

**A disconnect can be remembered, and the built-in display can be parked.** Three
new behaviours, each off by default or opt-in per display:

- *Remembered disconnects* — a display you ask to keep off is disconnected again
  every time it comes back, after a reboot or a replug. Re-enabling it forgets
  the request.
- *Turn off the built-in display while an external display is attached* — the
  panel goes off so you work on the external screen. On a base-M3 MacBook this
  is refused before any call to the display API is made at all, because the
  panel may not come back without a reboot.
- *Follow the built-in display's auto-brightness* — an external monitor has no
  ambient sensor, so it can follow the built-in panel's, mapped through nits
  rather than by raw slider position.

None of the three has been exercised on real hardware yet: the machine this was
built on has no external display attached, so only the decisions they make are
tested — the hardware paths are not.

## Install

Releases are on the [GitHub Releases](https://github.com/FisiFla/FBD/releases) page. A
release asset named `FBD-unsigned.zip` (marked prerelease) is **not** signed or notarized:
macOS Gatekeeper will refuse to open it at first. Either right-click `FBD.app` →
**Open** → **Open**, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/FBD.app
```

Signed, notarized builds (`FBD.zip`) open normally. FBD asks for these permissions, each only
for the feature that needs it:

| Permission | Needed for |
|---|---|
| Screen Recording | software brightness boost (XDR fallback), full-screen filters, picture-in-picture and streaming (ScreenCaptureKit) |
| Accessibility | media-key interception (off by default) and `make ui-smoke` |
| Local Network | controlling TVs/AVRs over the network (LG, Samsung, Philips, Yamaha) |

Nothing is granted automatically; features whose permission is missing stay off.

## Requirements

- macOS 13.2+ (Apple Silicon preferred; DDC requires native arm64)
- Xcode 15+ (Swift 5.9+)

## Build & run

```bash
make build        # debug, native arch
make test         # unit tests
make app          # release universal FBD.app → build/FBD.app
open build/FBD.app
```

`make ui-smoke` drives the real panel via Accessibility/CGEvent (status-item
click → brightness slider → Settings → Back → close); needs Accessibility
permission for your terminal.

`fbdcli` (command-line interface) is built alongside:

```bash
swift run fbdcli list                 # displays
swift run fbdcli brightness 1 60      # set display 1 to 60%
swift run fbdcli filter 1 1 0 1 1     # full-screen filter (contrast sat gamma temp)
swift run fbdcli filter 1 1 1 1 1 --sharpness 2 --zoom 1.5   # sharpen + zoom
swift run fbdcli filter 1 1 1 1 1 --lut ~/LUTs/grade.cube     # custom 3D LUT
swift run fbdcli rotate 3 90          # rotate an external display
swift run fbdcli settings             # masked settings dump (for bug reports)
swift run fbdcli report               # detailed per-display report (for bug reports)
swift run fbdcli config show          # lock dim, keyboard target, groups, brightness model…
swift run fbdcli config device add "Living room TV" lg 192.168.0.50
swift run fbdcli hidpi 3 status        # scaled-mode ladder for display 3
swift run fbdcli hidpi 3 install       # install it (macOS asks for an admin password)
swift run fbdcli gamma-floor 3 on 15   # reach the bottom of the slider in software
swift run fbdcli display 3 disconnect --remember   # keep it off when it comes back
```

`fbdcli help` lists all commands; `--direct` forces local execution instead of routing
through the app's HTTP API.

## Shell completion (zsh)

```sh
mkdir -p ~/.zfunc
cp completions/_fbdcli ~/.zfunc/
echo 'fpath=(~/.zfunc $fpath); autoload -Uz compinit && compinit' >> ~/.zshrc
```

## Agent skill

`fbdcli` ships an agent-ready skill: a `SKILL.md` that teaches an agent the CLI's grammar, the
token model and the read-back contract.

```sh
fbdcli skill install claude            # ~/.claude/skills/fbd/SKILL.md
fbdcli skill install codex              # ~/.codex/skills/fbd/SKILL.md
fbdcli skill install claude --path DIR # a directory of your choice
fbdcli skill install claude --print    # dump the file to stdout instead of writing it
```

The document is compiled into the binary — it is never assembled by running the CLI and reading
its help output — so `--print` and the installed file are byte-for-byte the same. The install
overwrites the file, so re-running it after an upgrade refreshes the skill in place.

Two rules the skill teaches an agent:

- **the token is a secret** — `fbdcli auth-token` explains how to obtain it and `--reveal`
  prints it; an agent never needs it, because `fbdcli` sends it itself.
- **a write that was not confirmed is not a failed write** — when the app's answer is lost the
  CLI prints *the command may have applied* and names the command that reads the state back
  (exit code `75`). Repeating such a write blindly would apply the change twice.

## HTTP control API

The app exposes a JSON API on `127.0.0.1` only (`fbdcli http on <port>`, default 8765 —
applies live, no restart). All requests must send the local API token:

```sh
fbdcli auth-token --reveal  # print the token (a secret — keep it out of logs and chats)
TOKEN=$(fbdcli auth-token --reveal)
curl -H "X-FBD-Token: $TOKEN" http://127.0.0.1:8765/api/displays
# or: curl -H "Authorization: Bearer $TOKEN" ...
```

Without `--reveal`, `fbdcli auth-token` only explains how to obtain the token — it never
prints the secret itself.

`fbdcli` sends the token automatically (single driver — writes go through the app so the
CLI never races the DDC bus). CORS is enabled for web clients (`OPTIONS` → 204);
`GET /api/health` is the one unauthenticated endpoint.

Alongside `/api/displays`, `/api/virtual` and `/api/system`, a `/api/config` namespace
covers the settings surfaces: lock-dim, the keyboard control target, connection management,
per-display protection, resolution favourites, named display presets and the saved device
registry. `GET
/api/config` reports them all; writes are `POST /api/config/<what>` with a JSON body, and a
refusal names the valid values rather than ignoring the request.

A display's own settings are written with `POST /api/displays/<id>/<action>` and a JSON body:
`brightness`, `contrast`, `volume`, `mute`, `input`, `mode`, `xdr`, `rotate` and `filter`, plus
`disconnect` / `reconnect` (with `{"remember": true}` to keep a display off when it comes
back), `hidpi` (`{"operation": "install" | "remove" | "status"}`) and `gamma-floor`
(`{"enabled": true, "threshold": 0.15}`). The CLI, the HTTP API and the Shortcuts actions all
drive the same controller, so they cannot drift apart.

## DDC on Apple Silicon

DDC/CI uses the private IOKit `IOAVService` I2C transport, which exists only on Apple
Silicon — **DDC does not work under Rosetta** (disabled with a warning) and is not
supported on Intel Macs.

## URL scheme & media keys

- `fbd://open` opens the settings panel (handy for Shortcuts / quick-launch
  tools; `fbd://open` is also what the CLI's `http` status hints at).
- `fbd://close` closes the settings panel that `fbd://open` shows.
- `fbd://brightness/<displayID>/<value>` (0…1) changes brightness, but now
  requires the local API token as `?token=<httpAPIToken>` (see above). Writes
  without a matching token are refused.
- Media-key interception (F1/F2, F10–F12 mapped to external-display
  brightness/volume) is **off by default** — enable it explicitly in
  Settings → General ("Intercept media keys"). It requires Accessibility
  permission and only affects keys when FBD is running.

## Docs

Roadmap: [docs/ROADMAP.md](docs/ROADMAP.md) · Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
· Private APIs: [docs/PRIVATE_APIS.md](docs/PRIVATE_APIS.md) · DDC audit: [docs/ddc-equivalence.md](docs/ddc-equivalence.md)
· Changes: [CHANGELOG.md](CHANGELOG.md)
· Releasing: [RELEASING.md](RELEASING.md) · Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)

## License

MIT — see [LICENSE](LICENSE). This project is an independent implementation based on
public documentation and observable behaviour; it is not affiliated with BetterDisplay or
its author.
