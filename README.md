# FBD — Free Better Display

A free, MIT-licensed macOS menu-bar app for display control: brightness (Apple + DDC/CI),
volume, contrast, input switching, resolution/refresh-rate control, virtual displays,
XDR/HDR brightness upscaling, EDID overrides, and more.

**Goal: full feature parity with BetterDisplay — no Pro tier, no licensing, no telemetry.
Updates via Sparkle (optional).**

[![CI](https://github.com/FisiFla/FBD/actions/workflows/ci.yml/badge.svg)](https://github.com/FisiFla/FBD/actions/workflows/ci.yml)

> ⚠️ Early development. Tier 1 (core display control + DDC) is in progress.
> Roadmap: [docs/ROADMAP.md](docs/ROADMAP.md) · Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
> Private APIs: [docs/PRIVATE_APIS.md](docs/PRIVATE_APIS.md)

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
