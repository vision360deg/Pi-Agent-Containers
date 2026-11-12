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
WORKSPACE_H="$TMP_DIR/workspace-h"
WORKSPACE_I="$TMP_DIR/workspace-i"
mkdir -p "$FAKE_BIN" "$REGISTRY" "$TMP_DIR/home" "$WORKSPACE_A" "$WORKSPACE_B" "$WORKSPACE_C" "$WORKSPACE_D" "$WORKSPACE_E" "$WORKSPACE_F" "$WORKSPACE_G" "$WORKSPACE_H" "$WORKSPACE_I"
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

if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  exit 0
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "inspect" ]]; then
  volume="${@: -1}"
  if [[ "$*" == *'com.pi-agents.managed'* ]]; then
    exit 0
  fi
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
  if [[ "$*" == *'exit 11'* ]]; then
    case "${FAKE_STATE_MARKER-none}" in
      complete) exit 0 ;;
      pending) exit 10 ;;
      *) exit 11 ;;
    esac
  fi
  if [[ "$*" == *'exit 42'* ]]; then
    [[ "${FAKE_TARGET_HAS_USEFUL_STATE-false}" == true ]] && exit 0
    exit 42
  fi
  if [[ "$*" == *'cat /state/.container-initialization-pending'* ]]; then
    printf '%s\n' "${FAKE_PENDING_SOURCE-}"
    exit 0
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
      FAKE_STATE_MARKER="${FAKE_STATE_MARKER-none}" \
      FAKE_PENDING_SOURCE="${FAKE_PENDING_SOURCE-}" \
      PATH="$FAKE_BIN:$PATH" "$ROOT/bin/pi" "$@" ${WRAPPER_SUFFIX---version}
  ) >"$OUTPUT_LOG" 2>&1
}

target_volume() {
  grep -F 'PI_AGENT_STATE_VOLUME_NAME=' "$DOCKER_LOG" | tail -n 1 | cut -d= -f2-
}

assert_source() {
  local expected="$1"
  grep -Fq -- "$expected:/state-source:ro" "$DOCKER_LOG"
}

