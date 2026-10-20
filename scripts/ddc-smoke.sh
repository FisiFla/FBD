#!/bin/bash
# FBD DDC/CI smoke test — exercises the real DDC path against attached hardware.
#
# What it does:
#   1. enumerates the attached displays through the app's *own* matching layer
#      (`fbdcli list --json` → DisplayController → ExternalController →
#      IOAVServiceAPI), so a display paired to the wrong DDC channel shows up
#      as a wrong answer instead of being quietly skipped
#   2. for every DDC-capable display: parses its EDID, parses its capabilities
#      string, and reads brightness, contrast and volume
#   3. optionally round-trips one write per feature and restores the original
#      value
#
# Read-only by default. Nothing is written to a display unless --write-test is
# given, and even then only one step per feature — with the original value
# restored afterwards, and restored again if the script is interrupted.
#
# The output shape follows `fbdcli list` / `fbdcli xdr`: aligned columns, so the
# table can be pasted straight into issue #7.
#
# Usage:
#   bash scripts/ddc-smoke.sh [--json] [--write-test] [--write-all] [--ledger]
#
#   --json        machine-readable output (the evidence format)
#   --write-test  one set-and-read-back round trip per display (brightness)
#   --write-all   also round-trip contrast and volume (needs --write-test)
#   --ledger      append the timestamped evidence block to docs/PRIVATE_APIS.md
#
# Exit 0 = every check passed or was skipped; 1 = a check failed.
#
# Requirements: an external DDC display attached (the built-in panel has no DDC
# channel), and this checkout's `fbdcli` buildable with `swift build`.

set -u
cd "$(dirname "$0")/.." || exit 1

JSON=0
WRITE_TEST=0
WRITE_ALL=0
LEDGER=0

usage() {
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --json) JSON=1 ;;
        --write-test) WRITE_TEST=1 ;;
        --write-all) WRITE_ALL=1 ;;
        --ledger) LEDGER=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ddc-smoke: unknown argument '$1' (try --help)" >&2; exit 1 ;;
    esac
    shift
done

if [ "$WRITE_ALL" -eq 1 ] && [ "$WRITE_TEST" -eq 0 ]; then
    echo "ddc-smoke: --write-all needs --write-test" >&2
    exit 1
fi

CLI=".build/debug/fbdcli"
LEDGER_FILE="docs/PRIVATE_APIS.md"
RESULT_FILE=""
ALL_RESULTS_FILE=""
JSON_FILE=""
PASS=0
FAIL=0
SKIP=0
HOST_OS="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
HOST_ARCH="$(uname -m)"
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

cleanup() {
    # A write test that was interrupted must still put the display back.
    if [ -n "${RESTORE_ID:-}" ] && [ -n "${RESTORE_VALUE:-}" ]; then
        "$CLI" "$RESTORE_CMD" "$RESTORE_ID" "$RESTORE_VALUE" >/dev/null 2>&1
        RESTORE_ID=""
    fi
    [ -n "$RESULT_FILE" ] && rm -f "$RESULT_FILE"
    [ -n "$ALL_RESULTS_FILE" ] && rm -f "$ALL_RESULTS_FILE"
    [ -n "$JSON_FILE" ] && rm -f "$JSON_FILE"
}
trap cleanup EXIT INT TERM

now() { perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()'; }
elapsed_ms() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.0f", (b - a) * 1000 }'; }

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\r\t' '   '
}

# Escape a value for a markdown table cell.
md_escape() {
    printf '%s' "$1" | sed -e 's/|/\\|/g' | tr '\n\r' '  '
}

# Record one check: name, status (pass/fail/skip), duration in ms, detail.
record() {
    printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$(printf '%s' "$4" | tr '\n\r' '  ')" >> "$RESULT_FILE"
    case "$2" in
        pass) PASS=$((PASS + 1)) ;;
        fail) FAIL=$((FAIL + 1)) ;;
        *) SKIP=$((SKIP + 1)) ;;
    esac
}

