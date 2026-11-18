#!/usr/bin/env bash
# bin/pi-session-format: rendering Pi session JSONL as pretty, plain, and raw output.
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"

INPUT="$TMP_DIR/input.jsonl"
PRETTY="$TMP_DIR/pretty.log"
PLAIN="$TMP_DIR/plain.log"
RAW="$TMP_DIR/raw.log"

cat > "$INPUT" <<'EOF'
{"type":"message","timestamp":"2026-08-08T19:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"Inspect this project"}]}}
{"type":"message","timestamp":"2026-08-08T19:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"I will inspect it."}]}}
{"type":"message","timestamp":"2026-08-08T19:00:03.000Z","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"git status"}}]}}
{"type":"message","timestamp":"2026-08-08T19:00:04.000Z","message":{"role":"bashExecution","command":"git status","output":"working tree clean","exitCode":0}}
{"type":"message","timestamp":"2026-08-08T19:00:05.000Z","message":{"role":"toolResult","toolName":"bash","isError":false,"content":[{"type":"text","text":"working tree clean"}]}}
{"type":"model_change","timestamp":"2026-08-08T19:00:06.000Z","provider":"openai-codex","modelId":"gpt-5.6"}
EOF

PI_SESSION_LOG_FORMAT=pretty PI_SESSION_LOG_COLOR=always \
  bash "$ROOT/bin/pi-session-format" < "$INPUT" > "$PRETTY"

grep -Fq -- $'\033[36m' "$PRETTY"
grep -Fq -- 'USER' "$PRETTY"
grep -Fq -- 'Inspect this project' "$PRETTY"
grep -Fq -- 'ASSISTANT' "$PRETTY"
grep -Fq -- 'TOOL' "$PRETTY"
grep -Fq -- 'bash' "$PRETTY"
grep -Fq -- 'COMMAND' "$PRETTY"
grep -Fq -- 'RESULT' "$PRETTY"
grep -Fq -- 'MODEL' "$PRETTY"

PI_SESSION_LOG_FORMAT=pretty PI_SESSION_LOG_COLOR=never \
  bash "$ROOT/bin/pi-session-format" < "$INPUT" > "$PLAIN"
if grep -Fq -- $'\033[' "$PLAIN"; then
  fail 'plain pretty output unexpectedly contains ANSI color codes'
fi

# Color is on by default.
PI_SESSION_LOG_FORMAT=pretty bash "$ROOT/bin/pi-session-format" < "$INPUT" > "$TMP_DIR/default.log"
grep -Fq -- $'\033[36m' "$TMP_DIR/default.log" || fail 'color must be on by default'

# Auto colors only a terminal; this output is a file.
PI_SESSION_LOG_FORMAT=pretty PI_SESSION_LOG_COLOR=auto \
  bash "$ROOT/bin/pi-session-format" < "$INPUT" > "$TMP_DIR/auto.log"
cmp -s "$PLAIN" "$TMP_DIR/auto.log" || fail 'auto color mode on a non-terminal must match plain output'

# An unsupported color mode is refused before any output.
if PI_SESSION_LOG_COLOR=sometimes bash "$ROOT/bin/pi-session-format" < "$INPUT" > "$TMP_DIR/invalid" 2> "$TMP_DIR/invalid.err"; then
  fail 'unsupported color mode must fail'
else
  assert_eq "$?" 2 'unsupported color mode exit status'
fi
assert_file_has "$TMP_DIR/invalid.err" 'pi-session-format: unsupported color mode: sometimes'
[[ ! -s $TMP_DIR/invalid ]] || fail "unsupported color mode must not format: $(cat "$TMP_DIR/invalid")"

PI_SESSION_LOG_FORMAT=raw \
  bash "$ROOT/bin/pi-session-format" < "$INPUT" > "$RAW"
cmp -s "$INPUT" "$RAW"

# A line that is not JSON keeps its payload instead of collapsing to EVENT.
MALFORMED='{"type":"message", truncated record'
MALFORMED_OUTPUT="$(printf '%s\n%s\n' "$MALFORMED" '{"type":"custom","timestamp":"2026-08-08T19:00:07.000Z"}' |
  PI_SESSION_LOG_FORMAT=pretty PI_SESSION_LOG_COLOR=never bash "$ROOT/bin/pi-session-format")"
if [[ "$(head -n 1 <<< "$MALFORMED_OUTPUT")" != "$MALFORMED" ]]; then
  printf 'malformed session line was not passed through verbatim:\n%s\n' "$MALFORMED_OUTPUT" >&2
  exit 1
fi
if ! grep -Fq -- 'EVENT' <<< "$MALFORMED_OUTPUT" || ! grep -Fq -- 'custom' <<< "$MALFORMED_OUTPUT"; then
  printf 'formatting must continue after a malformed line:\n%s\n' "$MALFORMED_OUTPUT" >&2
  exit 1
fi

pass
