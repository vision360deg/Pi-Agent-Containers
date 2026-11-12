#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN" "$TMP_DIR/workspace" "$TMP_DIR/home"
DOCKER_LOG="$TMP_DIR/docker.log"
OUTPUT_LOG="$TMP_DIR/output.log"
export DOCKER_LOG

workspace_hash() {
  printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 12)}'
}
# Alpha has an unused extra state volume; delta runs on its legacy extra
# volume, which still carries the normal agent kind label.
ALPHA_EXTRA="pi-agents-new-ws-$(workspace_hash /tmp/workspaces/alpha)_pi-agent-state"
DELTA_EXTRA="pi-agents-new-ws-$(workspace_hash /tmp/workspaces/delta)_pi-agent-state"
export ALPHA_EXTRA DELTA_EXTRA

cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >> "$DOCKER_LOG"

if [[ "${1:-}" == "ps" ]]; then
  if [[ "$#" -ne 6 || "$2" != "-a" || "$3" != "--filter" ||
    "$4" != "label=com.pi-agents.workspace" || "$5" != "--format" ||
    "$6" != '{{.ID}}' ]]; then
    printf 'incorrect docker ps invocation: %s\n' "$*" >&2
    exit 98
  fi
  if [[ "${FAKE_EMPTY-false}" == true ]]; then
    exit 0
  fi
  printf 'zeta-id\nunresolvable-id\nno-agent-state-id\ndelta-id\nalpha-id\n'
  exit 0
fi

if [[ "${1:-}" == "inspect" ]]; then
  if [[ "$#" -ne 5 || "$2" != "--format" || "$4" != "--" ||
    "$3" != *'.Name'* || "$3" != *'.State.Status'* ||
    "$3" != *'.Created'* || "$3" != *'.State.StartedAt'* ||
    "$3" != *'.Config.Labels'* || "$3" != *'.Mounts'* ||
    "$3" != *$'\037'* ]]; then
    printf 'incorrect docker inspect invocation: %s\n' "$*" >&2
    exit 98
  fi
  container="${@: -1}"
  case "$container" in
    alpha-id)
      printf '/pi-agents-pi-alpha\037running\0372026-08-08T08:00:00.000000000Z\0372026-08-08T09:15:00.000000000Z\037/tmp/workspaces/alpha\037\037pi-agents-ws-alpha_pi-agent-state\n'
      ;;
    delta-id)
      printf '/pi-agents-pi-delta\037running\0372026-08-08T07:00:00.000000000Z\0372026-08-08T07:30:00.000000000Z\037/tmp/workspaces/delta\037pi-agents-pi-delta\037%s\n' "$DELTA_EXTRA"
      ;;
    no-agent-state-id)
      printf '/pi-agents-pi-no-agent-state\037paused\0372026-08-08T09:00:00.000000000Z\0372026-08-08T09:30:00.000000000Z\037/tmp/workspaces/no-agent-state\037pi-agents-pi-no-agent-state\037\n'
      ;;
    unresolvable-id)
      printf '/pi-agents-pi-unresolvable\037created\0372026-08-08T09:30:00.000000000Z\0370001-01-01T00:00:00Z\037/tmp/workspaces/unresolvable\037pi-agents-pi-unresolvable\037pi-agents-ws-unresolvable_pi-agent-state\n'
      ;;
    zeta-id)
      printf '/pi-agents-pi-zeta\037exited\0372026-08-08T10:00:00.000000000Z\0370001-01-01T00:00:00Z\037/tmp/workspaces/zeta\037pi-agents-pi-zeta\037pi-agents-ws-zeta_pi-agent-state\n'
      ;;
    *)
      printf 'unexpected inspect target: %s\n' "$container" >&2
      exit 1
      ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "ls" ]]; then
  if [[ "$#" -ne 8 || "$3" != "--filter" ||
    "$4" != "label=com.pi-agents.managed=true" || "$5" != "--filter" ||
    "$6" != "label=com.pi-agents.state-kind=agent" || "$7" != "--format" ||
    "$8" != '{{.Name}}' ]]; then
    printf 'incorrect docker volume ls invocation: %s\n' "$*" >&2
    exit 98
  fi
  printf 'pi-agents-ws-alpha_pi-agent-state\npi-agents-ws-zeta_pi-agent-state\n%s\n' "$DELTA_EXTRA"
  exit 0
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "inspect" ]]; then
  if [[ "$#" -eq 3 ]]; then
    volume="$3"
  elif [[ "$#" -eq 5 && "$3" == "--format" && "$4" == '{{.CreatedAt}}' ]]; then
    volume="$5"
  else
    printf 'incorrect docker volume inspect invocation: %s\n' "$*" >&2
    exit 98
  fi

  case "$volume" in
    pi-agents-ws-alpha_pi-agent-state)
      [[ "$#" -eq 5 ]] && printf '2026-08-08T12:30:00Z\n'
      ;;
    pi-agents-ws-zeta_pi-agent-state)
      [[ "$#" -eq 5 ]] && printf '2026-08-08T13:30:00Z\n'
      ;;
    "$ALPHA_EXTRA")
      [[ "$#" -eq 5 ]] && printf '2026-08-09T12:30:00Z\n'
      ;;
    "$DELTA_EXTRA")
      [[ "$#" -eq 5 ]] && printf '2026-08-09T13:30:00Z\n'
      ;;
    pi-agents-new-ws-*)
      exit 1
      ;;
    pi-agents-ws-unresolvable_pi-agent-state)
      exit 1
      ;;
    *)
      printf 'unexpected volume inspect target: %s\n' "$volume" >&2
      exit 1
      ;;
  esac
  exit 0