# Run fbdcli, capture its output, exit code and duration. The notice about
# falling back to the direct controllers is not part of the answer.
CHECK_OUT=""
CHECK_RC=0
CHECK_MS=0
run_cli() {
    local t0 t1 out rc
    t0="$(now)"
    out="$("$CLI" "$@" 2>&1)"
    rc=$?
    t1="$(now)"
    CHECK_OUT="$(printf '%s\n' "$out" | grep -v '^fbdcli: app HTTP API not available' | sed '/^[[:space:]]*$/d')"
    CHECK_RC=$rc
    CHECK_MS="$(elapsed_ms "$t0" "$t1")"
}

is_number() { printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; }

# The last number in the output — `fbdcli brightness 1` prints "48.9",
# `fbdcli brightness 1 50` prints "brightness 1 = 50.0".
last_number() {
    printf '%s\n' "$1" | grep -Eo '[0-9]+(\.[0-9]+)?' | tail -1
}

# True when the capabilities string advertises a VCP code.
caps_contain() { printf '%s' "$1" | grep -qiw "$2"; }

# One step from the current value, at a value that is safe to leave the
# display at for a moment.
one_step() {
    awk -v v="$1" 'BEGIN {
        if (v + 10 <= 95) t = v + 10;
        else if (v - 10 >= 5) t = v - 10;
        else t = 50;
        printf "%.0f", t;
    }'
}

# ---------------------------------------------------------------------------
# Build and enumerate
# ---------------------------------------------------------------------------

if [ ! -x "$CLI" ]; then
    echo "[setup] building fbdcli"
    BUILD_LOG="$(mktemp)"
    if ! swift build --disable-sandbox > "$BUILD_LOG" 2>&1; then
        grep -E "error:" "$BUILD_LOG" | head -20 >&2
        rm -f "$BUILD_LOG"
        echo "FATAL: swift build failed" >&2
        exit 1
    fi
    rm -f "$BUILD_LOG"
fi
if [ ! -x "$CLI" ]; then
    echo "FATAL: $CLI not found after a successful build" >&2
    exit 1
fi

LIST_JSON="$("$CLI" list --json 2>/dev/null)"
if [ -z "$LIST_JSON" ]; then
    echo "FATAL: 'fbdcli list --json' produced no output" >&2
    exit 1
fi

DISPLAY_COUNT="$(printf '%s' "$LIST_JSON" | plutil -extract displays raw -o - - 2>/dev/null)"
case "$DISPLAY_COUNT" in
    ''|*[!0-9]*) DISPLAY_COUNT=0 ;;
esac

RESULT_FILE="$(mktemp)"
ALL_RESULTS_FILE="$(mktemp)"
JSON_FILE="$(mktemp)"

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

# One write-and-read-back round trip for a feature: read the current value,
# write one step, read it back, restore the original value, read it back again.
write_roundtrip() {
    local label="$1" cmd="$2" code="$3" id="$4" caps="$5"
    if [ -n "$caps" ] && ! caps_contain "$caps" "$code"; then
        record "write-$label" "skip" 0 "not advertised by the display"
        return
    fi

    run_cli "$cmd" "$id"
    if [ "$CHECK_RC" -ne 0 ]; then
        record "write-$label" "fail" "$CHECK_MS" "current value unreadable"
        return
    fi
    local before
    before="$(last_number "$CHECK_OUT")"
    if ! is_number "$before"; then
        record "write-$label" "fail" "$CHECK_MS" "current value unreadable"
        return
    fi

    # Remember how to put the display back, even if this script dies halfway.
    RESTORE_ID="$id"
    RESTORE_CMD="$cmd"
    RESTORE_VALUE="$before"

    local target
    target="$(one_step "$before")"

    run_cli "$cmd" "$id" "$target"
    if [ "$CHECK_RC" -ne 0 ]; then
        record "write-$label" "fail" "$CHECK_MS" "write rejected (target $target)"
        "$CLI" "$cmd" "$id" "$before" >/dev/null 2>&1
        RESTORE_ID=""
        return
    fi

    run_cli "$cmd" "$id"
    local mid
    mid="$(last_number "$CHECK_OUT")"
    if ! is_number "$mid"; then
        record "write-$label" "fail" "$CHECK_MS" "no read-back after the write"
    elif awk -v a="$mid" -v b="$target" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 3) }'; then
        record "write-$label" "pass" "$CHECK_MS" "$before -> $target -> $mid"
    else
        record "write-$label" "fail" "$CHECK_MS" "wrote $target, read back $mid"
    fi

    # Restore, and prove the restore landed.
    run_cli "$cmd" "$id" "$before"
    local after
    after="$(last_number "$CHECK_OUT")"
    if ! is_number "$after"; then
        record "restore-$label" "fail" "$CHECK_MS" "no read-back after the restore"
    elif awk -v a="$after" -v b="$before" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 3) }'; then
        record "restore-$label" "pass" "$CHECK_MS" "restored $before"
    else
        record "restore-$label" "fail" "$CHECK_MS" "restored $before, read back $after"
    fi
    RESTORE_ID=""
}

