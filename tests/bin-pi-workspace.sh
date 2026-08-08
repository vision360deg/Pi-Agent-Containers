#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN" "$TMP_DIR/home/path-1/workspace" "$TMP_DIR/home/path-2/workspace"
DOCKER_LOG="$TMP_DIR/docker.log"
OUTPUT_LOG="$TMP_DIR/output.log"
export DOCKER_LOG OUTPUT_LOG

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >> "$DOCKER_LOG"
if [[ "${1:-}" == "ps" ]]; then
  if [[ "$*" == *'label=com.pi-agents.workspace-basename='* && -n "${FAKE_CONTAINERS-}" ]]; then
    printf '%s\n' "$FAKE_CONTAINERS"
  fi
  exit 0
fi

if [[ "${1:-}" == "rename" ]]; then
  printf 'rename %s -> %s\n' "$2" "$3" >> "$DOCKER_LOG"
  exit 0
fi

if [[ "${1:-}" == "inspect" ]]; then
  if [[ "$*" == *State.Running* ]]; then
    printf '%s\n' "${FAKE_RUNNING-false}"
  else
    printf '%s\n' "${FAKE_PROJECT-}"
  fi
  exit 0
fi

if [[ "${1:-}" == "run" ]]; then
  exit 0
fi

if [[ "${1:-}" == "volume" ]]; then
  if [[ "${2:-}" == "inspect" ]]; then
    exit 1
  fi
  if [[ "${2:-}" == "create" ]]; then
    exit 0
  fi
  if [[ "${2:-}" == "ls" ]]; then
    exit 0
  fi
  if [[ "${2:-}" == "rm" ]]; then
    printf '%s\n' "$*" >> "$DOCKER_LOG"
    exit 0
  fi
  exit 1
fi

if [[ "${1:-}" == "stop" || "${1:-}" == "rm" ]]; then
  printf '%s\n' "$*" >> "$DOCKER_LOG"
  exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
  printf 'PI_WORKSPACE=%s\nPI_WORKSPACE_BASENAME=%s\nPI_CONTAINER_NAME=%s\nPI_WORKSPACE_PROJECT=%s\nPI_AGENT_STATE_VOLUME_NAME=%s\nPI_SESSION_STATE_VOLUME_NAME=%s\nPI_BROWSER_STATE_VOLUME_NAME=%s\n' \
    "${PI_WORKSPACE-}" "${PI_WORKSPACE_BASENAME-}" "${PI_CONTAINER_NAME-}" \
    "${PI_WORKSPACE_PROJECT-}" "${PI_AGENT_STATE_VOLUME_NAME-}" \
    "${PI_SESSION_STATE_VOLUME_NAME-}" "${PI_BROWSER_STATE_VOLUME_NAME-}" >> "$DOCKER_LOG"
  exit 0
fi

printf 'unexpected fake docker command\n' >&2
exit 1
FAKE_DOCKER
chmod +x "$FAKE_BIN/docker"

run_wrapper() {
  local workspace="$1"
  shift
  : > "$DOCKER_LOG"
  : > "$OUTPUT_LOG"
  (
    cd "$workspace"
    env -u PI_WORKSPACE PI_AGENT_CONTAINERS_CONFIG_PATH="$TMP_DIR/state-registry" HOME="$TMP_DIR/home" PATH="$FAKE_BIN:$PATH" "$ROOT/bin/pi" "$@"
  ) >"$OUTPUT_LOG" 2>&1
}

