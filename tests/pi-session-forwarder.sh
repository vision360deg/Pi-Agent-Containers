#!/usr/bin/env bash
# bin/pi-session-forwarder: streaming session logs to the container output without leaking processes.
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.bash"
cleanup() {
  if [[ -n "${FORWARDER_PID:-}" ]]; then
    kill "$FORWARDER_PID" 2>/dev/null || true
    wait "$FORWARDER_PID" 2>/dev/null || true
  fi
  # Never leak stream processes from a failed run.
  session_tail_pids | xargs kill 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

SESSION_DIR="$TMP_DIR/sessions"
OUTPUT_LOG="$TMP_DIR/docker-stdout.log"
FAKE_BIN="$TMP_DIR/bin"
FORMATTER_PIDS="$TMP_DIR/formatter.pids"
mkdir -p "$SESSION_DIR" "$FAKE_BIN" "$TMP_DIR/tmp"

# Record each formatter the forwarder starts so the test can prove none of
# them outlives it.
cat > "$FAKE_BIN/pi-session-format" <<FAKE_FORMAT
#!/usr/bin/env bash
printf '%s\\n' "\$\$" >> "$FORMATTER_PIDS"
exec bash "$ROOT/bin/pi-session-format"
FAKE_FORMAT
chmod +x "$FAKE_BIN/pi-session-format"

session_tail_pids() {
  /bin/ps -axo pid=,command= | awk -v dir="$SESSION_DIR/" '$2 == "tail" && index($0, dir) {print $1}'
}

live_pids() {
  local pid
  for pid in "$@"; do
    if kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$pid"
    fi
  done
}

start_forwarder() {
  PI_CODING_AGENT_SESSION_DIR="$SESSION_DIR" \
  PI_SESSION_LOG_FORMAT=raw \
  PI_SESSION_LOG_POLL_INTERVAL=0.05 \
  TMPDIR="$TMP_DIR/tmp" \
  PATH="$FAKE_BIN:$ROOT/bin:$PATH" \
    bash "$ROOT/bin/pi-session-forwarder" \
    >"$OUTPUT_LOG" 2>&1 &
  FORWARDER_PID=$!
}

# Existing sessions are history and must not be replayed when the service starts.
printf '%s\n' '{"session":"old","event":"history"}' > "$SESSION_DIR/old.jsonl"
printf '%s\n' 'not a session' > "$SESSION_DIR/notes.txt"

start_forwarder

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

# Sessions in nested folders are forwarded from their beginning too, so Pi's
# per-folder default layout (sessions/--<cwd>--/) still reaches the Docker log.
mkdir -p "$SESSION_DIR/--workspace--"
printf '%s\n' '{"session":"nested","event":"start"}' > "$SESSION_DIR/--workspace--/nested.jsonl"
wait_for_line '{"session":"nested","event":"start"}'

if grep -Fq -- '"session":"old"' "$OUTPUT_LOG"; then
  fail 'old session was replayed into the Docker log'
fi

printf '%s\n' '{"session":"old","event":"new_append"}' >> "$SESSION_DIR/old.jsonl"
wait_for_line '{"session":"old","event":"new_append"}'

if grep -Fq -- '{"session":"old","event":"history"}' "$OUTPUT_LOG"; then
  fail 'existing session history was replayed into the Docker log'
fi

# Non-session files are ignored.
printf '%s\n' 'more notes' >> "$SESSION_DIR/notes.txt"
sleep 0.3
assert_file_lacks "$OUTPUT_LOG" 'notes'

# Termination exits cleanly and leaves no tail, formatter, or runtime
# directory behind.
mapfile -t tails < <(session_tail_pids)
mapfile -t formatters < "$FORMATTER_PIDS"
if (( ${#tails[@]} == 0 || ${#formatters[@]} == 0 )); then
  printf 'expected running session streams, found tails=%s formatters=%s\n' "${tails[*]-}" "${formatters[*]-}" >&2
  exit 1
fi
kill -TERM "$FORWARDER_PID"
if wait "$FORWARDER_PID"; then status=0; else status=$?; fi
FORWARDER_PID=''
if (( status != 0 )); then
  printf 'forwarder must exit cleanly on TERM, got %s\n' "$status" >&2
  exit 1
fi
survivors="$(live_pids "${tails[@]}" "${formatters[@]}") $(session_tail_pids)"
if [[ -n "${survivors// /}" ]]; then
  printf 'session stream processes survived the forwarder: %s\n' "$survivors" >&2
  kill $survivors 2>/dev/null || true
  exit 1
fi
if [[ -n "$(/usr/bin/find "$TMP_DIR/tmp" -mindepth 1 -maxdepth 1)" ]]; then
  fail 'forwarder runtime directory was not removed'
fi

# A stream that dies is fatal: restarting it from a stale offset could
# re-emit records already forwarded.
start_forwarder
sleep 0.2
printf '%s\n' '{"session":"new","event":"after_restart"}' >> "$SESSION_DIR/new.jsonl"
wait_for_line '{"session":"new","event":"after_restart"}'
mapfile -t tails < <(session_tail_pids)
kill "${tails[@]}"
for attempt in {1..40}; do
  kill -0 "$FORWARDER_PID" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$FORWARDER_PID" 2>/dev/null; then
  fail 'forwarder kept running after a session stream died'
fi
if wait "$FORWARDER_PID"; then status=0; else status=$?; fi
FORWARDER_PID=''
if (( status == 0 )); then
  fail 'a dead session stream must make the forwarder fail'
fi
grep -Fq -- 'session log stream stopped' "$OUTPUT_LOG"
survivors="$(live_pids $(cat "$FORMATTER_PIDS")) $(session_tail_pids)"
if [[ -n "${survivors// /}" ]]; then
  printf 'session stream processes survived a failed forwarder: %s\n' "$survivors" >&2
  kill $survivors 2>/dev/null || true
  exit 1
fi

pass
