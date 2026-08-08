#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'if [[ -n "${FORWARDER_PID:-}" ]]; then kill "$FORWARDER_PID" 2>/dev/null || true; wait "$FORWARDER_PID" 2>/dev/null || true; fi; rm -rf "$TMP_DIR"' EXIT

SESSION_DIR="$TMP_DIR/sessions"
OUTPUT_LOG="$TMP_DIR/docker-stdout.log"
mkdir -p "$SESSION_DIR"

# Existing sessions are history and must not be replayed when the service starts.
printf '%s\n' '{"session":"old","event":"history"}' > "$SESSION_DIR/old.jsonl"

PI_CODING_AGENT_SESSION_DIR="$SESSION_DIR" \
PI_SESSION_LOG_FORMAT=raw \
PATH="$ROOT/bin:$PATH" \
  bash "$ROOT/bin/pi-session-forwarder" \
  >"$OUTPUT_LOG" 2>&1 &
FORWARDER_PID=$!

sleep 0.2
printf '%s\n' '{"session":"new","event":"start"}' > "$SESSION_DIR/new.jsonl"

wait_for_line() {
  local expected="$1"
  local attempt
  for attempt in {1..40}; do
    if grep -Fqx -- "$expected" "$OUTPUT_LOG" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  printf 'missing forwarded session record:\n%s\nactual:\n%s\n' \
    "$expected" "$(cat "$OUTPUT_LOG" 2>/dev/null || true)" >&2
  exit 1
}

wait_for_line '{"session":"new","event":"start"}'

if grep -Fq -- '"session":"old"' "$OUTPUT_LOG"; then
  printf 'old session was replayed into the Docker log\n' >&2
  exit 1
fi

printf '%s\n' '{"session":"old","event":"new_append"}' >> "$SESSION_DIR/old.jsonl"
wait_for_line '{"session":"old","event":"new_append"}'

if grep -Fq -- '{"session":"old","event":"history"}' "$OUTPUT_LOG"; then
  printf 'existing session history was replayed into the Docker log\n' >&2
  exit 1
fi

printf 'pi session forwarder tests passed\n'
