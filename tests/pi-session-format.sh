#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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
  printf 'plain pretty output unexpectedly contains ANSI color codes\n' >&2
  exit 1
fi

PI_SESSION_LOG_FORMAT=raw \
  bash "$ROOT/bin/pi-session-format" < "$INPUT" > "$RAW"
cmp -s "$INPUT" "$RAW"

printf 'pi session formatter tests passed\n'
