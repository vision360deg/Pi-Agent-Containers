#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
WORKSPACE="$TMP_DIR/workspace"
mkdir -p "$FAKE_BIN" "$TMP_DIR/home" "$WORKSPACE"
DOCKER_LOG="$TMP_DIR/docker.log"
export DOCKER_LOG

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >> "$DOCKER_LOG"

if [[ "${1:-}" == "ps" ]]; then
  if [[ "$*" == *'volume=pi-agents_pi-agent-state'* ]]; then
    printf 'forbidden shared-default volume lookup\n' >&2
    exit 99
  fi
  exit 0
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "create" ]]; then
  exit 0
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "inspect" ]]; then
  volume="${@: -1}"
  if [[ "$*" == *'CreatedAt'* && -n "${FAKE_WORKSPACE_SOURCE_VOLUME-}" && "$volume" == "$FAKE_WORKSPACE_SOURCE_VOLUME" ]]; then
    printf '2026-08-01T12:00:00Z\n'
    exit 0
  fi
  if [[ "$volume" == pi-agents_pi-agent-state ]]; then
    printf 'forbidden shared-default volume inspection\n' >&2
    exit 99
  fi
  if [[ "$volume" == pi-agents-ws-* && "${FAKE_TARGET_VOLUME_EXISTS-false}" == true ]]; then
    exit 0
  fi
  if [[ -n "${FAKE_WORKSPACE_SOURCE_VOLUME-}" && "$volume" == "$FAKE_WORKSPACE_SOURCE_VOLUME" ]]; then
    exit 0
  fi
  exit 1
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "ls" ]]; then
  if [[ -n "${FAKE_WORKSPACE_SOURCE_VOLUME-}" ]]; then
    printf '%s\n' "$FAKE_WORKSPACE_SOURCE_VOLUME"
  fi
  exit 0
fi

if [[ "${1:-}" == "run" ]]; then
  if [[ "$*" == *':/state:ro'* ]]; then
    [[ "${FAKE_TARGET_HAS_USEFUL_STATE-false}" == true ]]
    exit $?
  fi
  exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
  printf 'PI_AGENT_STATE_VOLUME_NAME=%s\n' "${PI_AGENT_STATE_VOLUME_NAME-}" >> "$DOCKER_LOG"
  exit 0
fi

printf 'unexpected fake docker command\n' >&2
exit 1
FAKE_DOCKER
chmod +x "$FAKE_BIN/docker"

run_wrapper() {
  : > "$DOCKER_LOG"
  (
    cd "$WORKSPACE"
    env -u PI_WORKSPACE \
      PI_AGENT_CONTAINERS_CONFIG_PATH="$TMP_DIR/state-registry" \
      HOME="$TMP_DIR/home" \
      FAKE_WORKSPACE_SOURCE_VOLUME="${FAKE_WORKSPACE_SOURCE_VOLUME-}" \
      FAKE_TARGET_VOLUME_EXISTS="${FAKE_TARGET_VOLUME_EXISTS-false}" \
      FAKE_TARGET_HAS_USEFUL_STATE="${FAKE_TARGET_HAS_USEFUL_STATE-false}" \
      PATH="$FAKE_BIN:$PATH" "$ROOT/bin/pi" --version
  )
}

export FAKE_WORKSPACE_SOURCE_VOLUME=pi-agents-ws-source_pi-agent-state
mkdir -p "$TMP_DIR/state-registry"
printf '%s\n' "$FAKE_WORKSPACE_SOURCE_VOLUME" > "$TMP_DIR/state-registry/seed"
run_wrapper
if ! grep -Fq 'pi-agents-ws-source_pi-agent-state:/state-source:ro' "$DOCKER_LOG"; then
  exit 1
fi
if ! grep -Fq -- '--user 0:0' "$DOCKER_LOG" || ! grep -Fq -- ':/sessions' "$DOCKER_LOG"; then
  printf 'state permission repair was not run for the persisted session volume\n' >&2
  exit 1
fi
if ! grep -Fq -- '--label com.pi-agents.managed=true' "$DOCKER_LOG" ||
  ! grep -Fq -- '--label com.pi-agents.state-kind=agent' "$DOCKER_LOG"; then
  printf 'new agent-state volume was not provisioned with Docker metadata\n' >&2
  exit 1
fi

export FAKE_TARGET_VOLUME_EXISTS=true
export FAKE_TARGET_HAS_USEFUL_STATE=true
run_wrapper
if grep -Fq ':state-source:ro' "$DOCKER_LOG"; then
  printf 'existing workspace state volume was seeded again\n' >&2
  exit 1
fi

unset FAKE_TARGET_VOLUME_EXISTS
unset FAKE_TARGET_HAS_USEFUL_STATE
export FAKE_TARGET_VOLUME_EXISTS=true
export FAKE_WORKSPACE_SOURCE_VOLUME=pi-agents-ws-source_pi-agent-state
run_wrapper
grep -Fq 'pi-agents-ws-source_pi-agent-state:/state-source:ro' "$DOCKER_LOG"

unset FAKE_TARGET_VOLUME_EXISTS
unset FAKE_WORKSPACE_SOURCE_VOLUME
run_wrapper
grep -Eq '^PI_AGENT_STATE_VOLUME_NAME=pi-agents-ws-[a-z0-9]+_pi-agent-state$' "$DOCKER_LOG"
if grep -Fq ':state-source:ro' "$DOCKER_LOG"; then
  printf 'state was copied without an existing workspace source\n' >&2
  exit 1
fi
if grep -Fq 'pi-agents_pi-agent-state' "$DOCKER_LOG"; then
  printf 'forbidden shared agent-state volume was referenced\n' >&2
  exit 1
fi

printf 'bin/pi state-copy tests passed\n'
