# FBD — Free Better Display

A free, MIT-licensed macOS menu-bar app for display control: brightness (Apple + DDC/CI),
volume, contrast, input switching, resolution/refresh-rate control, virtual displays,
XDR/HDR brightness upscaling, EDID overrides, and more.

**Goal: full feature parity with BetterDisplay — no Pro tier, no licensing, no telemetry.
Updates via Sparkle (optional).**

[![CI](https://github.com/FisiFla/FBD/actions/workflows/ci.yml/badge.svg)](https://github.com/FisiFla/FBD/actions/workflows/ci.yml)

> ⚠️ Early development. Tier 1 (core display control + DDC) is in progress.
> Roadmap: [docs/ROADMAP.md](docs/ROADMAP.md) · Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
> Private APIs: [docs/PRIVATE_APIS.md](docs/PRIVATE_APIS.md) · Changes: [CHANGELOG.md](CHANGELOG.md)
> Releasing: [RELEASING.md](RELEASING.md)

## Feature matrix by macOS version

Apple locks down private display APIs differently per release; FBD degrades
gracefully (feature off, UI notes it) when a path is unavailable.

| Feature | macOS 13–15 | macOS 26 | macOS 27 (beta) |
|---|---|---|---|
| Apple brightness / resolution / rotation | ✅ | ✅ | ✅ |
| DDC/CI (external displays, Apple Silicon) | ✅ | ✅ | ✅ |
| Virtual displays | ✅ `CGVirtualDisplay` (dlopen) | ✅ `SLVirtualDisplay` | ✅ `SLVirtualDisplay` (live-verified) |
| XDR upscaling (native preset rewrite) | ✅ | ✅ | ⚠️ rewrite write-protected → software boost*; preset switching ✅ |

*The software boost overlay needs **Screen Recording** permission (grant in
System Settings → Privacy & Security → Screen Recording) and combined
brightness mode enabled. With both in place, XDR upscaling works on macOS 27.
| XDR direct (IOMobileFramebuffer) | ✅ | ⚠️ | ❌ entitlement-gated (probe only) |
| True Tone toggle | ✅ | ⚠️ | ⚠️ degrades |
| Night Shift / OSD / PiP / EDID / profiles | ✅ | ✅ | ✅ |

## HTTP control API

The app exposes a JSON API on `127.0.0.1` only (port from `fbdcli http on
<port>`, default 8765). All requests must send the local API token:

```sh
fbdcli auth-token          # print the token
curl -H "X-FBD-Token: $TOKEN" http://127.0.0.1:8765/api/displays
# or: curl -H "Authorization: Bearer $TOKEN" ...
```

`fbdcli` sends the token automatically when the app is running (single
driver — writes go through the app so the CLI never races the DDC bus).
CORS is enabled (`*`) for web clients; `OPTIONS` preflight returns 204.
`GET /api/health` is the one unauthenticated endpoint (uptime checks).

## Requirements

- macOS 13.2+ (Apple Silicon preferred; DDC requires native arm64, see below)
- Xcode 15+ (Swift 5.9+)

## Build

```bash
make build        # debug, native arch
make test         # unit tests
make app          # release universal FBD.app → build/FBD.app
```

The app is a menu-bar (LSUIElement) app. Run the built bundle with:

```bash
open build/FBD.app
```

`fbdcli` (command-line interface) is built alongside:

```bash
swift run fbdcli list
swift run fbdcli set-brightness <display-id> 60
```

## Feature status

| Area | Status |
|---|---|
| Display enumeration + brightness (Apple displays) | Tier 1 — implemented |
| DDC/CI brightness, volume, contrast, input | Tier 1 — implemented (needs real hardware to verify) |
| DDC auto-configuration (capabilities VCP 0xF3) | Tier 1 — implemented |
| Resolution picker + HiDPI modes (CGS) | Tier 1 — implemented |
| Refresh rate / ProMotion / VRR detection | Tier 1 — implemented |
| Rotation · keyboard shortcuts · persistence | Tier 1 — implemented |
| XDR/HDR brightness upscaling (3 methods) | Tier 2 — planned |
| Virtual displays (CGVirtualDisplay + Sidecar fallback) | Tier 3 — planned |
| EDID export/parse/override | Tier 4 — planned |
| PiP / streaming / network TV control / App Intents | Tier 5 — planned |

## DDC on Apple Silicon

DDC/CI control uses the private IOKit `IOAVService` I2C transport, which exists only on
Apple Silicon — **DDC does not work under Rosetta** and is disabled there with a warning.
Intel Macs are not supported for DDC in Tier 1 (IOKit framebuffer I2C path is a later
tier).

## License

MIT — see [LICENSE](LICENSE). This project is an independent implementation based on
public documentation and binary analysis; it is not affiliated with BetterDisplay or
its author.
