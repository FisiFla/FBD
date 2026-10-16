# 4. The CLI routes through the app's HTTP API (single bus owner)

Date: 2026-10-16

## Status

Accepted.

## Context

DDC/CI writes go over an I2C bus (`IOAVService`) that tolerates one driver at
a time: two processes issuing writes interleave transactions, and the app
also enforces a per-display cooldown and debounce that a second process cannot
see. `fbdcli` is a separate process that could drive the same hardware
directly.

## Decision

When `FBD.app` is running, `fbdcli` executes control commands by calling the
app's local HTTP API (127.0.0.1, token-authenticated), so the app is the only
process that touches the bus. The request mapping lives in
`HTTPRoutingPlanBuilder` (FBDCLIParser, unit-tested); `fbdcli` only executes
the plan and formats output.

Direct control is used only when the app is **not listening** (connection
refused / no published port), or when forced with `--direct`. If the app is up
but misbehaves, the CLI does not fall back:

- HTTP 401/403: exit 2 with an authentication message;
- timeout or other error: exit 2. A timed-out write is not retried directly,
  because the app may still apply it.

`--json` output exists only for `list` and `info`, in direct mode, so for
those two commands the flag selects direct execution; it does not change
routing for any other command.

## Consequences

- No bus contention and no double-applied writes while the app runs.
- Behaviour differs slightly between routed and direct output; the routed
  formatters mirror the direct style.
- The token (`fbdcli auth-token`) is required for any non-CLI HTTP client.
- Falling back silently on errors was rejected: it is exactly the
  double-apply and contention case this decision exists to prevent.
