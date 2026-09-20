#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
CURRENT_WORKSPACE="$TMP_DIR/current-workspace"
OTHER_WORKSPACE="$TMP_DIR/other-workspace"
STOPPED_WORKSPACE="$TMP_DIR/stopped-workspace"
MISSING_WORKSPACE="$TMP_DIR/new-project"
CANCEL_WORKSPACE="$TMP_DIR/cancel-project"
mkdir -p "$FAKE_BIN" "$CURRENT_WORKSPACE" "$OTHER_WORKSPACE" "$STOPPED_WORKSPACE" "$TMP_DIR/home"
DOCKER_LOG="$TMP_DIR/docker.log"
OUTPUT_LOG="$TMP_DIR/output.log"
export DOCKER_LOG

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >> "$DOCKER_LOG"

if [[ "${1:-}" == "ps" ]]; then
  if [[ "$*" == *'--filter label=com.docker.compose.oneoff=False'* ]]; then
    if [[ "$*" != *'--filter label=com.pi-agents.workspace'* ]]; then
      printf 'shell discovery did not use the Pi workspace label: %s\n' "$*" >&2
      exit 98
    fi
    printf '%s\n' "${FAKE_CONTAINERS-}"
  fi
  exit 0
fi

if [[ "${1:-}" == "inspect" ]]; then
  printf 'mounted\n'
  exit 0
fi

if [[ "${1:-}" == "start" || "${1:-}" == "exec" ]]; then
  exit 0
fi

if [[ "${1:-}" == "volume" ]]; then
  case "${2:-}" in
    inspect)
      exit 1
      ;;
    ls|create)
      exit 0
      ;;
  esac
fi

if [[ "${1:-}" == "run" || "${1:-}" == "compose" ]]; then
  exit 0
fi

printf 'unexpected Docker command: %s\n' "$*" >&2
exit 99
FAKE_DOCKER
chmod +x "$FAKE_BIN/docker"

run_wrapper() {
  : > "$DOCKER_LOG"
  : > "$OUTPUT_LOG"
  (
    cd "$CURRENT_WORKSPACE"
    env -u PI_WORKSPACE \
      PI_AGENT_CONTAINERS_CONFIG_PATH="$TMP_DIR/state-registry" \
      HOME="$TMP_DIR/home" \
      SHELL=/bin/bash \
      FAKE_CONTAINERS="${FAKE_CONTAINERS-}" \
      PATH="$FAKE_BIN:$PATH" \
      "$ROOT/bin/pi" "$@"
  ) >"$OUTPUT_LOG" 2>&1
}

