#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
REGISTRY="$TMP_DIR/state-registry"
WORKSPACE_A="$TMP_DIR/workspace-a"
WORKSPACE_B="$TMP_DIR/workspace-b"
WORKSPACE_C="$TMP_DIR/workspace-c"
WORKSPACE_D="$TMP_DIR/workspace-d"
WORKSPACE_E="$TMP_DIR/workspace-e"
WORKSPACE_F="$TMP_DIR/workspace-f"
WORKSPACE_G="$TMP_DIR/workspace-g"
mkdir -p "$FAKE_BIN" "$REGISTRY" "$TMP_DIR/home" "$WORKSPACE_A" "$WORKSPACE_B" "$WORKSPACE_C" "$WORKSPACE_D" "$WORKSPACE_E" "$WORKSPACE_F" "$WORKSPACE_G"
DOCKER_LOG="$TMP_DIR/docker.log"
OUTPUT_LOG="$TMP_DIR/output.log"
VOLUMES_FILE="$TMP_DIR/volumes"
export DOCKER_LOG OUTPUT_LOG

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >> "$DOCKER_LOG"

if [[ "${1:-}" == "ps" ]]; then
  exit 0
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "inspect" ]]; then
  volume="${@: -1}"
  if [[ "$*" == *'CreatedAt'* ]]; then
    while IFS='|' read -r known_volume created_at; do
      if [[ "$known_volume" == "$volume" ]]; then
        printf '%s\n' "$created_at"
        exit 0
      fi
    done <<< "${FAKE_VOLUME_CREATED_ATS-}"
    exit 1
  fi
  if [[ "$volume" == "${FAKE_TARGET_VOLUME_NAME-}" && "${FAKE_TARGET_VOLUME_EXISTS-false}" == true ]]; then
    exit 0
  fi
  if [[ -n "${FAKE_VOLUMES_FILE-}" ]] && grep -Fqx -- "$volume" "$FAKE_VOLUMES_FILE"; then
    exit 0
  fi
  exit 1
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "create" ]]; then
  volume="${@: -1}"
  if [[ "$volume" == *_pi-agent-state ]] && ! grep -Fqx -- "$volume" "$FAKE_VOLUMES_FILE"; then
    printf '%s\n' "$volume" >> "$FAKE_VOLUMES_FILE"
  fi
  exit 0
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "ls" ]]; then
  if [[ -n "${FAKE_VOLUMES_FILE-}" && -f "$FAKE_VOLUMES_FILE" ]]; then
    cat "$FAKE_VOLUMES_FILE"
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
  if [[ "$*" == *' up '* || "$*" == *' up' ]]; then
    if ! grep -Fqx -- "${PI_AGENT_STATE_VOLUME_NAME-}" "$FAKE_VOLUMES_FILE"; then
      printf '%s\n' "${PI_AGENT_STATE_VOLUME_NAME-}" >> "$FAKE_VOLUMES_FILE"
    fi
  fi
  exit 0
fi

printf 'unexpected fake docker command\n' >&2
exit 1
FAKE_DOCKER
chmod +x "$FAKE_BIN/docker"

run_wrapper() {
  local workspace="$1"
  shift
  run_wrapper_with_registry "$REGISTRY" "$workspace" "$@"
}

run_wrapper_with_registry() {
  local registry="$1"
  local workspace="$2"
  shift 2
  : > "$DOCKER_LOG"
  : > "$OUTPUT_LOG"
  printf '%s\n' "${FAKE_VOLUMES-}" > "$VOLUMES_FILE"
  (
    cd "$workspace"
    env -u PI_WORKSPACE \
      PI_AGENT_CONTAINERS_CONFIG_PATH="$registry" \
      HOME="$TMP_DIR/home" \
      FAKE_VOLUMES="${FAKE_VOLUMES-}" \
      FAKE_VOLUMES_FILE="$VOLUMES_FILE" \
      FAKE_VOLUME_CREATED_ATS="${FAKE_VOLUME_CREATED_ATS-}" \
      FAKE_TARGET_VOLUME_NAME="${FAKE_TARGET_VOLUME_NAME-}" \
      FAKE_TARGET_VOLUME_EXISTS="${FAKE_TARGET_VOLUME_EXISTS-false}" \
      FAKE_TARGET_HAS_USEFUL_STATE="${FAKE_TARGET_HAS_USEFUL_STATE-false}" \
      PATH="$FAKE_BIN:$PATH" "$ROOT/bin/pi" "$@" --version
  ) >"$OUTPUT_LOG" 2>&1
}

target_volume() {
  grep -F 'PI_AGENT_STATE_VOLUME_NAME=' "$DOCKER_LOG" | tail -n 1 | cut -d= -f2-
}

assert_source() {
  local expected="$1"
  grep -Fq -- "$expected:/state-source:ro" "$DOCKER_LOG"
}