# The first log line containing $1 precedes the first containing $2.
assert_log_order() {
  local first second
  first="$(grep -nF -- "$1" "$DOCKER_LOG" | head -n 1 | cut -d: -f1)"
  second="$(grep -nF -- "$2" "$DOCKER_LOG" | head -n 1 | cut -d: -f1)"
  if [[ -z "$first" || -z "$second" || "$first" -ge "$second" ]]; then
    printf 'expected %s before %s:\n%s\n' "$1" "$2" "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

assert_no_source_copy() {
  if grep -Fq -- ':/state-source:ro' "$DOCKER_LOG"; then
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
[[ "$FOURTH_VOLUME" == pi-agents-new-ws-*_pi-agent-state ]]
assert_no_source_copy
grep -Fq -- "--label com.pi-agents.state-kind=agent-extra --label com.pi-agents.workspace=$(cd -P "$WORKSPACE_D" && pwd)" "$DOCKER_LOG"
grep -Fq -- 'state-initialization complete' "$DOCKER_LOG"
[[ "$(cat "$REGISTRY/seed")" == "$FIRST_VOLUME" ]]
FAKE_VOLUME_CREATED_ATS="$FAKE_VOLUME_CREATED_ATS
$FOURTH_VOLUME|2026-08-04T12:00:00Z"

# The extra volume is never seeded, so --new-state --latest-state is refused
# before anything runs.
FAKE_VOLUMES="$FIRST_VOLUME
$SECOND_VOLUME
$THIRD_VOLUME
$FOURTH_VOLUME"
if run_wrapper "$WORKSPACE_D" --new-state --latest-state; then
  printf -- '--new-state --latest-state unexpectedly succeeded\n' >&2
  exit 1
elif [[ $? -ne 2 ]]; then
  printf -- '--new-state --latest-state returned an unexpected status\n' >&2
  exit 1
fi
grep -Fq -- 'pi: --latest-state cannot be combined with --new-state' "$OUTPUT_LOG"
[[ ! -s "$DOCKER_LOG" ]]
[[ "$(cat "$REGISTRY/seed")" == "$FIRST_VOLUME" ]]

# The newest volume is the extra one, but --latest-state skips it.
run_wrapper "$WORKSPACE_E" --latest-state
FIFTH_VOLUME="$(target_volume)"
assert_source "$THIRD_VOLUME"
if grep -Fq -- "$FOURTH_VOLUME:/state-source:ro" "$DOCKER_LOG"; then
  printf 'extra state volume used as --latest-state source\n' >&2
  exit 1
fi
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
# A pre-marker volume holding auth or model settings is migrated in place.
grep -Fq -- 'state-initialization complete' "$DOCKER_LOG"

# Initialized volumes are recognized by their marker alone.
FAKE_STATE_MARKER=complete
FAKE_TARGET_HAS_USEFUL_STATE=false
run_wrapper "$WORKSPACE_F"
assert_no_source_copy
if grep -Fq -- 'state-initialization' "$DOCKER_LOG"; then
  printf 'initialized state was marked again:\n%s\n' "$(cat "$DOCKER_LOG")" >&2
  exit 1
fi

# An interrupted seed resumes from the source recorded in the pending marker,
# even though the seed pointer now names a different volume.
FAKE_STATE_MARKER=pending
FAKE_PENDING_SOURCE="$SECOND_VOLUME"
run_wrapper "$WORKSPACE_F"
assert_source "$SECOND_VOLUME"
grep -Fq -- "state-initialization pending $SECOND_VOLUME" "$DOCKER_LOG"
grep -Fq -- 'state-initialization complete' "$DOCKER_LOG"

# A pending seed whose recorded source vanished is refused, not restarted.
FAKE_PENDING_SOURCE=pi-agents-ws-gone_pi-agent-state
if run_wrapper "$WORKSPACE_F"; then
  printf 'pending seed with a missing source unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq -- 'pending agent-state initialization source is unavailable' "$OUTPUT_LOG"
assert_no_source_copy
grep -Fq -- ' up ' "$DOCKER_LOG" && { printf 'stack started despite unavailable pending source\n' >&2; exit 1; }
FAKE_STATE_MARKER=none
FAKE_PENDING_SOURCE=''

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
# A legacy seed pointer naming an extra state volume is discarded, and the
# extra volume is not proposed even though it is the oldest.
printf '%s\n' "$FOURTH_VOLUME" > "$RECOVERY_REGISTRY/seed"
FAKE_VOLUME_CREATED_ATS="$FOURTH_VOLUME|2026-07-01T12:00:00Z
$FAKE_VOLUME_CREATED_ATS"
if printf 'n\n' | run_wrapper_with_registry "$RECOVERY_REGISTRY" "$WORKSPACE_G"; then
  printf 'missing-seed confirmation unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq -- 'seed pointer was not found' "$OUTPUT_LOG"
grep -Fq -- "$FIRST_VOLUME" "$OUTPUT_LOG"
if grep -Fq -- "$FOURTH_VOLUME" "$OUTPUT_LOG"; then
  printf 'extra state volume proposed as seed\n' >&2
  exit 1
fi
# Every managed normal state volume is listed with its creation time before
# the warning and proposal.
EXPECTED_CANDIDATES="Managed Pi state volumes:
  $SECOND_VOLUME  (2026-08-02T12:00:00Z)
  $FIRST_VOLUME  (2026-08-01T12:00:00Z)
  $THIRD_VOLUME  (2026-08-03T12:00:00Z)
  $FIFTH_VOLUME  (2026-08-05T12:00:00Z)
  $SIXTH_VOLUME  (2026-08-06T12:00:00Z)
pi: warning: the seed pointer was not found."
if [[ "$(cat "$OUTPUT_LOG")" != *"$EXPECTED_CANDIDATES"* ]]; then
  printf 'missing-seed prompt did not list the candidates first:\n%s\n' "$(cat "$OUTPUT_LOG")" >&2
  exit 1
fi

# The prompt also accepts yes/YES, and still runs with --latest-state.
for answer in yes YES; do
  rm -f "$RECOVERY_REGISTRY/seed"
  printf '%s\n' "$answer" | run_wrapper_with_registry "$RECOVERY_REGISTRY" "$WORKSPACE_G" --latest-state
  grep -Fq -- 'seed pointer was not found' "$OUTPUT_LOG"
  [[ "$(cat "$RECOVERY_REGISTRY/seed")" == "$FIRST_VOLUME" ]]
done
rm -f "$RECOVERY_REGISTRY/seed"

printf 'y\n' | run_wrapper_with_registry "$RECOVERY_REGISTRY" "$WORKSPACE_G"
RECOVERED_VOLUME="$(target_volume)"
assert_source "$FIRST_VOLUME"
[[ "$(cat "$RECOVERY_REGISTRY/seed")" == "$FIRST_VOLUME" ]]

# Launching an already-initialized workspace while the pointer is missing, or
# names a volume that is gone, never silently makes it the seed: the pointer
# stays unset so the next new workspace gets the confirmation.
UNSET_REGISTRY="$TMP_DIR/unset-registry"
mkdir -p "$UNSET_REGISTRY"
FAKE_TARGET_VOLUME_NAME="$SIXTH_VOLUME"
FAKE_TARGET_VOLUME_EXISTS=true
FAKE_STATE_MARKER=complete
for stale_pointer in '' pi-agents-ws-gone_pi-agent-state; do
  rm -f "$UNSET_REGISTRY/seed"
  [[ -z "$stale_pointer" ]] || printf '%s\n' "$stale_pointer" > "$UNSET_REGISTRY/seed"
  run_wrapper_with_registry "$UNSET_REGISTRY" "$WORKSPACE_F" < /dev/null
  if [[ -s "$UNSET_REGISTRY/seed" ]]; then
    printf 'initialized workspace became the seed: %s\n' "$(cat "$UNSET_REGISTRY/seed")" >&2
    exit 1
  fi
  if grep -Fq -- 'seed pointer was not found' "$OUTPUT_LOG"; then
    printf 'initialized workspace prompted for a seed\n' >&2
    exit 1
  fi
done

# --seed still promotes it when the pointer is missing.
rm -f "$UNSET_REGISTRY/seed"
run_wrapper_with_registry "$UNSET_REGISTRY" "$WORKSPACE_F" --seed < /dev/null
[[ "$(cat "$UNSET_REGISTRY/seed")" == "$SIXTH_VOLUME" ]]
FAKE_STATE_MARKER=none
FAKE_TARGET_VOLUME_EXISTS=false

# State is created with labels, seeded and repaired before the service starts,
# for both a persistent launch and `pi update`.
ORDER_REGISTRY="$TMP_DIR/order-registry"
mkdir -p "$ORDER_REGISTRY"
FAKE_VOLUMES="$FIRST_VOLUME"
for workspace_and_command in "$WORKSPACE_H|" "$WORKSPACE_I|update"; do
  printf '%s\n' "$FIRST_VOLUME" > "$ORDER_REGISTRY/seed"
  workspace="${workspace_and_command%%|*}"
  command="${workspace_and_command#*|}"
  if [[ -n "$command" ]]; then
    WRAPPER_SUFFIX='' run_wrapper_with_registry "$ORDER_REGISTRY" "$workspace" "$command"
  else
    run_wrapper_with_registry "$ORDER_REGISTRY" "$workspace"
  fi
  assert_source "$FIRST_VOLUME"
  assert_log_order 'docker volume create' 'docker run '
  assert_log_order "$FIRST_VOLUME:/state-source:ro" ' up '
  assert_log_order 'state-initialization complete' ' up '
  assert_log_order 'chown -R 1000:1000 "$path"' ' up '
  assert_log_order ' up ' 'install npm:pi-agent-browser-native'
done

# Running a workspace on its extra volume never records it as the seed.
EMPTY_REGISTRY="$TMP_DIR/empty-registry"
mkdir -p "$EMPTY_REGISTRY"
FAKE_VOLUMES=''
run_wrapper_with_registry "$EMPTY_REGISTRY" "$WORKSPACE_G" --new-state
[[ "$(target_volume)" == pi-agents-new-ws-*_pi-agent-state ]]
[[ ! -s "$EMPTY_REGISTRY/seed" ]]

printf 'bin/pi state-lineage tests passed\n'
