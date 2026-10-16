# Security Policy

FBD is a small MIT-licensed display utility; there is no dedicated security
team.

## Reporting a vulnerability

- **Public repo (issues):** open a GitHub issue at
  https://github.com/FisiFla/FBD/issues with `[security]` in the title.
  Do **not** include exploit details in a public issue — describe the
  affected area and how to reproduce privately instead.
- **Private disclosure:** email the maintainer via the address in the git
  history / release notes, or open a draft PR fixing the issue.

## What we care about

- The local HTTP API (`127.0.0.1`) auth token handling and its
  constant-time comparison. The token (and the LG TV pairing key) live in the
  login Keychain (generic password, service `dev.fisifla.fbd`, this-device-only),
  not in UserDefaults; token generation fails closed (no token = API refuses
  all requests). The server answers only to `Host: 127.0.0.1|localhost|[::1]:<port>`
  and rejects any request carrying an `Origin` header, and emits no CORS
  headers, to block DNS rebinding and browser access. Concurrent connections
  are capped.
- Automation scripts: `FBD_DISPLAY_NAME` comes from the monitor's EDID and is
  untrusted; it is restricted to letters, digits, space and `- _ . ( )` before
  being exported to shell rules.
- Secrets: never commit `.env` files or tokens; the repo gitignores them.
- Private-API usage: every private symbol is a forward-compatibility risk —
  see `docs/PRIVATE_APIS.md`.

## Scope

This policy covers the FBD app, `fbdcli`, and the release workflows. It does
not cover macOS itself or third-party frameworks (Sparkle, SkyLight).