assert_no_source_copy() {
  if grep -Fq -- ':state-source:ro' "$DOCKER_LOG"; then
    printf 'unexpected state source copy:\n%s\n' "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

run_wrapper "$WORKSPACE_A"
FIRST_VOLUME="$(target_volume)"
[[ "$(cat "$REGISTRY/seed")" == "$FIRST_VOLUME" ]]
FAKE_VOLUME_CREATED_ATS="$FIRST_VOLUME|2026-08-01T12:00:00Z"

FAKE_VOLUMES="$FIRST_VOLUME"
run_wrapper "$WORKSPACE_B"
SECOND_VOLUME="$(target_volume)"
assert_source "$FIRST_VOLUME"
[[ "$(cat "$REGISTRY/seed")" == "$FIRST_VOLUME" ]]
FAKE_VOLUME_CREATED_ATS="$FAKE_VOLUME_CREATED_ATS
$SECOND_VOLUME|2026-08-02T12:00:00Z"

FAKE_VOLUMES="$FIRST_VOLUME
$SECOND_VOLUME"
run_wrapper "$WORKSPACE_C" --latest-state
THIRD_VOLUME="$(target_volume)"
assert_source "$SECOND_VOLUME"
[[ "$(cat "$REGISTRY/seed")" == "$FIRST_VOLUME" ]]
FAKE_VOLUME_CREATED_ATS="$FAKE_VOLUME_CREATED_ATS
$THIRD_VOLUME|2026-08-03T12:00:00Z"

FAKE_VOLUMES="$FIRST_VOLUME
$SECOND_VOLUME
$THIRD_VOLUME"
run_wrapper "$WORKSPACE_D" --new-state
FOURTH_VOLUME="$(target_volume)"
assert_no_source_copy
FAKE_VOLUME_CREATED_ATS="$FAKE_VOLUME_CREATED_ATS
$FOURTH_VOLUME|2026-08-04T12:00:00Z"

FAKE_VOLUMES="$FIRST_VOLUME
$SECOND_VOLUME
$THIRD_VOLUME
$FOURTH_VOLUME"
run_wrapper "$WORKSPACE_E" --latest-state
FIFTH_VOLUME="$(target_volume)"
assert_source "$FOURTH_VOLUME"
FAKE_VOLUME_CREATED_ATS="$FAKE_VOLUME_CREATED_ATS
$FIFTH_VOLUME|2026-08-05T12:00:00Z"

FAKE_VOLUMES="$FIRST_VOLUME
$SECOND_VOLUME
$THIRD_VOLUME
$FOURTH_VOLUME
$FIFTH_VOLUME"
run_wrapper "$WORKSPACE_F" --seed
SIXTH_VOLUME="$(target_volume)"
assert_source "$FIRST_VOLUME"
[[ "$(cat "$REGISTRY/seed")" == "$SIXTH_VOLUME" ]]
FAKE_VOLUME_CREATED_ATS="$FAKE_VOLUME_CREATED_ATS
$SIXTH_VOLUME|2026-08-06T12:00:00Z"

FAKE_VOLUMES="$FAKE_VOLUMES
$SIXTH_VOLUME"
FAKE_TARGET_VOLUME_NAME="$SIXTH_VOLUME"
FAKE_TARGET_VOLUME_EXISTS=true
FAKE_TARGET_HAS_USEFUL_STATE=true
run_wrapper "$WORKSPACE_F" --latest-state
assert_no_source_copy
grep -Fq -- '--latest-state has no effect' "$OUTPUT_LOG"

RECOVERY_REGISTRY="$TMP_DIR/recovery-registry"
mkdir -p "$RECOVERY_REGISTRY"
FAKE_TARGET_VOLUME_EXISTS=false
FAKE_TARGET_HAS_USEFUL_STATE=false
FAKE_VOLUMES="$SECOND_VOLUME
$FIRST_VOLUME
$THIRD_VOLUME
$FOURTH_VOLUME
$FIFTH_VOLUME
$SIXTH_VOLUME"
if printf 'n\n' | run_wrapper_with_registry "$RECOVERY_REGISTRY" "$WORKSPACE_G"; then
  printf 'missing-seed confirmation unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq -- 'seed pointer was not found' "$OUTPUT_LOG"
grep -Fq -- "$FIRST_VOLUME" "$OUTPUT_LOG"

printf 'y\n' | run_wrapper_with_registry "$RECOVERY_REGISTRY" "$WORKSPACE_G"
RECOVERED_VOLUME="$(target_volume)"
assert_source "$FIRST_VOLUME"
[[ "$(cat "$RECOVERY_REGISTRY/seed")" == "$FIRST_VOLUME" ]]

printf 'bin/pi state-lineage tests passed\n'