assert_log_has() {
  local expected="$1"
  if ! grep -Fq -- "$expected" "$DOCKER_LOG"; then
    printf 'missing Docker log text:\n%s\nactual:\n%s\n' "$expected" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

assert_log_lacks() {
  local unexpected="$1"
  if grep -Fq -- "$unexpected" "$DOCKER_LOG"; then
    printf 'unexpected Docker log text:\n%s\nactual:\n%s\n' "$unexpected" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

CURRENT_PATH="$(cd -P -- "$CURRENT_WORKSPACE" && pwd)"
OTHER_PATH="$(cd -P -- "$OTHER_WORKSPACE" && pwd)"
STOPPED_PATH="$(cd -P -- "$STOPPED_WORKSPACE" && pwd)"
SHELL_LAUNCH_ENV='--env PI_HOST_SHELL=bash --env PI_HOST_RC_FILE=/tmp/pi-host-shellrc/rc --env PI_NO_RC_CONFIG=0'

# A current running workspace container is selected without a picker or Compose.
FAKE_CONTAINERS=$'current-id\tpi-agents-pi-current\tUp 4 minutes\trunning\t'"$CURRENT_PATH"
run_wrapper shell
assert_log_has "docker exec -it $SHELL_LAUNCH_ENV pi-agents-pi-current pi-shell-launch"
assert_log_lacks 'docker start'
assert_log_lacks 'docker compose'

run_wrapper shell -r
assert_log_has "docker exec -it --user 0 $SHELL_LAUNCH_ENV pi-agents-pi-current pi-shell-launch"

# Multiple containers for the current workspace require an explicit choice.
FAKE_CONTAINERS=$'first-id\tpi-agents-pi-first\tUp 5 minutes\trunning\t'"$CURRENT_PATH"$'\nsecond-id\tpi-agents-pi-second\tUp 2 minutes\trunning\t'"$CURRENT_PATH"
printf '2\n' | run_wrapper shell
assert_log_has "docker exec -it $SHELL_LAUNCH_ENV pi-agents-pi-second pi-shell-launch"
grep -Fq 'Choose a Pi container:' "$OUTPUT_LOG"

# A current stopped workspace container is started before a normal-user shell.
FAKE_CONTAINERS=$'stopped-id\tpi-agents-pi-stopped\tExited (0) 2 hours ago\texited\t'"$CURRENT_PATH"
run_wrapper shell
assert_log_has 'docker start pi-agents-pi-stopped'
assert_log_has "docker exec -it $SHELL_LAUNCH_ENV pi-agents-pi-stopped pi-shell-launch"

# Without a current match, the picker can select another stopped container and
# root mode adds Docker's user override.
FAKE_CONTAINERS=$'other-id\tpi-agents-pi-other\tExited (0) 1 hour ago\texited\t'"$OTHER_PATH"$'\nsecond-id\tpi-agents-pi-second\tUp 1 minute\trunning\t'"$STOPPED_PATH"
printf '2\n' | run_wrapper shell --root
assert_log_has 'docker start pi-agents-pi-other'
assert_log_has "docker exec -it --user 0 $SHELL_LAUNCH_ENV pi-agents-pi-other pi-shell-launch"
grep -Fq 'Choose a Pi container:' "$OUTPUT_LOG"
grep -Fq '1) pi-agents-pi-other' "$OUTPUT_LOG"

# A missing workspace offers project creation and Escape cancellation.
FAKE_CONTAINERS=$'existing-id\tpi-agents-pi-existing\tUp 1 minute\trunning\t'"$OTHER_PATH"
printf '0\n' | run_wrapper --workspace "$MISSING_WORKSPACE" shell
[[ -d "$MISSING_WORKSPACE" ]]
grep -Fq '0) Start a new project' "$OUTPUT_LOG"
grep -Fq '1) pi-agents-pi-existing' "$OUTPUT_LOG"
grep -Fq 'X) Press Esc to cancel' "$OUTPUT_LOG"
assert_log_has 'docker compose'
assert_log_has 'up --build --detach pi'
assert_log_has 'docker volume create'
assert_log_has 'docker run'
assert_log_has 'exec pi pi-shell-launch pi-session-log --forward-output install npm:pi-agent-browser-native'
assert_log_has "docker exec -it $SHELL_LAUNCH_ENV pi-agents-pi-new-project pi-shell-launch"

if printf '\033' | run_wrapper --workspace "$CANCEL_WORKSPACE" shell; then
  printf 'Escape cancellation unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
  [[ "$status" -eq 2 ]]
fi
[[ ! -d "$CANCEL_WORKSPACE" ]]
grep -Fq 'X) Press Esc to cancel' "$OUTPUT_LOG"
grep -Fq 'container selection cancelled' "$OUTPUT_LOG"
assert_log_lacks 'docker compose'

# Invalid shell options are rejected without touching Docker.
if run_wrapper shell --unknown; then
  printf 'unknown shell option unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
  [[ "$status" -eq 2 ]]
fi
assert_log_lacks 'docker '
grep -Fq 'usage: pi shell [--root|-r]' "$OUTPUT_LOG"

# A workspace with no current container offers new-project and cancellation.
FAKE_CONTAINERS=''
if printf 'x' | run_wrapper shell; then
  printf 'shell cancellation unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
  [[ "$status" -eq 2 ]]
fi
grep -Fq '0) Start a new project' "$OUTPUT_LOG"
grep -Fq 'X) Press Esc to cancel' "$OUTPUT_LOG"
grep -Fq 'container selection cancelled' "$OUTPUT_LOG"
assert_log_lacks 'docker compose'

printf 'bin/pi shell tests passed\n'