DDC_DISPLAY_COUNT=0
INDEX=0
while [ "$INDEX" -lt "$DISPLAY_COUNT" ]; do
    ID="$(printf '%s' "$LIST_JSON" | plutil -extract "displays.$INDEX.id" raw -o - - 2>/dev/null)"
    NAME="$(printf '%s' "$LIST_JSON" | plutil -extract "displays.$INDEX.name" raw -o - - 2>/dev/null)"
    HAS_DDC="$(printf '%s' "$LIST_JSON" | plutil -extract "displays.$INDEX.ddc" raw -o - - 2>/dev/null)"
    INDEX=$((INDEX + 1))
    [ -n "$ID" ] || continue
    [ "$HAS_DDC" = "true" ] || continue

    DDC_DISPLAY_COUNT=$((DDC_DISPLAY_COUNT + 1))
    : > "$RESULT_FILE"

    # EDID — a sibling path rather than DDC itself, but a display whose EDID
    # cannot be parsed is a display FBD cannot describe.
    run_cli edid export "$ID"
    if [ "$CHECK_RC" -ne 0 ]; then
        record "edid" "skip" "$CHECK_MS" "no EDID available"
    elif printf '%s' "$CHECK_OUT" | grep -q 'could not parse EDID'; then
        record "edid" "fail" "$CHECK_MS" "EDID did not parse"
    else
        EDID_BYTES="$(printf '%s\n' "$CHECK_OUT" | sed -n 's/.*EDID (\([0-9]*\) bytes).*/\1/p' | head -1)"
        record "edid" "pass" "$CHECK_MS" "${EDID_BYTES:-?} bytes"
    fi

    # Capabilities — the string that says which VCP codes the display has.
    CAPS=""
    run_cli caps "$ID"
    if [ "$CHECK_RC" -eq 0 ]; then
        CAPS="$(printf '%s\n' "$CHECK_OUT" | sed -n 's/^ *vcp codes ([0-9]*): *//p' | head -1)"
        CAPS_COUNT="$(printf '%s\n' "$CHECK_OUT" | sed -n 's/^ *vcp codes (\([0-9]*\)).*/\1/p' | head -1)"
        MCCS="$(printf '%s\n' "$CHECK_OUT" | sed -n 's/^ *mccs version: *//p' | head -1)"
        record "capabilities" "pass" "$CHECK_MS" "mccs ${MCCS:-unknown}, ${CAPS_COUNT:-?} vcp codes"
    else
        record "capabilities" "fail" "$CHECK_MS" "capabilities read failed"
    fi

    # The three continuous features. A feature the display does not advertise
    # is skipped, not failed: the transport works, the feature is absent.
    run_cli brightness "$ID"
    if [ "$CHECK_RC" -eq 0 ] && is_number "$(last_number "$CHECK_OUT")"; then
        record "brightness" "pass" "$CHECK_MS" "$(last_number "$CHECK_OUT")%"
    elif [ -n "$CAPS" ] && ! caps_contain "$CAPS" "0x10"; then
        record "brightness" "skip" "$CHECK_MS" "not advertised by the display"
    else
        record "brightness" "fail" "$CHECK_MS" "read failed"
    fi

    run_cli contrast "$ID"
    if [ "$CHECK_RC" -eq 0 ] && is_number "$(last_number "$CHECK_OUT")"; then
        record "contrast" "pass" "$CHECK_MS" "$(last_number "$CHECK_OUT")%"
    elif [ -n "$CAPS" ] && ! caps_contain "$CAPS" "0x12"; then
        record "contrast" "skip" "$CHECK_MS" "not advertised by the display"
    else
        record "contrast" "fail" "$CHECK_MS" "read failed"
    fi

    run_cli volume "$ID"
    if [ "$CHECK_RC" -eq 0 ] && is_number "$(last_number "$CHECK_OUT")"; then
        record "volume" "pass" "$CHECK_MS" "$(last_number "$CHECK_OUT")%"
    elif [ -n "$CAPS" ] && ! caps_contain "$CAPS" "0x62"; then
        record "volume" "skip" "$CHECK_MS" "not advertised by the display"
    else
        record "volume" "fail" "$CHECK_MS" "read failed"
    fi

    if [ "$WRITE_TEST" -eq 1 ]; then
        write_roundtrip "brightness" "brightness" "0x10" "$ID" "$CAPS"
        if [ "$WRITE_ALL" -eq 1 ]; then
            write_roundtrip "contrast" "contrast" "0x12" "$ID" "$CAPS"
            write_roundtrip "volume" "volume" "0x62" "$ID" "$CAPS"
        fi
    fi

    # Per-display JSON fragment.
    {
        printf '    {\n'
        printf '      "id": %s,\n' "$ID"
        printf '      "name": "%s",\n' "$(json_escape "$NAME")"
        printf '      "checks": [\n'
        FIRST=1
        while IFS='|' read -r CHECK_NAME CHECK_STATUS CHECK_TIME CHECK_DETAIL; do
            [ -n "$CHECK_NAME" ] || continue
            if [ "$FIRST" -eq 0 ]; then printf ',\n'; fi
            FIRST=0
            printf '        { "name": "%s", "status": "%s", "ms": %s, "detail": "%s" }' \
                "$(json_escape "$CHECK_NAME")" "$CHECK_STATUS" "$CHECK_TIME" "$(json_escape "$CHECK_DETAIL")"
        done < "$RESULT_FILE"
        printf '\n      ]\n'
        printf '    }'
    } > "$JSON_FILE.frag"
    if [ -s "$JSON_FILE" ]; then printf ',\n' >> "$JSON_FILE"; fi
    cat "$JSON_FILE.frag" >> "$JSON_FILE"
    rm -f "$JSON_FILE.frag"

    # The whole run, for the evidence block.
    while IFS='|' read -r CHECK_NAME CHECK_STATUS CHECK_TIME CHECK_DETAIL; do
        [ -n "$CHECK_NAME" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$ID" "$NAME" "$CHECK_NAME" "$CHECK_STATUS" "$CHECK_TIME" "$CHECK_DETAIL" >> "$ALL_RESULTS_FILE"
    done < "$RESULT_FILE"

    if [ "$JSON" -eq 0 ]; then
        printf 'display %s — %s\n' "$ID" "$NAME"
        while IFS='|' read -r CHECK_NAME CHECK_STATUS CHECK_TIME CHECK_DETAIL; do
            [ -n "$CHECK_NAME" ] || continue
            printf '  %-14s %-6s %6s ms   %s\n' \
                "$CHECK_NAME" \
                "$(printf '%s' "$CHECK_STATUS" | tr '[:lower:]' '[:upper:]')" \
                "$CHECK_TIME" "$CHECK_DETAIL"
        done < "$RESULT_FILE"
        printf '\n'
    fi
done

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

emit_json() {
    printf '{\n'
    printf '  "tool": "fbd-ddc-smoke",\n'
    printf '  "schema": 1,\n'
    printf '  "timestamp": "%s",\n' "$TIMESTAMP"
    printf '  "host": { "os": "%s", "arch": "%s" },\n' "$(json_escape "$HOST_OS")" "$HOST_ARCH"
    printf '  "enumeration": "fbdcli list --json (DisplayController -> ExternalController -> IOAVServiceAPI)",\n'
    printf '  "displays": [\n'
    cat "$JSON_FILE"
    printf '\n  ],\n'
    printf '  "summary": { "passed": %d, "failed": %d, "skipped": %d }\n' "$PASS" "$FAIL" "$SKIP"
    printf '}\n'
}

if [ "$DDC_DISPLAY_COUNT" -eq 0 ]; then
    if [ "$JSON" -eq 1 ]; then
        printf '{\n'
        printf '  "tool": "fbd-ddc-smoke",\n'
        printf '  "schema": 1,\n'
        printf '  "timestamp": "%s",\n' "$TIMESTAMP"
        printf '  "host": { "os": "%s", "arch": "%s" },\n' "$(json_escape "$HOST_OS")" "$HOST_ARCH"
        printf '  "displays": [],\n'
        printf '  "summary": { "passed": 0, "failed": 0, "skipped": 0, "note": "no DDC-capable display attached" }\n'
        printf '}\n'
    else
        echo "no DDC-capable display attached — all checks skipped"
        echo "ddc-smoke: 0 passed, 0 failed, 0 skipped"
    fi
    exit 0
fi

if [ "$JSON" -eq 1 ]; then
    emit_json
else
    echo "ddc-smoke: $PASS passed, $FAIL failed, $SKIP skipped"
fi

# ---------------------------------------------------------------------------
# The evidence block
# ---------------------------------------------------------------------------

if [ "$LEDGER" -eq 1 ]; then
    if [ ! -f "$LEDGER_FILE" ]; then
        echo "ddc-smoke: $LEDGER_FILE not found" >&2
        exit 1
    fi
    BLOCK="$(mktemp)"
    {
        printf '## DDC/CI smoke evidence — %s\n\n' "$TIMESTAMP"
        printf "Generated by \`scripts/ddc-smoke.sh\` on macOS %s (%s, native — the DDC path\n" "$HOST_OS" "$HOST_ARCH"
        printf "does not work under Rosetta). Displays are enumerated through the app's own matching\n"
        printf "layer (\`fbdcli list --json\`), so a display paired to the wrong DDC channel shows up\n"
        printf "here as a wrong answer rather than as a missing row.\n\n"
        printf '| display | check | result | ms | detail |\n'
        printf '|---|---|---|---|---|\n'
        while IFS=$'\t' read -r ROW_ID ROW_NAME ROW_CHECK ROW_STATUS ROW_TIME ROW_DETAIL; do
            [ -n "$ROW_CHECK" ] || continue
            printf '| %s (%s) | %s | %s | %s | %s |\n' \
                "$ROW_ID" "$(md_escape "$ROW_NAME")" "$(md_escape "$ROW_CHECK")" \
                "$(printf '%s' "$ROW_STATUS" | tr '[:lower:]' '[:upper:]')" "$ROW_TIME" \
                "$(md_escape "$ROW_DETAIL")"
        done < "$ALL_RESULTS_FILE"
        printf "\n\`ddc-smoke: %s passed, %s failed, %s skipped\`\n\n" "$PASS" "$FAIL" "$SKIP"
        printf 'This is evidence that the DDC path answered on this machine and this display —\n'
        printf 'not a claim that it answers on every display. The code-level audit is in\n'
        printf "\`docs/ddc-equivalence.md\`.\n"
    } > "$BLOCK"

    TMP_LEDGER="$(mktemp)"
    awk -v blockfile="$BLOCK" '
        /^## Notes$/ && !done {
            while ((getline line < blockfile) > 0) print line
            print ""
            done = 1
        }
        { print }
    ' "$LEDGER_FILE" > "$TMP_LEDGER"
    if [ ! -s "$TMP_LEDGER" ]; then
        cat "$BLOCK" >> "$LEDGER_FILE"
    else
        cp "$TMP_LEDGER" "$LEDGER_FILE"
    fi
    rm -f "$TMP_LEDGER" "$BLOCK"
    echo "ddc-smoke: evidence block appended to $LEDGER_FILE"
fi

[ "$FAIL" -eq 0 ]
