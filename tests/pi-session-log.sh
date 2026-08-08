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
log_file=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --command)
      command_string="$2"
      shift 2
      ;;
    *)
      log_file="$1"
      shift
      ;;
  esac
done

if [[ "$log_file" != /dev/null ]]; then
  printf 'script transcript must be discarded instead of written to the workspace\n' >&2
  exit 1
fi

bash -c "$command_string"
FAKE_SCRIPT
chmod +x "$FAKE_BIN/script"

cat > "$FAKE_BIN/pi" <<'FAKE_PI'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$PI_SESSION_LOG_TEST_INVOCATION"
FAKE_PI
chmod +x "$FAKE_BIN/pi"

PI_SESSION_LOG_TEST_INVOCATION="$INVOCATION_LOG" \
PATH="$FAKE_BIN:$PATH" \
  bash "$ROOT/bin/pi-session-log" prompt

grep -Fqx -- 'prompt' "$INVOCATION_LOG"
printf 'pi session PTY tests passed\n'