fi

printf 'Docker command is not in the read-only list whitelist: %s\n' "$*" >&2
exit 99
FAKE_DOCKER
chmod +x "$FAKE_BIN/docker"

run_wrapper() {
  : > "$DOCKER_LOG"
  : > "$OUTPUT_LOG"
  (
    cd "$TMP_DIR/workspace"
    if [[ -n "${INHERITED_PI_WORKSPACE+x}" ]]; then
      env PI_WORKSPACE="$INHERITED_PI_WORKSPACE" \
        PI_AGENT_CONTAINERS_CONFIG_PATH="$TMP_DIR/state-registry" \
        HOME="$TMP_DIR/home" \
        FAKE_EMPTY="${FAKE_EMPTY-false}" \
        PATH="$FAKE_BIN:$PATH" "$ROOT/bin/pi" "$@"
    else
      env -u PI_WORKSPACE \
        PI_AGENT_CONTAINERS_CONFIG_PATH="$TMP_DIR/state-registry" \
        HOME="$TMP_DIR/home" \
        FAKE_EMPTY="${FAKE_EMPTY-false}" \
        PATH="$FAKE_BIN:$PATH" "$ROOT/bin/pi" "$@"
    fi
  ) >"$OUTPUT_LOG" 2>&1
}

assert_output() {
  local expected="$1"
  local actual
  actual="$(cat "$OUTPUT_LOG")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'unexpected output:\nexpected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

assert_no_docker_calls() {
  if [[ -s "$DOCKER_LOG" ]]; then
    printf 'unexpected Docker calls:\n%s\n' "$(cat "$DOCKER_LOG")" >&2
    exit 1
  fi
}

assert_read_only_docker_calls() {
  local call
  while IFS= read -r call; do
    case "$call" in
      'docker ps '*|'docker inspect '*|'docker volume ls '*|'docker volume inspect '*) ;;
      *)
        printf 'pi list invoked a command outside the read-only Docker whitelist:\n%s\n' \
          "$(cat "$DOCKER_LOG")" >&2
        exit 1
        ;;
    esac
  done < "$DOCKER_LOG"
}

stack_block() {
  printf 'STACK: %s\n  status: %s\n  workspace: %s\n  project: %s\n  created: %s\n  started: %s\n  agent-state: %s\n  active-state: %s\n  extra-state: %s\n  markers: %s\n' "$@"
}

expected_list() {
  local alpha_markers="$1" zeta_markers="$2"
  stack_block pi-agents-pi-alpha running /tmp/workspaces/alpha '' \
    2026-08-08T08:00:00.000000000Z 2026-08-08T09:15:00.000000000Z \
    pi-agents-ws-alpha_pi-agent-state normal "$ALPHA_EXTRA" "$alpha_markers"
  stack_block pi-agents-pi-delta running /tmp/workspaces/delta pi-agents-pi-delta \
    2026-08-08T07:00:00.000000000Z 2026-08-08T07:30:00.000000000Z \
    "$DELTA_EXTRA" extra "$DELTA_EXTRA" -
  stack_block pi-agents-pi-no-agent-state paused /tmp/workspaces/no-agent-state pi-agents-pi-no-agent-state \
    2026-08-08T09:00:00.000000000Z 2026-08-08T09:30:00.000000000Z none none none -
  stack_block pi-agents-pi-unresolvable created /tmp/workspaces/unresolvable pi-agents-pi-unresolvable \
    2026-08-08T09:30:00.000000000Z never none none none -
  stack_block pi-agents-pi-zeta exited /tmp/workspaces/zeta pi-agents-pi-zeta \
    2026-08-08T10:00:00.000000000Z never pi-agents-ws-zeta_pi-agent-state normal none "$zeta_markers"
}

mkdir -p "$TMP_DIR/state-registry"
printf '%s\n' 'pi-agents-ws-alpha_pi-agent-state' > "$TMP_DIR/state-registry/seed"
run_wrapper list

# Delta's extra volume is newer than every normal volume yet is never latest.
expected_alpha_seed="$(expected_list seed latest)"
assert_output "$expected_alpha_seed"
assert_read_only_docker_calls

printf '%s\n' 'pi-agents-ws-zeta_pi-agent-state' > "$TMP_DIR/state-registry/seed"
run_wrapper list
assert_output "$(expected_list - 'seed, latest')"
assert_read_only_docker_calls

# A legacy seed pointer naming an extra volume is not shown as the seed.
printf '%s\n' "$DELTA_EXTRA" > "$TMP_DIR/state-registry/seed"
run_wrapper list
assert_output "$(expected_list - latest)"
assert_read_only_docker_calls

printf '%s\n' 'pi-agents-ws-alpha_pi-agent-state' > "$TMP_DIR/state-registry/seed"
INHERITED_PI_WORKSPACE=/missing
run_wrapper list
unset INHERITED_PI_WORKSPACE
assert_output "$expected_alpha_seed"
assert_read_only_docker_calls

if run_wrapper list extra; then
  printf 'pi list extra unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
fi
[[ "$status" -eq 2 ]]
assert_output 'usage: pi list'
assert_no_docker_calls

if run_wrapper --rm list; then
  printf 'pi --rm list unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
fi
[[ "$status" -eq 2 ]]
assert_output 'usage: pi list'
assert_no_docker_calls

export FAKE_EMPTY=true
run_wrapper list
assert_output 'No Pi stacks found.'
assert_read_only_docker_calls

printf 'bin/pi list tests passed\n'