assert_log_has() {
  local expected="$1"
  if ! grep -Fq -- "$expected" "$DOCKER_LOG"; then
    printf 'missing log text:\n%s\nactual:\n%s\n' "$expected" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

assert_log_lacks() {
  local unexpected="$1"
  if grep -Fq -- "$unexpected" "$DOCKER_LOG"; then
    printf 'unexpected log text:\n%s\nactual:\n%s\n' "$unexpected" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

HOME_ROOT="$TMP_DIR/home"
PATH_1="$(cd -P -- "$HOME_ROOT/path-1/workspace" && pwd)"
PATH_2="$(cd -P -- "$HOME_ROOT/path-2/workspace" && pwd)"

unset FAKE_CONTAINERS
run_wrapper "$PATH_1"
assert_log_has '--project-name pi-agents-pi-workspace'
assert_log_lacks '--project-name pi-agents-ws-'
assert_log_has 'PI_CONTAINER_NAME=pi-agents-pi-workspace'
assert_log_has 'PI_WORKSPACE_PROJECT=pi-agents-pi-workspace'
grep -Eq '^PI_AGENT_STATE_VOLUME_NAME=pi-agents-ws-[a-z0-9]+_pi-agent-state$' "$DOCKER_LOG"
grep -Eq '^PI_SESSION_STATE_VOLUME_NAME=pi-agents-ws-[a-z0-9]+_pi-sessions$' "$DOCKER_LOG"
grep -Eq '^PI_BROWSER_STATE_VOLUME_NAME=pi-agents-ws-[a-z0-9]+_agent-browser-state$' "$DOCKER_LOG"
assert_log_has "PI_WORKSPACE=$PATH_1"

run_wrapper "$PATH_1" --new-state
grep -Eq '^PI_AGENT_STATE_VOLUME_NAME=pi-agents-new-ws-[a-z0-9]+_pi-agent-state$' "$DOCKER_LOG"
assert_log_has 'PI_SESSION_STATE_VOLUME_NAME=pi-agents-ws-'
assert_log_has 'up --detach --force-recreate pi'

export FAKE_CONTAINERS=$'id-1\tpi-agents-pi-workspace\tUp 2 minutes\t'$PATH_1
if printf 'c\n' | run_wrapper "$PATH_2"; then
  printf 'collision cancel unexpectedly succeeded\n' >&2
  exit 1
fi
assert_log_lacks 'rename'
grep -Fq '¡¡¡ WARNING !!!' "$OUTPUT_LOG"

printf 'r\n' | run_wrapper "$PATH_2"
assert_log_has 'rename pi-agents-pi-workspace -> pi-agents-pi-path-1-workspace'
assert_log_has 'PI_CONTAINER_NAME=pi-agents-pi-path-2-workspace'
assert_log_has 'compose --project-name pi-agents-pi-path-2-workspace'
assert_log_has 'up --detach --force-recreate pi'

export FAKE_CONTAINERS=$'id-1\tpi-agents-pi-workspace\tExited (0) 3 hours ago\t'$PATH_1
if printf 'c\n' | run_wrapper "$PATH_2"; then
  printf 'stopped-container collision cancel unexpectedly succeeded\n' >&2
  exit 1
fi
assert_log_lacks 'rename'
if grep -Fq '¡¡¡ WARNING !!!' "$OUTPUT_LOG"; then
  printf 'stopped-container collision incorrectly emitted running warning\n' >&2
  exit 1
fi

export FAKE_CONTAINERS=$'id-1\tpi-agents-pi-workspace\tUp 2 minutes\t'$PATH_1
run_wrapper "$PATH_2" --keep-existing
assert_log_lacks 'rename pi-agents-pi-workspace'
assert_log_has 'PI_CONTAINER_NAME=pi-agents-pi-path-2-workspace'
assert_log_has 'compose --project-name pi-agents-pi-path-2-workspace'

unset FAKE_CONTAINERS
run_wrapper "$PATH_1" --replace
assert_log_has 'up --detach --force-recreate pi'

run_wrapper "$PATH_1" stop
assert_log_has ' stop'
assert_log_lacks ' up '

unset FAKE_CONTAINERS
run_wrapper "$PATH_1" remove
assert_log_has 'compose --project-name pi-agents-pi-workspace'
assert_log_has ' down'
assert_log_lacks 'down --volumes'

run_wrapper "$PATH_1" remove --all
assert_log_has 'compose --project-name pi-agents-pi-workspace'
assert_log_has ' down'
assert_log_lacks 'down --volumes'

printf 'bin/pi workspace tests passed\n'
