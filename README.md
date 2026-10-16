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

## Feature matrix by macOS version

| Feature | macOS 13–15 | macOS 26 | macOS 27 |
|---|---|---|---|
| Apple brightness / resolution | ✅ | ✅ | ✅ |
| DDC/CI (external displays, Apple Silicon) | ⚠️ implemented, not yet verified on hardware ([#7](https://github.com/FisiFla/FBD/issues/7)) | ⚠️ same | ⚠️ same |
| Virtual displays | ⚠️ `CGVirtualDisplay` (dlopen; implemented, unverified) | ✅ `SLVirtualDisplay` | ✅ `SLVirtualDisplay` (live-verified) |
| XDR upscaling (native preset rewrite) | ✅ | ✅ | ⚠️ rewrite write-protected → software boost*; preset switching ✅ |
| True Tone toggle | ✅ | ⚠️ | ⚠️ degrades |
| Night Shift / OSD / PiP / EDID / profiles | ✅ | ✅ | ✅ |

Screen rotation on an external display is likewise implemented but unverified.

\* The software boost overlay needs **Screen Recording** permission and combined
brightness mode enabled — with both in place, XDR upscaling works on macOS 27.

**Built-in display disconnect is refused on base-M3 MacBooks.** On Macs with the
base M3 chip (M3 MacBook Air, entry-level M3 MacBook Pro) Apple repurposed the
built-in panel's connection to drive two external displays in clamshell mode; a
soft-disconnected built-in display may then not come back without a reboot. FBD
refuses to disconnect the built-in display on those Macs unless you set the
explicit override in Settings → Displays. BetterDisplay ships the same guard
(waydabber/BetterDisplay#4723).

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
```

`fbdcli help` lists all commands; `--direct` forces local execution instead of routing
through the app's HTTP API.

## Shell completion (zsh)

```sh
mkdir -p ~/.zfunc
cp completions/_fbdcli ~/.zfunc/
echo 'fpath=(~/.zfunc $fpath); autoload -Uz compinit && compinit' >> ~/.zshrc
```

## HTTP control API

The app exposes a JSON API on `127.0.0.1` only (`fbdcli http on <port>`, default 8765 —
applies live, no restart). All requests must send the local API token:

```sh
fbdcli auth-token          # print the token
curl -H "X-FBD-Token: $TOKEN" http://127.0.0.1:8765/api/displays
# or: curl -H "Authorization: Bearer $TOKEN" ...
```

`fbdcli` sends the token automatically (single driver — writes go through the app so the
CLI never races the DDC bus). CORS is enabled for web clients (`OPTIONS` → 204);
`GET /api/health` is the one unauthenticated endpoint.

Alongside `/api/displays`, `/api/virtual` and `/api/system`, a `/api/config` namespace
covers the settings surfaces: lock-dim, the keyboard control target, connection management,
per-display protection, resolution favourites, named display presets and the saved device
registry. `GET
/api/config` reports them all; writes are `POST /api/config/<what>` with a JSON body, and a
refusal names the valid values rather than ignoring the request.

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
· Private APIs: [docs/PRIVATE_APIS.md](docs/PRIVATE_APIS.md) · Changes: [CHANGELOG.md](CHANGELOG.md)
· Releasing: [RELEASING.md](RELEASING.md) · Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)

## License

MIT — see [LICENSE](LICENSE). This project is an independent implementation based on
public documentation and observable behaviour; it is not affiliated with BetterDisplay or
its author.
