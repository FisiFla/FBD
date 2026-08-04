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
  constant-time comparison.
- Secrets: never commit `.env` files or tokens; the repo gitignores them.
- Private-API usage: every private symbol is a forward-compatibility risk —
  see `docs/PRIVATE_APIS.md`.

## Scope

This policy covers the FBD app, `fbdcli`, and the release workflows. It does
not cover macOS itself or third-party frameworks (Sparkle, SkyLight).
