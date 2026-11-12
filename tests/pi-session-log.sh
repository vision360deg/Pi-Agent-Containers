#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
INVOCATION_LOG="$TMP_DIR/pi-invocation.log"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/script" <<'FAKE_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$$" -ne "${PI_SESSION_LOG_PID:-0}" ]]; then
  printf 'script is not the foreground helper process\n' >&2
  exit 1
fi

command_string=''
transcript_file=''
log_out_file=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet|--flush|--return)
      shift
      ;;
    --command)
      command_string="$2"
      shift 2
      ;;
    --log-out)
      log_out_file="$2"
      shift 2
      ;;
    *)
      if [[ -n "$transcript_file" ]]; then
        printf 'script: unexpected number of arguments\n' >&2
        exit 1
      fi
      transcript_file="$1"
      shift
      ;;
  esac
done

if [[ -n "$log_out_file" && -n "$transcript_file" ]]; then
  printf 'script: unexpected number of arguments\n' >&2
  exit 1
fi

printf '%s\n' "$log_out_file" > "$PI_SESSION_LOG_SCRIPT_LOG"
if [[ -z "$log_out_file" && "$transcript_file" != /dev/null ]]; then
  printf 'script transcript must be discarded instead of written to the workspace\n' >&2
  exit 1
fi

# util-linux script runs the command through /bin/sh, which is dash in the
# image; parse it the same way.
"$PI_SESSION_LOG_TEST_SH" -c "$command_string"
FAKE_SCRIPT
chmod +x "$FAKE_BIN/script"

cat > "$FAKE_BIN/pi" <<'FAKE_PI'
#!/usr/bin/env bash
set -euo pipefail
: > "$PI_SESSION_LOG_TEST_INVOCATION"
for argument in "$@"; do
  printf 'arg=%s\n' "$argument" >> "$PI_SESSION_LOG_TEST_INVOCATION"
done
exit "${FAKE_PI_STATUS:-0}"
FAKE_PI
chmod +x "$FAKE_BIN/pi"
SCRIPT_OPTIONS_LOG="$TMP_DIR/script-options.log"
if command -v dash >/dev/null 2>&1; then
  TEST_SH="$(command -v dash)"
else
  TEST_SH=/bin/sh
fi

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

STATUS=0
run_log() {
  if PI_SESSION_LOG_SCRIPT_LOG="$SCRIPT_OPTIONS_LOG" \
    PI_SESSION_LOG_TEST_INVOCATION="$INVOCATION_LOG" \
    PI_SESSION_LOG_TEST_SH="$TEST_SH" \
    PATH="$FAKE_BIN:$PATH" \
    bash "$ROOT/bin/pi-session-log" "$@"; then STATUS=0; else STATUS=$?; fi
}

run_log prompt
[[ $STATUS == 0 ]] || fail "session-log status $STATUS"
[[ "$(cat "$INVOCATION_LOG")" == 'arg=prompt' ]] || fail "pi arguments: $(cat "$INVOCATION_LOG")"
[[ -z "$(cat "$SCRIPT_OPTIONS_LOG")" ]] || fail 'transcript must not be forwarded by default'

run_log --forward-output prompt
[[ "$(cat "$INVOCATION_LOG")" == 'arg=prompt' ]] || fail "forwarded pi arguments: $(cat "$INVOCATION_LOG")"
grep -Fqx -- '/proc/1/fd/1' "$SCRIPT_OPTIONS_LOG" || fail 'transcript must be forwarded to the service stdout'

# Arguments reach Pi unchanged through /bin/sh, including quotes, shell
# syntax, empty arguments, and multi-line prompts.
run_log "it's two words" '$(touch /tmp/never)' ';' '' $'first line\nsecond line' $'tab\there'
[[ $STATUS == 0 ]] || fail "quoted session-log status $STATUS"
expected=$'arg=it\'s two words\narg=$(touch /tmp/never)\narg=;\narg=\narg=first line\nsecond line\narg=tab\there'
[[ "$(cat "$INVOCATION_LOG")" == "$expected" ]] || fail "quoted pi arguments:"$'\n'"$(cat "$INVOCATION_LOG")"

# Pi's exit status is returned.
FAKE_PI_STATUS=4 run_log
[[ $STATUS == 4 ]] || fail "pi status must propagate, got $STATUS"

printf 'pi session PTY tests passed\n'
