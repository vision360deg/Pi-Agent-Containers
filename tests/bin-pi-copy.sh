#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
FAKE_BIN="$TMP_DIR/bin"
WORKSPACE="$TMP_DIR/workspace"
mkdir -p "$FAKE_BIN" "$WORKSPACE" "$TMP_DIR/home"
OUTPUT_LOG="$TMP_DIR/output.log"
DOCKER_LOG="$TMP_DIR/docker.log"
OTHER_WORKSPACE="$TMP_DIR/other-workspace"
mkdir -p "$OTHER_WORKSPACE"
CURRENT_PATH="$(cd -P -- "$WORKSPACE" && pwd)"
OTHER_PATH="$(cd -P -- "$OTHER_WORKSPACE" && pwd)"
export DOCKER_LOG

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "$DOCKER_LOG"
case "${1:-}" in
  ps)
    printf 'current-id\tpi-agents-pi-current\tUp 1 minute\trunning\t%s\n' "$FAKE_CURRENT_WORKSPACE"
    printf 'other-id\tpi-agents-pi-other\tExited (0) 1 hour ago\texited\t%s\n' "$FAKE_OTHER_WORKSPACE"
    ;;
  inspect)
    case "${@: -1}" in
      pi-agents-pi-current) printf 'pi-agents-ws-current_pi-agent-state\n' ;;
      pi-agents-pi-other) printf 'pi-agents-ws-other_pi-agent-state\n' ;;
      *) exit 1 ;;
    esac
    ;;
  volume|compose|run) exit 0 ;;
  *) exit 0 ;;
esac
FAKE_DOCKER
chmod +x "$FAKE_BIN/docker"

run_capture() {
  : > "$OUTPUT_LOG"
  (cd "$WORKSPACE" && env -u PI_WORKSPACE HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" "$ROOT/bin/pi" "$@") >"$OUTPUT_LOG" 2>&1 || return $?
}

if run_capture --help; then
  grep -Fq -- 'pi copy' "$OUTPUT_LOG"
  grep -Fq -- '--sessions, -s' "$OUTPUT_LOG"
  grep -Fq -- '--auth, -a' "$OUTPUT_LOG"
  grep -Fq -- '--extensions, -e' "$OUTPUT_LOG"
  grep -Fq -- '--override' "$OUTPUT_LOG"
else
  printf 'detailed help failed\n%s\n' "$(cat "$OUTPUT_LOG")" >&2
  exit 1
fi

run_capture copy --help
grep -Fq -- 'Run `pi --help` for detailed usage.' "$OUTPUT_LOG"

if run_capture copy --unknown; then
  printf 'unknown copy option unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq -- 'usage: pi copy' "$OUTPUT_LOG"

: > "$DOCKER_LOG"
export FAKE_CURRENT_WORKSPACE="$CURRENT_PATH" FAKE_OTHER_WORKSPACE="$OTHER_PATH"
printf '1' | run_capture copy --from --sessions --all
grep -Fq -- 'pi-state-copy' "$DOCKER_LOG"
grep -Fq -- 'bash /usr/local/bin/pi-state-copy' "$DOCKER_LOG"
if grep -Fq -- '--no-deps' "$DOCKER_LOG"; then
  printf 'copy helper must not inherit Compose capability drops\n' >&2
  exit 1
fi
grep -Fq -- 'docker run --rm -i --user 0' "$DOCKER_LOG"
grep -Fq -- 'pi-agents-ws-other_pi-agent-state:/state-source:ro' "$DOCKER_LOG"
grep -Fq -- 'pi-agents-ws-current_pi-agent-state:/state-target' "$DOCKER_LOG"

: > "$DOCKER_LOG"
printf '1' | run_capture copy --to --auth --all
grep -Fq -- 'Choose a destination Pi container:' "$OUTPUT_LOG"
grep -Fq -- 'pi-agents-ws-current_pi-agent-state:/state-source:ro' "$DOCKER_LOG"
grep -Fq -- 'pi-agents-ws-other_pi-agent-state:/state-target' "$DOCKER_LOG"

printf 'bin/pi copy tests passed\n'
