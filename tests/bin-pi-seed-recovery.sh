#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
HOME_ROOT="$TMP_DIR/home"
REGISTRY="$HOME_ROOT/.config/pi-agent-containers"
WORKSPACE="$TMP_DIR/workspace"
STATE_VOLUMES="$TMP_DIR/state-volumes"
DOCKER_LOG="$TMP_DIR/docker.log"
mkdir -p "$FAKE_BIN" "$REGISTRY" "$WORKSPACE"
export DOCKER_LOG STATE_VOLUMES

WORKSPACE="$(cd -P -- "$WORKSPACE" && pwd)"
WORKSPACE_HASH="$(printf '%s' "$WORKSPACE" | shasum -a 256 | awk '{print substr($1, 1, 12)}')"
TARGET_VOLUME="pi-agents-ws-${WORKSPACE_HASH}_pi-agent-state"
OLDEST_VOLUME="pi-agents-ws-oldest_pi-agent-state"
NEWER_VOLUME="pi-agents-ws-newer_pi-agent-state"
export TARGET_VOLUME OLDEST_VOLUME NEWER_VOLUME
printf '%s\n%s\n%s\n' "$TARGET_VOLUME" "$OLDEST_VOLUME" "$NEWER_VOLUME" > "$STATE_VOLUMES"
printf '%s\n' "$TARGET_VOLUME" > "$REGISTRY/seed"

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >> "$DOCKER_LOG"

volume_exists() {
  grep -Fqx -- "$1" "$STATE_VOLUMES"
}

if [[ "${1:-}" == "ps" ]]; then
  exit 0
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "inspect" ]]; then
  volume="${@: -1}"
  if [[ "$*" == *'CreatedAt'* ]]; then
    case "$volume" in
      "$TARGET_VOLUME") printf '2026-08-06T12:00:00Z\n' ;;
      "$OLDEST_VOLUME") printf '2026-08-01T12:00:00Z\n' ;;
      "$NEWER_VOLUME") printf '2026-08-07T12:00:00Z\n' ;;
      *) exit 1 ;;
    esac
    exit 0
  fi
  volume_exists "$volume"
  exit $?
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "ls" ]]; then
  cat "$STATE_VOLUMES"
  exit 0
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "rm" ]]; then
  volume="${@: -1}"
  grep -Fvx -- "$volume" "$STATE_VOLUMES" > "$STATE_VOLUMES.tmp"
  mv "$STATE_VOLUMES.tmp" "$STATE_VOLUMES"
  exit 0
fi

if [[ "${1:-}" == "run" ]]; then
  if [[ "$*" == *':/state:ro'* ]]; then
    exit 0
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

(
  cd "$WORKSPACE"
  env -u PI_WORKSPACE \
    PI_AGENT_CONTAINERS_CONFIG_PATH="$REGISTRY" \
    HOME="$HOME_ROOT" \
    FAKE_TARGET_VOLUME_EXISTS=true \
    FAKE_TARGET_HAS_USEFUL_STATE=true \
    PATH="$FAKE_BIN:$PATH" "$ROOT/bin/pi" remove --all
)

if [[ "$(cat "$REGISTRY/seed")" != "$OLDEST_VOLUME" ]]; then
  printf 'unexpected seed pointer: %s\n' "$(cat "$REGISTRY/seed")" >&2
  cat "$DOCKER_LOG" >&2
  cat "$STATE_VOLUMES" >&2
  exit 1
fi
if grep -Fqx -- "$TARGET_VOLUME" "$STATE_VOLUMES"; then
  printf 'removed seed volume still appears in fake Docker state\n' >&2
  exit 1
fi

printf 'bin/pi seed-recovery tests passed\n'
