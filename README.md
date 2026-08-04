# FBD — Free Better Display

A free, MIT-licensed macOS menu-bar app for display control: brightness (Apple + DDC/CI),
volume, contrast, input switching, resolution/refresh-rate control, virtual displays,
XDR/HDR brightness upscaling, full-screen software filters (contrast, saturation,
gamma, color temperature, invert), screen rotation, EDID overrides, and more.

**Goal: full feature parity with BetterDisplay — no Pro tier, no licensing, no telemetry.
Updates via Sparkle (optional).**

[![CI](https://github.com/FisiFla/FBD/actions/workflows/ci.yml/badge.svg)](https://github.com/FisiFla/FBD/actions/workflows/ci.yml)

All feature tiers are implemented (268 unit tests, CI green per push). Apple locks down
private display APIs differently per macOS release; FBD degrades gracefully (feature off,
UI notes it) when a path is unavailable.

## Feature matrix by macOS version

| Feature | macOS 13–15 | macOS 26 | macOS 27 (beta) |
|---|---|---|---|
| Apple brightness / resolution | ✅ | ✅ | ✅ |
| DDC/CI (external displays, Apple Silicon) | ✅ | ✅ | ✅ |
| Virtual displays | ✅ `CGVirtualDisplay` (dlopen) | ✅ `SLVirtualDisplay` | ✅ `SLVirtualDisplay` (live-verified) |
| XDR upscaling (native preset rewrite) | ✅ | ✅ | ⚠️ rewrite write-protected → software boost*; preset switching ✅ |
| True Tone toggle | ✅ | ⚠️ | ⚠️ degrades |
| Night Shift / OSD / PiP / EDID / profiles | ✅ | ✅ | ✅ |

\* The software boost overlay needs **Screen Recording** permission and combined
brightness mode enabled — with both in place, XDR upscaling works on macOS 27.

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
```

`fbdcli` (command-line interface) is built alongside:

```bash
swift run fbdcli list                 # displays
swift run fbdcli brightness 1 60      # set display 1 to 60%
swift run fbdcli filter 1 1 0 1 1     # full-screen filter (contrast sat gamma temp)
swift run fbdcli rotate 3 90          # rotate an external display
swift run fbdcli settings             # masked settings dump (for bug reports)
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

## DDC on Apple Silicon

DDC/CI uses the private IOKit `IOAVService` I2C transport, which exists only on Apple
Silicon — **DDC does not work under Rosetta** (disabled with a warning) and is not
supported on Intel Macs.

## Docs

Roadmap: [docs/ROADMAP.md](docs/ROADMAP.md) · Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
· Private APIs: [docs/PRIVATE_APIS.md](docs/PRIVATE_APIS.md) · Changes: [CHANGELOG.md](CHANGELOG.md)
· Releasing: [RELEASING.md](RELEASING.md)

## License

MIT — see [LICENSE](LICENSE). This project is an independent implementation based on
public documentation and binary analysis; it is not affiliated with BetterDisplay or
its author.
